#!/usr/bin/env python3
"""Makes the small models tests/test_llm.nim runs, and what each should answer.

    python3 tools/genllm.py            # tests/data/llm/*.gguf, expected.json

Four models of random weights, one of each kind `retroui/llm` runs -- Llama (F16, Q8_0, Q4_0,
its rope's own frequencies, a SentencePiece tokenizer), BitNet b1.58 (I2_S, sub-norms, ReLU
squared), BitNet (TQ2_0 with tensor scales) and Qwen 2 (TQ1_0, biases) -- and their answers
worked out here with numpy, from the weights as gguf-py reads them back: a reference of its own,
not the Nim code. The byte-pair tokenizer is trained with Hugging Face's `tokenizers` and Llama
3's pre-tokenizer pattern, and the texts' tokens are its own.

Needs: pip install numpy gguf tokenizers (the files are in the repository: this is only to make
them again).

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""

import json
import os
import struct
import sys

import numpy as np
from gguf import GGMLQuantizationType as Q
from gguf.quants import dequantize, quantize

OUT = os.path.join(os.path.dirname(__file__), "..", "tests", "data", "llm")
I2_S = 36

LLAMA3_SPLIT = (r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}|"
                r" ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+")

QWEN2_SPLIT = (r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}|"
               r" ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+")

SPECIALS = ["<|begin_of_text|>", "<|end_of_text|>", "<|start_header_id|>", "<|end_header_id|>",
            "<|eot_id|>", "<|im_start|>", "<|im_end|>"]

CORPUS = [
    "The quick brown fox jumps over the lazy dog. The dog sleeps; the fox runs.",
    "Hello, world! It's a small model: it doesn't know much, and they'll see that.",
    "Write SALE in big red letters at the top of the poster, then add a blue line.",
    "مرحبا بالعالم. هذه رسالة قصيرة باللغة العربية، مكتوبة للتجربة.",
    "Numbers: 1, 22, 333, 4444, 2026-11-20; prices $12.50 and 99%.",
    "def main():\n    print('hi')\n\n    return 0\n",
    "  spaces   before\tand after  \n\nnew lines\r\n",
    "User: what is the capital of Oman?\nAssistant: Muscat is the capital of Oman.",
] * 4

TEXTS = [
    "Hello, world!",
    "The fox's dog doesn't run; they'll see.",
    "مرحبا بالعالم",
    "Numbers 12345 and 2026",
    "  two  spaces\n\nand lines \n",
    "<|start_header_id|>user<|end_header_id|>\n\nHi<|eot_id|>",
    "emoji 🙂 and café",
]


# ---- a GGUF file, written by hand (gguf-py has no I2_S) -------------------------------------------------

def gstr(s):
    b = s.encode()
    return struct.pack("<Q", len(b)) + b


def gval(v):
    if isinstance(v, bool):
        return struct.pack("<I", 7) + struct.pack("<?", v)
    if isinstance(v, int):
        # (as llama.cpp writes them: sizes and token numbers unsigned)
        return struct.pack("<I", 4) + struct.pack("<I", v) if 0 <= v < 2**32 else \
            struct.pack("<I", 11) + struct.pack("<q", v)
    if isinstance(v, float):
        return struct.pack("<I", 6) + struct.pack("<f", v)
    if isinstance(v, str):
        return struct.pack("<I", 8) + gstr(v)
    if isinstance(v, list):
        if all(isinstance(x, str) for x in v):
            return struct.pack("<I", 9) + struct.pack("<IQ", 8, len(v)) + b"".join(gstr(x) for x in v)
        if all(isinstance(x, float) for x in v):
            return struct.pack("<I", 9) + struct.pack("<IQ", 6, len(v)) + b"".join(struct.pack("<f", x) for x in v)
        return struct.pack("<I", 9) + struct.pack("<IQ", 5, len(v)) + b"".join(struct.pack("<i", x) for x in v)
    raise TypeError(v)


def write_gguf(path, meta, tensors):
    """`tensors`: (name, dims with the fastest first, ggml type, bytes)."""
    head = b"GGUF" + struct.pack("<IQQ", 3, len(tensors), len(meta))
    for k, v in meta.items():
        head += gstr(k) + gval(v)
    off = 0
    infos = b""
    datas = []
    for name, dims, kind, data in tensors:
        infos += gstr(name) + struct.pack("<I", len(dims)) + b"".join(struct.pack("<Q", d) for d in dims)
        infos += struct.pack("<IQ", kind, off)
        pad = (-len(data)) % 32
        datas.append(data + b"\0" * pad)
        off += len(data) + pad
    body = head + infos
    body += b"\0" * ((-len(body)) % 32)
    with open(path, "wb") as f:
        f.write(body + b"".join(datas))


# ---- tokenizers ---------------------------------------------------------------------------------------------

def bpe_tokenizer(vocab_size, qwen=False):
    from tokenizers import Regex, Tokenizer, decoders, models, pre_tokenizers, trainers
    tk = Tokenizer(models.BPE())
    tk.pre_tokenizer = pre_tokenizers.Sequence([
        pre_tokenizers.Split(Regex(LLAMA3_SPLIT), behavior="isolated", invert=False),
        pre_tokenizers.ByteLevel(add_prefix_space=False, use_regex=False)])
    tk.decoder = decoders.ByteLevel()
    tr = trainers.BpeTrainer(vocab_size=vocab_size, special_tokens=SPECIALS,
                             initial_alphabet=pre_tokenizers.ByteLevel.alphabet(), show_progress=False)
    tk.train_from_iterator(CORPUS, tr)
    model = json.loads(tk.to_str())["model"]
    vocab = sorted(model["vocab"].items(), key=lambda kv: kv[1])
    tokens = [t for t, _ in vocab]
    merges = [m if isinstance(m, str) else " ".join(m) for m in model["merges"]]
    types = [3 if t in SPECIALS else 1 for t in tokens]
    meta = {
        "tokenizer.ggml.model": "gpt2", "tokenizer.ggml.pre": "llama-bpe",
        "tokenizer.ggml.tokens": tokens, "tokenizer.ggml.token_type": types,
        "tokenizer.ggml.merges": merges,
        "tokenizer.ggml.bos_token_id": tokens.index("<|begin_of_text|>"),
        "tokenizer.ggml.eos_token_id": tokens.index("<|end_of_text|>"),
        "tokenizer.ggml.eot_token_id": tokens.index("<|eot_id|>"),
    }
    if qwen:
        # (the same tokens, cut first as Qwen cuts: a digit at a time)
        tk.pre_tokenizer = pre_tokenizers.Sequence([
            pre_tokenizers.Split(Regex(QWEN2_SPLIT), behavior="isolated", invert=False),
            pre_tokenizers.ByteLevel(add_prefix_space=False, use_regex=False)])
        meta = dict(meta)
        meta["tokenizer.ggml.pre"] = "qwen2"
        meta["tokenizer.ggml.add_bos_token"] = False
        meta["tokenizer.ggml.add_eos_token"] = True
    expect = {t: tk.encode(t).ids for t in TEXTS}
    return meta, len(tokens), expect, tk


def spm_tokenizer():
    # (Llama 2's kind: pieces with scores, a byte for each letter it has not)
    tokens = ["<unk>", "<s>", "</s>"] + ["<0x%02X>" % b for b in range(256)]
    types = [2, 3, 3] + [6] * 256
    pieces = ["▁", "e", "l", "o", "h", "H", "w", "r", "d", "t", "a", "n", "s", "i", ",", "!",
              "ll", "he", "lo", "llo", "ello", "Hello", "▁Hello", "or", "wor", "worl", "world", "▁world",
              "▁t", "▁th", "th", "▁the", "an", "▁an", "▁and", "in", "▁in", "is", "▁is", "it", "▁it"]
    scores = [0.0] * len(tokens)
    for i, p in enumerate(pieces):
        tokens.append(p)
        types.append(1)
        scores.append(float(-100 + len(p) * 10 + i * 0.01))
    meta = {
        "tokenizer.ggml.model": "llama", "tokenizer.ggml.tokens": tokens,
        "tokenizer.ggml.token_type": types, "tokenizer.ggml.scores": scores,
        "tokenizer.ggml.bos_token_id": 1, "tokenizer.ggml.eos_token_id": 2,
        "tokenizer.ggml.add_bos_token": True,
    }
    ids = {t: i for i, t in enumerate(tokens)}
    expect = {
        # (worked out by hand: the best-scored pairs merged first)
        "Hello world": [ids["▁Hello"], ids["▁world"]],
        "Hello, the world!": [ids["▁Hello"], ids[","], ids["▁the"], ids["▁world"], ids["!"]],
        "is it in": [ids["▁is"], ids["▁it"], ids["▁in"]],
        "س": [ids["▁"], ids["<0xD8>"], ids["<0xB3>"]],
    }
    return meta, len(tokens), expect


# ---- weights ------------------------------------------------------------------------------------------------

def ternary(rng, rows, cols, scale):
    return rng.choice([-1.0, 0.0, 1.0], size=(rows, cols), p=[0.3, 0.4, 0.3]) * scale


def pack(kind, w):
    """`w` (rows, cols) packed as `kind`; the weights as the file has them, read back."""
    if kind == I2_S:
        flat = w.reshape(-1)
        scale = float(np.abs(flat).max())
        codes = np.where(np.abs(flat) < 1e-6, 1, np.where(flat > 0, 2, 0)).astype(np.uint8)
        blocks = codes.reshape(-1, 4, 32)              # (128 a block: 4 groups of 32)
        packed = (blocks[:, 0] << 6) | (blocks[:, 1] << 4) | (blocks[:, 2] << 2) | blocks[:, 3]
        data = packed.astype(np.uint8).tobytes() + struct.pack("<f", scale) + b"\0" * 28
        back = (codes.astype(np.float64) - 1) * np.float32(scale)
        return data, back.reshape(w.shape)
    if kind == Q.F32:
        a = w.astype(np.float32)
        return a.tobytes(), a.astype(np.float64)
    if kind == Q.F16:
        a = w.astype(np.float16)
        return a.tobytes(), a.astype(np.float64)
    q = quantize(w.astype(np.float32), kind)
    return q.tobytes(), dequantize(q, kind).astype(np.float64).reshape(w.shape)


def rms(x, w, eps):
    return x / np.sqrt(np.mean(x * x) + eps) * w


def rope(v, heads, hd, pos, base, neox, freqs):
    v = v.reshape(heads, hd).copy()
    for i in range(hd // 2):
        theta = pos * base ** (-2.0 * i / hd)
        if freqs is not None:
            theta /= freqs[i]
        c, s = np.cos(theta), np.sin(theta)
        a, b = (i, i + hd // 2) if neox else (2 * i, 2 * i + 1)
        x0, x1 = v[:, a].copy(), v[:, b].copy()
        v[:, a] = x0 * c - x1 * s
        v[:, b] = x0 * s + x1 * c
    return v.reshape(-1)


TERNARY = (I2_S, Q.TQ1_0, Q.TQ2_0)


def roundf(v):
    """C's roundf: half away from 0 (numpy's round is half to even; and in float32, 0.49999997 +
    0.5 would be 1)."""
    v = v.astype(np.float64)
    return np.sign(v) * np.floor(np.abs(v) + 0.5)


class Ref:
    """The model worked out in numpy, token by token: a ternary row takes the input as whole
    numbers, -127 .. 127 and a scale (as BitNet b1.58 was taught, and as the runner does), a
    Q8_0 or Q4_0 row too, a scale each 32 (as llama.cpp does)."""

    def __init__(self, c, W, K):
        self.c, self.W, self.K = c, W, K
        self.kc = [[] for _ in range(c["layers"])]
        self.vc = [[] for _ in range(c["layers"])]
        self.pos = 0

    def mm(self, name, x):
        if self.K.get(name) in TERNARY:
            x32 = x.astype(np.float32)
            top = np.abs(x32).max()
            if top == 0:
                return np.zeros(self.W[name].shape[0])
            xq = np.clip(roundf(x32 * (np.float32(127.0) / top)), -128, 127)
            return (self.W[name] @ xq.astype(np.float64)) * float(top / np.float32(127.0))
        if self.K.get(name) in (Q.Q8_0, Q.Q4_0):
            # (32 at a time, each its own scale, as llama.cpp does)
            x32 = x.astype(np.float32).reshape(-1, 32)
            top = np.abs(x32).max(axis=1, keepdims=True)
            k = np.where(top == 0, np.float32(0), np.float32(127.0) / np.where(top == 0, 1, top)).astype(np.float32)
            xq = np.clip(roundf(x32 * k), -128, 127)
            back = (xq * (top / np.float32(127.0)).astype(np.float64)).reshape(-1)
            return self.W[name] @ back
        return self.W[name] @ x

    def step(self, tok):
        c, W = self.c, self.W
        hd = c.get("hd", c["embd"] // c["heads"])
        group = c["heads"] // c["kv"]
        x = W["token_embd.weight"][tok].copy()
        for li in range(c["layers"]):
            p = "blk.%d." % li
            h = rms(x, W[p + "attn_norm.weight"], c["eps"])
            q = self.mm(p + "attn_q.weight", h)
            k = self.mm(p + "attn_k.weight", h)
            v = self.mm(p + "attn_v.weight", h)
            if c.get("bias"):
                q, k, v = q + W[p + "attn_q.bias"], k + W[p + "attn_k.bias"], v + W[p + "attn_v.bias"]
            if c.get("qknorm"):
                q = np.concatenate([rms(h_, W[p + "attn_q_norm.weight"], c["eps"]) for h_ in q.reshape(c["heads"], hd)])
                k = np.concatenate([rms(h_, W[p + "attn_k_norm.weight"], c["eps"]) for h_ in k.reshape(c["kv"], hd)])
            q = rope(q, c["heads"], hd, self.pos, c["base"], c["neox"], W.get("rope_freqs.weight"))
            k = rope(k, c["kv"], hd, self.pos, c["base"], c["neox"], W.get("rope_freqs.weight"))
            self.kc[li].append(k.reshape(c["kv"], hd))
            self.vc[li].append(v.reshape(c["kv"], hd))
            K = np.stack(self.kc[li])                  # (t, kv, hd)
            V = np.stack(self.vc[li])
            att = np.zeros(c["heads"] * hd)
            for hh in range(c["heads"]):
                qh = q.reshape(c["heads"], hd)[hh]
                sc = K[:, hh // group, :] @ qh / np.sqrt(hd)
                e = np.exp(sc - sc.max())
                att[hh * hd:(hh + 1) * hd] = (e / e.sum()) @ V[:, hh // group, :]
            if c.get("sub"):
                att = rms(att, W[p + "attn_sub_norm.weight"], c["eps"])
            o = self.mm(p + "attn_output.weight", att)
            x = x + o
            h = rms(x, W[p + "ffn_norm.weight"], c["eps"])
            g = self.mm(p + "ffn_gate.weight", h)
            u = self.mm(p + "ffn_up.weight", h)
            a = np.maximum(g, 0) ** 2 if c["relu2"] else g / (1 + np.exp(-g))
            hh = a * u
            if c.get("sub"):
                hh = rms(hh, W[p + "ffn_sub_norm.weight"], c["eps"])
            x = x + self.mm(p + "ffn_down.weight", hh)
        self.pos += 1
        self.hidden = rms(x, W["output_norm.weight"], c["eps"])
        return self.mm("output.weight" if "output.weight" in W else "token_embd.weight", self.hidden)


EMBED_TEXTS = ["The fox runs.", "Hello, world!", "مرحبا بالعالم"]


def make(name, c, tok_meta, vocab, rng, chat_template, tk=None):
    a = c["arch"]
    meta = {"general.architecture": a, "general.name": "retroui test " + name,
            "general.alignment": 32,
            a + ".context_length": 64, a + ".embedding_length": c["embd"], a + ".block_count": c["layers"],
            a + ".feed_forward_length": c["ff"], a + ".attention.head_count": c["heads"],
            a + ".attention.head_count_kv": c["kv"], a + ".rope.freq_base": float(c["base"]),
            a + ".attention.layer_norm_rms_epsilon": float(c["eps"])}
    if c.get("hd"):
        meta[a + ".attention.key_length"] = c["hd"]
        meta[a + ".attention.value_length"] = c["hd"]
    if c.get("pooling"):
        meta[a + ".pooling_type"] = c["pooling"]
    meta.update(tok_meta)
    if chat_template:
        meta["tokenizer.chat_template"] = chat_template
    tensors, W, K = [], {}, {}
    HD = c.get("hd", c["embd"] // c["heads"])
    E, F, KV, QD = c["embd"], c["ff"], c["kv"] * HD, c["heads"] * HD

    def mat(tname, rows, cols, kind, ternary_scale=None, scale_tensor=False):
        if ternary_scale is not None:
            w = ternary(rng, rows, cols, ternary_scale)
        else:
            w = rng.normal(0, 1 / np.sqrt(cols), size=(rows, cols))
        st = None
        if scale_tensor:                               # (BitNet's: weights of 1, a scale on its own)
            st = float(np.abs(w).max())
            w = w / st
        data, back = pack(kind, w)
        tensors.append((tname, [cols, rows], int(kind), data))
        K[tname] = kind
        if st is not None:
            tensors.append((tname.replace(".weight", ".scale"), [1], 0, struct.pack("<f", st)))
            back = back * np.float32(st)
        W[tname] = back

    def vec(tname, n, around=1.0, spread=0.1):
        v = (around + rng.normal(0, spread, size=n)).astype(np.float32)
        tensors.append((tname, [n], 0, v.tobytes()))
        W[tname] = v.astype(np.float64)

    mat("token_embd.weight", vocab, E, c["embd_kind"])
    if c.get("output_kind") is not None:
        mat("output.weight", vocab, E, c["output_kind"])
    vec("output_norm.weight", E)
    if c.get("rope_freqs"):
        f = rng.uniform(1, 4, size=(E // c["heads"]) // 2).astype(np.float32)
        tensors.append(("rope_freqs.weight", [len(f)], 0, f.tobytes()))
        W["rope_freqs.weight"] = f.astype(np.float64)
    for li in range(c["layers"]):
        p = "blk.%d." % li
        k = c["kinds"]
        ts = c.get("ternary")
        sc = c.get("scale_tensors", False)
        vec(p + "attn_norm.weight", E)
        vec(p + "ffn_norm.weight", E)
        if c.get("sub"):
            vec(p + "attn_sub_norm.weight", E)
            vec(p + "ffn_sub_norm.weight", F)
        mat(p + "attn_q.weight", QD, E, k["attn"], ts and 0.05, sc)
        mat(p + "attn_k.weight", KV, E, k["attn"], ts and 0.05, sc)
        mat(p + "attn_v.weight", KV, E, k["attn"], ts and 0.07, sc)
        mat(p + "attn_output.weight", E, QD, k["attn"], ts and 0.06, sc)
        mat(p + "ffn_gate.weight", F, E, k["ffn"], ts and 0.06, sc)
        mat(p + "ffn_up.weight", F, E, k["ffn"], ts and 0.06, sc)
        mat(p + "ffn_down.weight", E, F, k["down"], ts and 0.05, sc)
        if c.get("bias"):
            for b, n in (("attn_q.bias", QD), ("attn_k.bias", KV), ("attn_v.bias", KV)):
                vec(p + b, n, 0.0, 0.2)
        if c.get("qknorm"):
            vec(p + "attn_q_norm.weight", HD)
            vec(p + "attn_k_norm.weight", HD)
    write_gguf(os.path.join(OUT, name + ".gguf"), meta, tensors)

    # (what it should answer: the scores after each token, and the likeliest next ones)
    prompt = [int(t) for t in rng.integers(10, vocab, size=10)]
    ref = Ref(c, W, K)
    seen = {}
    for i, t in enumerate(prompt):
        lg = ref.step(t)
        if i in (0, 4, len(prompt) - 1):
            seen[str(i)] = [float(x) for x in lg[:48]]
            seen["max" + str(i)] = int(np.argmax(lg))
    greedy, gaps = [], []
    lg_now = lg
    for _ in range(6):
        order = np.argsort(-lg_now)
        gaps.append(float(lg_now[order[0]] - lg_now[order[1]]))
        greedy.append(int(order[0]))
        lg_now = ref.step(int(order[0]))
    out = {"prompt": prompt, "logits": seen, "greedy": greedy, "greedyGap": min(gaps)}
    if c.get("pooling") and tk is not None:
        # (texts as one vector each: the last token's, normed -- the end token added)
        vecs = {}
        eos = tok_meta["tokenizer.ggml.eos_token_id"]
        for t in EMBED_TEXTS:
            r2 = Ref(c, W, K)
            for i in tk.encode(t, add_special_tokens=False).ids + [eos]:
                r2.step(i)
            vecs[t] = r2.hidden / np.linalg.norm(r2.hidden)
        out["embed"] = {t: [float(x) for x in v[:16]] for t, v in vecs.items()}
        out["similar"] = [[float(vecs[a] @ vecs[b]) for b in EMBED_TEXTS] for a in EMBED_TEXTS]
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    rng = np.random.default_rng(1101)
    bpe_meta, bpe_vocab, bpe_expect, _ = bpe_tokenizer(420)
    qwen_meta, qwen_vocab, qwen_expect, qwen_tk = bpe_tokenizer(420, qwen=True)
    spm_meta, spm_vocab, spm_expect = spm_tokenizer()
    expected = {"bpe": bpe_expect, "qwen": qwen_expect, "spm": spm_expect, "models": {}}
    llama3_tpl = "{% for m in messages %}<|start_header_id|>{{ m['role'] }}<|end_header_id|>{% endfor %}"
    bitnet_tpl = "{% for m in messages %}{{ m['role'] | capitalize + ': ' + m['content'] }}<|eot_id|>{% endfor %}"
    chatml_tpl = "{% for m in messages %}<|im_start|>{{ m['role'] }}{% endfor %}"
    models = {
        "tiny-llama": (dict(arch="llama", embd=64, layers=2, heads=4, kv=2, ff=160, base=10000.0, eps=1e-5,
                            neox=False, relu2=False, rope_freqs=True, embd_kind=Q.F16, output_kind=Q.Q8_0,
                            kinds={"attn": Q.F16, "ffn": Q.Q8_0, "down": Q.Q4_0}),
                       spm_meta, spm_vocab, None),
        "tiny-bitnet-b158": (dict(arch="bitnet-b1.58", embd=256, layers=2, heads=4, kv=2, ff=256, base=500000.0,
                                  eps=1e-5, neox=True, relu2=True, sub=True, ternary=True, embd_kind=Q.F16,
                                  kinds={"attn": I2_S, "ffn": I2_S, "down": I2_S}),
                             bpe_meta, bpe_vocab, bitnet_tpl),
        "tiny-bitnet": (dict(arch="bitnet", embd=256, layers=2, heads=4, kv=4, ff=256, base=10000.0, eps=1e-6,
                             neox=True, relu2=False, sub=True, ternary=True, scale_tensors=True,
                             embd_kind=Q.Q8_0, output_kind=Q.F16,
                             kinds={"attn": Q.TQ2_0, "ffn": Q.TQ2_0, "down": Q.TQ2_0}),
                        bpe_meta, bpe_vocab, llama3_tpl),
        "tiny-qwen2": (dict(arch="qwen2", embd=256, layers=2, heads=8, kv=2, ff=256, base=1000000.0, eps=1e-6,
                            neox=True, relu2=False, bias=True, embd_kind=Q.Q8_0,
                            kinds={"attn": Q.Q8_0, "ffn": Q.TQ1_0, "down": Q.TQ1_0}, ternary=None),
                       bpe_meta, bpe_vocab, chatml_tpl),
        "tiny-qwen3": (dict(arch="qwen3", embd=128, layers=2, heads=4, kv=2, hd=48, ff=192, base=1000000.0,
                            eps=1e-6, neox=True, relu2=False, qknorm=True, pooling=3, embd_kind=Q.F16,
                            kinds={"attn": Q.Q8_0, "ffn": Q.Q8_0, "down": Q.Q8_0}),
                       qwen_meta, qwen_vocab, chatml_tpl),
    }
    for name, (c, meta, vocab, tpl) in models.items():
        expected["models"][name] = make(name, c, meta, vocab, rng, tpl, qwen_tk if name == "tiny-qwen3" else None)
        print(name, os.path.getsize(os.path.join(OUT, name + ".gguf")), "bytes, smallest greedy gap",
              round(expected["models"][name]["greedyGap"], 4))
    with open(os.path.join(OUT, "expected.json"), "w") as f:
        json.dump(expected, f, indent=1, ensure_ascii=False)
        f.write("\n")


if __name__ == "__main__":
    sys.exit(main())
