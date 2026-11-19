#!/usr/bin/env python3
"""Google Fonts' families -- each one's name, its kind and whether it has
the Arabic letters -- as src/retroui/googlefontlist.txt, the list
Type > Get Google Fonts shows (`googleFontCatalog`):

    npm pack google-font-metadata       (in a folder of its own)
    tar xzf google-font-metadata-*.tgz
    python3 -I tools/gengooglefonts.py package/data/api-response.json

api-response.json is Google Fonts' developer API's list of families as
the google-font-metadata package keeps it. A line a family:
"Name|kind|a" -- kind s sans serif, r serif, d display, h handwriting,
m monospace; "a" when it has Arabic letters."""
import json, os, sys

kinds = {"sans-serif": "s", "serif": "r", "display": "d", "handwriting": "h", "monospace": "m"}
families = json.load(open(sys.argv[1]))
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "retroui", "googlefontlist.txt")
lines = []
for f in sorted(families, key=lambda f: f["family"].lower()):
    name = f["family"]
    if "|" in name or "\n" in name:
        continue
    k = kinds.get(f.get("category", ""), "s")
    a = "a" if "arabic" in f.get("subsets", []) else ""
    lines.append(f"{name}|{k}|{a}")
with open(out, "w", encoding="utf-8") as o:
    o.write("\n".join(lines) + "\n")
print(len(lines), "families,", sum(1 for l in lines if l.endswith("|a")), "with Arabic ->", os.path.normpath(out))
