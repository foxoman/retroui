# Retro Atelier Library

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

Brushes, patterns, gradients, swatches, layer styles and designs for
Retro Atelier's **Assets** window (File > Browse Assets). Everything here is
CC0: free to use for anything, no credit needed.

The app carries this folder inside it, so the library works offline. Put
the folder in a GitHub repository (for example `retro-photo-library`) and
set its `catalog.json` address in Assets > Settings (the default is
`https://raw.githubusercontent.com/foxoman/retro-photo-library/main/catalog.json`):
what you add there shows up in every copy of the app, with no new version.

## Adding an item

1. Put the file in its folder: `brushes/` (Retro Atelier brush presets,
   `.json`, saved from the Brushes panel), `patterns/` (a `.png` tile),
   `gradients/` (`.json`, as the ones here), `swatches/` (`.ase` or `.aco`),
   `styles/` (`.json`, as the ones here), `designs/` (a `.rpd` or `.psd`
   document).
2. Put a small picture (about 160 pixels) in `thumbs/`.
3. Add an entry to `catalog.json`:

```json
{"id": "palm-leaves", "title": "Palm Leaves", "kind": "pattern", "category": "Nature",
 "thumb": "thumbs/pattern-palm-leaves.png", "file": "patterns/palm-leaves.png", "ext": "png",
 "author": "Your Name", "license": "CC0", "tags": ["palm", "leaves", "summer"]}
```

`kind` is one of `brush`, `pattern`, `gradient`, `swatches`, `style`,
`design`, `photo`, `vector`, `texture`. Items whose `id` matches one the
app carries replace it.

`tools/genlibrary.nim` in Retro Nim UI made the items here (in code).
