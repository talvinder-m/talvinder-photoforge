"""
Fetch Real-ESRGAN's compact general model (realesr-general-x4v3, BSD-3-Clause) and convert
it to Core ML for PhotoForge's AI upscaler.

  python3 tools/convert_realesrgan.py <out_dir>

Produces <out_dir>/RealESRGANx4v3.mlpackage
  input  "input":  Float32 [1, 3, 256, 256]  RGB in 0…1 (one tile)
  output "output": Float32 [1, 3, 1024, 1024] RGB in ~0…1 (×4)
The architecture (SRVGGNetCompact) is re-declared here exactly as in xinntao/Real-ESRGAN
(basicsr/archs/srvgg_arch.py), so no extra packages are needed.
"""
import hashlib, os, sys, urllib.request
import numpy as np
import torch, torch.nn as nn, torch.nn.functional as F

URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-general-x4v3.pth"
TILE = 256

class SRVGGNetCompact(nn.Module):
    def __init__(self, num_in_ch=3, num_out_ch=3, num_feat=64, num_conv=32, upscale=4):
        super().__init__()
        self.upscale = upscale
        self.body = nn.ModuleList()
        self.body.append(nn.Conv2d(num_in_ch, num_feat, 3, 1, 1))
        self.body.append(nn.PReLU(num_parameters=num_feat))
        for _ in range(num_conv):
            self.body.append(nn.Conv2d(num_feat, num_feat, 3, 1, 1))
            self.body.append(nn.PReLU(num_parameters=num_feat))
        self.body.append(nn.Conv2d(num_feat, num_out_ch * upscale * upscale, 3, 1, 1))
        self.upsampler = nn.PixelShuffle(upscale)

    def forward(self, x):
        out = x
        for layer in self.body:
            out = layer(out)
        out = self.upsampler(out)
        return out + F.interpolate(x, scale_factor=self.upscale, mode="nearest")

out = sys.argv[1] if len(sys.argv) > 1 else "build/models"
os.makedirs(out, exist_ok=True)
pth = os.path.join(out, "realesr-general-x4v3.pth")
if not os.path.exists(pth) or os.path.getsize(pth) < 1_000_000:
    print("downloading", URL)
    urllib.request.urlretrieve(URL, pth)
data = open(pth, "rb").read()
print(f"weights: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")

state = torch.load(pth, map_location="cpu")
state = state.get("params_ema", state.get("params", state))
net = SRVGGNetCompact().eval()
net.load_state_dict(state, strict=True)
print("parameters:", sum(p.numel() for p in net.parameters()))

import coremltools as ct
example = torch.rand(1, 3, TILE, TILE)
traced = torch.jit.trace(net, example)
ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, TILE, TILE), dtype=np.float32)],
    outputs=[ct.TensorType(name="output", dtype=np.float32)],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,   # halves size and memory traffic; verified below
    minimum_deployment_target=ct.target.macOS13,
)
ml.short_description = "Real-ESRGAN general x4v3 (SRVGGNetCompact). 256x256 RGB tile in 0-1 -> 1024x1024."
ml.author = "Xintao Wang et al. (Real-ESRGAN); converted for PhotoForge"
ml.license = "BSD-3-Clause"
ml.version = "realesr-general-x4v3"
pkg = os.path.join(out, "RealESRGANx4v3.mlpackage")
ml.save(pkg)
print("saved", pkg)

# Verify Core ML against PyTorch on a smooth, photo-like tile (random noise is a poor test for SR).
rng = np.random.default_rng(0)
worst_psnr = 1e9
for i in range(3):
    x = np.cumsum(np.cumsum(rng.normal(0, 1, (1, 3, TILE, TILE)), axis=2), axis=3)
    x = ((x - x.min()) / (x.max() - x.min())).astype(np.float32)
    with torch.no_grad():
        ref = net(torch.from_numpy(x)).numpy()
    got = np.asarray(ml.predict({"input": x})["output"])
    mse = float(np.mean((np.clip(ref, 0, 1) - np.clip(got, 0, 1)) ** 2))
    psnr = 10 * np.log10(1.0 / max(mse, 1e-12))
    worst_psnr = min(worst_psnr, psnr)
print(f"Core ML (fp16) vs PyTorch (fp32): worst PSNR {worst_psnr:.1f} dB")
assert worst_psnr > 40, "conversion mismatch"
print("CONVERSION OK")
