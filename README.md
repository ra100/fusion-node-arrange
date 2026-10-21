# Node Arrange for Fusion

Blender-style **Arrange Nodes** for Blackmagic Fusion Studio and the DaVinci
Resolve Fusion page. One click lays out the selected tools, or the whole comp,
as a clean left-to-right or top-to-bottom flow.

## What it does

It uses a layered (Sugiyama) layout, the same family of algorithm as Blender's
Node Arrange:

1. **Columns.** Each tool gets a column. Sources start on the left, and each
   tool is placed right before its nearest consumer, so Loaders sit next to the
   node they feed.
2. **Long links.** A link that skips columns gets an invisible placeholder in
   each column it crosses, so it is routed like a real node.
3. **Crossing reduction.** Barycenter sweeps plus adjacent swaps, from two
   starting orders: the current flow, and a walk upstream from the outputs. On
   ties, the order closest to the current flow wins, so running it again on an
   arranged comp changes nothing.
4. **Placement.** For each column, a weighted least-squares fit with minimum
   spacing. Main inputs weigh most, so the main image path is a straight line.
   Foreground sources go one row above the node they feed, masks one row below.
5. **Separate trees** are stacked and right-aligned on their outputs.

Other behaviour:

- With 2 or more tools selected, only the selection is arranged. Otherwise the
  whole comp is.
- Groups and Macros count as one tile. Notes and Underlays are not moved.
- Each run is one undo step.
- **Arrange Nodes** picks horizontal or vertical from the comp's current links.
  **Arrange Nodes Horizontal** and **Arrange Nodes Vertical** force a direction.

## Install

### Reactor (custom repository)

This repository is laid out as a Reactor repository, so Reactor can install
from it directly.

1. Close Fusion or Resolve.
2. Open `Reactor.cfg`:
   - Fusion Studio, Linux: `/var/BlackmagicDesign/Fusion/Reactor/System/Reactor.cfg`
   - Fusion Studio, Windows: `C:\ProgramData\Blackmagic Design\Fusion\Reactor\System\Reactor.cfg`
   - Fusion Studio, macOS: `/Library/Application Support/Blackmagic Design/Fusion/Reactor/System/Reactor.cfg`
   - Resolve: the same path with `DaVinci Resolve/Fusion` in place of `Fusion`,
     for example `/var/BlackmagicDesign/DaVinci Resolve/Fusion/Reactor/System/Reactor.cfg`
3. Add this entry inside `Repos = { ... }`, next to `_Core` and `Reactor`:

   ```lua
   NodeArrange = {
       Protocol = "GitHub",
       ID = "ra100/fusion-node-arrange",
   },
   ```

4. Start Fusion, open Reactor, find **Node Arrange** under Scripts > Flow, and
   click Install.

### Manual

Copy the files from `Atoms/net.ra100.NodeArrange/` into your Fusion user
folder:

| Platform | Folder |
|---|---|
| Resolve, Linux | `~/.local/share/DaVinciResolve/Fusion/` |
| Resolve, Windows | `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\` |
| Resolve, macOS | `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/` |
| Fusion Studio, Linux | `~/.fusion/BlackmagicDesign/Fusion/` |
| Fusion Studio, Windows | `%APPDATA%\Blackmagic Design\Fusion\` |
| Fusion Studio, macOS | `~/Library/Application Support/Blackmagic Design/Fusion/` |

```bash
SRC="Atoms/net.ra100.NodeArrange"
DST=~/.local/share/DaVinciResolve/Fusion    # pick from the table
mkdir -p "$DST/Modules/Lua" "$DST/Scripts/Comp" "$DST/Config"
cp "$SRC/Modules/Lua/NodeArrange.lua" "$DST/Modules/Lua/"
cp -r "$SRC/Scripts/Comp/Node Arrange" "$DST/Scripts/Comp/"
cp "$SRC/Config/NodeArrange.fu" "$DST/Config/"   # Fusion Studio menu bar entry
```

## Use

- **Resolve:** Workspace > Scripts > Comp > Node Arrange.
- **Fusion Studio:** the **Node Arrange** menu in the menu bar (appears after a
  restart), or Scripts > Comp > Node Arrange. The three actions are listed
  under "Node Arrange" in View > Customize Hotkeys, where you can bind keys.

The Console (Workspace > Console) shows one summary line per run, for example
`[NodeArrange] 14 tools (comp), 14 links, horizontal, 1 trees, 0 crossings`.

## Settings

Spacing is in `M.defaults` at the top of `Modules/Lua/NodeArrange.lua`, in
Fusion grid units (one tile = 1):

| Key | Default | Meaning |
|---|---|---|
| `horizontal.layer` / `vertical.layer` | 1.5 / 2.0 | distance between columns (rows) |
| `horizontal.node` / `vertical.node` | 1.5 / 1.5 | distance between tiles in a column |
| `componentGap` | 1.0 | extra space between separate trees |
| `snap` | 0.25 | grid rounding, 0 disables |

From a script you can also call it directly:

```lua
local NA = dofile(fu:MapPath("LuaModules:NodeArrange.lua"))
NA.run(comp, { direction = "vertical" })               -- arrange
local pos, info = NA.run(comp, { apply = false })      -- dry run, moves nothing
```

## Limits

- Fusion draws links as straight lines, so a link that skips several columns
  can still pass behind tiles. Inserting PipeRouters would fix it but changes
  the comp, so it is not done.
- Nodes inside an Underlay are moved like any other node and may leave it.

## Tests

The layout core is pure Lua 5.1, so it is tested outside Fusion through
[lupa](https://pypi.org/project/lupa/):

```bash
pip install lupa pillow
python3 tests/test_layout.py /tmp/nodearrange_out
```

Each case is checked in both directions: every link points downstream, no tiles
overlap, and re-running on the result does not add crossings (a crossing-free
layout must not move at all). PNG previews go to the output folder. Cases: a
real Resolve comp snapshot, a synthetic keying comp, and random graphs.

## Credits

Inspired by [NodeAlign](https://github.com/prismanetcom/nodealign) by
Stefano / Prismanet. Node Arrange takes its idea of treating Groups and Macros
as single tiles, but is a separate implementation with a different algorithm.
The real-comp test fixture
comes from NodeAlign under the MIT license; see
[tests/fixtures/NOTICE.md](tests/fixtures/NOTICE.md).

## License

[MIT](LICENSE)
