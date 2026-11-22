-- Vendors and trainers: what each one offers, saved when you open their window, together with
-- where they stand. Also flight masters: where each stands and which flight point it is, and
-- (per character, section "flightPaths") which flight points you know. Shared by the whole account:
--   QuartermasterDB.account.npcs[npcID]      name, map position, what kind of NPC
--   QuartermasterDB.account.vendors[npcID]   everything the vendor sells, with prices and costs
--   QuartermasterDB.account.trainers[npcID]  everything the trainer teaches, with cost and requirements

local _, ns = ...

local Try = ns.Try
local RequestLoad = C_Item and C_Item.RequestLoadItemDataByID

-- Remembers the NPC you're talking to and where it stands (your own position: you're in reach).
-- Returns its ID (or "name:<name>" if the game gives no ID) and its name.
local function NoteNpc(kind, flightNode)
  local id = ns.NpcID("npc")
  local name = Try(UnitName, "npc")
  if not ns.Plain(name) then name = nil end
  if not id and not name then return nil end
  local key = id or ("name:" .. name)
  local old = ns.db.account.npcs[key] or {}
  local pos = ns.Position()
  local kinds = {}
  for k in pairs(old.kinds or {}) do kinds[k] = true end
  kinds[kind] = true
  local info = ns.Char() and ns.Char().info or {}
  ns.SaveShared("npcs", key, {
    name = name or old.name, kinds = kinds,
    -- Inside buildings the game sometimes gives no position; the last known one is kept.
    map = pos.x and pos.map or old.map or pos.map, mapName = pos.x and pos.mapName or old.mapName or pos.mapName,
    x = pos.x or old.x, y = pos.y or old.y,
    zone = pos.zone or old.zone, subzone = pos.subzone or old.subzone,
    -- The faction and ruleset of the character who could talk to it.
    faction = info.faction or old.faction, ruleset = info.ruleset or old.ruleset,
    -- For a flight master: the flight point it stands at.
    flightNode = flightNode or old.flightNode,
  })
  return key, name
end
ns.NoteNpc = NoteNpc

-- Remembers a place that isn't an NPC (a mailbox), where you're standing. One record per spot.
local function NotePlace(kind, name)
  local pos = ns.Position()
  if not (pos.map and pos.x) then return nil end
  local key = ("%s:%d:%d:%d"):format(kind, pos.map, math.floor(pos.x + 0.5), math.floor(pos.y + 0.5))
  local info = ns.Char() and ns.Char().info or {}
  ns.SaveShared("npcs", key, {
    name = name, kinds = { [kind] = true }, map = pos.map, mapName = pos.mapName, x = pos.x, y = pos.y,
    zone = pos.zone, subzone = pos.subzone, faction = info.faction, ruleset = info.ruleset,
  })
  return key
end
ns.NotePlace = NotePlace

----------------------------------------------------------------------
-- Vendor
----------------------------------------------------------------------

local merchantOpen = false

local function MerchantItemID(i)
  return (GetMerchantItemID and Try(GetMerchantItemID, i)) or ns.ItemID(GetMerchantItemLink and Try(GetMerchantItemLink, i))
end

-- Asks the game to load every item the vendor sells, so their tooltips are complete.
local function RequestMerchantItems()
  if not RequestLoad then return end
  for i = 1, Try(GetMerchantNumItems) or 0 do
    local id = MerchantItemID(i)
    if id then pcall(RequestLoad, id) end
  end
end

-- Costs that aren't gold, like Merchant's Favor.
local function ExtraCosts(i)
  local costs = {}
  if not (GetMerchantItemCostInfo and GetMerchantItemCostItem) then return costs end
  for c = 1, Try(GetMerchantItemCostInfo, i) or 0 do
    local _, value, link, currencyName = GetMerchantItemCostItem(i, c)
    costs[#costs + 1] = {
      n = value, name = currencyName or (type(link) == "string" and link:match("%[(.-)%]")) or nil,
      item = ns.ItemID(link), currency = type(link) == "string" and tonumber(link:match("currency:(%d+)")) or nil,
    }
  end
  return costs
