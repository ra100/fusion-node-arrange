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
    opts = dict(opts or {})
    if "obstacles" in opts:
        # (x, y) is one tile, (x, y, w, h) a box
        opts["obstacles"] = lua.table_from([
            lua.table_from(dict(zip(("x", "y", "w", "h"), q))) for q in opts["obstacles"]
        ])
    if "clusters" in opts:
        # a cluster is a list of names, or (names, {"left": .., ...}) with pads
        def cluster(c):
            names_, pad = (c if isinstance(c, tuple) else (c, None))
            t = {"members": lua.table_from([idx[n] for n in names_])}
            if pad:
                t["pad"] = lua.table_from(pad)
            return lua.table_from(t)
        opts["clusters"] = lua.table_from([cluster(c) for c in opts["clusters"]])
    for k in ("horizontal", "vertical"):
        if isinstance(opts.get(k), dict):
            opts[k] = lua.table_from(opts[k])
    pos, info = M.layout(nodes, edges, lua.table_from(opts))
    if pos is None:
        raise RuntimeError(info)
    out = {n: (pos[idx[n]].x, pos[idx[n]].y) for n in names}
    info = dict(info)
    info["clusters"] = {k: (c.left, c.right, c.top, c.bottom) for k, c in info["clusters"].items()}
    return out, info


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


def check_clusters(names, pos, clusters, boxes):
    """Members inside their frame, nothing else inside it, frames apart."""
    errors = []
    for k, members in enumerate(clusters, 1):
        if k not in boxes:
            continue
        l, r, t, b = boxes[k]
        for n in names:
            x, y = pos[n]
            inside = l < x < r and t < y < b
            if n in members and not (l + 0.5 - 1e-6 <= x <= r - 0.5 + 1e-6 and t + 0.5 - 1e-6 <= y <= b - 0.5 + 1e-6):
                errors.append(f"{n} outside its frame {k}")
            if n not in members and (abs(x - (l + r) / 2) < (r - l + 1) / 2 - 1e-6
                                     and abs(y - (t + b) / 2) < (b - t + 1) / 2 - 1e-6):
                errors.append(f"{n} overlaps frame {k}")
        for k2, (l2, r2, t2, b2) in boxes.items():
            if k2 > k and l < r2 and l2 < r and t < b2 and t2 < b:
                errors.append(f"frames {k} and {k2} overlap")
    return errors


def links_through_tiles(names, links, pos, half=0.45):
    """Count (link, tile) pairs where the straight link line crosses another tile.

    Fusion draws links as straight lines; this is reported, not checked.
    """
    def hits(p, q, c):
        t0, t1 = 0.0, 1.0
        for d, lo, hi, s in ((q[0] - p[0], c[0] - half, c[0] + half, p[0]),
                             (q[1] - p[1], c[1] - half, c[1] + half, p[1])):
            if abs(d) < 1e-12:
                if s < lo or s > hi:
                    return False
            else:
                a, b = sorted(((lo - s) / d, (hi - s) / d))
                t0, t1 = max(t0, a), min(t1, b)
                if t0 > t1:
                    return False
        return True

    return sum(1 for a, b, _, _ in links for n in names if n not in (a, b) and hits(pos[a], pos[b], pos[n]))


def render(path, names, links, pos, frames=None):
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

    for l, r, t, b in (frames or {}).values():
        d.rectangle([(l - ox) * sx, (t - oy) * sy, (r - ox) * sx, (b - oy) * sy], fill=(70, 66, 56), outline=(190, 180, 150))
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


# Same as MAIN_IDS in NodeArrange.lua.
MAIN_IDS = {"Background", "Input", "MainInput", "Input1", "SceneInput", "SceneInput1", "Image", "Image1",
            "Source", "Data3D", "MaterialInput"}


def fixture_case(path=FIXTURE):
    """Real Resolve comp snapshot (see fixtures/NOTICE.md), with its own positions."""
    with open(path) as f:
        data = json.load(f)
    positions = {n["name"]: (n["x"], n["y"]) for n in data["nodes"]}
    names = sorted(positions)
    links = []
    for n in data["nodes"]:
        ins = [i for i in n["inputs"] if i["source"] in positions]
        is_mask = ["Mask" in i["id"] or "Matte" in i["id"] or i["type"] == "Mask" for i in ins]
        main = next((k for k, i in enumerate(ins) if i["id"] in MAIN_IDS), None)
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


