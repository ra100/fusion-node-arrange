"""Offline tests for NodeArrange.layout using lupa (Lua 5.1, like Fusion's LuaJIT).

    pip install lupa pillow
    python3 tests/test_layout.py [out_dir]

Checks: every link points downstream along the flow, no tiles overlap, and
renders each case to PNG for a visual check.
"""

import json
import os
import random
import sys
import tempfile

from lupa import lua51

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "..", "Atoms", "net.ra100.NodeArrange", "Modules", "Lua", "NodeArrange.lua")
FIXTURE = os.path.join(HERE, "fixtures", "resolve-s08.json")


def load():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    with open(MODULE) as f:
        M = lua.execute(f.read())
    return lua, M


def run_layout(lua, M, names, links, positions, opts=None):
    """links: (src, dst, slot, main). Returns dict name -> (x, y), info."""
    idx = {n: i + 1 for i, n in enumerate(names)}
    nodes = lua.table_from({idx[n]: lua.table_from({"x": positions[n][0], "y": positions[n][1]}) for n in names})
    edges = lua.table_from([
        lua.table_from({"from": idx[a], "to": idx[b], "slot": s, "main": m}) for a, b, s, m in links
    ])
    pos, info = M.layout(nodes, edges, lua.table_from(opts or {}))
    if pos is None:
        raise RuntimeError(info)
    out = {n: (pos[idx[n]].x, pos[idx[n]].y) for n in names}
    return out, dict(info)


def check(names, links, pos, direction):
    errors = []
    axis = 0 if direction == "horizontal" else 1
    for a, b, _, _ in links:
        if pos[b][axis] <= pos[a][axis]:
            errors.append(f"link {a}->{b} not downstream")
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if abs(pos[a][0] - pos[b][0]) < 1 - 1e-6 and abs(pos[a][1] - pos[b][1]) < 1 - 1e-6:
                errors.append(f"overlap {a} {b}")
    return errors


def render(path, names, links, pos):
    from PIL import Image, ImageDraw

    sx, sy = 110, 33
    xs = [p[0] for p in pos.values()]
    ys = [p[1] for p in pos.values()]
    ox, oy = min(xs) - 1, min(ys) - 1
    w = int((max(xs) - ox + 2) * sx)
    h = int((max(ys) - oy + 2) * sy)
    img = Image.new("RGB", (max(w, 200), max(h, 100)), (40, 40, 44))
    d = ImageDraw.Draw(img)

    def c(n):
        return ((pos[n][0] - ox) * sx, (pos[n][1] - oy) * sy)

    for a, b, slot, _ in links:
        col = (220, 200, 60) if slot == 0 else (90, 160, 255) if slot < 0 else (120, 220, 120)
        d.line([c(a), c(b)], fill=col, width=2)
    for n in names:
        x, y = c(n)
        d.rectangle([x - sx / 2 + 2, y - sy / 2 + 2, x + sx / 2 - 2, y + sy / 2 - 2], fill=(90, 90, 98), outline=(200, 200, 200))
        d.text((x - sx / 2 + 6, y - 6), n[:16], fill=(255, 255, 255))
    img.save(path)


def comp_case():
    """Typical keying comp: plate, key, despill, cleanup masks, bg, grade, output."""
    L = []

    def link(a, b, slot=0):
        L.append((a, b, slot, slot == 0))

    link("Plate", "DeltaKeyer")
    link("Plate", "Despill")
    link("DeltaKeyer", "MatteCtrl")
    link("GarbageMask", "MatteCtrl", 1)
    link("Despill", "Combine")
    link("MatteCtrl", "Combine", -1)
    link("Combine", "EdgeBlur")
    link("BG", "BGBlur")
    link("BGBlur", "BGGrade")
    link("BGGrade", "Merge1")
    link("EdgeBlur", "Merge1", -1)
    link("Text", "Merge2", -1)
    link("Merge1", "Merge2")
    link("Merge2", "Grade")
    link("VignetteMask", "Grade", 1)
    link("Grade", "MediaOut")
    link("Grade", "Saver")
    link("Plate", "Tracker")
    link("Tracker", "Text", 1)
    # an unrelated tree
    link("Noise", "Blur9")
    link("Blur9", "Preview")
    names = sorted({n for l in L for n in l[:2]})
    return names, L


