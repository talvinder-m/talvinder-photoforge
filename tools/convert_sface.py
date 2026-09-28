"""
Fetch OpenCV Zoo's SFace face-recognition model (Apache-2.0) and convert it to Core ML.

  python3 tools/convert_sface.py <out_dir>

Produces <out_dir>/SFace.mlpackage with
  input  "input":     Float32 [1, 3, 112, 112], RGB, raw 0–255 (OpenCV FaceRecognizerSF preprocessing)
  output "embedding": Float32 [1, 128]
and verifies Core ML output against ONNX Runtime on random and structured inputs.
"""
import hashlib, os, sys, urllib.request
import numpy as np

URL = "https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx"
out = sys.argv[1] if len(sys.argv) > 1 else "build/models"
os.makedirs(out, exist_ok=True)
onnx_path = os.path.join(out, "sface.onnx")

if not os.path.exists(onnx_path) or os.path.getsize(onnx_path) < 1_000_000:
    print("downloading", URL)
    urllib.request.urlretrieve(URL, onnx_path)
data = open(onnx_path, "rb").read()
print(f"sface.onnx: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")
assert len(data) > 1_000_000, "download looks wrong (Git LFS pointer?)"

import onnx, onnxruntime as ort, torch
from onnx2torch import convert
import coremltools as ct

model = onnx.load(onnx_path)
in_name = model.graph.input[0].name
print("onnx input:", in_name, [d.dim_value for d in model.graph.input[0].type.tensor_type.shape.dim])

torch_model = convert(model).eval()
example = torch.rand(1, 3, 112, 112) * 255
traced = torch.jit.trace(torch_model, example)

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, 112, 112), dtype=np.float32)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.macOS13,
)
mlmodel.short_description = "SFace face-recognition embedding (OpenCV Zoo, Apache-2.0). 112x112 RGB aligned face, raw 0-255 → 128-d."
mlmodel.author = "OpenCV Zoo (SFace, 2021dec); converted for PhotoForge"
mlmodel.license = "Apache-2.0"
mlmodel.version = "2021dec"
pkg = os.path.join(out, "SFace.mlpackage")
mlmodel.save(pkg)
print("saved", pkg)

# Verify against ONNX Runtime
sess = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
rng = np.random.default_rng(0)
worst = 1.0
for i in range(8):
    x = (rng.random((1, 3, 112, 112)) * 255).astype(np.float32) if i < 4 else \
        np.clip(np.cumsum(rng.normal(0, 8, (1, 3, 112, 112)), axis=3) + 128, 0, 255).astype(np.float32)
    ref = sess.run(None, {in_name: x})[0].ravel()
    got = np.asarray(mlmodel.predict({"input": x})["embedding"]).ravel()
    cos = float(ref @ got / (np.linalg.norm(ref) * np.linalg.norm(got)))
    worst = min(worst, cos)
print(f"Core ML vs ONNX Runtime: worst cosine over 8 inputs = {worst:.6f}")
assert worst > 0.999, "conversion mismatch"
print("CONVERSION OK")