end

local function SaveVendor()
  if not merchantOpen or not GetMerchantNumItems then return end
  local count = GetMerchantNumItems() or 0
  if count == 0 then return end
  local key, npcName = NoteNpc("vendor")
  if not key then return end
  local items = {}
  for i = 1, count do
    local name, price, stack, stock, usable
    local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo and Try(C_MerchantFrame.GetItemInfo, i)
    if info then
      name, price, stack, stock, usable = info.name, info.price, info.stackCount, info.numAvailable, info.isUsable
    elseif GetMerchantItemInfo then
      local _
      name, _, price, stack, stock, _, usable = GetMerchantItemInfo(i)
    end
    local link = GetMerchantItemLink and Try(GetMerchantItemLink, i)
    local id = MerchantItemID(i)
    if name or id then
      local costs = ExtraCosts(i)
      -- Only the tooltip's requirement lines ("Requires Leatherworking (100)", "Requires
      -- Friendly with this faction."): a pattern's real skill and reputation requirements.
      local reqs = {}
      for _, line in ipairs(ns.Tooltip("MerchantItem", i)) do
        if line:find("^Requires ") then reqs[#reqs + 1] = line end
      end
      items[#items + 1] = {
        id = id, name = name, price = price, stack = stack,
        -- How many are left when the vendor's stock is limited.
        stock = (stock and stock >= 0) and stock or nil,
        costs = #costs > 0 and costs or nil,
        tip = #reqs > 0 and reqs or nil,
      }
      ns.Items.Note(link or id)
    end
  end
  local info = ns.Char() and ns.Char().info or {}
  ns.SaveShared("vendors", key, {
    npc = type(key) == "number" and key or nil, name = npcName,
    faction = info.faction, ruleset = info.ruleset, items = items,
  })
end

----------------------------------------------------------------------
-- Trainer
----------------------------------------------------------------------

local trainerOpen = false

-- A trainer entry's name, its sub-text (a rank, if any) and its status: "available",
-- "unavailable" (requirements not met), "used" (already known) or "header". Game versions order
-- the values differently, so the status is found by value.
local STATUS = { available = true, unavailable = true, used = true, header = true }
local function ServiceBasics(i)
  local info = { GetTrainerServiceInfo(i) }
  local name, sub, status = info[1], nil, nil
  for n = 2, #info do
    local v = info[n]
    if type(v) == "string" then
      if STATUS[v] then status = v elseif not sub and v ~= "" then sub = v end
    end
  end
  if not status and GetTrainerServiceSkillReq then
    local _, _, hasReq = GetTrainerServiceSkillReq(i)
    if hasReq ~= nil then status = (hasReq and hasReq ~= 0) and "available" or "unavailable" end
  end
  return name, sub, status
end

local function SaveTrainer()
  if not trainerOpen or not (GetNumTrainerServices and GetTrainerServiceInfo) then return end
  -- The list should show what you can't learn yet too. Turning a filter on makes the game send
  -- the list again, which brings us back here with the full list.
  if GetTrainerServiceTypeFilter and SetTrainerServiceTypeFilter then
    for _, filter in ipairs({ "available", "unavailable" }) do
      local ok, on = pcall(GetTrainerServiceTypeFilter, filter)
      if ok and not on then pcall(SetTrainerServiceTypeFilter, filter, true) end
    end
  end
  local count = GetNumTrainerServices() or 0
  if count == 0 then return end
  -- Only profession trainers: class trainers have nothing to do with crafting.
  if IsTradeskillTrainer and not Try(IsTradeskillTrainer) then return end
  local key, npcName = NoteNpc("trainer")
  if not key then return end
  local services = {}
  for i = 1, count do
    local name, _, status = ServiceBasics(i)
    if name and status ~= "header" then
      local skillName, skillRank = Try(GetTrainerServiceSkillReq, i)
      local link = GetTrainerServiceItemLink and Try(GetTrainerServiceItemLink, i)
      local level = Try(GetTrainerServiceLevelReq, i)
      services[#services + 1] = {
        name = name, status = status, cost = Try(GetTrainerServiceCost, i),
        skill = skillName, skillRank = skillRank, level = (level and level > 0) and level or nil,
        item = ns.ItemID(link),
      }
      if link then ns.Items.Note(link) end
    end
  end
  local info = ns.Char() and ns.Char().info or {}
  ns.SaveShared("trainers", key, {
    npc = type(key) == "number" and key or nil, name = npcName,
    faction = info.faction, ruleset = info.ruleset, services = services,
  })
end

----------------------------------------------------------------------
-- Flight masters: saved each time a flight master's map opens. The map only shows the continent
-- you're on, so flight points from earlier visits are kept. Routes to far-off steps use them.
----------------------------------------------------------------------

local function SaveFlightPaths()
  local c = ns.Char()
  if not c then return end
  local nodes = {}
  for name, node in pairs((c.flightPaths and c.flightPaths.nodes) or {}) do nodes[name] = node end
  local here
  local found = 0
  if NumTaxiNodes and TaxiNodeName and TaxiNodeGetType then
    for i = 1, Try(NumTaxiNodes) or 0 do
      local name, kind = Try(TaxiNodeName, i), Try(TaxiNodeGetType, i)
      if ns.Plain(name) and name and kind ~= "NONE" then
        found = found + 1
        local known = kind == "CURRENT" or kind == "REACHABLE"
        nodes[name] = { known = known or (nodes[name] and nodes[name].known) or false }
        if kind == "CURRENT" then here = name end
      end
    end
  end
  if found == 0 and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes then
    local mapID = C_Map and C_Map.GetBestMapForUnit and Try(C_Map.GetBestMapForUnit, "player")
    local states = (Enum and Enum.FlightPathState) or {}
    for _, node in ipairs((mapID and Try(C_TaxiMap.GetAllTaxiNodes, mapID)) or {}) do
      if ns.Plain(node.name) and node.name then
        found = found + 1
        local known = node.state == states.Current or node.state == states.Reachable
        nodes[node.name] = { known = known or (nodes[node.name] and nodes[node.name].known) or false }
        if node.state == states.Current then here = node.name end
      end
    end
  end
  -- An empty answer (the map still loading) never replaces what's saved.
  if found == 0 then return end
  ns.Save("flightPaths", { nodes = nodes })
  -- The flight master you're standing at, and which flight point it is.
  NoteNpc("flightmaster", here)
end

local function IsFlightMaster(kind)
  return Enum and Enum.PlayerInteractionType and kind == Enum.PlayerInteractionType.TaxiNode
end

----------------------------------------------------------------------
-- When to read
----------------------------------------------------------------------

ns.On("TAXIMAP_OPENED", function() ns.Later("flightPaths", 0.5, SaveFlightPaths) end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
  if IsFlightMaster(kind) then ns.Later("flightPaths", 0.5, SaveFlightPaths) end
end)

ns.On("MERCHANT_SHOW", function()
  merchantOpen = true
  ns.Run("vendor", RequestMerchantItems)
  ns.Later("vendor", 0.5, SaveVendor)
  -- Read once more when the items' details have had time to load.
  C_Timer.After(2.5, function() if merchantOpen then ns.Later("vendor", 0.1, SaveVendor) end end)
end)
ns.On("MERCHANT_UPDATE", function() if merchantOpen then ns.Later("vendor", 1, SaveVendor) end end)
ns.On("MERCHANT_CLOSED", function() merchantOpen = false end)

-- Where the auctioneers stand, so plans can point at the auction house.
ns.On("AUCTION_HOUSE_SHOW", function() ns.Run("auctioneer", NoteNpc, "auctioneer") end)

ns.On("TRAINER_SHOW", function()
  trainerOpen = true
  ns.Later("trainer", 0.5, SaveTrainer)
  C_Timer.After(2.5, function() if trainerOpen then ns.Later("trainer", 0.1, SaveTrainer) end end)
end)
ns.On("TRAINER_UPDATE", function() if trainerOpen then ns.Later("trainer", 1, SaveTrainer) end end)
ns.On("TRAINER_CLOSED", function() trainerOpen = false end)
