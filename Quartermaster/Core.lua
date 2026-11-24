-- Quartermaster: a profession companion. It records what your characters have, know and can
-- reach (this file and the recorder files: facts only), works out the cheapest plan for any
-- profession goal from that (the Planner files), and shows it in the plan window (Plan.lua).
--
-- Everything is kept in QuartermasterDB (account-wide):
--   QuartermasterDB.chars["First-Surname"]   one table per character, one sub-table per section
--                                            (info, gear, bags, bank, mail, ...), each with savedAt
--   QuartermasterDB.account                  shared: vendors, trainers, NPC positions, item cache,
--                                            settings
-- The game only writes this to disk on /reload, logout or quit. Whatever is still waiting to be
-- recorded is written out just before that (PLAYER_LOGOUT below).

local ADDON, ns = ...

ns.VERSION = "1.0.7"
ns.SCHEMA = 1

local unpackSafe = unpack or table.unpack

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

function ns.Print(msg)
  local chat = DEFAULT_CHAT_FRAME or ChatFrame1
  if chat then chat:AddMessage("|cffe6cc80Quartermaster|r: " .. tostring(msg)) end
end

-- True for a value addons are allowed to read (the game hides some values during combat).
function ns.Plain(v)
  return v ~= nil and not (issecretvalue and issecretvalue(v))
end

-- Calls a game function safely. Returns nothing if it's missing or errors.
function ns.Try(f, ...)
  if type(f) ~= "function" then return nil end
  local function pack(...) return select("#", ...), { ... } end
  local n, r = pack(pcall(f, ...))
  if not r[1] then return nil end
  return unpackSafe(r, 2, n)
end

-- A copy of a game table's plain fields (text, numbers, true/false), for records whose exact
-- shape differs between game versions.
function ns.Scalars(t)
  local out = {}
  if type(t) ~= "table" then return out end
  for k, v in pairs(t) do
    local kind = type(v)
    if type(k) == "string" and ns.Plain(v) and (kind == "string" or kind == "number" or kind == "boolean") then
      out[k] = v
    end
  end
  return out
end

-- Strips colors, icons and line-break codes from game text.
function ns.Clean(text)
  if type(text) ~= "string" or not ns.Plain(text) then return nil end
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|cn[^:]*:", ""):gsub("|r", "")
  text = text:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|4[^:;]*:([^;]*);", "%1")
  text = text:gsub("|n", " "):gsub("%s+", " ")
  text = text:match("^%s*(.-)%s*$")
  return text ~= "" and text or nil
end

function ns.ItemID(link)
  return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

function ns.Round(n, places)
  if type(n) ~= "number" then return nil end
  local mult = 10 ^ (places or 0)
  return math.floor(n * mult + 0.5) / mult
end

