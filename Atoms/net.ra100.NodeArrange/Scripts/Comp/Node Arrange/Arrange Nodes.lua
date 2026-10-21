-- Blender-style auto layout. Uses the selection (2+ tools), otherwise the whole comp; flow direction follows the comp's current links.
-- Core: Modules/Lua/NodeArrange.lua
local path = fu:MapPath("LuaModules:NodeArrange.lua")
if not bmd.fileexists(path) then
  path = fu:MapPath("Reactor:Deploy/Modules/Lua/NodeArrange.lua")
end
if not bmd.fileexists(path) then
  print("[NodeArrange] NodeArrange.lua not found in Modules/Lua")
  return
end
dofile(path).run(comp, { direction = "auto" })
