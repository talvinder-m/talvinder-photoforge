"""
FSRCNN super-resolution → Core ML, for PhotoForge's "Upscale to 2K".

  python3 tools/convert_fsrcnn.py <out_dir> [faces_dir_for_quality_check]

Source: FSRCNN_x{2,3,4}.pb from github.com/Saafke/FSRCNN_Tensorflow (the models OpenCV's
dnn_superres uses). Weights are read through OpenCV's TensorFlow importer, rebuilt as a
PyTorch module, and verified against OpenCV's own forward pass before conversion.

Each Core ML model:  input "y" [1,1,T,T] float32, luma in 0…1  →  output "sr" [1,1,sT,sT]
with T = TILE (fixed tile; the app tiles larger images with overlap).
"""
import os, sys, urllib.request, itertools
import numpy as np
import cv2
import torch, torch.nn as nn
import coremltools as ct

TILE = 128
out_dir = sys.argv[1] if len(sys.argv) > 1 else "build/sr"
faces_dir = sys.argv[2] if len(sys.argv) > 2 else None
os.makedirs(out_dir, exist_ok=True)
BASE = "https://github.com/Saafke/FSRCNN_Tensorflow/raw/master/models/"

try:
    lic = urllib.request.urlopen("https://raw.githubusercontent.com/Saafke/FSRCNN_Tensorflow/master/LICENSE", timeout=30).read().decode()
    print("LICENSE (first lines):\n" + "\n".join(lic.splitlines()[:4]))
except Exception as e:
    print("could not fetch LICENSE:", e)


def psnr(a, b):
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    return 99.0 if mse == 0 else 10 * np.log10(1.0 / mse)


class FSRCNN(nn.Module):
    def __init__(self, layers):
        super().__init__()
        self.body = nn.Sequential(*layers)

    def forward(self, x):
        return self.body(x)


class DeconvCrop(nn.Module):
    """Transposed conv with no padding, then a crop to exactly scale×input at `off`.
    Searching `off` covers every framework's padding/alignment convention."""
    def __init__(self, deconv, scale, off):
        super().__init__()
        self.d, self.s, self.off = deconv, scale, off

    def forward(self, x):
        h, w = x.shape[-2] * self.s, x.shape[-1] * self.s
        y = self.d(x)
        return y[:, :, self.off:self.off + h, self.off:self.off + w]


