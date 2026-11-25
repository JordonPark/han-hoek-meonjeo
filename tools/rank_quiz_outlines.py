"""Rank Quick, Draw! categories by the coarse outlines of their quiz drawings."""

import csv
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


def outline(drawing, prefix=1.0):
    strokes = [np.array(axes, dtype=float).T for axes in drawing]
    points = np.concatenate(strokes)
    extent = np.ptp(points, axis=0).max()
    center = (points.min(axis=0) + points.max(axis=0)) / 2
    image = Image.new('L', (64, 64))
    pen = ImageDraw.Draw(image)
    total = sum(np.linalg.norm(np.diff(stroke, axis=0), axis=1).sum() for stroke in strokes)
    remaining = total * prefix
    for stroke in strokes:
        scaled = (stroke - center) / max(1, extent) * 52 + 32
        for i, length in enumerate(np.linalg.norm(np.diff(stroke, axis=0), axis=1)):
            if remaining <= 0:
                break
            if length == 0:
                continue
            end = scaled[i] + min(1, remaining / length) * (scaled[i + 1] - scaled[i])
            pen.line([tuple(scaled[i]), tuple(end)], fill=255, width=3)
            remaining -= length
    small = image.filter(ImageFilter.GaussianBlur(2)).resize((16, 16), Image.Resampling.LANCZOS)
    return np.asarray(small, dtype=np.float32).ravel()


def unit(features):
    return features / np.maximum(1, np.linalg.norm(features, axis=-1, keepdims=True))


def main():
    assets = Path(__file__).resolve().parents[1] / 'assets'
    questions = json.loads((assets / 'questions.json').read_text(encoding='utf-8'))
    labels = [question['id'] for question in questions]
    drawings = [question['drawings'] for question in questions]
    vectors = unit(np.array([[outline(example) for example in category] for category in drawings]))
    prototypes = unit(vectors.mean(axis=1))
    pairs = (vectors.reshape(-1, 256) @ vectors.reshape(-1, 256).T).reshape(len(labels), 6, len(labels), 6)
    similarity = pairs.max(axis=3).mean(axis=1)
    result = {}
    review = []
    labels_ko = {question['id']: question['label'] for question in questions}
    semantic = json.loads((assets / 'related_questions.json').read_text(encoding='utf-8'))
    for i, label in enumerate(labels):
        neighbors = [labels[j] for j in np.argsort(-similarity[i], kind='stable') if j != i][:24]
        early = unit(np.array([outline(example, prefix=.45) for example in drawings[i]]))
        scores = early @ prototypes.T
        own = scores[:, i].copy()
        scores[:, i] = 0
        opening = int(np.argmax(own - scores.max(axis=1) + vectors[i] @ prototypes[i] * .4))
        complete = vectors[i] @ prototypes.T
        own_complete = complete[:, i].copy()
        complete[:, i] = 0
        sample_neighbors = pairs[i].max(axis=-1)
        visual = []
        ambiguous = []
        for sample, scores_by_label in enumerate(sample_neighbors):
            order = [j for j in np.argsort(-scores_by_label, kind='stable') if j != i]
            visual.append([labels[j] for j in order[:12]])
            ambiguous.append([labels[j] for j in order
                              if scores_by_label[j] >= max(.90, own_complete[sample] + .05)])
        result[label] = {'similar': neighbors, 'opening': opening,
                         'visualByDrawing': visual, 'ambiguousByDrawing': ambiguous}
        review.append([
            label, labels_ko[label], opening + 1,
            f'{own[opening] - scores[opening].max():.3f}',
            f'{own_complete[opening] - complete[opening].max():.3f}',
            ', '.join(labels_ko[value] for value in semantic[label][:5]),
            ', '.join(labels_ko[value] for value in neighbors[:5]),
        ])
    data = '{\n' + ',\n'.join(f'  {json.dumps(label)}: {json.dumps(value)}' for label, value in result.items()) + '\n}\n'
    (assets / 'outline_questions.json').write_text(data, encoding='utf-8')
    docs = assets.parent / 'docs'
    docs.mkdir(exist_ok=True)
    with (docs / 'quiz-level-review.csv').open('w', encoding='utf-8-sig', newline='') as handle:
        writer = csv.writer(handle, lineterminator='\n')
        writer.writerow([
            '제시어 ID', '제시어', '첫 문제 샘플 번호', '초반 윤곽 여유', '완성 윤곽 여유',
            '의미 유사 후보', '윤곽 유사 후보', '친숙도 검수', '구분 특징', 'AI 생성 검수',
        ])
        writer.writerows(row + ['', '', ''] for row in review)


if __name__ == '__main__':
    main()
