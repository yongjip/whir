# Whir icon source

Date: 2026-09-24. Based on the user's selected seven-square W reference.
Generated with the built-in ImageGen tool. This is a raster image, not a 3D scene.

Design accepted by the user on 2026-09-24: seven separate rounded square blocks
forming a W, with only the upper-right block blue. Use this design for Whir's
app and store icon exports.

- `app-icon-render.png`: generated source, 1254 × 1254. Keep this as the exporter input.
- `app-icon-master.png`: normalized output with a smooth rounded tile mask and soft shadow.
- `../../scripts/make_icon.swift`: applies the mask and exports all 10 macOS icon sizes.

The export mask is necessary because the generated source has stray alpha fragments
outside the white tile. Deliver the normalized master or exported PNGs, not the raw render.

## Design constraints

Exactly seven separate rounded square blocks: two on the top row, three in the
middle, two offset inward on the bottom. Six are charcoal; only the top-right
block is blue. No connected diagonal strokes, circular accent, numbers, or text.
Keep the raised satin material, bevels, contact shadows, and neutral white tile.

## Final ImageGen edit prompt

Input: the generated seven-block icon, based on the user's selected reference.

```text
Use case: background-extraction and precise-object-edit.
Clean up this exact icon for production. Preserve the ENTIRE interior unchanged: exactly seven rounded square blocks in this W arrangement, six charcoal and only upper-right blue, the same scale, position, materials, contact shadows on the tile, colors, and white tile proportions.
Change ONLY the outer white tile boundary and exterior alpha. There are many unwanted jagged white speckles and fragments outside the rounded square. Remove ALL detached white fragments and fringes. Rebuild the outer tile silhouette as ONE PERFECTLY SMOOTH rounded square, clean continuous antialiased edge. The white tile is fully opaque. All space outside that single rounded square is perfectly transparent, with absolutely no cast shadow or glow outside the tile and no speckles anywhere. Preserve contact shadows INSIDE the tile under the seven blocks.
Front-facing square composition. About 7% transparent margin at each side. Export high resolution 2048x2048 square PNG with genuine alpha transparency. Do not add a backdrop, no checkerboard, no grain outside the silhouette. No text, no additional objects. Do not reinterpret the design. Only edge/alpha cleanup.
```

The tool returned 1254 × 1254 pixels. Its alpha cleanup remained imperfect;
the exporter handles the outer silhouette deterministically.