def edge_cases(lua, M):
    """Small hand-made cases; returns the number of failures."""
    errs = []

    def case(name, names, links, positions, opts, test):
        try:
            pos, info = run_layout(lua, M, names, links, positions, opts)
            msg = test(pos, info)
        except Exception as e:  # noqa: BLE001
            msg = f"error {e}"
        print(("OK   " if not msg else "FAIL ") + name + (f": {msg}" if msg else ""))
        if msg:
            errs.append(name)

    case("empty", [], [], {}, {}, lambda p, i: None if p == {} else "not empty")
    case("single tool", ["A"], [], {"A": (3, 4)}, {}, lambda p, i: None if p["A"] == (3, 4) else p)
    case("duplicate links", ["A", "B"], [("A", "B", 0, True), ("A", "B", -1, False)], {"A": (0, 0), "B": (5, 0)},
         {}, lambda p, i: None if p["B"][0] > p["A"][0] else p)
    case("snap 0", ["A", "B", "C"], [("A", "C", 0, True), ("B", "C", -1, False)],
         {"A": (0, 0.3), "B": (0, 1.7), "C": (2, 0)}, {"snap": 0},
         lambda p, i: None if p["C"][0] > p["A"][0] else p)
    case("cycle does not block other trees", ["A", "G", "X", "Y"],
         [("A", "G", 0, True), ("G", "A", 1, False), ("X", "Y", 0, True)],
         {"A": (0, 0), "G": (2, 0), "X": (0, 3), "Y": (2, 3)}, {},
         lambda p, i: None if i["cycles"] == 1 and p["Y"][0] > p["X"][0] else (p, i["cycles"]))
    case("nested option table", ["A", "B"], [("A", "B", 0, True)], {"A": (0, 0), "B": (1, 0)},
         {"direction": "horizontal", "horizontal": {"layer": 3}},
         lambda p, i: None if abs(p["B"][0] - p["A"][0] - 3) < 1e-6 else p)
    fan = ["S1", "S2", "S3", "S4", "S5", "S6", "M"]
    fan_links = [(n, "M", 0 if n == "S1" else -k, n == "S1") for k, n in enumerate(fan[:-1])]
    fan_pos = {n: (k, 0) for k, n in enumerate(fan)}

    def keeps_vertical(p, i):
        _, again = run_layout(lua, M, fan, fan_links, p, {"direction": "auto"})
        return None if again["direction"] == "vertical" else "auto flipped to horizontal"
    case("fan-in stays vertical in auto", fan, fan_links, fan_pos, {"direction": "vertical"}, keeps_vertical)

    chain = ["A", "B", "C", "D", "E"]
    chain_links = [("A", "D", -1, False), ("B", "D", 0, True), ("C", "D", 1, False), ("D", "E", 0, True)]
    chain_pos = {"A": (0, 0), "B": (0, 2), "C": (0, 4), "D": (3, 2), "E": (6, 2)}

    def stable(p, i):
        p2, _ = run_layout(lua, M, chain, chain_links, p, {"clusters": [["B", "C", "D", "E"]]})
        moved = {n: (p[n], p2[n]) for n in chain if p[n] != p2[n]}
        return None if not moved else f"re-run moved {moved}"
    case("cluster re-run is stable", chain, chain_links, chain_pos, {"clusters": [["B", "C", "D", "E"]]}, stable)
    case("anchor inside a cluster", chain, chain_links, chain_pos,
         {"clusters": [["B", "C", "D", "E"]], "anchor": 4},
         lambda p, i: None if p["D"] == (3, 2) else p["D"])
    case("cluster pads widen the frame", chain, chain_links, chain_pos,
         {"clusters": [(["D", "E"], {"left": 1, "right": 1, "top": 1, "bottom": 1})]},
         lambda p, i: None if abs((i["clusters"][1][1] - i["clusters"][1][0]) - (p["E"][0] - p["D"][0] + 2)) < 1e-6
         else i["clusters"])
    case("box obstacle is avoided", ["A", "B"], [("A", "B", 0, True)], {"A": (0, 0), "B": (2, 0)},
         {"direction": "horizontal", "obstacles": [(1, 0, 6, 3)]},
         lambda p, i: None if all(abs(p[n][1]) >= 2 - 1e-6 for n in p) and i["overlaps"] == 0 else (p, i["overlaps"]))
    return len(errs)


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
            if info2["drawn"] > info["drawn"]:
                errs.append(f"re-run added drawn crossings: {info['drawn']} -> {info2['drawn']}")
            # Anchored: the anchor keeps its position, the rest is the same layout shifted.
            anchor = names[len(names) // 2]
            pos3, _ = run_layout(lua, M, names, links, positions,
                                 {"direction": direction, "anchor": names.index(anchor) + 1})
            if pos3[anchor] != tuple(positions[anchor]):
                errs.append(f"anchor {anchor} moved: {positions[anchor]} -> {pos3[anchor]}")
            dx, dy = pos3[anchor][0] - pos[anchor][0], pos3[anchor][1] - pos[anchor][1]
            if any(abs(pos3[n][0] - pos[n][0] - dx) + abs(pos3[n][1] - pos[n][1] - dy) > 1e-6 for n in names):
                errs.append("anchored layout differs from the unanchored one")
            # Selection: arrange half the nodes; the rest stay put and must not be covered.
            sel = names[: len(names) // 2]
            sel_links = [l for l in links if l[0] in sel and l[1] in sel]
            obstacles = [positions[n] for n in names if n not in sel]
            pos4, info4 = run_layout(lua, M, sel, sel_links, positions,
                                     {"direction": direction, "obstacles": obstacles})
            covered = [n for n in sel for q in obstacles
                       if abs(pos4[n][0] - q[0]) < 1 - 1e-6 and abs(pos4[n][1] - q[1]) < 1 - 1e-6]
            if covered or info4["overlaps"]:
                errs.append(f"selection covers unselected tiles: {covered[:3]} overlaps={info4['overlaps']}")
            errs += check(sel, sel_links, pos4, direction)
            # Underlays: each cluster is kept together inside its frame.
            rnd = random.Random(name + direction)
            clusters = [rnd.sample(names, 3), rnd.sample(names, 4)]
            clusters[1] = [n for n in clusters[1] if n not in clusters[0]]
            if name == "keying":
                clusters = [["DeltaKeyer", "MatteCtrl", "GarbageMask"], ["BG", "BGBlur", "BGGrade"]]
            pos5, info5 = run_layout(lua, M, names, links, positions,
                                     {"direction": direction, "clusters": clusters})
            errs += check(names, links, pos5, direction)
            errs += check_clusters(names, pos5, clusters, info5["clusters"])
            dropped = list(dict(info5["dropped"]).values())
            if name == "keying" and dropped:
                errs.append(f"keying clusters dropped {dropped}")
            cl_note = f"{len(info5['clusters'])}kept/{len(dropped)}dropped"
            pos6, info6 = run_layout(lua, M, names, links, pos5, {"direction": direction, "clusters": clusters})
            moved = [n for n in names if abs(pos5[n][0] - pos6[n][0]) + abs(pos5[n][1] - pos6[n][1]) > 1e-6]
            if info5["crossings"] == 0 and moved:
                errs.append(f"clusters: re-run moved {len(moved)} tools")
            # "Arrange Nodes" (auto) on an arranged comp keeps its direction.
            _, info7 = run_layout(lua, M, names, links, pos, {"direction": "auto"})
            if info7["direction"] != direction:
                errs.append(f"auto picked {info7['direction']} on a {direction} layout")
            try:
                render(os.path.join(out_dir, f"{name}_{direction}_clusters.png"), names, links, pos5,
                       info5["clusters"])
            except ImportError:
                pass
            status = "OK " if not errs else "FAIL"
            failed += bool(errs)
            through = links_through_tiles(names, links, pos)
            print(f"{status} {name:11s} {direction:10s} nodes={len(names):3d} trees={info['components']} "
                  f"crossings={info['drawn']} through-tiles={through} clusters={cl_note}")
            for e in errs[:5]:
                print("     ", e)
            try:
                render(os.path.join(out_dir, f"{name}_{direction}.png"), names, links, pos)
            except ImportError:
                pass
    failed += edge_cases(lua, M)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
