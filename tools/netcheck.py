#!/usr/bin/env python3
"""A model of yours run by onnxruntime, for tools/netcheck.nim to compare `retroui/nnet` with.

    python3 tools/netcheck.py MODEL.onnx DIR [HEIGHT WIDTH]
    nim r -d:release tools/netcheck.nim MODEL.onnx DIR

The first input gets a picture-like tensor of (1, 3, HEIGHT, WIDTH) -- 320 x 320 when not given
-- written to DIR/in.raw; each output onnxruntime makes is written beside it (DIR/out0.raw ...,
DIR/meta.json their names and sizes, and how long it took). The Nim side runs the same model on
the same input and says how far each output is from onnxruntime's, and how long it took.

Needs: pip install numpy onnxruntime

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""

import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    model, out = sys.argv[1], sys.argv[2]
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 320
    w = int(sys.argv[4]) if len(sys.argv) > 4 else 320
    os.makedirs(out, exist_ok=True)
    s = ort.InferenceSession(model, providers=["CPUExecutionProvider"])
    first = s.get_inputs()[0]
    # (a picture of sorts: smooth parts and fine ones, every channel its own)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    pic = np.stack([np.sin(xx / 17.0) + 0.3 * np.cos(yy / 5.0), np.cos((xx + yy) / 23.0),
                    ((xx * yy) % 97) / 97.0 - 0.5])
    x = pic[None].astype(np.float32)
    x.tofile(os.path.join(out, "in.raw"))
    t = time.time()
    outs = s.run(None, {first.name: x})
    meta = {"input": first.name, "dims": list(x.shape), "seconds": time.time() - t, "outputs": []}
    for o, v in zip(s.get_outputs(), outs):
        v = np.asarray(v, dtype=np.float32)
        name = "out%d.raw" % len(meta["outputs"])
        v.tofile(os.path.join(out, name))
        meta["outputs"].append({"name": o.name, "dims": list(v.shape), "file": name})
    with open(os.path.join(out, "meta.json"), "w") as f:
        json.dump(meta, f)
    print(model, "->", ", ".join("%s %s" % (o["name"], o["dims"]) for o in meta["outputs"]),
          "in %.0f ms" % (meta["seconds"] * 1000))
    return 0


if __name__ == "__main__":
    sys.exit(main())