def fixture_case(path=FIXTURE):
    """Real Resolve comp snapshot (see fixtures/NOTICE.md), with its own positions."""
    with open(path) as f:
        data = json.load(f)
    positions = {n["name"]: (n["x"], n["y"]) for n in data["nodes"]}
    names = sorted(positions)
    links = []
    for n in data["nodes"]:
        ins = [i for i in n["inputs"] if i["source"] in positions]
        is_mask = ["Mask" in i["id"] or i["type"] == "Mask" for i in ins]
        main = next((k for k, i in enumerate(ins) if i["id"] in ("Background", "Input", "SceneInput", "Image")), None)
        if main is None:
            main = next((k for k, i in enumerate(ins) if not is_mask[k] and i["id"] != "Foreground"), None)
        above = below = 0
        for k, i in enumerate(ins):
            if k == main:
                slot = 0
            elif is_mask[k]:
                below += 1
                slot = below
            else:
                above += 1
                slot = -above
            links.append((i["source"], n["name"], slot, slot == 0))
    return names, links, positions


def random_case(seed, n=25):
    rnd = random.Random(seed)
    names = [f"N{i}" for i in range(n)]
    L = []
    for i in range(1, n):
        k = rnd.choice([1, 1, 1, 2])
        srcs = rnd.sample(range(i), min(k, i))
        for j, s in enumerate(srcs):
            slot = 0 if j == 0 else rnd.choice([-1, 1])
            L.append((names[s], names[i], slot, slot == 0))
    return names, L


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(tempfile.gettempdir(), "nodearrange_out")
    os.makedirs(out_dir, exist_ok=True)
    lua, M = load()
    cases = [("resolve-s08", *fixture_case()), ("keying", *comp_case(), None)]
    cases += [(f"random{s}", *random_case(s), None) for s in range(6)]
    failed = 0
    for name, names, links, positions in cases:
        if positions is None:
            rnd = random.Random(name)
            positions = {n: (rnd.uniform(0, 20), rnd.uniform(0, 10)) for n in names}
        for direction in ("horizontal", "vertical"):
            pos, info = run_layout(lua, M, names, links, positions, {"direction": direction})
            errs = check(names, links, pos, direction)
            # Re-running on its own output: a crossing-free layout must not
            # move at all, otherwise crossings must not increase.
            pos2, info2 = run_layout(lua, M, names, links, pos, {"direction": direction})
            moved = [n for n in names if abs(pos[n][0] - pos2[n][0]) + abs(pos[n][1] - pos2[n][1]) > 1e-6]
            if info["crossings"] == 0 and moved:
                errs.append(f"not idempotent: {len(moved)} moved")
            if info2["crossings"] > info["crossings"]:
                errs.append(f"re-run added crossings: {info['crossings']} -> {info2['crossings']}")
            # Anchored: the anchor keeps its position, the rest is the same layout shifted.
            anchor = names[len(names) // 2]
            pos3, _ = run_layout(lua, M, names, links, positions,
                                 {"direction": direction, "anchor": names.index(anchor) + 1})
            if pos3[anchor] != tuple(positions[anchor]):
                errs.append(f"anchor {anchor} moved: {positions[anchor]} -> {pos3[anchor]}")
            dx, dy = pos3[anchor][0] - pos[anchor][0], pos3[anchor][1] - pos[anchor][1]
            if any(abs(pos3[n][0] - pos[n][0] - dx) + abs(pos3[n][1] - pos[n][1] - dy) > 1e-6 for n in names):
                errs.append("anchored layout differs from the unanchored one")
            status = "OK " if not errs else "FAIL"
            failed += bool(errs)
            print(f"{status} {name:11s} {direction:10s} nodes={len(names):3d} trees={info['components']} crossings={info['crossings']}")
            for e in errs[:5]:
                print("     ", e)
            try:
                render(os.path.join(out_dir, f"{name}_{direction}.png"), names, links, pos)
            except ImportError:
                pass
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
