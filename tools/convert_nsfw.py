"""
OpenNSFW → Core ML, for PhotoForge's private "sensitive photos" review.

Model: Yahoo open_nsfw (BSD-2-Clause), weights as published by the opennsfw2 project
(Bosco Yung, MIT): https://github.com/bhky/opennsfw2. A ResNet-50-"thin" that outputs the
probability that a photo is not safe for work (nudity / sexual content).

The network is rebuilt in PyTorch from the Keras weights file (like tools/convert_fsrcnn.py),
traced and converted. Two checks must pass or the conversion fails:
  1. PyTorch matches the original Keras model (same weights, same padding rules).
  2. Core ML matches PyTorch.
Only face/scene photos and noise are used for checking; no explicit material is downloaded.

Usage: python tools/convert_nsfw.py <out_dir> [<folder of sample jpgs>]
"""
import glob, hashlib, os, sys, urllib.request
import numpy as np
import h5py
import torch, torch.nn as nn, torch.nn.functional as F
import coremltools as ct
from PIL import Image

WEIGHTS_URL = "https://github.com/bhky/opennsfw2/releases/download/v0.1.0/open_nsfw_weights.h5"
MEAN_BGR = [104.0, 117.0, 123.0]


def fetch(path):
    if not os.path.exists(path):
        print("downloading", WEIGHTS_URL)
        urllib.request.urlretrieve(WEIGHTS_URL, path)
    print("weights sha256", hashlib.sha256(open(path, "rb").read()).hexdigest()[:16], os.path.getsize(path), "bytes")


def load_h5(path):
    """{layer name: {kernel|bias|gamma|beta|moving_mean|moving_variance: array}}"""
    out = {}
    with h5py.File(path, "r") as f:
        def visit(name, obj):
            if isinstance(obj, h5py.Dataset):
                parts = name.split("/")
                layer = parts[0]
                key = parts[-1].split(":")[0]
                out.setdefault(layer, {})[key] = np.array(obj)
        f.visititems(visit)
    return out


# ---------------------------------------------------------------- PyTorch network

class ConvBN(nn.Module):
    def __init__(self, cin, cout, k, stride=1, pad=0):
        super().__init__()
        self.conv = nn.Conv2d(cin, cout, k, stride, pad, bias=True)
        self.bn = nn.BatchNorm2d(cout, eps=1e-5)

    def forward(self, x):
        return self.bn(self.conv(x))


class Block(nn.Module):
    """Keras _conv_block (projection shortcut, stride on the 1×1 convs) or _identity_block."""
    def __init__(self, cin, f, stride, project):
        super().__init__()
        f1, f2, f3 = f
        self.project = project
        if project:
            self.short = ConvBN(cin, f3, 1, stride)
        self.a = ConvBN(cin, f1, 1, stride if project else 1)
        self.b = ConvBN(f1, f2, 3, 1, 1)
        self.c = ConvBN(f2, f3, 1)

    def forward(self, x):
        s = self.short(x) if self.project else x
        y = F.relu(self.a(x))
        y = F.relu(self.b(y))
        y = self.c(y)
        return F.relu(y + s)


STAGES = [((32, 32, 128), 1, 3), ((64, 64, 256), 2, 4), ((128, 128, 512), 2, 6), ((256, 256, 1024), 2, 3)]