def build(net, scale, variant):
    """Rebuild the OpenCV-imported graph as torch layers, in network order."""
    off, w_mode = variant
    mods, prev_c = [], 1
    for name in net.getLayerNames():
        L = net.getLayer(net.getLayerId(name))
        t, blobs = L.type, [np.array(b) for b in L.blobs]
        if t == "Convolution":
            w = blobs[0]
            k = w.shape[-1]
            c = nn.Conv2d(w.shape[1], w.shape[0], k, padding=k // 2)
            c.weight.data = torch.from_numpy(w.copy()).float()
            c.bias.data = torch.from_numpy(blobs[1].ravel().copy()).float() if len(blobs) > 1 else torch.zeros(w.shape[0])
            mods.append(c); prev_c = w.shape[0]
        elif t in ("PReLU", "ReLU") and blobs:
            slope = blobs[0].ravel()
            pr = nn.PReLU(num_parameters=len(slope))
            pr.weight.data = torch.from_numpy(slope.copy()).float()
            mods.append(pr)
        elif t == "ReLU":
            mods.append(nn.ReLU())
        elif t == "Deconvolution":
            w = blobs[0]
            k = w.shape[-1]
            tw = w if w.shape[0] == prev_c else np.transpose(w, (1, 0, 2, 3))   # torch: (in, out, k, k)
            if w_mode == "flip":
                tw = tw[:, :, ::-1, ::-1]
            d = nn.ConvTranspose2d(tw.shape[0], tw.shape[1], k, stride=scale, padding=0)
            d.weight.data = torch.from_numpy(np.ascontiguousarray(tw)).float()
            d.bias.data = torch.from_numpy(blobs[1].ravel().copy()).float() if len(blobs) > 1 else torch.zeros(tw.shape[1])
            mods.append(DeconvCrop(d, scale, off))
        elif t in ("Identity", "Permute", "Reshape", "Flatten", "Const"):
            continue
        else:
            print(f"   note: skipping layer {name} of type {t} with blobs {[b.shape for b in blobs]}")
    return FSRCNN(mods).eval()


summary = []
for scale in (2, 3, 4):
    pb = os.path.join(out_dir, f"FSRCNN_x{scale}.pb")
    if not os.path.exists(pb):
        urllib.request.urlretrieve(BASE + f"FSRCNN_x{scale}.pb", pb)
    print(f"\n== FSRCNN x{scale}: {os.path.getsize(pb)} bytes")
    net = cv2.dnn.readNetFromTensorflow(pb)
    for name in net.getLayerNames():
        L = net.getLayer(net.getLayerId(name))
        print(f"   {name:40s} {L.type:15s} {[tuple(np.array(b).shape) for b in L.blobs]}")

    rng = np.random.default_rng(scale)
    # Smooth-ish random luma patch (natural-image-like), 0..1
    y = np.clip(cv2.GaussianBlur(rng.random((TILE, TILE)).astype(np.float32), (0, 0), 2.0) * 2 - 0.5, 0, 1).astype(np.float32)
    net.setInput(y[None, None])
    ref = net.forward()[0, 0]
    print(f"   OpenCV output {ref.shape}")

    best = None
    for variant in itertools.product(range(0, 9), ("plain", "flip")):
        try:
            m = build(net, scale, variant)
            with torch.no_grad():
                got = m(torch.from_numpy(y)[None, None]).numpy()[0, 0]
            if got.shape != ref.shape:
                continue
            p = psnr(np.clip(got, 0, 1), np.clip(ref, 0, 1))
            if best is None or p > best[0]:
                best = (p, variant, m)
        except Exception as e:
            print("   variant", variant, "failed:", e)
    assert best is not None, "no variant reproduced OpenCV's output shape"
    p, variant, model = best
    print(f"   rebuilt network matches OpenCV: PSNR {p:.1f} dB (deconv variant {variant})")
    assert p > 45, "rebuilt network does not match OpenCV"

    traced = torch.jit.trace(model, torch.rand(1, 1, TILE, TILE))
    ml = ct.convert(traced, inputs=[ct.TensorType(name="y", shape=(1, 1, TILE, TILE), dtype=np.float32)],
                    outputs=[ct.TensorType(name="sr", dtype=np.float32)], convert_to="mlprogram",
                    compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.macOS13)
    ml.short_description = f"FSRCNN x{scale} super-resolution on luma (Dong et al. 2016; weights: Saafke/FSRCNN_Tensorflow)"
    ml.version = "1"
    path = os.path.join(out_dir, f"FSRCNN_x{scale}.mlpackage")
    ml.save(path)
    cm = np.asarray(ml.predict({"y": y[None, None]})["sr"])[0, 0]
    pc = psnr(np.clip(cm, 0, 1), np.clip(ref, 0, 1))
    print(f"   Core ML vs OpenCV: PSNR {pc:.1f} dB")
    assert pc > 45, "Core ML conversion mismatch"

    # Quality vs bicubic on real photos (optional)
    if faces_dir and os.path.isdir(faces_dir):
        gains = []
        files = [os.path.join(r, f) for r, _, fs in os.walk(faces_dir) for f in fs if f.endswith(".jpg")][:40]
        for f in files:
            img = cv2.imread(f)
            h, w = (img.shape[0] // scale) * scale, (img.shape[1] // scale) * scale
            img = img[:h, :w]
            Y = cv2.cvtColor(img, cv2.COLOR_BGR2YCrCb)[:, :, 0].astype(np.float32) / 255
            small = cv2.resize(Y, (w // scale, h // scale), interpolation=cv2.INTER_CUBIC)
            bic = cv2.resize(small, (w, h), interpolation=cv2.INTER_CUBIC)
            with torch.no_grad():
                sr = model(torch.from_numpy(small)[None, None]).numpy()[0, 0][:h, :w]
            b = 6  # ignore borders
            gains.append(psnr(np.clip(sr, 0, 1)[b:-b, b:-b], Y[b:-b, b:-b]) - psnr(np.clip(bic, 0, 1)[b:-b, b:-b], Y[b:-b, b:-b]))
        print(f"   quality on {len(gains)} real photos: FSRCNN beats bicubic by {np.mean(gains):+.2f} dB PSNR on average (min {np.min(gains):+.2f})")
        summary.append((scale, float(np.mean(gains))))

print("\nSUMMARY", summary)
print("CONVERSION OK")
