#!/usr/bin/env python3
"""Makes the small ONNX models tests/test_nnet.nim runs, and what each should give.

    python3 tools/gennet.py            # tests/data/nnet/*.onnx, expected.json (and vision-*.onnx)

Graphs of random weights that use the operations `retroui/nnet` runs -- convolutions (grouped,
strided, transposed), normalizations, attention, pools, resizing, the shape operations models
are full of -- worked out by onnxruntime: a reference of its own, not the Nim code.

Needs: pip install numpy onnx onnxruntime (the files are in the repository: this is only to make
them again).

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""

import json
import os
import sys

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper, numpy_helper

OUT = os.path.join(os.path.dirname(__file__), "..", "tests", "data", "nnet")
rng = np.random.default_rng(66)


def w(name, *shape, scale=0.3):
    return numpy_helper.from_array((rng.standard_normal(shape) * scale).astype(np.float32), name)


def ints(name, values):
    return numpy_helper.from_array(np.array(values, dtype=np.int64), name)


def floats(name, values):
    return numpy_helper.from_array(np.array(values, dtype=np.float32), name)


def model(name, nodes, inputs, outputs, inits, opset=17):
    g = helper.make_graph(nodes, name, inputs, outputs, inits)
    m = helper.make_model(g, opset_imports=[helper.make_opsetid("", opset)], producer_name="retroui gennet")
    m.ir_version = 8
    onnx.checker.check_model(m)
    return m


def vi(name, *shape):
    return helper.make_tensor_value_info(name, TensorProto.FLOAT, list(shape))


def conv_net():
    n = helper.make_node
    nodes = [
        n("Conv", ["x", "w1", "b1"], ["c1"], kernel_shape=[3, 3], pads=[1, 1, 1, 1], strides=[2, 2]),
        n("BatchNormalization", ["c1", "bn_s", "bn_b", "bn_m", "bn_v"], ["bn"], epsilon=1e-5),
        n("Relu", ["bn"], ["r1"]),
        n("Conv", ["r1", "w2"], ["c2"], kernel_shape=[3, 3], pads=[1, 1, 1, 1], group=8),
        n("HardSwish", ["c2"], ["hs"]),
        n("GlobalAveragePool", ["hs"], ["gap"]),
        n("Conv", ["gap", "w3", "b3"], ["se"], kernel_shape=[1, 1]),
        n("HardSigmoid", ["se"], ["se2"], alpha=0.2, beta=0.5),
        n("Mul", ["hs", "se2"], ["sc"]),
        n("Conv", ["sc", "w4"], ["c4"], kernel_shape=[3, 3], pads=[2, 2, 2, 2], dilations=[2, 2]),
        n("LeakyRelu", ["c4"], ["lr"], alpha=0.1),
        n("ConvTranspose", ["lr", "wt", "bt"], ["up"], kernel_shape=[2, 2], strides=[2, 2]),
        n("InstanceNormalization", ["up", "in_s", "in_b"], ["inn"], epsilon=1e-5),
        n("Sigmoid", ["inn"], ["y"]),
        n("MaxPool", ["y"], ["mp"], kernel_shape=[3, 3], strides=[2, 2], pads=[1, 1, 1, 1]),
        n("AveragePool", ["y"], ["ap"], kernel_shape=[2, 2], strides=[2, 2]),
        n("Add", ["mp", "ap"], ["y2"]),
        # (a Relu straight after a Conv, run as one; a pool whose last window runs past the edge)
        n("Conv", ["y2", "w5", "b5"], ["c5"], kernel_shape=[3, 3], pads=[1, 1, 1, 1]),
        n("Relu", ["c5"], ["r5"]),
        n("MaxPool", ["r5"], ["y3"], kernel_shape=[2, 2], strides=[2, 2], ceil_mode=1),
        n("AveragePool", ["r5"], ["y4"], kernel_shape=[3, 3], strides=[2, 2], pads=[1, 1, 1, 1], ceil_mode=1,
          count_include_pad=1),
    ]
    inits = [w("w1", 8, 3, 3, 3), w("b1", 8), floats("bn_s", rng.uniform(0.5, 1.5, 8)),
             w("bn_b", 8), w("bn_m", 8), floats("bn_v", rng.uniform(0.5, 1.5, 8)),
             w("w2", 8, 1, 3, 3), w("w3", 8, 8, 1, 1), w("b3", 8), w("w4", 6, 8, 3, 3),
             w("wt", 6, 4, 2, 2), w("bt", 4), floats("in_s", rng.uniform(0.5, 1.5, 4)), w("in_b", 4),
             w("w5", 5, 4, 3, 3), w("b5", 5)]
    m = model("conv", nodes, [vi("x", 1, 3, 16, 20)], [vi("y", 1, 4, 16, 20), vi("y2", 1, 4, 8, 10),
              vi("y3", 1, 5, 4, 5), vi("y4", 1, 5, 5, 6)], inits)
    return m, {"x": rng.standard_normal((1, 3, 16, 20)).astype(np.float32)}


def attention_net():
    n = helper.make_node
    T, D, H = 12, 32, 4
    nodes = [
        n("MatMul", ["x", "wq"], ["q0"]), n("MatMul", ["x", "wk"], ["k0"]), n("MatMul", ["x", "wv"], ["v0"]),
        n("Reshape", ["q0", "heads"], ["q1"]), n("Reshape", ["k0", "heads"], ["k1"]),
        n("Reshape", ["v0", "heads"], ["v1"]),
        n("Transpose", ["q1"], ["q"], perm=[0, 2, 1, 3]), n("Transpose", ["k1"], ["kt"], perm=[0, 2, 3, 1]),
        n("Transpose", ["v1"], ["v"], perm=[0, 2, 1, 3]),
        n("MatMul", ["q", "kt"], ["s0"]), n("Div", ["s0", "scale"], ["s1"]),
        n("Softmax", ["s1"], ["a"], axis=-1), n("MatMul", ["a", "v"], ["o0"]),
        n("Transpose", ["o0"], ["o1"], perm=[0, 2, 1, 3]), n("Reshape", ["o1", "flat"], ["o2"]),
        n("Reshape", ["o2", "rows"], ["o2r"]),
        n("Gemm", ["o2r", "wo", "bo"], ["o3"], transB=1),
        n("Reshape", ["o3", "back"], ["o4"]),
        n("Add", ["x", "o4"], ["r"]),
        n("LayerNormalization", ["r", "ln_s", "ln_b"], ["ln"], axis=-1, epsilon=1e-5),
        n("Div", ["ln", "sqrt2"], ["g0"]), n("Erf", ["g0"], ["g1"]), n("Add", ["g1", "one"], ["g2"]),
        n("Mul", ["ln", "g2"], ["g3"]), n("Mul", ["g3", "half"], ["y"]),
        n("ReduceMean", ["y", "ax"], ["m"], keepdims=1),
        n("ArgMax", ["y"], ["am"], axis=2, keepdims=0),
    ]
    inits = [w("wq", D, D), w("wk", D, D), w("wv", D, D), w("wo", D, D), w("bo", D),
             ints("heads", [1, T, H, D // H]), ints("flat", [1, T, D]), ints("rows", [T, D]),
             ints("back", [1, T, D]), floats("scale", [np.sqrt(D // H)]), floats("ln_s", rng.uniform(0.5, 1.5, D)),
             w("ln_b", D), floats("sqrt2", [np.sqrt(2)]), floats("one", [1.0]), floats("half", [0.5]),
             ints("ax", [1])]
    m = model("attention", nodes, [vi("x", 1, T, D)],
              [vi("y", 1, T, D), vi("m", 1, 1, D), helper.make_tensor_value_info("am", TensorProto.INT64, [1, T])],
              inits, opset=18)
    return m, {"x": rng.standard_normal((1, T, D)).astype(np.float32)}


def shapes_net():
    n = helper.make_node
    nodes = [
        n("Shape", ["x"], ["sh"]),
        n("Gather", ["sh", "i2"], ["hdim"], axis=0),
        n("Unsqueeze", ["hdim", "ax0"], ["hdim1"]),
        n("Concat", ["one1", "hdim1", "minus1"], ["shape3"], axis=0),
        n("Reshape", ["x", "shape3"], ["xr"]),
        n("Slice", ["x", "st", "en", "axs", "steps"], ["sl"]),
        n("Pad", ["sl", "pads"], ["pd"], mode="reflect"),
        n("Resize", ["pd", "", "scales"], ["rz"], mode="linear", coordinate_transformation_mode="half_pixel"),
        n("Resize", ["pd", "", "scales2"], ["rn"], mode="nearest", coordinate_transformation_mode="asymmetric",
          nearest_mode="floor"),
        # (cubic, as Depth Anything's: to sizes given, the edges repeated; and leaving them out)
        n("Resize", ["pd", "", "", "size3"], ["rc"], mode="cubic", coordinate_transformation_mode="half_pixel"),
        n("Resize", ["pd", "", "scales"], ["rx"], mode="cubic", exclude_outside=1, cubic_coeff_a=-0.5,
          coordinate_transformation_mode="align_corners"),
        n("Split", ["x", "splits"], ["s1", "s2"], axis=1),
        n("Sub", ["s1", "s2"], ["sd"]),
        n("Greater", ["sd", "zero"], ["pos"]),
        n("Where", ["pos", "sd", "zero"], ["rl"]),
        n("Expand", ["bias", "sh"], ["bx"]),
        n("Tile", ["s1", "reps"], ["tl"]),
        n("Concat", ["tl", "bx"], ["cat"], axis=0),
        n("Range", ["r0", "r1", "r2"], ["rg"]),
        n("Cast", ["rg"], ["rgf"], to=TensorProto.FLOAT),
        n("Mul", ["cat", "rgf"], ["catw"]),
        n("Unsqueeze", ["rl", "ax0"], ["rlu"]),
        n("Squeeze", ["rlu", "ax0"], ["sq"]),
        n("DepthToSpace", ["x4", ], ["d2s"], blocksize=2, mode="CRD"),
        n("GroupNormalization", ["x4", "gn_s", "gn_b"], ["gn"], num_groups=2, epsilon=1e-5),
        n("Clip", ["gn", "lo", "hi"], ["cl"]),
    ]
    inits = [numpy_helper.from_array(np.array(2, dtype=np.int64), "i2"), ints("ax0", [0]), ints("one1", [1]), ints("minus1", [-1]),
             ints("st", [1, 0]), ints("en", [7, 9]), ints("axs", [2, 3]), ints("steps", [2, 1]),
             ints("pads", [0, 0, 1, 2, 0, 0, 1, 2]), floats("scales", [1, 1, 1.5, 2]),
             floats("scales2", [1, 1, 2, 0.5]), ints("size3", [1, 4, 9, 7]), ints("splits", [2, 2]), floats("zero", [0]),
             w("bias", 1, 1, 1, 10), ints("reps", [1, 2, 1, 1]), numpy_helper.from_array(np.array(1, dtype=np.int64), "r0"),
             numpy_helper.from_array(np.array(11, dtype=np.int64), "r1"),
             numpy_helper.from_array(np.array(1, dtype=np.int64), "r2"), floats("gn_s", rng.uniform(0.5, 1.5, 8)), w("gn_b", 8),
             floats("lo", [-0.5]), floats("hi", [0.8])]
    outs = [vi("xr", 1, 8, -1), vi("rz", 1, 4, 7, 26), vi("rn", 1, 4, 10, 6), vi("rc", 1, 4, 9, 7),
            vi("rx", 1, 4, 7, 26), vi("rl", 1, 2, 8, 10),
            vi("sq", 1, 2, 8, 10), vi("catw", 2, 4, 8, 10), vi("d2s", 1, 2, 12, 12), vi("cl", 1, 8, 6, 6)]
    m = model("shapes", nodes, [vi("x", 1, 4, 8, 10), vi("x4", 1, 8, 6, 6)], outs, inits, opset=21)
    return m, {"x": rng.standard_normal((1, 4, 8, 10)).astype(np.float32),
               "x4": rng.standard_normal((1, 8, 6, 6)).astype(np.float32)}


def fourier_net():
    # (LaMa's Fourier units: a real picture to its spectrum, back again)
    n = helper.make_node
    nodes = [
        n("Unsqueeze", ["x", "last"], ["xc"]),
        n("DFT", ["xc", ""], ["f1"], axis=2, onesided=1),
        n("DFT", ["f1", ""], ["f2"], axis=1),
        n("Mul", ["f2", "gain"], ["f3"]),
        n("DFT", ["f3", ""], ["y"], axis=1, inverse=1),
    ]
    inits = [ints("last", [-1]), floats("gain", [0.5])]
    m = model("fourier", nodes, [vi("x", 1, 6, 8)], [vi("y", 1, 6, 5, 2)], inits, opset=17)
    return m, {"x": rng.standard_normal((1, 6, 8)).astype(np.float32)}


def vision_nets():
    # (stand-ins for retroui/vision's models, for tests/test_vision.nim -- what they find follows
    # from the picture by rule, so the pipeline round them is what is tried: a "detector" whose
    # map is how dark each place is, a "reader" whose answer is fixed, a "subject" model and a
    # "depth" model that see brightness)
    n = helper.make_node
    dyn = lambda name, *shape: helper.make_tensor_value_info(name, TensorProto.FLOAT, list(shape))
    det = model("textdet", [n("Conv", ["x", "wd", "bd"], ["c"]), n("Sigmoid", ["c"], ["map"])],
                [dyn("x", 1, 3, "h", "w")], [dyn("map", 1, 1, "h", "w")],
                [floats("wd", np.full((1, 3, 1, 1), -3.0)), floats("bd", [0.0])])
    probs = np.zeros((1, 6, 5), dtype=np.float32)
    for t, k in enumerate([1, 1, 0, 2, 3, 0]):
        probs[0, t, k] = 1.0
    rec = model("textrec", [n("Constant", [], ["probs"], value=numpy_helper.from_array(probs, "p"))],
                [dyn("x", 1, 3, 48, "w")], [dyn("probs", 1, 6, 5)], [])
    rec2 = model("textrec", [n("Constant", [], ["probs"], value=numpy_helper.from_array(probs, "p"))],
                 [dyn("x", 1, 3, 48, "w")], [dyn("probs", 1, 6, 5)], [])
    onnx.helper.set_model_props(rec2, {"character": "x\ny\nz"})   # (its characters its own, as RapidOCR's)
    subject = model("subject", [n("Conv", ["x", "ws", "bs"], ["c"]), n("Sigmoid", ["c"], ["mask"])],
                    [vi("x", 1, 3, 32, 32)], [vi("mask", 1, 1, 32, 32)],
                    [floats("ws", np.full((1, 3, 1, 1), 2.0)), floats("bs", [0.0])])
    depth = model("depth", [n("Conv", ["x", "wz", "bz"], ["c"]), n("Squeeze", ["c", "one"], ["depth"])],
                  [dyn("x", 1, 3, "h", "w")], [dyn("depth", 1, "h", "w")],
                  [floats("wz", np.full((1, 3, 1, 1), 1.0)), floats("bz", [0.0]), ints("one", [1])])
    for name, m in (("textdet", det), ("textrec", rec), ("textrec2", rec2), ("subject", subject), ("depth", depth)):
        path = os.path.join(OUT, "vision-" + name + ".onnx")
        onnx.save(m, path)
        print("vision-" + name, os.path.getsize(path), "bytes")


def main():
    os.makedirs(OUT, exist_ok=True)
    expected = {}
    for name, make in (("conv", conv_net), ("attention", attention_net), ("shapes", shapes_net),
                       ("fourier", fourier_net)):
        m, feeds = make()
        path = os.path.join(OUT, name + ".onnx")
        onnx.save(m, path)
        sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        names = [o.name for o in sess.get_outputs()]
        outs = sess.run(names, feeds)
        expected[name] = {
            "inputs": {k: {"dims": list(v.shape), "data": [float(x) for x in v.reshape(-1)]} for k, v in feeds.items()},
            "outputs": {k: {"dims": list(v.shape), "data": [float(x) for x in v.reshape(-1)],
                            "int": bool(np.issubdtype(v.dtype, np.integer))} for k, v in zip(names, outs)},
        }
        print(name, os.path.getsize(path), "bytes,", ", ".join(f"{k} {list(v.shape)}" for k, v in zip(names, outs)))
    with open(os.path.join(OUT, "expected.json"), "w") as f:
        json.dump(expected, f)
        f.write("\n")
    vision_nets()


if __name__ == "__main__":
    sys.exit(main())
