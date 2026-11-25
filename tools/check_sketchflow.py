import json, pathlib, sys, time
import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw
root = pathlib.Path(sys.argv[1])
export_outlines = '--outlines' in sys.argv[2:]
categories = [value for value in sys.argv[2:] if value != '--outlines'] or ['rabbit', 'firetruck']
config = json.loads((root / 'sketchflow.json').read_text())
options = ort.SessionOptions()
options.intra_op_num_threads = 3
session = ort.InferenceSession(str(root / 'sketchflow.onnx'), sess_options=options, providers=['CPUExecutionProvider'])
gallery = Image.new('RGB', (900, 300 * len(categories)), '#fff7e8')
canvas = ImageDraw.Draw(gallery)
outlines = []
for row, category in enumerate(categories):
    condition = np.array([config['conditions'][category]], dtype=np.float32)
    for column, seed in enumerate([1,2,3]):
        rng = np.random.default_rng(seed)
        x = rng.standard_normal((1,256,3), dtype=np.float32)
        start = time.perf_counter()
        for t, alpha, a, b, std in config['steps']:
            pred = session.run(None,dict(points=x, timestep=np.array([t],dtype=np.int64), condition=condition))[0]
            x = (a * ((x-(1-alpha)**.5*pred)/alpha**.5)+b*x+std*rng.standard_normal(x.shape,dtype=np.float32)).astype(np.float32)
        assert np.isfinite(x).all()
        x=x[0]
        valid=x[1:,2] > config['penScale']/2
        assert int(valid.sum())>7
        coords = x[:,:2]
        chosen = np.concatenate((coords[1:][valid],coords[:-1][valid]))
        span = np.ptp(chosen,axis=0).max()
        normalized = (coords-(chosen.min(axis=0)+chosen.max(axis=0))/2) / span
        if export_outlines:
            strokes = []
            for i in range(1, len(normalized)):
                if not valid[i - 1]:
                    continue
                if i == 1 or not valid[i - 2]:
                    strokes.append([(normalized[i - 1] * .85 + .5).tolist()])
                strokes[-1].append((normalized[i] * .85 + .5).tolist())
            outlines.append({'id': category, 'seed': seed, 'strokes': strokes})
        coords = normalized * 220 + [150+column*300, 150+row*300]
        for i in range(1,len(coords)):
            if valid[i-1]:
                canvas.line([tuple(coords[i-1]),tuple(coords[i])], fill='#332a22', width=3)
        canvas.text((25+column*300,15+row*300), f'{category} / seed {seed}',fill='#332a22')
        print(category,seed,int(valid.sum()),round(time.perf_counter()-start,2),flush=True)
gallery.save(root/'generated-preview.png')
if export_outlines:
    (root/'generated-outlines.json').write_text(json.dumps(outlines), encoding='utf-8')
