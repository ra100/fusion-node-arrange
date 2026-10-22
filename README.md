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
   A long link's placeholders are held on the straight line Fusion draws.
5. **Links behind tiles.** Where a link would still pass behind a tile,
   neighbouring tiles in a column are swapped if that removes the overlap
   without adding crossings.
6. **Separate trees** are stacked and right-aligned on their outputs.

Other behaviour:

- **What gets arranged:** with 2 or more tools selected, only the selection.
  With 0 or 1, the whole comp.
- **Anchor:** the active tool (red border, the last one you clicked) keeps its
  position and the layout is built around it. With exactly one tool selected,
  that tool is the anchor. Without an active tool, the layout is right-aligned
  on the old outputs.
- **Selection and the rest of the comp:** when only a selection is arranged,
  the result is moved across the flow until it covers no other tool or
  Underlay. With an active tool, the active tool stays put instead, and the
  Console reports any overlap.
- **Underlays:** a tool belongs to an Underlay when its centre is inside it.
  An Underlay and its tools are arranged as one block, and the Underlay is
  resized around them with its old margins. If a link leaves the Underlay and
  comes back into it, that Underlay cannot be kept as one block: its tools are
  arranged on their own and the Console says so.
- After a run, every arranged tool and Underlay is selected, so the block can
  be moved straight away.
- Groups and Macros count as one tile. Notes are not moved.
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
`[NodeArrange] 14 tools (comp), 14 links, horizontal, 1 trees, 0 crossings, 1 underlays, anchor Merge1`.

## Settings

Spacing is in `M.defaults` at the top of `Modules/Lua/NodeArrange.lua`, in
Fusion grid units (one tile = 1):

| Key | Default | Meaning |
|---|---|---|
| `horizontal.layer` / `vertical.layer` | 1.5 / 2.0 | distance between columns (rows) |
| `horizontal.node` / `vertical.node` | 1.5 / 1.5 | distance between tiles in a column |
| `componentGap` | 1.0 | extra space between separate trees |
| `snap` | 0.25 | grid rounding, 0 disables |
| `untangle` | 200 | swap tries (at most 1 s) to move links off tiles |

From a script you can also call it directly:

```lua
local NA = require("NodeArrange")
NA.run(comp, { direction = "vertical" })               -- arrange
local pos, info = NA.run(comp, { apply = false })      -- dry run, moves nothing
```

## Limits

- Fusion draws links as straight lines. Some links that skip several columns
  still pass behind a tile when no swap can fix it without adding crossings.
  PipeRouters are not inserted, because that would change the comp.
- Resizing an Underlay replaces it with a pasted copy of the same name,
  comments and colour. Scripts that hold a reference to the old Underlay
  object have to look it up again.
- Nested Underlays: the outer one is kept as a block; inner ones are refitted
  around their tools afterwards and may overlap other tiles.

## How it is built

- `Modules/Lua/NodeArrange.lua` holds everything. `M.layout` is pure Lua 5.1
  with no Fusion calls. `M.run` is the thin Fusion part: it reads the flow,
  then moves tools with `FlowView:QueueSetPos` / `FlushSetPosQueue` inside one
  undo block.
- An Underlay's size exists only in its saved settings (`ViewInfo.Size`), so
  it is read with `CopySettings` and changed by pasting a resized copy.
- The three scripts in `Scripts/Comp/Node Arrange/` are one line each:
  `require("NodeArrange").run(...)`. Fusion's `package.path` already includes
  every `LuaModules:` folder, Reactor's `Deploy` among them.
- `Config/NodeArrange.fu` actions call those scripts with
  `RunScript("Scripts:...")`. The path map resolves the user folder and
  Reactor's `Deploy` folder alike.
- Lua, not Python: Lua is built into Fusion Studio and Resolve, while Python
  needs a separate install. The scripts do no file IO of their own, and tool
  names are never processed as text, so non-ASCII names and paths are passed
  through untouched.

## Tests

The layout core is tested outside Fusion through
[lupa](https://pypi.org/project/lupa/):

```bash
pip install lupa pillow
python3 tests/test_layout.py /tmp/nodearrange_out
```

Each case is checked in both directions: every link points downstream, no tiles
overlap, re-running on the result does not add crossings (a crossing-free
layout must not move at all), an anchored run keeps the anchor in place, an
arranged half of the graph covers none of the other half, and Underlay frames
hold exactly their own tools. The `through-tiles` column counts links that
pass behind a tile (60 before the swap step, 47 after, over all cases). PNG
previews go to the output folder. Cases: a real Resolve comp snapshot, a
synthetic keying comp, and random graphs.

The Fusion part is tested against a running Fusion Studio. The test opens a new
comp, runs this checkout's module, checks positions, selection, anchor,
overlap with unselected tools, Underlay refit, undo, and a non-ASCII tool name
with the module loaded from a non-ASCII folder. It then closes the comp without
saving:

```bash
cd /opt/BlackmagicDesign/Fusion21 && python3 /path/to/tests/test_fusion.py
```

Tested on: Fusion Studio 21, Linux. Not yet tested: Windows, macOS, Resolve.
Windows with a non-ASCII user folder is the case most likely to differ
([#3](https://github.com/ra100/fusion-node-arrange/issues/3)).

## Disclosure

The code was written with an AI coding assistant (Claude, by Anthropic) under
the author's direction. The tests above are what the tool is checked against;
anything they do not cover is listed as untested.
Bug reports and comps where the layout comes out wrong are welcome in the
[issues](https://github.com/ra100/fusion-node-arrange/issues).

## Credits

Inspired by [NodeAlign](https://github.com/prismanetcom/nodealign) by
Stefano / Prismanet. Node Arrange takes its idea of treating Groups and Macros
as single tiles, but is a separate implementation with a different algorithm.
The real-comp test fixture
comes from NodeAlign under the MIT license; see
[tests/fixtures/NOTICE.md](tests/fixtures/NOTICE.md).

## License

[MIT](LICENSE)
