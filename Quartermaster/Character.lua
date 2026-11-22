-- Who the character is (section "info"), its professions ("professions"), what it wears
-- ("gear", for the upgrade list) and the currencies recipes are bought with ("currencies").

local _, ns = ...

local Try = ns.Try

----------------------------------------------------------------------
-- Info
----------------------------------------------------------------------

-- The ruleset this character plays under, named the way Auctionator names it, so price data
-- can be matched: "PvE", "PvP", "RP", "RPPvP" or "HC".
local function Ruleset()
  local rules, kinds = C_GameRules, Enum and Enum.GameRule
  if not (rules and rules.IsGameRuleActive and kinds) then return nil end
  local function on(rule)
    if rule == nil then return false end
    local ok, active = pcall(rules.IsGameRuleActive, rule)
    return ok and active and true or false
  end
  local pvp, rp, hc = on(kinds.PvPRuleset), on(kinds.RPRuleset), on(kinds.HardcoreRuleset)
  if pvp and rp then return "RPPvP" end
  if pvp then return "PvP" end
  if rp then return "RP" end
  if hc then return "HC" end
  return "PvE"
end

local function SaveInfo()
  local key = ns.PlayerKey()
  if not key then return end
  local name, surname = Try(UnitFullName, "player")
  local className, classFile = Try(UnitClass, "player")
  local faction = Try(UnitFactionGroup, "player")
  local ruleset = Ruleset()
  local money = Try(GetMoney)
  ns.Char().own = true
  ns.Save("info", {
    key = key, name = ns.Plain(name) and name or nil, surname = ns.Plain(surname) and surname or nil,
    class = className, classFile = classFile, level = Try(UnitLevel, "player"),
    faction = faction, ruleset = ruleset,
    -- The name Auctionator files this character's auction prices under.
    ahKey = (ruleset and faction) and (ruleset .. " " .. faction) or nil,
    money = type(money) == "number" and money or nil,
  })
end

----------------------------------------------------------------------
-- Professions
----------------------------------------------------------------------

local function SaveProfessions()
  local profs = {}
  if GetProfessions and GetProfessionInfo then
    local found = { GetProfessions() }
    for i = 1, 6 do
      local index = found[i]
      if index then
        local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
        if name then profs[name] = { skill = rank, max = maxRank, skillLine = skillLine } end
      end
    end
  end
  -- An empty answer never replaces a saved list (the game can answer empty while loading).
  if next(profs) then
    ns.Save("professions", { list = profs })
    ns.profSkill = ns.profSkill or {}
    ns.profMax = ns.profMax or {}
    for name, p in pairs(profs) do ns.profSkill[name], ns.profMax[name] = p.skill, p.max end
  end
end
ns.SaveSkills = SaveProfessions

----------------------------------------------------------------------
-- Gear: what's worn in each slot, and the enchant on it (read from its tooltip), for comparing
-- craftable pieces with it. The items' own stats are in the item cache.
----------------------------------------------------------------------

local function SaveGear()
  local slots, count = {}, 0
  for slot = 1, 19 do
    local link = Try(GetInventoryItemLink, "player", slot)
    if link and ns.Plain(link) then
      count = count + 1
      local enchant
      for _, line in ipairs(ns.Tooltip("InventoryItem", "player", slot)) do
        if line:find("^Enchanted:") then enchant = line end
      end
      slots[slot] = { id = ns.ItemID(link), enchant = enchant }
      ns.Items.Note(link)
    end
  end
  -- A character with nothing equipped at all means the game hasn't loaded gear yet.
  local old = ns.Char() and ns.Char().gear
  if count == 0 and old and next(old.slots or {}) then return end
  ns.Save("gear", { slots = slots })
end

----------------------------------------------------------------------
-- Currencies: Merchant's Favor, and any other currency a recorded vendor charges for recipes.
----------------------------------------------------------------------

local FAVOR = 3402