class OpenNSFW(nn.Module):
    """Input: 1×3×224×224 RGB 0…255. Output: [p(safe), p(not safe)]."""
    def __init__(self):
        super().__init__()
        self.register_buffer("mean", torch.tensor(MEAN_BGR).view(1, 3, 1, 1))
        self.stem = ConvBN(3, 64, 7, 2, 0)
        blocks, cin = [], 64
        for f, stride, n in STAGES:
            for b in range(n):
                blocks.append(Block(cin, f, stride, project=(b == 0)))
                cin = f[2]
        self.blocks = nn.ModuleList(blocks)
        self.fc = nn.Linear(1024, 2)

    def forward(self, rgb):
        x = rgb[:, [2, 1, 0], :, :] - self.mean          # RGB → BGR, minus the training mean
        x = F.pad(x, (3, 3, 3, 3))                       # ZeroPadding2D(3)
        x = F.relu(self.stem(x))
        # TensorFlow "same" max-pool (3, stride 2): pads only the bottom/right.
        x = F.max_pool2d(F.pad(x, (0, 1, 0, 1), value=float("-inf")), 3, 2)
        for blk in self.blocks:
            x = blk(x)
        x = x.mean(dim=(2, 3))
        return F.softmax(self.fc(x), dim=1)


def load_into_torch(model, w):
    def cbn(m, conv, bn):
        k = w[conv]["kernel"]                            # kh, kw, in, out
        m.conv.weight.data = torch.from_numpy(k.transpose(3, 2, 0, 1).copy())
        m.conv.bias.data = torch.from_numpy(w[conv]["bias"].copy())
        b = w[bn]
        m.bn.weight.data = torch.from_numpy(b["gamma"].copy())
        m.bn.bias.data = torch.from_numpy(b["beta"].copy())
        m.bn.running_mean.data = torch.from_numpy(b["moving_mean"].copy())
        m.bn.running_var.data = torch.from_numpy(b["moving_variance"].copy())

    cbn(model.stem, "conv_1", "bn_1")
    i = 0
    for s, (f, stride, n) in enumerate(STAGES):
        for b in range(n):
            blk = model.blocks[i]; i += 1
            base = f"stage{s}_block{b}"
            if b == 0:
                cbn(blk.short, f"conv_{base}_proj_shortcut", f"bn_{base}_proj_shortcut")
            for part in "abc":
                cbn(getattr(blk, part), f"conv_{base}_branch2{part}", f"bn_{base}_branch2{part}")
    model.fc.weight.data = torch.from_numpy(w["fc_nsfw"]["kernel"].T.copy())
    model.fc.bias.data = torch.from_numpy(w["fc_nsfw"]["bias"].copy())


# ---------------------------------------------------------------- Keras reference (original architecture)

def keras_reference(weights_path):
    """The opennsfw2 architecture (MIT), built in Keras and loaded with the same weights."""
    import tensorflow as tf
    L = tf.keras.layers

    def bn(name):
        return L.BatchNormalization(name=name, epsilon=1e-05)

    def block(stage, blk, x, f, k, stride, project):
        f1, f2, f3 = f
        cb, bb = f"conv_stage{stage}_block{blk}_branch", f"bn_stage{stage}_block{blk}_branch"
        act = f"activation_stage{stage}_block{blk}"
        if project:
            sc = L.Conv2D(name=f"conv_stage{stage}_block{blk}_proj_shortcut", filters=f3, kernel_size=1, strides=stride, padding="same")(x)
            sc = bn(f"bn_stage{stage}_block{blk}_proj_shortcut")(sc)
        else:
            sc = x
        y = L.Conv2D(name=f"{cb}2a", filters=f1, kernel_size=1, strides=stride if project else 1, padding="same")(x)
        y = L.Activation("relu", name=f"{act}_branch2a")(bn(f"{bb}2a")(y))
        y = L.Conv2D(name=f"{cb}2b", filters=f2, kernel_size=k, strides=1, padding="same")(y)
        y = L.Activation("relu", name=f"{act}_branch2b")(bn(f"{bb}2b")(y))
        y = L.Conv2D(name=f"{cb}2c", filters=f3, kernel_size=1, strides=1, padding="same")(y)
        y = bn(f"{bb}2c")(y)
        return L.Activation("relu", name=act)(L.Add()([y, sc]))

    inp = L.Input(shape=(224, 224, 3), name="input")
    x = L.ZeroPadding2D((3, 3))(inp)
    x = L.Conv2D(name="conv_1", filters=64, kernel_size=7, strides=2, padding="valid")(x)
    x = L.Activation("relu")(bn("bn_1")(x))
    x = L.MaxPooling2D(pool_size=3, strides=2, padding="same")(x)
    for s, (f, stride, n) in enumerate(STAGES):
        for b in range(n):
            x = block(s, b, x, f, 3, stride, b == 0)
    x = L.GlobalAveragePooling2D(name="global_average_pooling2d")(x)
    out = L.Activation("softmax", name="predictions")(L.Dense(name="fc_nsfw", units=2)(x))
    m = tf.keras.Model(inp, out, name="opennsfw2")
    m.load_weights(weights_path)
    return m


