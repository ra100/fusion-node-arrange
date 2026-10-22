--[[
NodeArrange - Blender-style "Arrange Nodes" for Fusion Studio and the
DaVinci Resolve Fusion page.

Layered (Sugiyama) layout: columns by longest path, dummy nodes on long links,
barycenter crossing reduction, then a weighted least-squares fit per column.

M.layout is pure Lua 5.1 with no Fusion calls, so it is tested offline.
M.run(comp, opts) is the Fusion glue.
]]

local M = {}
M.VERSION = "1.1"

M.defaults = {
  -- "auto" picks horizontal or vertical from the comp's current links.
  direction = "auto",
  -- Spacing in Fusion grid units (one tile is 1 x 1).
  --   layer: distance between columns (rows in vertical mode)
  --   node:  distance between tile centres inside a column
  --   dummy: distance between two long links passing through a column
  horizontal = { layer = 1.5, node = 1.5, dummy = 0.5 },
  vertical   = { layer = 2.0, node = 1.5, dummy = 0.5 },
  componentGap = 1.0,  -- extra space between independent node trees
  snap = 0.25,         -- round positions to this step; 0 disables
  sweeps = 24,         -- crossing-reduction sweeps per starting order
  straighten = 16,     -- coordinate-assignment passes
}

local EPS = 1e-9
local MAIN_W = 16  -- weight of main-input links: keeps the image path straight
local CHAIN_W = 64 -- weight that holds a long link's dummies on its straight line

local function copyDefaults(opts)
  local o = {}
  for k, v in pairs(M.defaults) do o[k] = v end
  for k, v in pairs(opts or {}) do o[k] = v end
  return o
end

local function mean(sum, n, fallback)
  if n > 0 then return sum / n end
  return fallback
end

-- Weighted isotonic regression with minimum gaps.
-- Minimises sum w[i] * (y[i] - t[i])^2 subject to y[i] >= y[i-1] + gap[i].
local function fitLayer(t, w, gap)
  local n = #t
  local c = { 0 }
  for i = 2, n do c[i] = c[i - 1] + gap[i] end
  local bw, bs, bn = {}, {}, {}
  local top = 0
  for i = 1, n do
    top = top + 1
    bw[top], bs[top], bn[top] = w[i], w[i] * (t[i] - c[i]), 1
    while top > 1 and bs[top - 1] / bw[top - 1] > bs[top] / bw[top] - EPS do
      bw[top - 1] = bw[top - 1] + bw[top]
      bs[top - 1] = bs[top - 1] + bs[top]
      bn[top - 1] = bn[top - 1] + bn[top]
      top = top - 1
    end
  end
  local y, i = {}, 1
  for b = 1, top do
    local z = bs[b] / bw[b]
    for _ = 1, bn[b] do
      y[i] = z + c[i]
      i = i + 1
    end
  end
  return y
end

local function snap(v, step)
  if not step or step <= 0 then return v end
  return math.floor(v / step + 0.5) * step
end