local function SaveCurrencies()
  local C = C_CurrencyInfo
  if not (C and C.GetCurrencyInfo) then return end
  local ids, seen = { FAVOR }, { [FAVOR] = true }
  for _, vendor in pairs((ns.db and ns.db.account.vendors) or {}) do
    for _, item in ipairs(type(vendor.items) == "table" and vendor.items or {}) do
      for _, cost in ipairs(type(item.costs) == "table" and item.costs or {}) do
        if cost.currency and not seen[cost.currency] then
          seen[cost.currency] = true
          ids[#ids + 1] = cost.currency
        end
      end
    end
  end
  local list = {}
  for _, id in ipairs(ids) do
    local info = Try(C.GetCurrencyInfo, id)
    if info and info.name and info.name ~= "" then
      list[#list + 1] = { id = id, name = info.name, n = info.quantity or 0 }
    end
  end
  if #list > 0 then ns.Save("currencies", { list = list }) end
end

-- Reputation with the factions Merchant's Favor vendors belong to (their patterns can ask for a
-- standing). `earned` is the reputation in all: Neutral starts at 0, Friendly at 3000.
local COMMERCE_FACTIONS = { 2586, 2587 }
local function FactionNow(id)
  local C = C_Reputation
  local data = C and C.GetFactionDataByID and Try(C.GetFactionDataByID, id)
  if type(data) == "table" and data.name then
    return data.name, data.currentStanding, data.reaction
  end
  if GetFactionInfoByID then
    local name, _, standing, _, _, value = Try(GetFactionInfoByID, id)
    if name then return name, value, standing end
  end
end

local function SaveReputations()
  local list = {}
  for _, id in ipairs(COMMERCE_FACTIONS) do
    local name, earned, standing = FactionNow(id)
    if type(name) == "string" and name ~= "" and type(earned) == "number" then
      list[name] = { id = id, earned = earned, standing = standing }
    end
  end
  -- An empty answer never replaces what's saved.
  if next(list) then ns.Save("reputations", { list = list }) end
end

-- The reputation you've earned with a faction right now, by name, or nil.
function ns.Reputation(faction)
  for _, id in ipairs(COMMERCE_FACTIONS) do
    local name, earned = FactionNow(id)
    if name == faction and type(earned) == "number" then return earned end
  end
end

ns.SaveInfo, ns.SaveCurrencies, ns.SaveReputations = SaveInfo, SaveCurrencies, SaveReputations

-- Where Merchant's Favor is earned: when yours goes up while you're talking to an NPC, that's
-- where crates are handed in. Its place is remembered, so plans can point there.
local lastFavor
local function FavorNow()
  local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and Try(C_CurrencyInfo.GetCurrencyInfo, FAVOR)
  return info and type(info.quantity) == "number" and info.quantity or nil
end
local function WatchFavor()
  local now = FavorNow()
  if now and lastFavor and now > lastFavor and ns.NoteNpc then ns.NoteNpc("crates") end
  if now then lastFavor = now end
end

----------------------------------------------------------------------
-- When to read
----------------------------------------------------------------------

ns.On("PLAYER_ENTERING_WORLD", function()
  ns.Later("info", 3, SaveInfo)
  ns.Later("skills", 4, SaveProfessions)
  ns.Later("gear", 5, SaveGear)
  ns.Later("currencies", 6, SaveCurrencies)
end)
ns.On("PLAYER_ENTERING_WORLD", function() ns.Later("reputations", 6, SaveReputations) end)
ns.On("UPDATE_FACTION", function() ns.Later("reputations", 3, SaveReputations) end)
ns.On("PLAYER_LEVEL_UP", function() ns.Later("info", 2, SaveInfo) end)
ns.On("PLAYER_MONEY", function() ns.Later("info", 2, SaveInfo) end)
ns.On("SKILL_LINES_CHANGED", function() ns.Later("skills", 3, SaveProfessions) end)
ns.On("PLAYER_EQUIPMENT_CHANGED", function() ns.Later("gear", 2, SaveGear) end)
ns.On("CURRENCY_DISPLAY_UPDATE", function()
  -- Straight away, while the NPC is still in front of you.
  WatchFavor()
  ns.Later("currencies", 3, SaveCurrencies)
end)
ns.On("PLAYER_ENTERING_WORLD", function() lastFavor = FavorNow() or lastFavor end)
ns.On("MERCHANT_CLOSED", function() ns.Later("currencies", 2, SaveCurrencies) end)
