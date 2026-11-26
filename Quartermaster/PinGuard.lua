-- PinGuard: a map icon never shows in the middle of the screen.
--
-- HereBeDragons (the library TomTom and others draw world map icons with) parks an icon on UIParent,
-- hidden, whenever the map lets go of it. OpenMap's own map view borrows those icons and, giving them
-- back, puts each on the frame it came from, centred, and shows it: for a parked icon that's UIParent,
-- so a waypoint pin (and its tooltip, "From: ...") sits in the middle of the screen. This hides any
-- such icon the moment it's shown there. An icon on UIParent is never meant to be seen.
--
-- The same file is in several of the user's addons; whichever loads first does the work (a newer
-- VERSION takes over).

local VERSION = 1
if type(_G.PinGuardVersion) == "number" and _G.PinGuardVersion >= VERSION then return end
_G.PinGuardVersion = VERSION

local guarded = setmetatable({}, { __mode = "k" })
local hooked = setmetatable({}, { __mode = "k" }) -- lib -> { [method] = the function hooked }

local function OffScreen(icon)
  if _G.PinGuardVersion ~= VERSION then return end -- a newer copy is doing it
  if icon.GetParent and icon:GetParent() == UIParent and icon.IsShown and icon:IsShown() then icon:Hide() end
end

local function Guard(icon)
  if type(icon) ~= "table" or guarded[icon] or type(icon.GetParent) ~= "function" then return end
  guarded[icon] = true
  pcall(hooksecurefunc, icon, "Show", OffScreen)
  pcall(hooksecurefunc, icon, "SetParent", OffScreen)
  if icon.HookScript then pcall(icon.HookScript, icon, "OnShow", OffScreen) end
  OffScreen(icon)
end

local ADDS = { "AddWorldMapIconMap", "AddWorldMapIconWorld" }

-- Every icon a copy of the library holds now, and every one it's handed from here on.
local function Watch(lib)
  if type(lib) ~= "table" then return end
  for icon in pairs(type(lib.worldmapPins) == "table" and lib.worldmapPins or {}) do Guard(icon) end
  local mine = hooked[lib] or {}
  hooked[lib] = mine
  for _, name in ipairs(ADDS) do
    -- (a newer copy of the library replaces its functions: hook the new one)
    if type(lib[name]) == "function" and lib[name] ~= mine[name] then
      pcall(hooksecurefunc, lib, name, function(_, _, icon) Guard(icon) end)
      mine[name] = lib[name]
    end
  end
end

local function WatchAll()
  local stub = _G.LibStub
  if type(stub) == "table" and type(stub.IterateLibraries) == "function" then
    for name, lib in stub:IterateLibraries() do
      if type(name) == "string" and (name:match("^HereBeDragons.*%-Pins%-2%.0$") or name == "HereBeDragons-Pins-ZGV") then
        Watch(lib)
      end
    end
  end
  -- Questie 12.8 and later keeps its copy as one of its own modules, not in LibStub.
  local loader = _G.QuestieLoader
  local modules = type(loader) == "table" and rawget(loader, "_modules")
  if type(modules) == "table" then Watch(rawget(modules, "HBDPins")) end
end

pcall(WatchAll)
if CreateFrame then
  local frame = CreateFrame("Frame")
  frame:RegisterEvent("ADDON_LOADED")
  frame:RegisterEvent("PLAYER_LOGIN")
  frame:SetScript("OnEvent", function() pcall(WatchAll) end)
end
