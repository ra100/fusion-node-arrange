"""Integration test against a running Fusion Studio.

    cd /opt/BlackmagicDesign/Fusion21 && python3 /path/to/tests/test_fusion.py

Opens a new comp, builds a small graph, runs NodeArrange from this checkout
through comp:RunScript, and checks positions, selection, anchor and undo.
The test comp is closed without saving; other open comps are not touched.
"""

import os
import sys
import tempfile
import time

sys.path.insert(0, os.getcwd())
from collections import OrderedDict  # noqa: E402,F401  (bmd.readstring needs it in scope)
import BlackmagicFusion as bmd  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_DIR = os.path.join(HERE, "..", "Atoms", "net.ra100.NodeArrange", "Modules", "Lua")


def run_arrange(comp, opts_lua, module_dir=MODULE_DIR):
    """Run M.run inside Fusion with the checkout's module; wait for it to finish."""
    tmp = tempfile.mkdtemp()
    done = os.path.join(tmp, "done")
    script = os.path.join(tmp, "drive.lua")
    with open(script, "w", encoding="utf-8") as f:
        f.write(
            f'package.path = [[{module_dir}/?.lua;]] .. package.path\n'
            'package.loaded.NodeArrange = nil\n'
            f'local ok, err = pcall(function() require("NodeArrange").run(comp, {opts_lua}) end)\n'
            f'local f = io.open([[{done}]], "w") f:write(ok and "ok" or tostring(err)) f:close()\n'
        )
    comp.RunScript(script)
    for _ in range(100):
        if os.path.exists(done):
            with open(done, encoding="utf-8") as f:
                result = f.read()
            if result != "ok":
                raise RuntimeError(result)
            return
        time.sleep(0.1)
    raise TimeoutError("NodeArrange did not finish")


def build(comp, flow):
    flow.Select()
    t = {}
    for name, rid, x, y in [
        ("Plate", "Background", 0, 0), ("BG", "Background", 3, 4), ("Blur", "Blur", 7, 1),
        ("Key", "Blur", 2, 3), ("Mrg", "Merge", 5, 5), ("Grade", "ColorCorrector", 1, 6),
        ("Mask", "EllipseMask", 6, -2),
    ]:
        tool = comp.AddTool(rid, x, y)
        tool.SetAttrs({"TOOLS_Name": name})
        t[name] = tool
        flow.Select()
    t["Blur"].ConnectInput("Input", t["Plate"])
    t["Key"].ConnectInput("Input", t["Plate"])
    t["Mrg"].ConnectInput("Background", t["BG"])
    t["Mrg"].ConnectInput("Foreground", t["Key"])
    t["Grade"].ConnectInput("Input", t["Mrg"])
    t["Grade"].ConnectInput("EffectMask", t["Mask"])
    links = [("Plate", "Blur"), ("Plate", "Key"), ("BG", "Mrg"), ("Key", "Mrg"),
             ("Mrg", "Grade"), ("Mask", "Grade")]
    return t, links


def positions(flow, tools):
    out = {}
    for n, tool in tools.items():
        p = flow.GetPosTable(tool)
        out[n] = (p[1], p[2])
    return out


def undo(comp, flow, tools):
    """comp.Undo from outside Fusion can land late; wait until positions change."""
    before = positions(flow, tools)
    comp.Undo(1)
    for _ in range(50):
        if positions(flow, tools) != before:
            return
        time.sleep(0.1)
    raise TimeoutError("undo did not change any position")


def selected_names(comp):
    return sorted(t.GetAttrs()["TOOLS_Name"] for t in comp.GetToolList(True).values())


def underlay_rect(comp, flow, u):
    """Same model as NodeArrange.lua: top-left at a tile's top-left, size from ViewInfo."""
    p = flow.GetPosTable(u)
    tools = comp.CopySettings(u)["Tools"]
    size = tools[u.GetAttrs()["TOOLS_Name"]]["ViewInfo"]["Size"]
    left, top = p[1] - 43 / 110, p[2] - 8 / 33
    return (round(left, 3), round(left + size[1] / 110, 3), round(top, 3), round(top + size[2] / 33, 3))


