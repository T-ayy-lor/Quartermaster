-- The planner, part 3: running it in the game.
--
-- Keeps this character's goals for each profession (in memory: they're worked out again from
-- what's recorded, never saved), and works plans out in the background, a few milliseconds a
-- frame, so the game never stutters:
--   Planner.Plans()                 every profession's goals, by profession name
--   Planner.Want(profession)        make sure its goals, and the plan of the goal that's picked,
--                                   are worked out and up to date
--   Planner.Rebuild(profession)     work them out again from scratch
-- A profession's goals are worked out again when the plan window is shown or a goal is picked
-- and something they depend on has changed since (bags, bank, gold, skill, recipes, vendors,
-- trainers, auction prices). While you're working through a plan it's left alone, so its steps
-- tick off instead of shifting under you.
-- What's saved is only what you chose: QuartermasterDB.chars[key].planPrefs[profession] =
-- { selected = goal id, picked = several goal ids }.

local _, ns = ...

local P, G = ns.P, ns.Goals
local Planner = {}
ns.Planner = Planner

local plans = {}   -- profession -> its goals (see Plan.lua for the layout)
local version = 1  -- goes up whenever something plans depend on changes
local queue, running, ticker = {}, nil, nil

local BUDGET_MS = 5 -- how long planning may take out of one frame
local clock = debugprofilestop or function() return os.clock() * 1000 end
local sliceStart = 0

function P.Yield()
  if running and running.co and coroutine.running() == running.co and clock() - sliceStart > BUDGET_MS then
    coroutine.yield()
  end
end

-- Gold, currencies and item names are asked from the game for the character you're on.
local recordedGold, recordedCurrency = P.Gold, P.Currency
function P.Gold(key)
  if key == ns.PlayerKey() and GetMoney then
    local money = ns.Try(GetMoney)
    if type(money) == "number" then return money end
  end
  return recordedGold(key)
end
function P.Currency(key, id)
  local n, name = recordedCurrency(key, id)
  if key == ns.PlayerKey() and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
    local info = ns.Try(C_CurrencyInfo.GetCurrencyInfo, id)
    if info and type(info.quantity) == "number" then return info.quantity, info.name or name end
  end
  return n, name
end
-- An item the recorder hasn't got to yet (it works through thousands in the background) is
-- asked from the game: its slot and kind are known at once, its name, quality, level and
-- vendor value as soon as the game has loaded it. So gear is filed under its slot ("Chest",
-- "Gloves") from the first look, never under "Other".
local recordedItem = P.Item
local liveItems = {}
function P.Item(item)
  local e = recordedItem(item)
  if e.name or type(item) ~= "number" then return e end
  local live = liveItems[item]
  if live then return live end
  live = {}
  local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if instant then
    local _, _, _, loc, _, classID, subID = ns.Try(instant, item)
    if type(loc) == "string" and loc ~= "" then live.loc, live.classID, live.subID = loc, classID, subID end
  end
  local full = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local name, _, quality, _, reqLevel, _, _, _, _, _, sell, _, _, bind
  if full then name, _, quality, _, reqLevel, _, _, _, _, _, sell, _, _, bind = ns.Try(full, item) end
  if name then
    live.name, live.q = name, quality
    live.req = (reqLevel and reqLevel > 0) and reqLevel or nil
    live.sell = (sell and sell > 0) and sell or nil
    live.bind = (bind and bind > 0) and bind or nil
    -- Complete: kept for the session. (Until then it's asked again each time.)
    liveItems[item] = live
  elseif C_Item and C_Item.RequestLoadItemDataByID then
    pcall(C_Item.RequestLoadItemDataByID, item)
  end
  return live
end

function P.Knows(key, spell)
  return key == ns.PlayerKey() and IsPlayerSpell and ns.Try(IsPlayerSpell, spell) and true or false
end
function P.LiveLevel(item)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not get then return nil end
  local ok, _, _, _, _, minLevel = pcall(get, item)
  if ok and ns.Plain(minLevel) and minLevel then return minLevel end
  -- Not in the game's item cache yet: Questie's item data, when it's installed.
  if type(QuestieLoader) == "table" and QuestieLoader.ImportModule then
    local got, level = pcall(function()
      return QuestieLoader:ImportModule("QuestieDB").QueryItemSingle(item, "requiredLevel")
    end)
    if got and type(level) == "number" then return level end
  end
  return nil
end
function P.LocalName(line)
  local T = C_TradeSkillUI
  local name = T and T.GetTradeSkillDisplayName and ns.Try(T.GetTradeSkillDisplayName, line)
  return type(name) == "string" and name ~= "" and name or nil
end
function P.LiveName(item)
  local name = C_Item and C_Item.GetItemNameByID and ns.Try(C_Item.GetItemNameByID, item)
  return type(name) == "string" and name ~= "" and name or nil
end

----------------------------------------------------------------------
-- Places: where you are, how far things are, and where unrecorded NPCs stand
----------------------------------------------------------------------

function P.Here()
  local pos = ns.Position()
  if pos.map and pos.x then return { map = pos.map, x = pos.x, y = pos.y } end
  return nil
end

-- A place in the world's own coordinates (yards), which compare across neighboring maps.
local function World(place)
  if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D and place.map and place.x) then return nil end
  local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, place.map, CreateVector2D(place.x / 100, place.y / 100))
  if ok and continent and pos and pos.GetXY then
    local x, y = pos:GetXY()
    if type(x) == "number" and type(y) == "number" then return continent, x, y end
  end
  return nil