-- Deep comparison that ignores savedAt, so re-reading unchanged data doesn't count as a change.
function ns.Same(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if k ~= "savedAt" and not ns.Same(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if k ~= "savedAt" and a[k] == nil then return false end
  end
  return true
end

----------------------------------------------------------------------
-- Character keys. WoW Forever has no realms: every character has a first name and a surname
-- ("Rend Nightrush"). The name functions hand the surname back where retail puts the realm, and
-- the first value can already have the surname joined on. Characters are saved as "First-Surname".
----------------------------------------------------------------------

function ns.Key(name, surname)
  if not ns.Plain(name) or type(name) ~= "string" or name == "" then return nil end
  if not ns.Plain(surname) or type(surname) ~= "string" then surname = nil end
  local first, joined = name:match("^(%S+)[%s%-]+(.+)$")
  if first then
    name = first
    if not surname or surname == "" then surname = joined end
  end
  if not surname or surname == "" then return name end
  return name .. "-" .. surname
end

function ns.UnitKey(unit)
  local name, surname = ns.Try(UnitFullName, unit)
  if not name then name, surname = ns.Try(UnitName, unit) end
  return ns.Key(name, surname)
end

function ns.PlayerKey()
  if not ns.playerKey then ns.playerKey = ns.UnitKey("player") end
  return ns.playerKey
end

-- "Ana-Brightwood" -> "Ana Brightwood"
function ns.Pretty(key)
  return (tostring(key):gsub("%-", " "))
end

----------------------------------------------------------------------
-- Saved data
----------------------------------------------------------------------

ns.dirty = {} -- section -> when it first changed this session

function ns.InitDB()
  local db = QuartermasterDB
  if type(db) ~= "table" then db = {} end
  -- Data written by a newer version of the addon is kept as it is and flagged.
  if type(db.schema) == "number" and db.schema > ns.SCHEMA then db.schemaNewer = db.schema end
  db.schema = ns.SCHEMA
  db.addonVersion = ns.VERSION
  db.chars = type(db.chars) == "table" and db.chars or {}
  db.account = type(db.account) == "table" and db.account or {}
  local a = db.account
  for _, name in ipairs({ "npcs", "vendors", "trainers", "items", "ui", "errors" }) do
    if type(a[name]) ~= "table" then a[name] = {} end
  end
  -- Friend tracking was removed in 0.8: drop its list and the characters it recorded (anyone
  -- who isn't one of yours).
  a.track = nil
  for key, c in pairs(db.chars) do
    if type(c) ~= "table" or not c.own then db.chars[key] = nil end
  end
  -- Plans used to be made outside the game and delivered through an inbox file. They're worked
  -- out in game now and never saved.
  a.inboxDone = nil
  for _, c in pairs(db.chars) do
    c.plans, c.plan = nil, nil
  end
  -- Recording that 0.9 cut (it had nothing to do with crafting), and tooltips nothing reads.
  for _, c in pairs(db.chars) do
    for _, section in ipairs({ "talents", "spells", "skills", "quests", "questsDone", "reputations",
      "location", "auctions", "waypoints" }) do
      c[section] = nil
    end
    if type(c.gear) == "table" and type(c.gear.slots) == "table" then
      c.gear.stats = nil
      for _, slot in pairs(c.gear.slots) do
        if type(slot) == "table" and slot.tip then
          for _, line in ipairs(slot.tip) do
            if type(line) == "string" and line:find("^Enchanted:") then slot.enchant = line end
          end
          slot.tip, slot.link, slot.durability, slot.q, slot.ilvl = nil, nil, nil, nil, nil
        end
      end
    end
  end
  for _, item in pairs(a.items) do
    if type(item) == "table" and item.tip then
      item.tip, item.ilvl, item.class, item.sub, item.stack = nil, nil, nil, nil, nil
    end
  end
  for _, trainer in pairs(a.trainers) do
    for _, service in ipairs(type(trainer) == "table" and type(trainer.services) == "table" and trainer.services or {}) do
      service.tip, service.link, service.rank, service.line = nil, nil, nil, nil
    end
  end
  QuartermasterDB = db
  ns.db = db
end

-- This character's table (or another character's, by key). Nil until the name is known.
function ns.Char(key)
  if not ns.db then return nil end
  key = key or ns.PlayerKey()
  if not key then return nil end
  local c = ns.db.chars[key]
  if not c then
    c = {}
    ns.db.chars[key] = c
  end
  return c
end

function ns.MarkDirty(section)
  if not ns.dirty[section] then ns.dirty[section] = time() end
end

-- Saves one section of a character. Unchanged data only gets a new savedAt.
-- Returns true if something changed.
function ns.Save(section, data, key)
  local c = ns.Char(key)
  if not c or type(data) ~= "table" then return false end
  local old = c[section]
  if type(old) == "table" and ns.Same(old, data) then
    old.savedAt = time()
    return false
  end
  data.savedAt = time()
  c[section] = data
  ns.MarkDirty(section)
  return true
end

-- Same, for a record shared by the whole account (a vendor, a trainer, an NPC's position).
function ns.SaveShared(kind, id, data)
  if not ns.db or id == nil or type(data) ~= "table" then return false end
  local tbl = ns.db.account[kind]
  local old = tbl[id]
  if type(old) == "table" and ns.Same(old, data) then
    old.savedAt = time()
    return false
  end
  data.savedAt = time()
  tbl[id] = data
  ns.MarkDirty(kind)
  return true
end

-- Keeps the last 30 errors in the saved data, so they can be read from disk, and passes each
-- one to the game's error handler (BugSack shows it).
function ns.Error(where, err)
  local a = ns.db and ns.db.account
  if a then
    local list = a.errors
    list[#list + 1] = { at = time(), where = tostring(where), err = tostring(err), version = ns.VERSION }
    while #list > 30 do table.remove(list, 1) end
  end
  local handler = geterrorhandler and geterrorhandler()
  if handler then pcall(handler, "Quartermaster (" .. tostring(where) .. "): " .. tostring(err)) end
end

function ns.Run(where, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then ns.Error(where, err) end
  return ok
end

----------------------------------------------------------------------
-- Events: ns.On("EVENT", function(event, ...) end). Events this client doesn't have are skipped.
----------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
  local list = handlers[event]
  if not list then
    list = {}
    handlers[event] = list
    pcall(frame.RegisterEvent, frame, event)
  end
  list[#list + 1] = fn
end

frame:SetScript("OnEvent", function(_, event, ...)
  local list = handlers[event]
  if not list then return end
  for i = 1, #list do ns.Run(event, list[i], event, ...) end
end)

----------------------------------------------------------------------
-- Delayed work. Events come in bursts, so each reader runs once after things settle. Work that
-- comes due during combat waits until combat ends.
----------------------------------------------------------------------

local pending = {}

local function InCombat()
  return InCombatLockdown and InCombatLockdown() and true or false
end
ns.InCombat = InCombat

function ns.Later(key, delay, fn)
  local p = pending[key]
  if p then
    p.fn = fn
    return
  end
  p = { fn = fn }
  pending[key] = p
  C_Timer.After(delay, function()
    if pending[key] ~= p then return end
    if InCombat() then
      p.waiting = true
      return
    end
    pending[key] = nil
    ns.Run(key, p.fn)
  end)
end

local function RunPending(onlyWaiting)
  local due = {}
  for key, p in pairs(pending) do
    if p.waiting or not onlyWaiting then due[#due + 1] = key end
  end
  for _, key in ipairs(due) do
    local p = pending[key]
    if p then
      pending[key] = nil
      ns.Run(key, p.fn)
    end
  end
end

ns.On("PLAYER_REGEN_ENABLED", function() RunPending(true) end)

-- Runs everything that's still waiting, right now. Used just before the data goes to disk.
function ns.Flush()
  RunPending(false)
end

----------------------------------------------------------------------
-- Where you are
----------------------------------------------------------------------

-- Map ID and position in percent (0 to 100), plus zone names. Position is nil inside instances.
function ns.Position()
  local out = {}
  local mapID = C_Map and C_Map.GetBestMapForUnit and ns.Try(C_Map.GetBestMapForUnit, "player")
  if mapID then
    out.map = mapID
    local info = ns.Try(C_Map.GetMapInfo, mapID)
    out.mapName = info and info.name or nil
    local pos = ns.Try(C_Map.GetPlayerMapPosition, mapID, "player")
    if pos and pos.GetXY then
      local x, y = pos:GetXY()
      if ns.Plain(x) and ns.Plain(y) and x and y and (x > 0 or y > 0) then
        out.x, out.y = ns.Round(x * 100, 2), ns.Round(y * 100, 2)
      end
    end
  end
  out.zone = ns.Clean(ns.Try(GetRealZoneText))
  local sub = ns.Clean(ns.Try(GetSubZoneText))
  if sub and sub ~= out.zone then out.subzone = sub end
  return out
end

-- The NPC ID from a unit's GUID ("Creature-0-1234-0-56-3482-0000ABCDEF" -> 3482).
function ns.NpcID(unit)
  local guid = ns.Try(UnitGUID, unit)
  if type(guid) ~= "string" or not ns.Plain(guid) then return nil end
  local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
  if kind == "Creature" or kind == "Vehicle" or kind == "GameObject" then return tonumber(id) end
  return nil
end

----------------------------------------------------------------------
-- Tooltips as plain lines. Right-hand text ("Sword", "Speed 3.40") follows the left-hand text.
----------------------------------------------------------------------

local INFO_NAME = { MerchantItem = "GetMerchantItem", InventoryItem = "GetInventoryItem" }
local TIP_METHOD = { MerchantItem = "SetMerchantItem", InventoryItem = "SetInventoryItem" }
local scanTip

local function JoinLine(left, right)
  left, right = ns.Clean(left), ns.Clean(right)
  if left and right then return left .. "    " .. right end
  return left or right
end

function ns.Tooltip(kind, ...)
  local out = {}
  local info = C_TooltipInfo and C_TooltipInfo[INFO_NAME[kind]]
  if info then
    local ok, data = pcall(info, ...)
    if ok and type(data) == "table" and type(data.lines) == "table" then
      for _, line in ipairs(data.lines) do
        local text = JoinLine(line.leftText, line.rightText)
        if text then out[#out + 1] = text end
      end
      return out
    end
  end
  local method = TIP_METHOD[kind]
  if not method or not GameTooltip then return out end
  if not scanTip then
    scanTip = CreateFrame("GameTooltip", "QuartermasterScanTip", nil, "GameTooltipTemplate")
  end
  if type(scanTip[method]) ~= "function" then return out end
  scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
  scanTip:ClearLines()
  pcall(scanTip[method], scanTip, ...)
  for n = 1, scanTip:NumLines() or 0 do
    local left, right = _G["QuartermasterScanTipTextLeft" .. n], _G["QuartermasterScanTipTextRight" .. n]
    local text = JoinLine(left and left:GetText(), right and right:IsShown() and right:GetText() or nil)
    if text then out[#out + 1] = text end
  end
  scanTip:Hide()
  return out
end

----------------------------------------------------------------------
-- Start-up and the moment before the data goes to disk
----------------------------------------------------------------------

ns.On("ADDON_LOADED", function(_, name)
  if name == ADDON then ns.InitDB() end
end)

-- Facts about this game client, so differences between versions can be worked out from the
-- saved file alone.
ns.On("PLAYER_LOGIN", function()
  if not ns.db then return end
  local version, build, _, interface = ns.Try(GetBuildInfo)
  local bagIndex = {}
  for k, v in pairs((Enum and Enum.BagIndex) or {}) do
    if type(k) == "string" and type(v) == "number" then bagIndex[k] = v end
  end
  local client = {
    version = version, build = build, interface = interface, locale = ns.Try(GetLocale),
    keyring = KEYRING_CONTAINER, bank = BANK_CONTAINER, reagentBank = REAGENTBANK_CONTAINER,
    bagSlots = NUM_BAG_SLOTS, equippedBagSlots = NUM_TOTAL_EQUIPPED_BAG_SLOTS, bankBagSlots = NUM_BANKBAGSLOTS,
    bagIndex = bagIndex,
    oldTradeSkill = GetNumTradeSkills ~= nil, oldAuctionHouse = GetNumAuctionItems ~= nil,
    oldTalents = GetNumTalentTabs ~= nil, oldSkills = GetNumSkillLines ~= nil,
    tooltipInfo = C_TooltipInfo ~= nil,
  }
  if not ns.Same(ns.db.client, client) then
    ns.db.client = client
    ns.MarkDirty("client")
  end
end)

-- Fires on /reload, logout and quit, just before the game writes the saved data.
ns.On("PLAYER_LOGOUT", function()
  ns.Flush()
  local c = ns.Char()
  if c then c.flushedAt = time() end
  if ns.db then ns.db.lastFlush = { at = time(), by = ns.PlayerKey() } end
end)