def test_underlay(fu, expect):
    comp = fu.NewComp()
    try:
        flow = comp.CurrentFrame.FlowView
        tools, links = build(comp, flow)
        flow.Select()
        ul = comp.AddTool("Underlay", 0, 0)
        ul.SetAttrs({"TOOLS_Name": "UL"})
        flow.SetPos(ul, 10, 0)
        flow.SetPos(tools["BG"], 10, 1)
        flow.SetPos(tools["Mrg"], 10, 3)
        flow.Select()
        note = comp.AddTool("Note", 0, 0)
        note.SetAttrs({"TOOLS_Name": "NoteIn"})
        flow.SetPos(note, 10, 4)
        before = underlay_rect(comp, flow, ul)
        note_before = flow.GetPosTable(note)
        flow.Select()
        comp.SetActiveTool(None)
        run_arrange(comp, '{ direction = "horizontal" }')
        ul2 = comp.FindTool("UL")
        expect(ul2 is not None, "underlay still exists after resize")
        l, r, t, b = underlay_rect(comp, flow, ul2)
        after = positions(flow, tools)
        inside = sorted(n for n, (x, y) in after.items() if l < x < r and t < y < b)
        expect(inside == ["BG", "Mrg"], f"underlay holds exactly its tools {inside}")
        expect((l, r, t, b) != before, f"underlay refitted {before} -> {(l, r, t, b)}")
        n2 = flow.GetPosTable(comp.FindTool("NoteIn"))
        # Fusion rounds Underlay positions to its pixel grid, hence the tolerance.
        expect(abs((n2[1] - note_before[1]) - (l - before[0])) < 0.02 and abs((n2[2] - note_before[2]) - (t - before[2])) < 0.02,
               "note inside the underlay moved with it")
        comp.Undo(1)
        for _ in range(50):
            ul3 = comp.FindTool("UL")
            if ul3 and underlay_rect(comp, flow, ul3) == before:
                break
            time.sleep(0.1)
        expect(ul3 is not None and underlay_rect(comp, flow, ul3) == before, "one undo restores the underlay")

        # Selecting only the Underlay arranges the tools inside it.
        start = positions(flow, tools)
        flow.Select()
        flow.Select(ul3, True)
        comp.SetActiveTool(None)
        run_arrange(comp, '{ direction = "horizontal" }')
        after = positions(flow, tools)
        changed = sorted(n for n in tools if after[n] != start[n])
        expect(set(changed) <= {"BG", "Mrg"} and changed, f"selected underlay arranges only its tools {changed}")
    finally:
        comp.SetAttrs({"COMPB_Modified": False})
        comp.Close()


def test_unicode(fu, expect):
    """Non-ASCII tool name as the anchor, module loaded from a non-ASCII folder."""
    import shutil
    folder = tempfile.mkdtemp(prefix="モジュール_")
    shutil.copy(os.path.join(MODULE_DIR, "NodeArrange.lua"), folder)
    comp = fu.NewComp()
    try:
        flow = comp.CurrentFrame.FlowView
        tools, links = build(comp, flow)
        name = "合成_Mrg"
        tools["Mrg"].SetAttrs({"TOOLS_Name": name})
        got = tools["Mrg"].GetAttrs()["TOOLS_Name"]
        flow.Select()
        flow.Select(tools["Mrg"], True)
        comp.SetActiveTool(tools["Mrg"])
        pin = positions(flow, tools)["Mrg"]
        run_arrange(comp, '{ direction = "horizontal" }', module_dir=folder)
        after = positions(flow, tools)
        expect(after["Mrg"] == pin, f"tool named {got!r} is kept as the anchor")
        expect(all(after[b][0] > after[a][0] for a, b in links), "layout done with module in a non-ASCII folder")
    finally:
        comp.SetAttrs({"COMPB_Modified": False})
        comp.Close()
        shutil.rmtree(folder, ignore_errors=True)


def own_routers(comp, flow):
    return {t.GetAttrs()["TOOLS_Name"]: tuple(flow.GetPosTable(t).values())[:2]
            for t in comp.GetToolList(False, "PipeRouter").values()
            if t.GetAttrs()["TOOLS_Name"].startswith("NARouter")}


def source_of(tool, input_id):
    """Name of the tool feeding an input, looking through NARouters."""
    out = getattr(tool, input_id).GetConnectedOutput()
    while out and out.GetTool().GetAttrs()["TOOLS_Name"].startswith("NARouter"):
        out = out.GetTool().Input.GetConnectedOutput()
    return out and out.GetTool().GetAttrs()["TOOLS_Name"]


