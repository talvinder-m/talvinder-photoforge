"""
Convert the pretrained FSRCNN super-resolution models (Saafke/FSRCNN_Tensorflow, Apache-2.0;
the same models OpenCV's dnn_superres uses) to Core ML, verify them, and benchmark them.

  python3 tools/convert_fsrcnn.py <out_dir>

For each scale s in (2, 3, 4) this writes <out_dir>/SR_x{s}.mlpackage with
  input  "y":    Float32 [1, 1, 128, 128]   luma (Y of YCbCr, BT.601), range 0…1
  output "y_sr": Float32 [1, 1, 128·s, 128·s]
The app processes images in overlapping 128×128 tiles, so a fixed shape is all it needs,
and memory stays bounded on small Macs.

Steps: download .pb → read weights with TensorFlow → rebuild FSRCNN in PyTorch →
check PyTorch == TensorFlow on random input → convert to Core ML → check Core ML == PyTorch →
report PSNR gain over bicubic on real photos (scikit-learn sample images).
"""
import hashlib, math, os, sys, urllib.request
import numpy as np

TILE = 128
out = sys.argv[1] if len(sys.argv) > 1 else "build/models"
os.makedirs(out, exist_ok=True)

import tensorflow as tf
import torch, torch.nn as nn, torch.nn.functional as F
import coremltools as ct
from PIL import Image

tf.compat.v1.disable_eager_execution()


