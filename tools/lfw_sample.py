"""
Writes a small face-calibration set from Labeled Faces in the Wild (LFW), used ONLY in CI
to measure face-grouping thresholds. Never bundled with the app.

  python3 tools/lfw_sample.py <out_dir> [people=12] [per_person=8]

Layout: <out_dir>/<person_name>/<n>.jpg  (full 250x250 LFW frames, so the app's own
Vision detection + alignment pipeline runs on them)
"""
import os, sys
import numpy as np
from PIL import Image
from sklearn.datasets import fetch_lfw_people

out = sys.argv[1]; people = int(sys.argv[2]) if len(sys.argv) > 2 else 12; per = int(sys.argv[3]) if len(sys.argv) > 3 else 8
lfw = fetch_lfw_people(min_faces_per_person=per, resize=1.0, slice_=None, color=True, funneled=False)
names = lfw.target_names
rng = np.random.default_rng(1)
chosen = rng.choice(len(names), size=min(people, len(names)), replace=False)
total = 0
for t in chosen:
    idx = np.where(lfw.target == t)[0][:per]
    d = os.path.join(out, names[t].replace(" ", "_"))
    os.makedirs(d, exist_ok=True)
    for k, i in enumerate(idx):
        img = lfw.images[i]
        img = (img * 255 if img.max() <= 1.0 else img).clip(0, 255).astype(np.uint8)
        Image.fromarray(img).save(os.path.join(d, f"{k}.jpg"), quality=95)
        total += 1
print(f"wrote {total} images for {len(chosen)} people to {out}")