def test_routers(fu, expect):
    """Long links get NARouters; re-runs keep them, a plain run removes them, undo brings them back."""
    comp = fu.NewComp()
    try:
        flow = comp.CurrentFrame.FlowView
        flow.Select()
        t = {}
        for name, rid, x, y in [("Plate", "Background", 0, 0), ("B1", "Blur", 2, 2), ("B2", "Blur", 4, 2),
                                ("B3", "Blur", 6, 2), ("Mrg", "Merge", 8, 0), ("Mine", "PipeRouter", 3, 4)]:
            t[name] = comp.AddTool(rid, x, y)
            t[name].SetAttrs({"TOOLS_Name": name})
            flow.Select()
        t["B1"].ConnectInput("Input", t["Plate"])
        t["B2"].ConnectInput("Input", t["B1"])
        t["Mine"].ConnectInput("Input", t["B2"])
        t["B3"].ConnectInput("Input", t["Mine"])
        t["Mrg"].ConnectInput("Background", t["B3"])
        t["Mrg"].ConnectInput("Foreground", t["Plate"])
        wiring = {("Mrg", "Background"): "B3", ("Mrg", "Foreground"): "Plate", ("B3", "Input"): "Mine",
                  ("Mine", "Input"): "B2", ("B2", "Input"): "B1", ("B1", "Input"): "Plate"}

        def wired():
            return all(source_of(comp.FindTool(a), i) == s for (a, i), s in wiring.items())

        comp.SetActiveTool(None)
        run_arrange(comp, '{ direction = "horizontal", routers = true }')
        first = own_routers(comp, flow)
        expect(len(first) > 0, f"long link got routers {sorted(first)}")
        expect(wired(), "every input still fed by the same tool")
        pos = positions(flow, t)
        on_tile = [(r, n) for r, p in first.items() for n, q in pos.items()
                   if abs(p[0] - q[0]) < 0.5 and abs(p[1] - q[1]) < 0.5]
        expect(not on_tile, f"routers clear of tiles {on_tile}")

        flow.Select()
        comp.SetActiveTool(None)
        run_arrange(comp, '{ direction = "horizontal", routers = true }')
        expect(own_routers(comp, flow) == first, "re-run keeps the same routers")

        flow.Select()
        comp.SetActiveTool(None)
        run_arrange(comp, '{ direction = "horizontal" }')
        expect(not own_routers(comp, flow) and wired(), "plain arrange removes them and rewires directly")
        expect(comp.FindTool("Mine") is not None, "a PipeRouter the user added is kept")

        comp.Undo(1)
        for _ in range(50):
            if own_routers(comp, flow) == first:
                break
            time.sleep(0.1)
        expect(own_routers(comp, flow) == first and wired(), "one undo brings the routers back")
    finally:
        comp.SetAttrs({"COMPB_Modified": False})
        comp.Close()


def main():
    fu = bmd.scriptapp("Fusion")
    if not fu:
        sys.exit("Fusion is not running")
    comp = fu.NewComp()
    errors = []

    def expect(cond, msg):
        print(("OK   " if cond else "FAIL ") + msg)
        if not cond:
            errors.append(msg)

    try:
        flow = comp.CurrentFrame.FlowView
        tools, links = build(comp, flow)
        before = positions(flow, tools)

        # Nothing selected, no active tool: whole comp.
        flow.Select()
        comp.SetActiveTool(None)
        run_arrange(comp, '{ direction = "horizontal" }')
        after = positions(flow, tools)
        expect(all(after[b][0] > after[a][0] for a, b in links), "every link points right")
        names = list(after)
        overlap = [(a, b) for i, a in enumerate(names) for b in names[i + 1:]
                   if abs(after[a][0] - after[b][0]) < 1 and abs(after[a][1] - after[b][1]) < 1]
        expect(not overlap, f"no overlapping tiles {overlap}")
        expect(selected_names(comp) == sorted(tools), "all arranged tools are selected")

        undo(comp, flow, tools)
        expect(positions(flow, tools) == before, "one undo restores every position")

        # One selected tool: whole comp, that tool stays put.
        flow.Select()
        flow.Select(tools["Mrg"], True)
        comp.SetActiveTool(tools["Mrg"])
        start_one = positions(flow, tools)
        pin = start_one["Mrg"]
        run_arrange(comp, '{ direction = "horizontal" }')
        after = positions(flow, tools)
        expect(after["Mrg"] == pin, f"single selected tool is the anchor {pin} -> {after['Mrg']}")
        expect(after != start_one and len(selected_names(comp)) == len(tools), "whole comp arranged and selected")
        expect(comp.ActiveTool is not None and comp.ActiveTool.GetAttrs()["TOOLS_Name"] == "Mrg",
               "anchor stays active")

        # Several selected, active one inside: only the selection moves.
        undo(comp, flow, tools)
        start = positions(flow, tools)
        sel = ["BG", "Key", "Mrg", "Grade"]
        flow.Select()
        for n in sel:
            flow.Select(tools[n], True)
        comp.SetActiveTool(tools["Key"])
        run_arrange(comp, '{ direction = "horizontal" }')
        after = positions(flow, tools)
        moved = {n: (start[n], after[n]) for n in tools if n not in sel and after[n] != start[n]}
        expect(not moved, f"unselected tools did not move {moved}")
        expect(after["Key"] == start["Key"], "active tool in the selection is the anchor")
        expect(selected_names(comp) == sorted(sel), "selection is the arranged tools")

        # Several selected, no active tool: the block must not cover unselected tiles.
        undo(comp, flow, tools)
        flow.Select()
        for n in sel:
            flow.Select(tools[n], True)
        comp.SetActiveTool(None)
        flow.SetPos(tools["Plate"], start["Mrg"][0], start["Mrg"][1] - 1)
        flow.SetPos(tools["Blur"], start["Mrg"][0] - 1.5, start["Mrg"][1])
        run_arrange(comp, '{ direction = "horizontal" }')
        after = positions(flow, tools)
        covered = [(a, b) for a in sel for b in tools if b not in sel
                   and abs(after[a][0] - after[b][0]) < 1 and abs(after[a][1] - after[b][1]) < 1]
        expect(not covered, f"arranged selection clears unselected tiles {covered}")
    finally:
        comp.SetAttrs({"COMPB_Modified": False})
        comp.Close()
    test_underlay(fu, expect)
    test_unicode(fu, expect)
    test_routers(fu, expect)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
