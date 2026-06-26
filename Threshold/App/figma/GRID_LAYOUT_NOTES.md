# Building grids in Figma via the Plugin API (`use_figma`)

Why the earlier mockup "grid" didn't render as a grid: it was a **VERTICAL
auto-layout list of full-width rows** — that's a stack, not a grid. Figma has
two real ways to lay tiles out in a grid. Source: Figma Developer Docs
(developers.figma.com/docs/plugins/api), scraped 2026-06-26.

---

## Option A — Native Grid layout (`layoutMode = 'GRID'`)  ← use for fixed-column mockups

Figma's CSS-grid-style layout. Best when you want a predictable *N columns ×
M rows* block (e.g. a 3-column tile pane).

```ts
const grid = figma.createFrame()
grid.layoutMode    = 'GRID'      // <-- the key line. Not HORIZONTAL/VERTICAL.
grid.gridColumnCount = 3
grid.gridRowCount    = 2         // rows; grows as you add children past R*C
grid.gridColumnGap   = 10
grid.gridRowGap      = 10
grid.paddingTop = grid.paddingBottom = grid.paddingLeft = grid.paddingRight = 12

// Children flow into the first free cell on appendChild():
grid.appendChild(tileA)          // -> row 0, col 0
grid.appendChild(tileB)          // -> row 0, col 1
// ...or place explicitly (0-based row, col):
tileC.setGridChildPosition(1, 0) // row 1, col 0
```

**Gotchas**
- `gridRowCount` / `gridColumnCount` must be ≥ 1 (setter throws otherwise).
- New tracks default to `GridTrackSize` type `"FLEX"` (equal share of the
  parent's width/height). To make a track a fixed size, use the `GridTrackSize`
  objects from `grid.gridColumnSizes` / `grid.gridRowSizes`.
- `setGridChildPosition(r, c)` throws if the cell is occupied, out of bounds, or
  if the parent's `gridItemsPositioning === "ROW_AUTO_FLOW"` (auto-flow manages
  positions for you — just `appendChild` in order instead).
- Setting `gridRowCount` throws if `gridAutoTracks === "ROWS"` (count is managed
  automatically — add/remove children to change it).
- To make tiles fill their cell, give each child
  `layoutSizingHorizontal = 'FILL'` **after** appending it.

---

## Option B — Wrapping auto-layout (`layoutWrap = 'WRAP'`)  ← use for responsive tiles

Mirrors SwiftUI `LazyVGrid(.adaptive)` / CSS flex-wrap: fixed-width tiles flow
left-to-right and wrap to the next row when they run out of width. Best when the
column count should adapt to the pane width.

```ts
const wrap = figma.createFrame()
wrap.layoutMode   = 'HORIZONTAL'   // REQUIRED — layoutWrap only works here
wrap.layoutWrap   = 'WRAP'
wrap.itemSpacing       = 10        // gap between tiles in a row (main axis)
wrap.counterAxisSpacing = 10       // gap between rows (only applies when WRAP)
wrap.counterAxisAlignContent = 'AUTO'   // or 'SPACE_BETWEEN'
wrap.primaryAxisSizingMode  = 'FIXED'   // fix the frame width so wrapping happens
wrap.counterAxisSizingMode  = 'AUTO'    // hug height
wrap.resize(960, 10)

// Each tile needs an explicit width (wrap can't size from FILL children):
for (const tile of tiles) {
  wrap.appendChild(tile)
  tile.primaryAxisSizingMode = 'FIXED'  // if the tile is itself auto-layout
  tile.resize(150, 72)
}
```

**Gotchas**
- `layoutWrap = 'WRAP'` **throws unless `layoutMode === 'HORIZONTAL'`**.
- `counterAxisSpacing` and `counterAxisAlignContent` are ignored unless
  `layoutWrap === 'WRAP'`.
- The parent must have a bounded width (FIXED, or FILL inside a fixed parent)
  or there's nothing to wrap against — everything stays on one line.
- Tiles need real widths; a tile set to FILL has no intrinsic width to wrap.

---

## Which to use here

- **Fixed pane mockup (our 1000px-wide screen): Option A**, 3 columns, tiles set
  to `FILL` so they split the row evenly. Cleanest and most predictable.
- **Responsive / "as many as fit": Option B.**

## Drop-in tile-grid helper (Option A)

```ts
// rows: [{label, icon, on}]  accent fill applied when on
function tileGrid(rows, cols, onFill, offFill) {
  const grid = figma.createFrame()
  grid.layoutMode = 'GRID'
  grid.gridColumnCount = cols
  grid.gridRowCount = Math.max(1, Math.ceil(rows.length / cols))
  grid.gridColumnGap = 10
  grid.gridRowGap = 10
  grid.fills = []
  rows.forEach(r => {
    const tile = AF('tile-' + r.label, 'VERTICAL', {gap:6, pad:10, corner:14, pa:'CENTER', ca:'CENTER'})
    tile.fills = r.on ? onFill : offFill
    tile.appendChild(R(20,20, r.on ? W90 : W40, 4))   // icon placeholder
    tile.appendChild(T(r.label, r.on ? FSB : FR, 12, r.on ? hx('#ffffff') : SEC))
    grid.appendChild(tile)
    tile.layoutSizingHorizontal = 'FILL'              // split the row evenly
  })
  return grid
}
// onFill for the "rainbow" ON state: a GRADIENT_LINEAR paint (red→purple).
```

Use a `GRADIENT_LINEAR` paint for the ON fill to match the in-app rainbow tiles
(`type:'GRADIENT_LINEAR'`, diagonal `gradientTransform`, multi-stop
red/orange/yellow/green/blue/purple).