-- Lay out one connected component. Coordinates: r = along the flow,
-- s = across it. Returns pos[node] = {r, s} relative to the component.
local function layoutComponent(nodes, edges, compNodes, compEdges, sp, o, origS)
  -- adjacency
  local succ, pred = {}, {}
  for _, v in ipairs(compNodes) do succ[v], pred[v] = {}, {} end
  for _, e in ipairs(compEdges) do
    local ed = edges[e]
    table.insert(succ[ed.from], e)
    table.insert(pred[ed.to], e)
  end

  -- topological order (Kahn), stable by original position
  local indeg, queue, topo = {}, {}, {}
  for _, v in ipairs(compNodes) do
    indeg[v] = #pred[v]
    if indeg[v] == 0 then queue[#queue + 1] = v end
  end
  local head = 1
  while head <= #queue do
    local v = queue[head]
    head = head + 1
    topo[#topo + 1] = v
    for _, e in ipairs(succ[v]) do
      local w = edges[e].to
      indeg[w] = indeg[w] - 1
      if indeg[w] == 0 then queue[#queue + 1] = w end
    end
  end
  if #topo ~= #compNodes then return nil, "cycle in node graph" end

  -- 1. ranks: longest path from sources, then pull towards consumers
  local rank = {}
  for _, v in ipairs(topo) do
    local r = 0
    for _, e in ipairs(pred[v]) do r = math.max(r, rank[edges[e].from] + 1) end
    rank[v] = r
  end
  for i = #topo, 1, -1 do
    local v = topo[i]
    if #succ[v] > 0 then
      local r = math.huge
      for _, e in ipairs(succ[v]) do r = math.min(r, rank[edges[e].to] - 1) end
      rank[v] = r
    end
  end
  local minR, maxR = math.huge, -math.huge
  for _, v in ipairs(compNodes) do
    minR = math.min(minR, rank[v])
    maxR = math.max(maxR, rank[v])
  end

  -- 2. layered graph with dummies. item = {node=, rank=, s0=}
  local items, itemOf = {}, {}
  local inSeg, outSeg = {}, {}
  local function newItem(node, r, s0)
    local it = { node = node, rank = r - minR, s0 = s0 }
    items[#items + 1] = it
    inSeg[it], outSeg[it] = {}, {}
    return it
  end
  for _, v in ipairs(compNodes) do itemOf[v] = newItem(v, rank[v], origS[v]) end
  local segs = {}
  for _, e in ipairs(compEdges) do
    local ed = edges[e]
    local a, b = itemOf[ed.from], itemOf[ed.to]
    local span = b.rank - a.rank
    local prev = a
    for k = 1, span - 1 do
      local s0 = a.s0 + (b.s0 - a.s0) * k / span
      local d = newItem(nil, a.rank + minR + k, s0)
      d.chain = { a = a, b = b, t = k / span }
      local w = (k > 1) and 8 or (ed.main and MAIN_W or 2)
      local sg = { a = prev, b = d, slot = 0, w = w }
      segs[#segs + 1] = sg
      table.insert(outSeg[prev], sg)
      table.insert(inSeg[d], sg)
      prev = d
    end
    local w = ed.main and MAIN_W or 1
    if span > 1 and not ed.main then w = 2 end
    local sg = { a = prev, b = b, slot = ed.slot or 0, w = w }
    segs[#segs + 1] = sg
    table.insert(outSeg[prev], sg)
    table.insert(inSeg[b], sg)
  end
  local nLayers = maxR - minR + 1
  local layers = {}
  for r = 0, nLayers - 1 do layers[r] = {} end

  -- 3. crossing reduction
  local function slotFrac(slot)
    return math.max(-0.45, math.min(0.45, slot * 0.15))
  end

  local function crossingsBetween(r, idx)
    local list = {}
    for _, it in ipairs(layers[r]) do
      for _, sg in ipairs(outSeg[it]) do
        list[#list + 1] = { idx[sg.a], idx[sg.b] + slotFrac(sg.slot) }
      end
    end
    local c = 0
    for i = 1, #list do
      local p = list[i]
      for j = i + 1, #list do
        local q = list[j]
        if (p[1] - q[1]) * (p[2] - q[2]) < 0 then c = c + 1 end
      end
    end
    return c
  end

  local function indexAll()
    local idx = {}
    for r = 0, nLayers - 1 do
      for i, it in ipairs(layers[r]) do idx[it] = i end
    end
    return idx
  end

  local function totalCrossings()
    local idx, c = indexAll(), 0
    for r = 0, nLayers - 2 do c = c + crossingsBetween(r, idx) end
    return c
  end

  local function sortLayer(r, key, idx)
    table.sort(layers[r], function(p, q)
      local kp, kq = key[p], key[q]
      if math.abs(kp - kq) > EPS then return kp < kq end
      return idx[p] < idx[q]
    end)
  end

  local function sweep(down)
    local idx = indexAll()
    local from, to, step = 1, nLayers - 1, 1
    if not down then from, to, step = nLayers - 2, 0, -1 end
    for r = from, to, step do
      local key = {}
      for _, it in ipairs(layers[r]) do
        local sum, n = 0, 0
        if down then
          for _, sg in ipairs(inSeg[it]) do sum = sum + idx[sg.a]; n = n + 1 end
        else
          for _, sg in ipairs(outSeg[it]) do
            sum = sum + idx[sg.b] + slotFrac(sg.slot); n = n + 1
          end
        end
        key[it] = mean(sum, n, idx[it])
      end
      sortLayer(r, key, idx)
      for i, it in ipairs(layers[r]) do idx[it] = i end
    end
  end

  -- Crossings among links of two adjacent items p (left/above) and q.
  local function pairCross(p, q, idx)
    local c = 0
    for _, a in ipairs(inSeg[p]) do
      for _, b in ipairs(inSeg[q]) do
        if idx[a.a] > idx[b.a] then c = c + 1 end
      end
    end
    for _, a in ipairs(outSeg[p]) do
      local pa = idx[a.b] + slotFrac(a.slot)
      for _, b in ipairs(outSeg[q]) do
        if pa > idx[b.b] + slotFrac(b.slot) then c = c + 1 end
      end
    end
    return c
  end

  -- Swap neighbours while that removes crossings.
  local function transpose()
    local idx = indexAll()
    local improved, guard = true, 0
    while improved and guard < 20 do
      improved, guard = false, guard + 1
      for r = 0, nLayers - 1 do
        local L = layers[r]
        for i = 1, #L - 1 do
          local p, q = L[i], L[i + 1]
          if pairCross(q, p, idx) < pairCross(p, q, idx) then
            L[i], L[i + 1] = q, p
            idx[q], idx[p] = i, i + 1
            improved = true
          end
        end
      end
    end
  end

  local function snapshot()
    local s = {}
    for r = 0, nLayers - 1 do
      s[r] = {}
      for i, it in ipairs(layers[r]) do s[r][i] = it end
    end
    return s
  end

  local function restore(s)
    for r = 0, nLayers - 1 do
      layers[r] = {}
      for i, it in ipairs(s[r]) do layers[r][i] = it end
    end
  end

  -- initial order B: DFS upstream from the outputs, inputs in slot order
  local function initDFS()
    for r = 0, nLayers - 1 do layers[r] = {} end
    local seen = {}
    local function visit(it)
      if seen[it] then return end
      seen[it] = true
      table.insert(layers[it.rank], it)
      local ins = {}
      for _, sg in ipairs(inSeg[it]) do ins[#ins + 1] = sg end
      table.sort(ins, function(p, q)
        if p.slot ~= q.slot then return p.slot < q.slot end
        return p.a.s0 < q.a.s0
      end)
      for _, sg in ipairs(ins) do visit(sg.a) end
    end
    local sinks = {}
    for _, it in ipairs(items) do
      if #outSeg[it] == 0 then sinks[#sinks + 1] = it end
    end
    table.sort(sinks, function(p, q) return p.s0 < q.s0 end)
    for _, it in ipairs(sinks) do visit(it) end
    for _, it in ipairs(items) do visit(it) end
  end

  -- initial order A (tried first, wins ties): current positions in the flow
  local function initOriginal()
    for r = 0, nLayers - 1 do layers[r] = {} end
    for _, it in ipairs(items) do table.insert(layers[it.rank], it) end
    for r = 0, nLayers - 1 do
      table.sort(layers[r], function(p, q) return p.s0 < q.s0 end)
    end
  end

  -- Tie-break between orders with equal crossings: fewest real-node pairs
  -- swapped relative to the current flow, so re-running is stable.
  local function disorder()
    local d = 0
    for r = 0, nLayers - 1 do
      local L = layers[r]
      for i = 1, #L do
        if L[i].node then
          for j = i + 1, #L do
            if L[j].node and L[j].s0 < L[i].s0 then d = d + 1 end
          end
        end
      end
    end
    return d
  end

  local best, bestC, bestD = nil, math.huge, math.huge
  local function consider()
    local c = totalCrossings()
    if c < bestC or (c == bestC and disorder() < bestD) then
      best, bestC, bestD = snapshot(), c, disorder()
    end
  end
  for _, init in ipairs({ initOriginal, initDFS }) do
    init()
    consider()
    for k = 1, o.sweeps do
      if bestC == 0 then break end
      sweep(k % 2 == 0)
      transpose()
      consider()
    end
  end
  restore(best)

  -- 4. coordinates across the flow
  local function gapBetween(p, q)
    if p.node and q.node then return sp.node end
    if not p.node and not q.node then return sp.dummy end
    return (sp.node + sp.dummy) / 2
  end

  local s = {}
  for r = 0, nLayers - 1 do
    local L, y = layers[r], 0
    for i, it in ipairs(L) do
      if i > 1 then y = y + gapBetween(L[i - 1], it) end
      s[it] = y
    end
    local shift = y / 2
    for _, it in ipairs(L) do s[it] = s[it] - shift end
  end

  local function fit(r, useIn, useOut)
    local L = layers[r]
    if #L == 0 then return end
    local t, w, gap = {}, {}, {}
    for i, it in ipairs(L) do
      local sum, ws = 0, 0
      local ch = it.chain
      if ch then
        -- Fusion draws the link straight from a to b, so its dummies sit on that line.
        sum, ws = CHAIN_W * (s[ch.a] + (s[ch.b] - s[ch.a]) * ch.t), CHAIN_W
      elseif useIn then
        for _, sg in ipairs(inSeg[it]) do
          sum = sum + sg.w * (s[sg.a] - sg.slot * sp.node)
          ws = ws + sg.w
        end
      end
      if useOut and not ch then
        for _, sg in ipairs(outSeg[it]) do
          sum = sum + sg.w * (s[sg.b] + sg.slot * sp.node)
          ws = ws + sg.w
        end
      end
      if ws > 0 then
        t[i], w[i] = sum / ws, ws
      else
        t[i], w[i] = s[it], 1e-3
      end
      gap[i] = i > 1 and gapBetween(L[i - 1], it) or 0
    end
    local y = fitLayer(t, w, gap)
    for i, it in ipairs(L) do s[it] = y[i] end
  end

  for _ = 1, o.straighten do
    for r = 1, nLayers - 1 do fit(r, true, false) end
    for r = nLayers - 2, 0, -1 do fit(r, false, true) end
  end
  for _ = 1, 4 do
    for r = 0, nLayers - 1 do fit(r, true, true) end
    for r = nLayers - 1, 0, -1 do fit(r, true, true) end
  end

  local pos = {}
  for _, it in ipairs(items) do
    if it.node then pos[it.node] = { r = it.rank * sp.layer, s = s[it] } end
  end
  return pos, (nLayers - 1) * sp.layer, bestC
end

--[[
Pure layout.
  nodes[i] = { x = , y = }  current flow positions
  edges[k] = { from = i, to = j, slot = int, main = bool }
    slot: 0 = main input, -1, -2 ... above (Foreground), 1, 2 ... below (masks)
  opts.anchor = i keeps node i at its current position.
  opts.obstacles = { {x=, y=}, ... } tiles that stay put and must not be covered.
Returns positions[i] = { x = , y = }, info  or nil, err.
]]
function M.layout(nodes, edges, opts)
  local o = copyDefaults(opts)

  -- merge duplicate links between the same two nodes
  local uniq, byKey = {}, {}
  for _, e in ipairs(edges) do
    if e.from ~= e.to and nodes[e.from] and nodes[e.to] then
      local key = e.from .. ">" .. e.to
      local cur = byKey[key]
      if not cur then
        cur = { from = e.from, to = e.to, slot = e.slot or 0, main = e.main }
        byKey[key] = cur
        uniq[#uniq + 1] = cur
      elseif e.main or (not cur.main and math.abs(e.slot or 0) < math.abs(cur.slot)) then
        cur.slot, cur.main = e.slot or 0, e.main
      end
    end
  end
  edges = uniq

  local dir = o.direction
  if dir ~= "horizontal" and dir ~= "vertical" then
    local dx, dy = 0, 0
    for _, e in ipairs(edges) do
      dx = dx + math.abs(nodes[e.to].x - nodes[e.from].x)
      dy = dy + math.abs(nodes[e.to].y - nodes[e.from].y)
    end
    dir = (dy > dx) and "vertical" or "horizontal"
  end
  local sp = o[dir]
  local function rs(n)
    if dir == "horizontal" then return n.x, n.y end
    return n.y, n.x
  end

  -- connected components (union-find)
  local parent = {}
  local function find(i)
    while parent[i] ~= i do
      parent[i] = parent[parent[i]]
      i = parent[i]
    end
    return i
  end
  local ids = {}
  for i in pairs(nodes) do ids[#ids + 1] = i; parent[i] = i end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  for _, e in ipairs(edges) do
    local a, b = find(e.from), find(e.to)
    if a ~= b then parent[a] = b end
  end
  local groups, order = {}, {}
  for _, i in ipairs(ids) do
    local g = find(i)
    if not groups[g] then
      groups[g] = { nodes = {}, edges = {} }
      order[#order + 1] = g
    end
    table.insert(groups[g].nodes, i)
  end
  for k, e in ipairs(edges) do table.insert(groups[find(e.from)].edges, k) end

  local origS, maxR0, minS0 = {}, -math.huge, math.huge
  for _, i in ipairs(ids) do
    local r, s = rs(nodes[i])
    origS[i] = s
    maxR0 = math.max(maxR0, r)
    minS0 = math.min(minS0, s)
  end

  -- lay out each tree; stack them in their current order across the flow
  local comps = {}
  for _, g in ipairs(order) do
    local G = groups[g]
    local pos, width, crossings = layoutComponent(nodes, edges, G.nodes, G.edges, sp, o, origS)
    if not pos then return nil, width end
    local sum, smin, smax = 0, math.huge, -math.huge
    for _, i in ipairs(G.nodes) do
      sum = sum + origS[i]
      smin = math.min(smin, pos[i].s)
      smax = math.max(smax, pos[i].s)
    end
    comps[#comps + 1] = { nodes = G.nodes, pos = pos, width = width,
      key = sum / #G.nodes, smin = smin, smax = smax, crossings = crossings }
  end
  table.sort(comps, function(a, b) return a.key < b.key end)

  local out, cursor, crossings = {}, 0, 0
  for _, c in ipairs(comps) do
    local shiftS = cursor - c.smin
    for _, i in ipairs(c.nodes) do
      local p = c.pos[i]
      local r = snap(maxR0, o.snap) + snap(p.r - c.width, o.snap)
      local s = snap(minS0, o.snap) + snap(shiftS + p.s, o.snap)
      if dir == "horizontal" then out[i] = { x = r, y = s }
      else out[i] = { x = s, y = r } end
    end
    cursor = cursor + (c.smax - c.smin) + sp.node + o.componentGap
    crossings = crossings + c.crossings
  end
  local a = o.anchor
  if a and out[a] then
    local dx, dy = nodes[a].x - out[a].x, nodes[a].y - out[a].y
    for _, p in pairs(out) do p.x, p.y = p.x + dx, p.y + dy end
    out[a] = { x = nodes[a].x, y = nodes[a].y }
  end

  -- Keep clear of tiles that are not being arranged. Without an anchor the
  -- block slides across the flow; an anchored block stays and overlaps are reported.
  local obstacles = o.obstacles or {}
  local function overlaps(ds)
    local sx, sy = 0, ds
    if dir == "vertical" then sx, sy = ds, 0 end
    local n = 0
    for _, p in pairs(out) do
      for _, q in ipairs(obstacles) do
        if math.abs(p.x + sx - q.x) < 1 - EPS and math.abs(p.y + sy - q.y) < 1 - EPS then n = n + 1 end
      end
    end
    return n
  end
  local hits = overlaps(0)
  if hits > 0 and not (a and out[a]) then
    local step = (o.snap and o.snap > 0) and o.snap or 0.25
    for k = 1, 4000 do
      local ds
      for _, sign in ipairs({ 1, -1 }) do
        if overlaps(sign * k * step) == 0 then ds = sign * k * step break end
      end
      if ds then
        for _, p in pairs(out) do
          if dir == "horizontal" then p.y = p.y + ds else p.x = p.x + ds end
        end
        hits = 0
        break
      end
    end
  end
  return out, { direction = dir, components = #comps, crossings = crossings, overlaps = hits }
end

local SKIP_TYPES = { Note = true, Underlay = true }
local MAIN_IDS = {
  Background = true, Input = true, MainInput = true, Input1 = true,
  SceneInput = true, SceneInput1 = true, Image = true, Image1 = true,
  Source = true, Data3D = true, MaterialInput = true,
}

local function getFlow(comp)
  local ok, fv = pcall(function() return comp.CurrentFrame.FlowView end)
  if ok and fv then return fv end
  for _, f in ipairs(comp:GetFrameList() or {}) do
    ok, fv = pcall(function() return f.FlowView end)
    if ok and fv then return fv end
  end
  return nil
end

local function topLevel(t)
  local seen = {}
  while t and not seen[t] do
    seen[t] = true
    local ok, parent = pcall(function() return t.ParentTool end)
    if not ok or not parent then return t end
    t = parent
  end
  return t
end

local function isMask(id, dt)
  return dt == "Mask" or id:find("Mask") ~= nil or id:find("Matte") ~= nil
end

-- Connected inputs of `tool` whose source is in `index`, with slot numbers.
local function toolEdges(tool, index)
  local list = {}
  local inputs = tool:GetInputList() or {}
  local keys = {}
  for k in pairs(inputs) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local inp = inputs[k]
    local ok, out = pcall(function() return inp:GetConnectedOutput() end)
    if ok and out then
      local src = topLevel(out:GetTool())
      if src and index[src] and src ~= tool then
        local a = inp:GetAttrs() or {}
        list[#list + 1] = { src = index[src], id = a.INPS_ID or "", dt = a.INPS_DataType or "" }
      end
    end
  end
  local main
  for i, l in ipairs(list) do
    if MAIN_IDS[l.id] then main = i; break end
  end
  if not main then
    for i, l in ipairs(list) do
      if not isMask(l.id, l.dt) and l.id ~= "Foreground" then main = i; break end
    end
  end
  if not main then
    for i, l in ipairs(list) do
      if not isMask(l.id, l.dt) then main = i; break end
    end
  end
  local above, below = 0, 0
  for i, l in ipairs(list) do
    if i == main then
      l.slot, l.main = 0, true
    elseif isMask(l.id, l.dt) then
      below = below + 1
      l.slot = below
    else
      above = above + 1
      l.slot = -above
    end
  end
  return list
end

-- opts: direction = "auto"|"horizontal"|"vertical"; selected = false to ignore
-- the selection; apply = false computes the layout without moving anything.
-- 2+ selected tools: only those are arranged. Otherwise the whole comp is.
-- The anchor (a single selected tool, else the active tool) keeps its position.
function M.run(comp, opts)
  opts = opts or {}
  local fu = fu or fusion or app
  comp = comp or fu:GetCurrentComp()
  if not comp then print("[NodeArrange] no comp") return end
  local flow = getFlow(comp)
  if not flow then print("[NodeArrange] no FlowView, open the Fusion page") return end

  local function gather(selected)
    local tools, seen = {}, {}
    for _, t in pairs(comp:GetToolList(selected) or {}) do
      local top = topLevel(t)
      if top == t and not seen[t] then
        local attrs = t:GetAttrs() or {}
        local x = flow:GetPos(t)
        if x and not SKIP_TYPES[attrs.TOOLS_RegID or ""] then
          seen[t] = true
          tools[#tools + 1] = t
        end
      end
    end
    return tools
  end

  local selected = (opts.selected ~= false) and gather(true) or {}
  local tools, scope = selected, "selection"
  if #selected < 2 then tools, scope = gather(false), "comp" end
  if #tools == 0 then print("[NodeArrange] nothing to arrange") return end
  local anchorTool = selected[1]
  if #selected ~= 1 then anchorTool = topLevel(comp.ActiveTool) end

  local index, nodes, edges = {}, {}, {}
  for i, t in ipairs(tools) do
    index[t] = i
    local x, y = flow:GetPos(t)
    nodes[i] = { x = x or 0, y = y or 0 }
  end
  for i, t in ipairs(tools) do
    for _, l in ipairs(toolEdges(t, index)) do
      edges[#edges + 1] = { from = l.src, to = i, slot = l.slot, main = l.main }
    end
  end

  local layoutOpts = copyDefaults(opts)
  layoutOpts.anchor = anchorTool and index[anchorTool]
  layoutOpts.obstacles = {}
  if scope == "selection" then
    for _, t in ipairs(gather(false)) do
      if not index[t] then
        local x, y = flow:GetPos(t)
        table.insert(layoutOpts.obstacles, { x = x, y = y })
      end
    end
  end
  local pos, info = M.layout(nodes, edges, layoutOpts)
  if not pos then print("[NodeArrange] " .. tostring(info)) return end
  if opts.apply == false then return pos, info, tools, edges end

  comp:StartUndo("Arrange Nodes")
  for i, t in ipairs(tools) do flow:QueueSetPos(t, pos[i].x, pos[i].y) end
  flow:FlushSetPosQueue()
  comp:EndUndo(true)

  flow:Select()
  for _, t in ipairs(tools) do flow:Select(t, true) end
  if layoutOpts.anchor then comp:SetActiveTool(anchorTool) end

  print(string.format("[NodeArrange] %d tools (%s), %d links, %s, %d trees, %d crossings, anchor %s",
    #tools, scope, #edges, info.direction, info.components, info.crossings,
    layoutOpts.anchor and anchorTool.Name or "none"))
  if info.overlaps > 0 then
    print(string.format("[NodeArrange] %d tiles overlap unselected tools%s", info.overlaps,
      layoutOpts.anchor and ("; the anchor " .. anchorTool.Name .. " was kept in place") or ""))
  end
end

return M
