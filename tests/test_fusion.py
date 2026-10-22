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
import BlackmagicFusion as bmd  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE_DIR = os.path.join(HERE, "..", "Atoms", "net.ra100.NodeArrange", "Modules", "Lua")


def run_arrange(comp, opts_lua):
    """Run M.run inside Fusion with the checkout's module; wait for it to finish."""
    tmp = tempfile.mkdtemp()
    done = os.path.join(tmp, "done")
    script = os.path.join(tmp, "drive.lua")
    with open(script, "w") as f:
        f.write(
            f'package.path = [[{MODULE_DIR}/?.lua;]] .. package.path\n'
            'package.loaded.NodeArrange = nil\n'
            f'local ok, err = pcall(function() require("NodeArrange").run(comp, {opts_lua}) end)\n'
            f'local f = io.open([[{done}]], "w") f:write(ok and "ok" or tostring(err)) f:close()\n'
        )
    comp.RunScript(script)
    for _ in range(100):
        if os.path.exists(done):
            with open(done) as f:
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


def selected_names(comp):
    return sorted(t.GetAttrs()["TOOLS_Name"] for t in comp.GetToolList(True).values())


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

        comp.Undo(1)
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
        comp.Undo(1)
        start = positions(flow, tools)
        sel = ["BG", "Key", "Mrg", "Grade"]
        flow.Select()
        for n in sel:
            flow.Select(tools[n], True)
        comp.SetActiveTool(tools["Key"])
        run_arrange(comp, '{ direction = "horizontal" }')
        after = positions(flow, tools)
        expect(all(after[n] == start[n] for n in tools if n not in sel), "unselected tools did not move")
        expect(after["Key"] == start["Key"], "active tool in the selection is the anchor")
        expect(selected_names(comp) == sorted(sel), "selection is the arranged tools")

        # Several selected, no active tool: the block must not cover unselected tiles.
        comp.Undo(1)
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
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