def fetch(scale):
    path = os.path.join(out, f"FSRCNN_x{scale}.pb")
    if not os.path.exists(path):
        url = f"https://github.com/Saafke/FSRCNN_Tensorflow/raw/master/models/FSRCNN_x{scale}.pb"
        print("downloading", url)
        urllib.request.urlretrieve(url, path)
    data = open(path, "rb").read()
    print(f"FSRCNN_x{scale}.pb: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
    assert len(data) > 20_000, "download looks wrong"
    return path


def load_tf(path):
    gd = tf.compat.v1.GraphDef()
    gd.ParseFromString(open(path, "rb").read())
    g = tf.Graph()
    with g.as_default():
        tf.compat.v1.import_graph_def(gd, name="")
    sess = tf.compat.v1.Session(graph=g)
    ops = g.get_operations()
    inp = [o for o in ops if o.type == "Placeholder"]
    assert len(inp) == 1, f"expected one placeholder, got {[o.name for o in inp]}"
    # Output: the last op that produces a float tensor and is not consumed by anything.
    consumed = {t.name for o in ops for t in o.inputs}
    outs = [o for o in ops if o.outputs and o.outputs[0].name not in consumed and o.type not in ("Const", "NoOp", "Placeholder")]
    print("  placeholder:", inp[0].name, inp[0].outputs[0].shape, "| candidate outputs:", [o.name for o in outs][-3:])
    return sess, inp[0].outputs[0], outs[-1].outputs[0], ops


def extract(sess, ops):
    """Returns conv weights, biases, PReLU slopes, and the upsampling stage.
    The graph upsamples either with a transposed conv (Conv2DBackpropInput) or with a
    final conv producing s² channels followed by DepthToSpace (sub-pixel shuffle)."""
    print("  op types:", sorted({o.type for o in ops}))
    convs = [o for o in ops if o.type == "Conv2D"]
    deconvs = [o for o in ops if o.type == "Conv2DBackpropInput"]
    d2s = [o for o in ops if o.type == "DepthToSpace"]
    W = [sess.run(o.inputs[1]) for o in convs]                       # [kh, kw, in, out]
    if deconvs:
        assert len(deconvs) == 1, f"expected one transposed conv, got {len(deconvs)}"
        D = sess.run(deconvs[0].inputs[1])                           # [kh, kw, out, in]
        mode = "deconv"
    else:
        assert len(d2s) == 1, "no upsampling op found"
        D = W.pop()                                                  # last conv feeds DepthToSpace
        mode = "shuffle"
    # Biases: second input of BiasAdd, or a 1-D constant added after a conv.
    biases = []
    for o in ops:
        if o.type == "BiasAdd":
            biases.append(sess.run(o.inputs[1]))
        elif o.type in ("Add", "AddV2") and any(i.op.type in ("Conv2D", "Conv2DBackpropInput") for i in o.inputs):
            other = [i for i in o.inputs if i.op.type not in ("Conv2D", "Conv2DBackpropInput")][0]
            biases.append(sess.run(other))
    # PReLU slopes: 1-D variables whose names mention alpha.
    alphas = []
    seen = set()
    for o in ops:
        if "alpha" in o.name.lower() and o.type in ("Const", "VariableV2", "Identity") and o.outputs:
            base = o.name.split("/")[0]
            if base in seen: continue
            v = sess.run(o.outputs[0])
            if v.ndim == 1:
                alphas.append(v); seen.add(base)
    print("  convs:", [w.shape for w in W], "| deconv:", D.shape, "| biases:", [b.shape for b in biases],
          "| alphas:", [a.shape for a in alphas])
    print("  upsampling:", mode)
    assert len(biases) == len(W) + 1, "bias count mismatch"
    assert len(alphas) == len(W), "PReLU count mismatch"
    return W, biases, alphas, D, mode


class FSRCNN(nn.Module):
    def __init__(self, W, biases, alphas, D, scale, mode="deconv"):
        super().__init__()
        self.scale = scale
        self.convs = nn.ModuleList()
        for w, b in zip(W, biases[:-1]):
            k, cin, cout = w.shape[0], w.shape[2], w.shape[3]
            c = nn.Conv2d(cin, cout, k, padding=k // 2)
            c.weight.data = torch.from_numpy(np.ascontiguousarray(w.transpose(3, 2, 0, 1)))
            c.bias.data = torch.from_numpy(b.copy())
            self.convs.append(c)
        self.alphas = nn.ParameterList([nn.Parameter(torch.from_numpy(a.reshape(1, -1, 1, 1).copy())) for a in alphas])
        self.mode = mode
        if mode == "deconv":
            k, cout, cin = D.shape[0], D.shape[2], D.shape[3]
            self.k = k
            self.deconv = nn.ConvTranspose2d(cin, cout, k, stride=scale, padding=0, bias=True)
            self.deconv.weight.data = torch.from_numpy(np.ascontiguousarray(D.transpose(3, 2, 0, 1)))
            self.deconv.bias.data = torch.from_numpy(biases[-1].copy())
            self.crop = (k - scale) // 2          # TensorFlow 'SAME' transposed-conv alignment
        else:
            # conv → s² channels → pixel shuffle. With one output channel, TF DepthToSpace and
            # torch PixelShuffle use the same channel order (dy·s + dx).
            # The graph adds its final bias *after* DepthToSpace (one output channel).
            k, cin, cout = D.shape[0], D.shape[2], D.shape[3]
            self.up = nn.Conv2d(cin, cout, k, padding=k // 2, bias=False)
            self.up.weight.data = torch.from_numpy(np.ascontiguousarray(D.transpose(3, 2, 0, 1)))
            self.shuffle = nn.PixelShuffle(scale)
            self.post_bias = nn.Parameter(torch.from_numpy(biases[-1].reshape(1, -1, 1, 1).copy()))

    def forward(self, x):
        H, Wd = x.shape[2], x.shape[3]
        for c, a in zip(self.convs, self.alphas):
            x = c(x)
            x = F.relu(x) + a * torch.clamp(x, max=0)      # PReLU
        if self.mode == "shuffle":
            return self.shuffle(self.up(x)) + self.post_bias
        y = self.deconv(x)
        return y[:, :, self.crop:self.crop + H * self.scale, self.crop:self.crop + Wd * self.scale]


def psnr(a, b):
    mse = np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2)
    return 99.0 if mse == 0 else 10 * math.log10(255.0 ** 2 / mse)


def luma(img):
    a = np.asarray(img.convert("RGB")).astype(np.float32)
    return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def upscale_tiled(model, y01, scale):
    """Same tiling scheme as the app (Upscaler.swift): 128px tiles, 12px overlap."""
    O = 12; step = TILE - 2 * O
    H, W = y01.shape
    padded = np.pad(y01, ((O, O + TILE), (O, O + TILE)), mode="edge")
    outp = np.zeros((H * scale, W * scale), np.float32)
    for ty in range(0, H, step):
        for tx in range(0, W, step):
            tile = padded[ty:ty + TILE, tx:tx + TILE]
            r = model(torch.from_numpy(tile[None, None].copy())).detach().numpy()[0, 0]
            h = min(step, H - ty); w = min(step, W - tx)
            outp[ty * scale:(ty + h) * scale, tx * scale:(tx + w) * scale] = \
                r[O * scale:(O + h) * scale, O * scale:(O + w) * scale]
    return outp


from sklearn.datasets import load_sample_images
samples = [Image.fromarray(a) for a in load_sample_images().images]

for scale in (2, 3, 4):
    print(f"\n== x{scale}")
    sess, x_in, y_out, ops = load_tf(fetch(scale))
    W, B, A, D, mode = extract(sess, ops)
    model = FSRCNN(W, B, A, D, scale, mode).eval()

    # 1. PyTorch rebuild == TensorFlow original
    x = np.random.default_rng(scale).random((1, 64, 80, 1)).astype(np.float32)
    ref = np.squeeze(sess.run(y_out, {x_in: x}))          # output may be NHWC or NCHW
    got = model(torch.from_numpy(x.transpose(0, 3, 1, 2))).detach().numpy()[0, 0]
    err = float(np.abs(ref - got).max())
    print(f"  PyTorch vs TensorFlow: shapes {ref.shape} / {got.shape}, max abs diff {err:.2e}")
    assert ref.shape == got.shape and err < 1e-4, "rebuild mismatch"

    # 2. Core ML conversion (fixed 128×128 tile)
    traced = torch.jit.trace(model, torch.rand(1, 1, TILE, TILE))
    ml = ct.convert(traced, inputs=[ct.TensorType(name="y", shape=(1, 1, TILE, TILE), dtype=np.float32)],
                    outputs=[ct.TensorType(name="y_sr", dtype=np.float32)], convert_to="mlprogram",
                    compute_precision=ct.precision.FLOAT32, minimum_deployment_target=ct.target.macOS13)
    ml.short_description = f"FSRCNN x{scale} super-resolution on luma (Saafke/FSRCNN_Tensorflow, Apache-2.0). Input Y 0-1, 128x128 tile."
    ml.license = "Apache-2.0"; ml.author = "Saafke/FSRCNN_Tensorflow (FSRCNN, Dong et al. 2016); converted for PhotoForge"
    ml.version = "1"
    t = np.random.default_rng(9).random((1, 1, TILE, TILE)).astype(np.float32)
    cm = np.asarray(ml.predict({"y": t})["y_sr"])[0, 0]
    tt = model(torch.from_numpy(t)).detach().numpy()[0, 0]
    cerr = float(np.abs(cm - tt).max())
    print(f"  Core ML vs PyTorch: max abs diff {cerr:.2e}")
    assert cerr < 1e-3, "Core ML mismatch"
    ml.save(os.path.join(out, f"SR_x{scale}.mlpackage"))

    # 3. Quality on real photos: downscale by s, upscale back, compare with the original.
    gains = []
    for img in samples:
        w, h = (img.width // scale) * scale, (img.height // scale) * scale
        hr = img.crop((0, 0, w, h))
        lr = hr.resize((w // scale, h // scale), Image.BICUBIC)
        bic = lr.resize((w, h), Image.BICUBIC)
        sr_y = np.clip(upscale_tiled(model, luma(lr) / 255.0, scale) * 255.0, 0, 255)
        p_bic, p_sr = psnr(luma(hr), luma(bic)), psnr(luma(hr), sr_y)
        gains.append(p_sr - p_bic)
        print(f"  {w}x{h}: bicubic {p_bic:.2f} dB → FSRCNN {p_sr:.2f} dB (+{p_sr - p_bic:.2f})")
    assert min(gains) > 0, "FSRCNN should beat bicubic"

print("\nFSRCNN CONVERSION OK")