end

local mapDistance = P.Distance
function P.Distance(a, b)
  local ca, ax, ay = World(a)
  local cb, bx, by = World(b)
  if ca and cb then
    -- Another continent is a boat or a portal away: no telling how far.
    if ca ~= cb then return nil end
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
  end
  return mapDistance(a, b)
end

-- Where an NPC you haven't met stands, from Questie's data when Questie is installed:
-- { { map, x, y, name } }, or nil. Nothing here is needed for the addon to work.
local placeCache = {}
function P.NpcPlaces(id)
  if not (type(QuestieLoader) == "table" and QuestieLoader.ImportModule) then return nil end
  if placeCache[id] ~= nil then return placeCache[id] or nil end
  local found = false
  do
    local ok, out = pcall(function()
      local db = QuestieLoader:ImportModule("QuestieDB")
      local zones = QuestieLoader:ImportModule("ZoneDB")
      local spawns = db.QueryNPCSingle(id, "spawns")
      if type(spawns) ~= "table" then return nil end
      local name = db.QueryNPCSingle(id, "name")
      local list = {}
      for area, points in pairs(spawns) do
        local map = zones:GetUiMapIdByAreaId(area)
        if type(map) == "number" and type(points) == "table" then
          -- An NPC that walks about has many points; the first few are enough to find it.
          for i = 1, math.min(#points, 3) do
            local pt = points[i]
            if type(pt) == "table" and type(pt[1]) == "number" and type(pt[2]) == "number" and pt[1] >= 0 then
              list[#list + 1] = { map = map, x = pt[1], y = pt[2], name = type(name) == "string" and name or nil }
            end
          end
        end
      end
      return #list > 0 and list or nil
    end)
    if ok and out then found = out end
  end
  placeCache[id] = found
  return found or nil
end

-- A profession's trainers for the character's faction, as NPC IDs, from Questie's own list of
-- them (its Townsfolk module, by skill line). Nil without Questie, or before it has started.
local trainerIds = {}
function P.ProfessionTrainers(key, profession)
  if key ~= ns.PlayerKey() then return nil end
  if not (type(QuestieLoader) == "table" and QuestieLoader.ImportModule) then return nil end
  local line = P.SkillLine(key, profession)
  if not line then return nil end
  if trainerIds[line] then return trainerIds[line] end
  local ok, out = pcall(function()
    local folk = QuestieLoader:ImportModule("Townsfolk")
    local db = QuestieLoader:ImportModule("QuestieDB")
    local ids = type(folk) == "table" and type(folk.professionTrainers) == "table" and folk.professionTrainers[line]
    if type(ids) ~= "table" or #ids == 0 then return nil end
    local mine = (P.Info(key).faction or ""):sub(1, 1) -- "A" or "H"
    local found = {}
    for i = 1, #ids do
      local friendly = db.QueryNPCSingle(ids[i], "friendlyToFaction")
      if type(friendly) ~= "string" or mine == "" or friendly:find(mine, 1, true) then found[#found + 1] = ids[i] end
    end
    return #found > 0 and found or nil
  end)
  -- Questie may still be starting up: nothing is remembered until it answers.
  if ok and out then trainerIds[line] = out end
  return ok and out or nil
end

-- Whether the character's faction can use an NPC (Questie's data; yes when it doesn't say).
local friendlyCache = {}
function P.NpcUsable(key, id)
  if not (type(QuestieLoader) == "table" and QuestieLoader.ImportModule) then return true end
  local mine = (P.Info(key).faction or ""):sub(1, 1) -- "A" or "H"
  if mine == "" then return true end
  local friendly = friendlyCache[id]
  if friendly == nil then
    local ok, out = pcall(function()
      return QuestieLoader:ImportModule("QuestieDB").QueryNPCSingle(id, "friendlyToFaction")
    end)
    friendly = ok and type(out) == "string" and out or false
    friendlyCache[id] = friendly
  end
  return friendly == false or friendly:find(mine, 1, true) ~= nil
end

-- A map's name, from the game.
function P.ZoneName(map)
  local info = map and C_Map and C_Map.GetMapInfo and ns.Try(C_Map.GetMapInfo, map)
  return info and info.name or nil
end

-- Every banker, auctioneer and mailbox for the character's faction, from Questie's own lists (its
-- Townsfolk module), so the nearest is known without ever having opened it: { { map, x, y, name } }.
local FOLK = { banker = "Banker", auctioneer = "Auctioneer", mailbox = "Mailbox" }
local folkSpots = {}
local function Folk(key, kind)
  if folkSpots[kind] then return folkSpots[kind] end
  if not (FOLK[kind] and type(QuestieLoader) == "table" and QuestieLoader.ImportModule) then return nil end
  local ok, out = pcall(function()
    local folk = QuestieLoader:ImportModule("Townsfolk")
    local db = QuestieLoader:ImportModule("QuestieDB")
    local zones = QuestieLoader:ImportModule("ZoneDB")
    local spots = {}
    if kind == "mailbox" then
      local faction = P.Info(key).faction
      local mine = type(folk.factionSpecificTownsfolk) == "table" and faction and folk.factionSpecificTownsfolk[faction]
      local ids = type(mine) == "table" and mine.Mailbox
      if type(ids) ~= "table" then return nil end
      for i = 1, #ids do
        local spawns = db.QueryObjectSingle(ids[i], "spawns")
        for area, points in pairs(type(spawns) == "table" and spawns or {}) do
          local map = zones:GetUiMapIdByAreaId(area)
          for _, pt in ipairs(type(map) == "number" and type(points) == "table" and points or {}) do
            if type(pt) == "table" and type(pt[1]) == "number" and type(pt[2]) == "number" and pt[1] >= 0 then
              spots[#spots + 1] = { map = map, x = pt[1], y = pt[2], name = "Mailbox" }
            end
          end
        end
      end
    else
      local ids = type(folk.townsfolk) == "table" and folk.townsfolk[FOLK[kind]]
      if type(ids) ~= "table" then return nil end
      for i = 1, #ids do
        if P.NpcUsable(key, ids[i]) then
          for _, spot in ipairs(P.NpcPlaces(ids[i]) or {}) do spots[#spots + 1] = spot end
        end
      end
    end
    return #spots > 0 and spots or nil
  end)
  -- Questie may still be starting up: nothing is remembered until it answers.
  if ok and out then folkSpots[kind] = out end
  return ok and out or nil
end

-- The nearest place of a kind: the recorded ones (Planner.lua) and, for banks, auction houses and
-- mailboxes, every one Questie lists. Worked out at most once a second for each kind.
local recordedNearest = P.Nearest
local nearCache = {}
function P.Nearest(key, kind)
  local mine = recordedNearest(key, kind)
  if key ~= ns.PlayerKey() or not FOLK[kind] then return mine end
  local now = GetTime and GetTime() or 0
  local cached = nearCache[kind]
  if cached and now - cached.at < 1 then return cached.spot or mine end
  local here, best = P.Here(), nil
  -- Without a place to measure from, the one you used last is the one to name.
  if here or not mine then
    for _, spot in ipairs(Folk(key, kind) or {}) do
      if not best or P.Better(spot, 0, best, 0, here) then best = spot end
    end
  end
  local pick
  if best and (not mine or P.Better(best, 0, mine, 0, here)) then
    pick = { map = best.map, x = best.x, y = best.y, name = best.name, zone = P.ZoneName(best.map) }
  end
  nearCache[kind] = { at = now, spot = pick }
  return pick or mine
end

-- Every Craftsman's Writ, from Questie's quest data (read once, a little at a time): the writ's
-- item, the item it asks for, what it pays with the commerce factions, and who takes it.
-- How many of the item a writ asks for isn't in that data: one is assumed.
local writList
local COMMERCE_IDS = { [2586] = true, [2587] = true }
function P.Writs()
  if writList then return writList end
  if not (type(QuestieLoader) == "table" and QuestieLoader.ImportModule) then return nil end
  local ok, db = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
  -- Questie may still be starting up: ask again next time.
  if not ok or type(db) ~= "table" or type(db.QuestPointers) ~= "table" or not db.QueryQuestSingle then return nil end
  local quests = {}
  for quest in pairs(db.QuestPointers) do quests[#quests + 1] = quest end
  table.sort(quests)
  local function read(quest)
    local title = db.QueryQuestSingle(quest, "name")
    if type(title) ~= "string" or not title:find("^Craftsman's Writ: ") then return nil end
    local rep = 0
    local rewards = db.QueryQuestSingle(quest, "reputationReward")
    for _, r in ipairs(type(rewards) == "table" and rewards or {}) do
      if type(r) == "table" and COMMERCE_IDS[r[1]] and type(r[2]) == "number" then rep = math.max(rep, r[2]) end
    end
    local starts = db.QueryQuestSingle(quest, "startedBy")
    local writ = type(starts) == "table" and type(starts[3]) == "table" and starts[3][1] or nil
    local objectives = db.QueryQuestSingle(quest, "objectives")
    local items = {}
    for _, o in ipairs(type(objectives) == "table" and type(objectives[3]) == "table" and objectives[3] or {}) do
      if type(o) == "table" and type(o[1]) == "number" and o[1] ~= writ then items[#items + 1] = { o[1], 1 } end
    end
    local ends = db.QueryQuestSingle(quest, "finishedBy")
    local npc = type(ends) == "table" and type(ends[1]) == "table" and ends[1][1] or nil
    if rep > 0 and type(writ) == "number" and #items > 0 then
      return { quest = quest, writ = writ, title = title, items = items, rep = rep, npc = npc }
    end
  end
  local list = {}
  for i, quest in ipairs(quests) do
    local fine, writ = pcall(read, quest)
    if fine and writ then list[#list + 1] = writ end
    -- (Not inside the pcall: the game's Lua can't pause there.)
    if i % 50 == 0 then P.Yield() end
  end
  writList = list
  return list
end

-- A vendor that sells an item, from Questie's data, for an item no vendor you've opened sells:
-- the nearest one your faction can use, with an estimated price (four times what a vendor pays
-- for the item, which is how the game prices most vendor goods).
-- Only for ordinary vendor goods (thread, salt, vials, dyes: sold by trade suppliers everywhere,
-- without limit). Things only a few vendors carry, or that players craft (Copper Modulators,
-- Strange Dust), are sold one or two at a time: a plan can't count on buying dozens there.
local COMMON_AT = 20 -- how many vendors must sell it for it to count as an ordinary vendor good
local crafted     -- item -> true for everything a recipe makes
local function Crafted(item)
  if not crafted then
    crafted = {}
    for _, line in pairs(ns.recipeData or {}) do
      for _, recipe in pairs(line.r or {}) do
        if recipe.i then crafted[recipe.i] = true end
      end
    end
  end
  return crafted[item] or false
end
local sellers = {} -- item -> { npc ids } or false
local everySeller = {} -- the same, for goods known to be ordinary (ns.vendorGoods)
-- The nearest vendor of your faction that sells an item, from Questie's data: { name, map, x, y,
-- zone }, or nil. Only for ordinary goods (20 or more vendors, nothing a recipe makes) unless
-- `known` says it is one.
function P.NearestSeller(key, item, known)
  if key ~= ns.PlayerKey() then return nil end
  -- Without Questie there's nothing to ask (and nothing is remembered, in case it loads later).
  if not (type(QuestieLoader) == "table" and QuestieLoader.ImportModule) then return nil end
  local cache = known and everySeller or sellers
  local list = cache[item]
  if list == nil then
    list = false
    do
      local ok, out = pcall(function()
        local db = QuestieLoader:ImportModule("QuestieDB")
        local ids = db.QueryItemSingle(item, "vendors")
        if type(ids) ~= "table" then return nil end
        if not known and (#ids < COMMON_AT or Crafted(item)) then return nil end
        local mine = (P.Info(key).faction or ""):sub(1, 1) -- "A" or "H"
        local found = {}
        -- Every one of them, so the nearest (a capital city's trade supplier, say) is among them.
        for i = 1, #ids do
          local friendly = db.QueryNPCSingle(ids[i], "friendlyToFaction")
          if type(friendly) ~= "string" or mine == "" or friendly:find(mine, 1, true) then
            found[#found + 1] = ids[i]
          end
        end
        return #found > 0 and found or nil
      end)
      if ok and out then list = out end
    end
    cache[item] = list
  end
  if not list then return nil end
  local here, best = P.Here(), nil
  for _, id in ipairs(list) do
    for _, spot in ipairs(P.NpcPlaces(id) or {}) do
      if not best or P.Better(spot, 0, best, 0, here) then best = spot end
    end
  end
  if not best then return nil end
  local info = C_Map and C_Map.GetMapInfo and ns.Try(C_Map.GetMapInfo, best.map)
  return { name = best.name or "a vendor", map = best.map, x = best.x, y = best.y,
    zone = info and info.name or nil }
end

-- The same, with its price: the game's own vendor price (built in), else an estimate (4x what a
-- vendor pays for it), for ordinary goods with no price known at all.
function P.VendorGuess(key, item)
  local fact = ns.itemFacts and ns.itemFacts[item]
  local sell = P.Item(item).sell
  if not sell and C_Item and C_Item.GetItemInfo then sell = select(11, C_Item.GetItemInfo(item)) end
  local unit, real = fact and fact.b, fact and fact.b and true or false
  if not unit and type(sell) == "number" and sell > 0 then unit = sell * 4 end
  if not unit then return nil end
  local spot = P.NearestSeller(key, item)
  if spot then spot.unit, spot.real = unit, real end
  return spot
end

----------------------------------------------------------------------
-- What you chose, kept between sessions
----------------------------------------------------------------------

local function Prefs(profession)
  local c = ns.Char()
  if not c then return {} end
  if type(c.planPrefs) ~= "table" then c.planPrefs = {} end
  if type(c.planPrefs[profession]) ~= "table" then c.planPrefs[profession] = {} end
  return c.planPrefs[profession]
end
Planner.Prefs = Prefs

----------------------------------------------------------------------
-- Every profession's goals
----------------------------------------------------------------------

-- Goals that haven't been worked out yet: an empty list that says so.
local function Stub(profession)
  return { profession = profession, title = profession .. " goals", targets = {}, groups = {}, levels = {},
    stub = true, summary = "Working out your " .. profession .. " goals..." }
end

-- Every profession this character has, each with its goals (a stub until they're worked out).
function Planner.Plans()
  local c = ns.Char()
  local list = c and c.professions and c.professions.list
  if type(list) == "table" then
    for name in pairs(list) do
      if not plans[name] then plans[name] = Stub(name) end
    end
    for name, plan in pairs(plans) do
      if not list[name] and not plan.fixed and not P.browse[name] then plans[name] = nil end
    end
  end
  -- Professions you haven't learned but asked to look at.
  for name in pairs(P.browse) do
    if not plans[name] then plans[name] = Stub(name) end
  end
  return plans
end

-- Puts ready-made goals in place, never to be worked out again (the tests use this).
function Planner.Set(profession, plan)
  plan.fixed = true
  plan.profession = plan.profession or profession
  local prefs = Prefs(profession)
  prefs.showWaypoints = nil -- the waypoint tick box is gone (0.10)
  for _, t in ipairs(plan.targets or {}) do
    if t.id == prefs.selected and not t.no then plan.selected = t.id end
  end
  plans[profession] = plan
  if ns.PlanUpdated then ns.PlanUpdated(profession) end
end

function Planner.Version() return version end

-- Something plans depend on changed.
function Planner.Touch()
  version = version + 1
end

----------------------------------------------------------------------
-- Working plans out, a little each frame
----------------------------------------------------------------------

local Step

local function Start()
  if ticker or not C_Timer or not C_Timer.NewTicker then return end
  ticker = C_Timer.NewTicker(0.01, function() Step() end)
end

local function Stop()
  if ticker then
    ticker:Cancel()
    ticker = nil
  end
end

function Step()
  if not running then
    running = table.remove(queue, 1)
    if not running then
      Stop()
      return
    end
    running.co = coroutine.create(running.fn)
  end
  sliceStart = clock()
  local ok, err = coroutine.resume(running.co)
  if not ok then
    local job = running
    running = nil
    ns.Error("planner " .. tostring(job.key), tostring(err) .. "\n" .. (debug and debug.traceback and debug.traceback(job.co) or ""))
    if job.failed then job.failed() end
  elseif coroutine.status(running.co) == "dead" then
    -- Finished: only now is the window told, so it sees that nothing is being worked out.
    local job = running
    running = nil
    if job.done then ns.Run("planner", job.done) end
  end
  if not running and #queue == 0 then Stop() end
end

local function Queued(key)
  if running and running.key == key then return true end
  for _, job in ipairs(queue) do
    if job.key == key then return true end
  end
  return false
end

local function Enqueue(key, fn, done, failed)
  if Queued(key) then return end
  queue[#queue + 1] = { key = key, fn = fn, done = done, failed = failed }
  Start()
end

-- Whether anything is being worked out for a profession right now.
function Planner.Busy(profession)
  return Queued("build:" .. profession) or Queued("goal:" .. profession)
end

-- Brings what's recorded up to date before planning from it (it's normally a few seconds
-- behind the game).
local function RecordNow()
  for _, name in ipairs({ "SaveSkills", "SaveKnownRecipes", "SaveInfo", "SaveBags", "SaveCurrencies", "SaveReputations" }) do
    if ns[name] then ns.Run("planner", ns[name]) end
  end
end

----------------------------------------------------------------------
-- A started plan is kept through /reload and logging out
----------------------------------------------------------------------

-- A copy that the saved data can hold: plain values only, no functions, no loops.
local function Plain(v, seen)
  local kind = type(v)
  if kind == "string" or kind == "number" or kind == "boolean" then return v end
  if kind ~= "table" then return nil end
  seen = seen or {}
  if seen[v] then return nil end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    local kk = type(k)
    if kk == "string" or kk == "number" then out[k] = Plain(x, seen) end
  end
  seen[v] = nil
  return out
end

local function TargetOf(plan, id)
  if id == "multi" then return plan.multi end
  for _, t in ipairs(plan.targets or {}) do
    if t.id == id then return t end
  end
end

-- The picked goal's plan as worked out, with the progress on its steps, or nil when there's
-- nothing to keep (nothing picked, not worked out, or every step done).
function Planner.Snapshot(plan)
  local id = plan and plan.selected
  local t = id and TargetOf(plan, id)
  if not (t and t.planned and not t.no and t.level) then return nil end
  local level = type(plan.levels) == "table" and plan.levels[t.level]
  if type(level) ~= "table" then return nil end
  local open = false
  for _, list in ipairs({ level.steps or {}, t.tail or {} }) do
    for _, step in ipairs(list) do
      if not step.done then open = true end
    end
  end
  if not open then return nil end
  local goal = tostring(id)
  return Plain({ id = id, count = G.Count(plan, id), target = t, level = level, levelKey = t.level, items = plan.items,
    usedMats = type(plan.usedMats) == "table" and plan.usedMats[goal] or nil, at = time and time() or 0 })
end

-- Puts a kept plan back in place of working it out again. True when it did.
local function Restore(plan, kept)
  if type(kept) ~= "table" or kept.id == nil or plan.selected ~= kept.id then return false end
  if type(kept.target) ~= "table" or type(kept.level) ~= "table" or kept.levelKey == nil then return false end
  -- Kept for another count of crafts: worked out again.
  if kept.count ~= nil and kept.count ~= G.Count(plan, kept.id) then return false end
  if kept.id == "multi" then
    if not plan.multi then return false end
    plan.multi = kept.target
  else
    local t = TargetOf(plan, kept.id)
    if not t then return false end
    for k, v in pairs(kept.target) do t[k] = v end
  end
  local t = TargetOf(plan, kept.id)
  t.planned, t.no = true, nil
  plan.levels = type(plan.levels) == "table" and plan.levels or {}
  plan.levels[kept.levelKey] = kept.level
  if type(kept.items) == "table" then
    plan.items = type(plan.items) == "table" and plan.items or {}
    for item, meta in pairs(kept.items) do
      if plan.items[item] == nil then plan.items[item] = meta end
    end
  end
  if type(kept.usedMats) == "table" then
    plan.usedMats = type(plan.usedMats) == "table" and plan.usedMats or {}
    plan.usedMats[tostring(kept.id)] = kept.usedMats
  end
  -- Picking another goal works everything out afresh (the kept steps belong to this one).
  plan.restored = kept.id
  return true
end

-- Only the first time a profession's goals are worked out after logging in: Refresh, or
-- anything later, works them out from scratch.
local restoreTried = {}

ns.On("PLAYER_LOGOUT", function()
  for profession, plan in pairs(plans) do
    if not plan.fixed and not plan.stub then
      local ok, kept = pcall(Planner.Snapshot, plan)
      Prefs(profession).kept = ok and kept or nil
    end
  end
end)

-- Works a profession's goals out from scratch, then the plan of the goal that's picked.
local function Build(profession)
  local key = ns.PlayerKey()
  RecordNow()
  local built = version
  local plan = G.Catalog(key, profession)
  if not plan then
    plans[profession] = nil
    return
  end
  plan.version = built
  local prefs = Prefs(profession)
  -- How many of each recipe goal to craft (the count box), saved with the goals picked.
  prefs.counts = type(prefs.counts) == "table" and prefs.counts or {}
  plan.counts = prefs.counts
  prefs.showWaypoints = nil -- the waypoint tick box is gone (0.10)
  -- The goal you picked last time, if it's still there to pick; or the several you picked.
  for _, t in ipairs(plan.targets) do
    if t.id == prefs.selected and not t.no then plan.selected = t.id end
  end
  if type(prefs.picked) == "table" and #prefs.picked > 1 then
    local multi = G.NewMulti(plan, prefs.picked)
    if #multi.ids > 1 then
      plan.multi, plan.picked, plan.selected = multi, multi.ids, "multi"
    elseif #multi.ids == 1 then
      plan.selected = multi.ids[1]
    end
  end
  -- The plan you'd started before a /reload or logging out comes back as it was.
  local first = not restoreTried[profession]
  restoreTried[profession] = true
  local restored = first and plan.selected and Restore(plan, prefs.kept)
  if not restored then
    prefs.kept = nil
    if plan.selected then G.PlanGoal(plan, plan.selected) end
  end
  plans[profession] = plan
end

function Planner.Rebuild(profession)
  local plan = plans[profession]
  if plan and plan.fixed then return end
  if not P.Prof(ns.PlayerKey(), profession) then return end
  local function updated()
    -- True: the goal list itself is new, so an open dropdown showing the old one is closed.
    if ns.PlanUpdated then ns.PlanUpdated(profession, true) end
  end
  Enqueue("build:" .. profession, function() Build(profession) end, updated, function()
    -- It went wrong: say so in the window instead of "working it out" forever.
    local now = plans[profession]
    if now and now.stub then
      now.failed = true
      now.summary = "Something went wrong working out these goals. The error is saved for a bug report."
    end
    updated()
  end)
end

-- Makes sure a profession's goals are worked out and up to date, and the picked goal planned.
-- keep: the picked goal's plan is under way, so it stays as it was worked out (what was the
-- cheapest route when you started must not turn into another one after you've bought for it).
function Planner.Want(profession, keep)
  local plan = profession and plans[profession]
  if not plan or plan.fixed then return end
  if plan.stub or (plan.version ~= version and not keep)
    or (plan.restored ~= nil and plan.selected ~= plan.restored) then
    Planner.Rebuild(profession)
    return
  end
  local id = plan.selected
  if not id then return end
  local targets = plan.targets
  -- Several goals picked together are one goal of their own.
  if id == "multi" then targets = { plan.multi } end
  for _, t in ipairs(targets) do
    if t.id == id and not t.planned and not t.no and t.level then
      if not Queued("build:" .. profession) then
        Enqueue("goal:" .. profession, function()
          -- The goal picked by the time this runs.
          local now = plans[profession]
          if now and now == plan and now.selected then G.PlanGoal(now, now.selected) end
        end, function()
          if ns.PlanUpdated then ns.PlanUpdated(profession) end
        end, function()
          -- It went wrong: the goal says so instead of "working it out" forever.
          for _, goal in ipairs(targets) do
            if goal.id == plan.selected and not goal.planned then
              goal.no = "Something went wrong working out this plan. The error is saved for a bug report."
            end
          end
          if ns.PlanUpdated then ns.PlanUpdated(profession) end
        end)
      end
      return
    end
  end
end

-- True when the goal showing is still being worked out.
function Planner.Pending(plan)
  if not plan or plan.fixed then return false end
  if plan.stub then return not plan.failed end
  if plan.selected == "multi" then
    local m = plan.multi
    return m ~= nil and not m.planned and not m.no
  end
  for _, t in ipairs(plan.targets) do
    if t.id == plan.selected then return not t.planned and not t.no and t.level ~= nil end
  end
  return false
end

----------------------------------------------------------------------
-- When plans go out of date
----------------------------------------------------------------------

-- Every change to something recorded that plans are made from.
local DEPENDS = { info = true, professions = true, bags = true, bank = true, accountBank = true, mail = true,
  currencies = true, recipes = true, knownRecipes = true, vendors = true, trainers = true, gear = true }
local markDirty = ns.MarkDirty
function ns.MarkDirty(section)
  if DEPENDS[section] then version = version + 1 end
  return markDirty(section)
end

-- Auction prices can have changed after a visit (Auctionator scans there).
ns.On("AUCTION_HOUSE_CLOSED", Planner.Touch)
ns.On("PLAYER_MONEY", Planner.Touch)