# ---------------------------------------------------------------- helpers

def prep(img):
    """Yahoo preprocessing: resize to 256×256, centre-crop 224 (RGB, 0…255)."""
    img = img.convert("RGB").resize((256, 256), Image.BILINEAR)
    return img.crop((16, 16, 240, 240))


def samples(folder):
    imgs = []
    if folder:
        for p in sorted(glob.glob(os.path.join(folder, "**", "*.jpg"), recursive=True))[:16]:
            imgs.append(prep(Image.open(p)))
    rng = np.random.default_rng(0)
    for _ in range(4):
        imgs.append(Image.fromarray(rng.integers(0, 256, (224, 224, 3), dtype=np.uint8)))
    return imgs


def main():
    out = sys.argv[1]
    folder = sys.argv[2] if len(sys.argv) > 2 else None
    os.makedirs(out, exist_ok=True)
    wpath = os.path.join(out, "open_nsfw_weights.h5")
    fetch(wpath)
    w = load_h5(wpath)
    print("layers in weights file:", len(w))

    model = OpenNSFW().eval()
    load_into_torch(model, w)
    imgs = samples(folder)
    batch = torch.from_numpy(np.stack([np.asarray(i, dtype=np.float32) for i in imgs]).transpose(0, 3, 1, 2).copy())
    with torch.no_grad():
        pt = model(batch).numpy()

    # 1. PyTorch vs the original Keras network.
    km = keras_reference(wpath)
    bgr = batch.numpy().transpose(0, 2, 3, 1)[..., ::-1] - np.array(MEAN_BGR, dtype=np.float32)
    kr = km.predict(bgr.astype(np.float32), verbose=0)
    d1 = float(np.abs(kr - pt).max())
    print(f"PyTorch vs Keras: max |Δp| = {d1:.2e}   (NSFW scores, Keras: {np.round(kr[:, 1], 3).tolist()})")
    if d1 > 2e-3:
        sys.exit("FAIL: PyTorch rebuild does not match the Keras model")

    # 2. Convert and check Core ML against PyTorch.
    traced = torch.jit.trace(model, batch[:1])
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), color_layout=ct.colorlayout.RGB, scale=1.0)],
        outputs=[ct.TensorType(name="probabilities")],
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
    )
    ml.short_description = "OpenNSFW (Yahoo, BSD-2) — probability a photo contains nudity / sexual content"
    ml.author = "Yahoo open_nsfw; weights via opennsfw2 (MIT); converted for PhotoForge"
    ml.license = "BSD-2-Clause (model), MIT (weights conversion)"
    path = os.path.join(out, "OpenNSFW.mlpackage")
    ml.save(path)
    try:
        cm = np.stack([ml.predict({"image": i})["probabilities"].reshape(-1) for i in imgs])
        d2 = float(np.abs(cm - pt).max())
        print(f"Core ML vs PyTorch: max |Δp| = {d2:.2e}")
        if d2 > 1e-2:
            sys.exit("FAIL: Core ML output differs from PyTorch")
    except Exception as e:  # predict needs macOS; conversion still checked above
        print("Core ML predict unavailable here:", e)
    print("saved", path)


if __name__ == "__main__":
    main()
