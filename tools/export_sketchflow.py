"""Export the official SketchFlow decoder and quiz vocabulary for mobile ONNX."""

import argparse
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import onnxruntime as ort
import torch


class Decoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, points, timestep, condition):
        return self.model.predict(points, timestep, cond_vec=condition)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='Official SketchFlow checkout')
    parser.add_argument('checkpoint', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(args.source.resolve()))
    from model.sketchflow_model import SketchFlowModel
    from utils.clip_manager import get_clip_manager

    with args.checkpoint.open('rb') as handle:
        digest = hashlib.file_digest(handle, 'sha256').hexdigest()
    if digest != '899f5a32e72acb349ab70cfbe2cac068faa4b05bc54d47ccbd97624087279dbf':
        raise ValueError('Expected the official SketchFlow v1 checkpoint')

    args.output.mkdir(parents=True, exist_ok=True)
    torch.manual_seed(42)
    torch.set_num_threads(4)
    torch.backends.mha.set_fastpath_enabled(False)
    model = SketchFlowModel(
        idx_mode='binary', extra_scale=0.1, loss_mode='mse_denoised',
        sample_dir=args.output / 'samples',
    ).eval()
    checkpoint = torch.load(args.checkpoint, map_location='cpu', weights_only=True)
    model.load_state_dict(checkpoint.get('state_dict', checkpoint), strict=True)
    del checkpoint
    decoder = Decoder(model.model).eval()
    inputs = (torch.randn(1, 256, 3), torch.tensor([960]), torch.randn(1, 512))
    graph = args.output / 'sketchflow.onnx'
    names = ['points', 'timestep', 'condition']
    with torch.no_grad():
        torch.onnx.export(decoder, inputs, graph, input_names=names,
                          output_names=['noise'], opset_version=17, dynamo=False)
        options = ort.SessionOptions()
        options.intra_op_num_threads = 4
        session = ort.InferenceSession(str(graph), sess_options=options,
                                       providers=['CPUExecutionProvider'])
        result = session.run(None, dict(zip(names, (x.numpy() for x in inputs))))[0]
        np.testing.assert_allclose(result, decoder(*inputs).numpy(), atol=0.01, rtol=0.001)

        data_path = Path(__file__).resolve().parents[1] / 'assets' / 'questions.json'
        categories = [row['id'] for row in json.loads(data_path.read_text(encoding='utf-8'))]
        device = 'cuda' if torch.cuda.is_available() else 'cpu'
        clip = get_clip_manager(device=device)
        model.latent_conditioner.to(device)
        encoded = {}
        for start in range(0, len(categories), 32):
            words = categories[start:start + 32]
            features = clip.encode_text(words)
            shifted = model.latent_conditioner.shift(features, steps=60, variance_scale=1)
            encoded.update(zip(words, shifted.cpu().tolist()))

    model.scheduler.set_timesteps(60)
    steps = []
    for t in model.scheduler.timesteps:
        previous = model.scheduler.previous_timestep(t)
        alpha = model.scheduler.alphas_cumprod[t]
        prior = model.scheduler.alphas_cumprod[previous] if previous >= 0 else model.scheduler.one
        beta = 1 - alpha / prior
        steps.append([
            int(t), float(alpha),
            float(prior.sqrt() * beta / (1 - alpha)),
            float((alpha / prior).sqrt() * (1 - prior) / (1 - alpha)),
            float(((1 - prior) / (1 - alpha) * beta).sqrt()) if t > 0 else 0,
        ])
    manifest = {'steps': steps, 'conditions': encoded, 'penScale': model.extra_scale}
    (args.output / 'sketchflow.json').write_text(json.dumps(manifest, separators=(',', ':')))


if __name__ == '__main__':
    main()
