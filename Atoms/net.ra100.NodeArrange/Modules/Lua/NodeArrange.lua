--[[
NodeArrange - Blender-style "Arrange Nodes" for Fusion Studio and the
DaVinci Resolve Fusion page.

Layered (Sugiyama) layout: columns by longest path, dummy nodes on long links,
barycenter crossing reduction, then a weighted least-squares fit per column.

M.layout is pure Lua 5.1 with no Fusion calls, so it is tested offline.
M.run(comp, opts) is the Fusion glue.
]]

local M = {}
M.VERSION = "1.3"

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
  untangle = 200,      -- swap tries to move links off tiles they pass behind
}

local EPS = 1e-9
local MAIN_W = 16  -- weight of main-input links: keeps the image path straight
local CHAIN_W = 64 -- weight that holds a long link's dummies on its straight line

-- Nested option tables (horizontal, vertical) are merged key by key.
local function copyDefaults(opts)
  local o = {}
  for k, v in pairs(M.defaults) do
    if type(v) == "table" then
      o[k] = {}
      for a, b in pairs(v) do o[k][a] = b end
    else
      o[k] = v
    end
  end
  for k, v in pairs(opts or {}) do
    if type(v) == "table" and type(M.defaults[k]) == "table" then
      for a, b in pairs(v) do o[k][a] = b end
    else
      o[k] = v
    end
  end
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
  local segs, links = {}, {}
  for _, e in ipairs(compEdges) do
    local ed = edges[e]
    local a, b = itemOf[ed.from], itemOf[ed.to]
    local span = b.rank - a.rank
    local prev = a
    local link = { a = a, b = b, dummy = {} }
    links[#links + 1] = link
    for k = 1, span - 1 do
      local s0 = a.s0 + (b.s0 - a.s0) * k / span
      local d = newItem(nil, a.rank + minR + k, s0)
      d.chain = { a = a, b = b, t = k / span }
      link.dummy[d.rank] = d
      local w = (k > 1) and 8 or (ed.main and MAIN_W or 2)
      local sg = { a = prev, b = d, slot = 0, w = w, main = ed.main }
      segs[#segs + 1] = sg
      table.insert(outSeg[prev], sg)
      table.insert(inSeg[d], sg)
      prev = d
    end
    local w = ed.main and MAIN_W or 1
    if span > 1 and not ed.main then w = 2 end
    local sg = { a = prev, b = b, slot = ed.slot or 0, w = w, main = ed.main }
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
  local sizes = o.sizes or {}
  local function extent(it, axis)
    local z = it.node and sizes[it.node]
    return z and z[axis] or 1
  end
  local function gapBetween(p, q)
    local g
    if p.node and q.node then g = sp.node
    elseif not p.node and not q.node then g = sp.dummy
    else g = (sp.node + sp.dummy) / 2 end
    return g + (extent(p, "s") - 1) / 2 + (extent(q, "s") - 1) / 2
  end

  -- column positions; a wide block pushes its neighbouring columns apart
  local wide, R = {}, { [0] = 0 }
  for r = 0, nLayers - 1 do wide[r] = 1 end
  for _, it in ipairs(items) do wide[it.rank] = math.max(wide[it.rank], extent(it, "r")) end
  for r = 1, nLayers - 1 do
    R[r] = R[r - 1] + sp.layer + (wide[r - 1] - 1) / 2 + (wide[r] - 1) / 2
  end


  local function assign()
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

    -- Straighten main links: a tool goes level with its main input (or a
    -- source with its only, main, consumer) wherever its column has room.
    local function realEnd(sg, up)
      local it = up and sg.a or sg.b
      if it.chain then return up and it.chain.a or it.chain.b end
      return it
    end
    local function tryLevel(L, i, want)
      local it = L[i]
      if i > 1 and want < s[L[i - 1]] + gapBetween(L[i - 1], it) - EPS then return end
      if i < #L and want > s[L[i + 1]] - gapBetween(it, L[i + 1]) + EPS then return end
      s[it] = want
    end
    for r = 1, nLayers - 1 do
      local L = layers[r]
      for i, it in ipairs(L) do
        if it.node then
          for _, sg in ipairs(inSeg[it]) do
            if sg.main then tryLevel(L, i, s[realEnd(sg, true)]) break end
          end
        end
      end
    end
    for r = nLayers - 2, 0, -1 do
      local L = layers[r]
      for i, it in ipairs(L) do
        if it.node and #inSeg[it] == 0 and #outSeg[it] == 1 and outSeg[it][1].main then
          tryLevel(L, i, s[realEnd(outSeg[it][1], false)])
        end
      end
    end
    -- put long links' dummies back on the line between their moved ends
    for r = 1, nLayers - 2 do
      local L = layers[r]
      for i, it in ipairs(L) do
        local ch = it.chain
        if ch then tryLevel(L, i, s[ch.a] + (s[ch.b] - s[ch.a]) * ch.t) end
      end
    end
    return s
  end

  -- Swap neighbours in a column while that lowers the number of links drawn
  -- behind tiles and adds no crossings.
  local function throughTiles(s)
    local hits = {}
    for _, l in ipairs(links) do
      local ra, rb, sa, sb = R[l.a.rank], R[l.b.rank], s[l.a], s[l.b]
      for r = l.a.rank, l.b.rank do
        for i, it in ipairs(layers[r]) do
          if it.node and it ~= l.a and it ~= l.b then
            local hr, hs = extent(it, "r") / 2 - 0.05, extent(it, "s") / 2 - 0.05
            local r0, r1 = math.max(ra, R[r] - hr), math.min(rb, R[r] + hr)
            if r0 <= r1 then
              local s0 = sa + (sb - sa) * (r0 - ra) / (rb - ra)
              local s1 = sa + (sb - sa) * (r1 - ra) / (rb - ra)
              if math.max(s0, s1) > s[it] - hs and math.min(s0, s1) < s[it] + hs then
                hits[#hits + 1] = { r = r, i = i, link = l }
              end
            end
          end
        end
      end
    end
    return hits
  end

  local s = assign()
  local hits = throughTiles(s)
  local budget = o.untangle
  while #hits > 0 and budget > 0 do
    local tried, accepted = {}, false
    for _, h in ipairs(hits) do
      local cand = { { h.r, h.i - 1 }, { h.r, h.i } }
      local d = h.link.dummy[h.r]
      if d then
        for j, it in ipairs(layers[h.r]) do
          if it == d then cand[#cand + 1] = { h.r, j - 1 }; cand[#cand + 1] = { h.r, j } end
        end
      end
      for _, c in ipairs(cand) do
        local r, i = c[1], c[2]
        local L = layers[r]
        local key = r .. ":" .. i
        if i >= 1 and i < #L and not tried[key] and budget > 0 then
          tried[key], budget = true, budget - 1
          L[i], L[i + 1] = L[i + 1], L[i]
          if totalCrossings() <= bestC then
            local s2 = assign()
            local h2 = throughTiles(s2)
            if #h2 < #hits then
              s, hits, accepted = s2, h2, true
              break
            end
          end
          L[i], L[i + 1] = L[i + 1], L[i]
        end
      end
      if accepted then break end
    end
    if not accepted then break end
  end

  local pos = {}
  for _, it in ipairs(items) do
    if it.node then pos[it.node] = { r = R[it.rank], s = s[it] } end
  end
  return pos, R[nLayers - 1], bestC
end

local function mergeEdges(nodes, edges)
  local uniq, byKey = {}, {}
  for _, e in ipairs(edges) do
    if e.from ~= e.to and nodes[e.from] and nodes[e.to] then
      local key = tostring(e.from) .. ">" .. tostring(e.to)
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
  return uniq
end

-- Drop links that close a cycle (a Group counted as one tile can create one).
local function dropBackEdges(nodes, edges)
  local succ, ids = {}, {}
  for k, e in ipairs(edges) do
    succ[e.from] = succ[e.from] or {}
    table.insert(succ[e.from], k)
  end
  for i in pairs(nodes) do ids[#ids + 1] = i end
  table.sort(ids, function(a, b) return tostring(a) < tostring(b) end)
  local state, back = {}, {}
  for _, root in ipairs(ids) do
    if not state[root] then
      state[root] = 1
      local stack = { { v = root, k = 1 } }
      while #stack > 0 do
        local top = stack[#stack]
        local k = (succ[top.v] or {})[top.k]
        if k then
          top.k = top.k + 1
          local w = edges[k].to
          if state[w] == 1 then
            back[k] = true
          elseif not state[w] then
            state[w] = 1
            stack[#stack + 1] = { v = w, k = 1 }
          end
        else
          state[top.v] = 2
          stack[#stack] = nil
        end
      end
    end
  end
  local kept, n = {}, 0
  for k, e in ipairs(edges) do
    if back[k] then n = n + 1 else kept[#kept + 1] = e end
  end
  return kept, n
end

-- Lay out every connected component and stack them across the flow.
local function arrange(nodes, edges, o, dir)
  local sp = o[dir]
  local sizes = o.sizes or {}
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

  local function half(i, axis)
    local z = sizes[i]
    return z and (z[axis] - 1) / 2 or 0
  end
  -- align on tile edges, so a big block lands where its old frame was
  local origS, maxR0, minS0 = {}, -math.huge, math.huge
  for _, i in ipairs(ids) do
    local r, s = rs(nodes[i])
    origS[i] = s
    maxR0 = math.max(maxR0, r + half(i, "r"))
    minS0 = math.min(minS0, s - half(i, "s"))
  end

  local comps = {}
  for _, g in ipairs(order) do
    local G = groups[g]
    local pos, err, crossings = layoutComponent(nodes, edges, G.nodes, G.edges, sp, o, origS)
    if not pos then return nil, err end
    local sum, smin, smax, right = 0, math.huge, -math.huge, -math.huge
    for _, i in ipairs(G.nodes) do
      sum = sum + origS[i]
      smin = math.min(smin, pos[i].s - half(i, "s"))
      smax = math.max(smax, pos[i].s + half(i, "s"))
      right = math.max(right, pos[i].r + half(i, "r"))
    end
    comps[#comps + 1] = { nodes = G.nodes, pos = pos, right = right,
      key = sum / #G.nodes, smin = smin, smax = smax, crossings = crossings }
  end
  table.sort(comps, function(a, b) return a.key < b.key end)

  local out, cursor, crossings = {}, 0, 0
  for _, c in ipairs(comps) do
    local shiftS = cursor - c.smin
    for _, i in ipairs(c.nodes) do
      local p = c.pos[i]
      local r = snap(maxR0, o.snap) + snap(p.r - c.right, o.snap)
      local s = snap(minS0, o.snap) + snap(shiftS + p.s, o.snap)
      if dir == "horizontal" then out[i] = { x = r, y = s }
      else out[i] = { x = s, y = r } end
    end
    cursor = cursor + (c.smax - c.smin) + sp.node + o.componentGap
    crossings = crossings + c.crossings
  end
  return out, { direction = dir, components = #comps, crossings = crossings }
end

-- Each cluster (an Underlay and the tools inside it) is laid out on its own,
-- then placed as one big tile.
local function acyclic(edges, owner)
  local succ, indeg, all = {}, {}, {}
  local function id(i) return owner[i] and ("cluster:" .. owner[i]) or i end
  for _, e in ipairs(edges) do
    local a, b = id(e.from), id(e.to)
    if a ~= b then
      succ[a] = succ[a] or {}
      table.insert(succ[a], b)
      indeg[b] = (indeg[b] or 0) + 1
      all[a], all[b] = true, true
    end
  end
  local queue, n, seen = {}, 0, 0
  for v in pairs(all) do
    n = n + 1
    if not indeg[v] then queue[#queue + 1] = v end
  end
  local head = 1
  while head <= #queue do
    local v = queue[head]
    head, seen = head + 1, seen + 1
    for _, w in ipairs(succ[v] or {}) do
      indeg[w] = indeg[w] - 1
      if indeg[w] == 0 then queue[#queue + 1] = w end
    end
  end
  return seen == n
end

local function arrangeClustered(nodes, edges, o, dir)
  -- A frame that a path leaves and re-enters would make a cycle; such frames are dropped.
  local owner, blocks, dropped = {}, {}, {}
  for k, c in ipairs(o.clusters) do
    local members = {}
    for _, i in ipairs(c.members or {}) do
      if nodes[i] and not owner[i] then owner[i] = k; members[#members + 1] = i end
    end
    if #members > 0 then
      if acyclic(edges, owner) then
        blocks[k] = { members = members, pad = c.pad or {} }
      else
        for _, i in ipairs(members) do owner[i] = nil end
        dropped[#dropped + 1] = k
      end
    end
  end

  local cnodes, sizes = {}, {}
  for i, n in pairs(nodes) do if not owner[i] then cnodes[i] = n end end
  for k, b in pairs(blocks) do
    local sub, subEdges, ix = {}, {}, {}
    local p = b.pad
    local ox0, ox1, oy0, oy1 = math.huge, -math.huge, math.huge, -math.huge
    for j, i in ipairs(b.members) do
      sub[j], ix[i] = nodes[i], j
      ox0, ox1 = math.min(ox0, nodes[i].x), math.max(ox1, nodes[i].x)
      oy0, oy1 = math.min(oy0, nodes[i].y), math.max(oy1, nodes[i].y)
    end
    for _, e in ipairs(edges) do
      if ix[e.from] and ix[e.to] then
        subEdges[#subEdges + 1] = { from = ix[e.from], to = ix[e.to], slot = e.slot, main = e.main }
      end
    end
    local so = copyDefaults(o)
    so.direction, so.clusters, so.anchor, so.obstacles, so.sizes = dir, nil, nil, nil, nil
    local rel, err = M.layout(sub, subEdges, so)
    if not rel then return nil, err end
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    for j in ipairs(b.members) do
      x0, x1 = math.min(x0, rel[j].x), math.max(x1, rel[j].x)
      y0, y1 = math.min(y0, rel[j].y), math.max(y1, rel[j].y)
    end
    b.rel = rel
    b.box = { left = x0 - (p.left or 0.5), right = x1 + (p.right or 0.5),
              top = y0 - (p.top or 0.5), bottom = y1 + (p.bottom or 0.5) }
    b.key = "cluster:" .. k
    -- the block stands where its old frame was centred
    cnodes[b.key] = { x = (ox0 - (p.left or 0.5) + ox1 + (p.right or 0.5)) / 2,
                      y = (oy0 - (p.top or 0.5) + oy1 + (p.bottom or 0.5)) / 2 }
    local w, h = b.box.right - b.box.left, b.box.bottom - b.box.top
    sizes[b.key] = (dir == "horizontal") and { r = w, s = h } or { r = h, s = w }
  end

  local cedges = {}
  for _, e in ipairs(edges) do
    local a = owner[e.from] and blocks[owner[e.from]].key or e.from
    local z = owner[e.to] and blocks[owner[e.to]].key or e.to
    cedges[#cedges + 1] = { from = a, to = z, slot = e.slot, main = e.main }
  end
  local co = copyDefaults(o)
  co.sizes = sizes
  local out, info = arrange(cnodes, mergeEdges(cnodes, cedges), co, dir)
  if not out then return nil, info end

  info.clusters, info.dropped = {}, dropped
  for k, b in pairs(blocks) do
    local c = out[b.key]
    out[b.key] = nil
    local cx = snap((b.box.left + b.box.right) / 2, o.snap)
    local cy = snap((b.box.top + b.box.bottom) / 2, o.snap)
    local dx, dy = c.x - cx, c.y - cy
    for j, i in ipairs(b.members) do out[i] = { x = b.rel[j].x + dx, y = b.rel[j].y + dy } end
    info.clusters[k] = { left = b.box.left + dx, right = b.box.right + dx,
                         top = b.box.top + dy, bottom = b.box.bottom + dy }
  end
  return out, info
end

--[[
Pure layout.
  nodes[i] = { x = , y = }  current flow positions
  edges[k] = { from = i, to = j, slot = int, main = bool }
    slot: 0 = main input, -1, -2 ... above (Foreground), 1, 2 ... below (masks)
  opts.anchor = i keeps node i at its current position.
  opts.obstacles = { {x=, y=, w=, h=}, ... } boxes that stay put and must not be covered
    (w, h default to one tile).
  opts.clusters = { {members = {i, ...}, pad = {left=, right=, top=, bottom=}}, ... }
    nodes kept together inside a frame; info.clusters[k] is the frame's new box.
Returns positions[i] = { x = , y = }, info  or nil, err.
]]
function M.layout(nodes, edges, opts)
  local o = copyDefaults(opts)
  local broken
  edges, broken = dropBackEdges(nodes, mergeEdges(nodes, edges))

  -- auto: the axis along which more links point forward
  local dir = o.direction
  if dir ~= "horizontal" and dir ~= "vertical" then
    local h, v = 0, 0
    for _, e in ipairs(edges) do
      if nodes[e.to].x - nodes[e.from].x > 0.25 then h = h + 1 end
      if nodes[e.to].y - nodes[e.from].y > 0.25 then v = v + 1 end
    end
    dir = (v > h) and "vertical" or "horizontal"
  end

  local out, info
  if o.clusters and #o.clusters > 0 then
    out, info = arrangeClustered(nodes, edges, o, dir)
    if not out then return nil, info end
  else
    out, info = arrange(nodes, edges, o, dir)
    if not out then return nil, info end
  end
  info.clusters = info.clusters or {}
  info.dropped = info.dropped or {}
  info.cycles = broken

  local function move(dx, dy)
    for _, p in pairs(out) do p.x, p.y = p.x + dx, p.y + dy end
    for _, c in pairs(info.clusters) do
      c.left, c.right, c.top, c.bottom = c.left + dx, c.right + dx, c.top + dy, c.bottom + dy
    end
  end

  local a = o.anchor
  local anchored = a and out[a]
  if anchored then
    move(nodes[a].x - out[a].x, nodes[a].y - out[a].y)
    out[a] = { x = nodes[a].x, y = nodes[a].y }
  end

  -- Keep clear of boxes that are not being arranged. Without an anchor the
  -- block slides across the flow; an anchored block stays and overlaps are reported.
  local obstacles = o.obstacles or {}
  local bodies = {}
  local inCluster = {}
  for _, c in pairs(info.clusters) do
    bodies[#bodies + 1] = { x = (c.left + c.right) / 2, y = (c.top + c.bottom) / 2,
                            w = c.right - c.left, h = c.bottom - c.top }
  end
  for k, c in ipairs(o.clusters or {}) do
    if info.clusters[k] then
      for _, i in ipairs(c.members or {}) do inCluster[i] = true end
    end
  end
  for i, p in pairs(out) do
    if not inCluster[i] then bodies[#bodies + 1] = { p = p } end
  end
  local function overlaps(ds)
    local sx, sy = 0, ds
    if dir == "vertical" then sx, sy = ds, 0 end
    local n = 0
    for _, b in ipairs(bodies) do
      local bx, by = (b.p and b.p.x or b.x) + sx, (b.p and b.p.y or b.y) + sy
      local bw, bh = b.w or 1, b.h or 1
      for _, q in ipairs(obstacles) do
        if math.abs(bx - q.x) < (bw + (q.w or 1)) / 2 - EPS
          and math.abs(by - q.y) < (bh + (q.h or 1)) / 2 - EPS then
          n = n + 1
        end
      end
    end
    return n
  end
  local hits = (#obstacles > 0) and overlaps(0) or 0
  if hits > 0 and not anchored then
    local step = (o.snap and o.snap > 0) and o.snap or 0.25
    for k = 1, 4000 do
      local ds
      for _, sign in ipairs({ 1, -1 }) do
        if overlaps(sign * k * step) == 0 then ds = sign * k * step break end
      end
      if ds then
        if dir == "horizontal" then move(0, ds) else move(ds, 0) end
        hits = 0
        break
      end
    end
  end
  info.overlaps = hits

  -- crossings as Fusion draws them: straight lines between tile centres
  local function side(a, b, c) return (c.y - a.y) * (b.x - a.x) - (b.y - a.y) * (c.x - a.x) end
  local drawn = 0
  for i = 1, #edges do
    local e = edges[i]
    local p1, p2 = out[e.from], out[e.to]
    for j = i + 1, #edges do
      local f = edges[j]
      if f.from ~= e.from and f.from ~= e.to and f.to ~= e.from and f.to ~= e.to then
        local q1, q2 = out[f.from], out[f.to]
        if side(q1, q2, p1) * side(q1, q2, p2) < 0 and side(p1, p2, q1) * side(p1, p2, q2) < 0 then
          drawn = drawn + 1
        end
      end
    end
  end
  info.drawn = drawn
  return out, info
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

-- An Underlay's size exists only in its saved settings (ViewInfo.Size, in pixels).
-- SetPos puts its top-left corner where a tile at the same position has its own.
local PX_X, PX_Y = 110, 33                  -- ViewInfo pixels per flow unit
local TILE_HW, TILE_HH = 43 / PX_X, 8 / PX_Y  -- half a tile, in flow units

local function underlayRect(comp, flow, u)
  local x, y = flow:GetPos(u)
  local st = comp:CopySettings(u)
  local t = st and st.Tools and st.Tools[u.Name]
  local size = t and t.ViewInfo and t.ViewInfo.Size
  if not (x and size) then return nil end
  local left, top = x - TILE_HW, y - TILE_HH
  return { left = left, top = top, right = left + size[1] / PX_X, bottom = top + size[2] / PX_Y }
end

-- Returns the Underlay, which is a new tool when it had to be resized.
local function setUnderlayRect(comp, flow, u, r, old)
  local w, h = r.right - r.left, r.bottom - r.top
  if math.abs(w - (old.right - old.left)) > 1e-6 or math.abs(h - (old.bottom - old.top)) > 1e-6 then
    -- Size cannot be set on a live tool: replace it with a resized copy.
    -- Delete first so the copy keeps the name; a rename would not be undone.
    local name = u.Name
    local st = comp:CopySettings(u)
    st.Tools[name].ViewInfo.Size = { w * PX_X, h * PX_Y }
    u:Delete()
    flow:Select()
    comp:Paste(st)
    u = comp:FindTool(name)
    if not u then error("could not re-create Underlay " .. name) end
  end
  flow:SetPos(u, r.left + TILE_HW, r.top + TILE_HH)
  return u
end

local function framePad(rect, members, posOf)
  local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
  for _, t in ipairs(members) do
    local x, y = posOf(t)
    x0, x1, y0, y1 = math.min(x0, x), math.max(x1, x), math.min(y0, y), math.max(y1, y)
  end
  return { left = x0 - rect.left, right = rect.right - x1, top = y0 - rect.top, bottom = rect.bottom - y1 },
         { left = x0, right = x1, top = y0, bottom = y1 }
end

-- opts: direction = "auto"|"horizontal"|"vertical"; selected = false to ignore
-- the selection; apply = false computes the layout without moving anything.
-- 2+ selected tools: only those are arranged. Otherwise the whole comp is.
-- A tool selected inside a Group counts as the Group; a selected Underlay
-- selects the tools inside it.
-- The anchor (a single selected tool, else the active tool) keeps its position.
function M.run(comp, opts)
  opts = opts or {}
  local fu = fu or fusion or app
  comp = comp or fu:GetCurrentComp()
  if not comp then print("[NodeArrange] no comp") return end
  local flow = getFlow(comp)
  if not flow then print("[NodeArrange] no FlowView, open the Fusion page") return end

  -- top-level tiles, and the Notes and Underlays that are not arranged as tiles
  local all, extras, seen = {}, {}, {}
  for _, t in pairs(comp:GetToolList(false) or {}) do
    if topLevel(t) == t and not seen[t] and flow:GetPos(t) then
      seen[t] = true
      local id = (t:GetAttrs() or {}).TOOLS_RegID or ""
      if SKIP_TYPES[id] then extras[#extras + 1] = t else all[#all + 1] = t end
    end
  end

  -- A tool belongs to the outermost Underlay its centre is in; that Underlay
  -- and its tools move as one block. Nested Underlays are refitted after.
  local frames, frameOf = {}, {}
  for _, u in ipairs(extras) do
    local r = (u:GetAttrs().TOOLS_RegID == "Underlay") and underlayRect(comp, flow, u)
    if r then
      frames[#frames + 1] = { tool = u, rect = r, members = {}, inner = {} }
      frameOf[u] = frames[#frames]
    end
  end
  local function area(r) return (r.right - r.left) * (r.bottom - r.top) end
  local function inside(r, x, y) return x > r.left and x < r.right and y > r.top and y < r.bottom end
  for _, t in ipairs(all) do
    local x, y = flow:GetPos(t)
    local outer, inner
    for _, f in ipairs(frames) do
      if inside(f.rect, x, y) then
        if not outer or area(f.rect) > area(outer.rect) then outer = f end
        if not inner or area(f.rect) < area(inner.rect) then inner = f end
      end
    end
    if outer then table.insert(outer.members, t) end
    if inner and inner ~= outer then table.insert(inner.inner, t) end
  end

  local picked, raw = {}, 0
  for _, t in pairs((opts.selected ~= false) and comp:GetToolList(true) or {}) do
    raw = raw + 1
    local top = topLevel(t)
    if frameOf[top] then
      for _, m in ipairs(frameOf[top].members) do picked[m] = true end
      for _, m in ipairs(frameOf[top].inner) do picked[m] = true end
    elseif not SKIP_TYPES[(top:GetAttrs() or {}).TOOLS_RegID or ""] then
      picked[top] = true
    end
  end
  local selected = {}
  for _, t in ipairs(all) do if picked[t] then selected[#selected + 1] = t end end
  local tools, scope = selected, "selection"
  if #selected < 2 then
    tools, scope = all, "comp"
    if raw > 0 and #selected == 0 then
      print("[NodeArrange] the selection has no tools to arrange; arranging the whole comp")
    end
  end
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
  layoutOpts.obstacles, layoutOpts.clusters = {}, {}
  if scope == "selection" then
    for _, t in ipairs(all) do
      if not index[t] then
        local x, y = flow:GetPos(t)
        table.insert(layoutOpts.obstacles, { x = x, y = y })
      end
    end
  end
  local function oldPos(t) return flow:GetPos(t) end
  local clusterFrame = {}
  for _, f in ipairs(frames) do
    local arranged = 0
    for _, t in ipairs(f.members) do if index[t] then arranged = arranged + 1 end end
    if arranged > 0 and arranged == #f.members then
      local ids = {}
      for _, t in ipairs(f.members) do ids[#ids + 1] = index[t] end
      table.insert(layoutOpts.clusters, { members = ids, pad = framePad(f.rect, f.members, oldPos) })
      clusterFrame[#layoutOpts.clusters] = f
      f.cluster = true
    else
      local allInner = #f.inner > 0
      for _, t in ipairs(f.inner) do allInner = allInner and index[t] ~= nil end
      if allInner then f.innerPad = framePad(f.rect, f.inner, oldPos) end
    end
  end

  -- Notes and Underlays without tools of their own ride along with the block
  -- they sit in; any other Underlay without arranged tools is an obstacle.
  local riders = {}
  for _, t in ipairs(extras) do
    local f = frameOf[t]
    if not (f and (f.cluster or f.innerPad)) then
      local x, y = flow:GetPos(t)
      local host
      for _, g in ipairs(frames) do
        if g.cluster and g.tool ~= t and inside(g.rect, x, y)
          and (not host or area(g.rect) > area(host.rect)) then host = g end
      end
      if host then
        riders[#riders + 1] = { tool = t, host = host, x = x, y = y }
      elseif f and not f.cluster then
        local arranged = 0
        for _, m in ipairs(f.members) do if index[m] then arranged = arranged + 1 end end
        for _, m in ipairs(f.inner) do if index[m] then arranged = arranged + 1 end end
        if arranged == 0 then
          local r = f.rect
          table.insert(layoutOpts.obstacles, { x = (r.left + r.right) / 2, y = (r.top + r.bottom) / 2,
            w = r.right - r.left, h = r.bottom - r.top })
        end
      end
    end
  end

  local pos, info = M.layout(nodes, edges, layoutOpts)
  if not pos then print("[NodeArrange] " .. tostring(info)) return end
  if opts.apply == false then return pos, info, tools, edges end

  local moved = {}
  comp:StartUndo("Arrange Nodes")
  local ok, err = pcall(function()
    for i, t in ipairs(tools) do flow:QueueSetPos(t, pos[i].x, pos[i].y) end
    flow:FlushSetPosQueue()
    for k, r in pairs(info.clusters) do
      local f = clusterFrame[k]
      f.newRect = r
      f.tool = setUnderlayRect(comp, flow, f.tool, r, f.rect)
      moved[#moved + 1] = f.tool
    end
    for _, f in ipairs(frames) do
      if f.innerPad then
        local _, box = framePad(f.rect, f.inner, function(t) local p = pos[index[t]] return p.x, p.y end)
        local p = f.innerPad
        local r = { left = box.left - p.left, right = box.right + p.right,
                    top = box.top - p.top, bottom = box.bottom + p.bottom }
        f.tool = setUnderlayRect(comp, flow, f.tool, r, f.rect)
        moved[#moved + 1] = f.tool
      end
    end
    for _, rd in ipairs(riders) do
      local h = rd.host
      if h.newRect then
        flow:SetPos(rd.tool, rd.x + h.newRect.left - h.rect.left, rd.y + h.newRect.top - h.rect.top)
        moved[#moved + 1] = rd.tool
      end
    end
  end)
  comp:EndUndo(true)
  if not ok then print("[NodeArrange] stopped part way, use Undo to go back: " .. tostring(err)) end

  flow:Select()
  for _, t in ipairs(tools) do flow:Select(t, true) end
  for _, u in ipairs(moved) do flow:Select(u, true) end
  if layoutOpts.anchor then comp:SetActiveTool(anchorTool) end

  print(string.format("[NodeArrange] %d tools (%s), %d links, %s, %d trees, %d crossings, %d underlays/notes, anchor %s",
    #tools, scope, #edges, info.direction, info.components, info.drawn, #moved,
    layoutOpts.anchor and anchorTool.Name or "none"))
  for _, k in ipairs(info.dropped) do
    print(string.format("[NodeArrange] %s: a link leaves it and comes back, so its tools were arranged on their own",
      clusterFrame[k] and clusterFrame[k].tool.Name or "underlay"))
  end
  if info.cycles > 0 then
    print(string.format("[NodeArrange] %d links close a loop through a Group and were ignored for the layout", info.cycles))
  end
  if info.overlaps > 0 then
    print(string.format("[NodeArrange] %d tiles overlap unselected tools%s", info.overlaps,
      layoutOpts.anchor and ("; the anchor " .. anchorTool.Name .. " was kept in place") or ""))
  end
end

return M
