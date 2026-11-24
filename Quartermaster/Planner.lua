-- The planner, part 1: reading what's recorded, and the skill planner.
--
-- Everything here works from the recorded data (QuartermasterDB), the recipe data in
-- Recipes.lua and auction prices from Auctionator. It touches no windows, so it can run
-- outside the game too (the tests do that with real saved data).
--
-- The skill planner finds the cheapest way to take a profession from its current skill to a
-- target:
--   - What the character already owns is used first and counts as free.
--   - Anything it's short of is priced at the cheapest of: making it from sub-materials (Light
--     Leather -> Medium Leather), a recorded vendor, or the auction house (your own scans).
--   - Recipes it doesn't know yet can be used if a recorded trainer or vendor teaches them, or
--     the pattern is on the auction house. The cost to learn is part of the plan.
--   - The budget is gold on hand. Selling is never counted, to a vendor or on the auction
--     house: what's crafted often goes off to be disenchanted.
-- How it chooses: one skill point at a time, it looks at every usable recipe, works out what the
-- next stretch of points would cost with that recipe (using up owned materials as it goes), and
-- takes the cheapest. It repeats this with different weights on "save owned materials for later"
-- and keeps whichever whole plan costs the least gold.
--
-- Planning takes a while, so it runs a little each frame (see PlannerJobs.lua); P.Yield() is
-- where it pauses.

local _, ns = ...

local P = {}
ns.P = P

local EPS = 1e-9
local LOOKAHEAD = 25
local OWNED_WEIGHTS = { 0.0, 0.35, 1.0 }

P.CHANCE_NOTE = "Skill-up chances for yellow and green recipes use Classic's formula, which isn't confirmed "
  .. "for Forever. Craft counts for those steps are estimates."

local floor, ceil, max, min = math.floor, math.ceil, math.max, math.min

local function list(t) return type(t) == "table" and t or {} end
P.list = list

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end
P.copy = copy

-- A scratch copy of an inventory for trying something out: it reads through to the real one
-- and keeps only what the trial changes, so trying is cheap however much the character owns.
local function trialOf(inv)
  return setmetatable({}, { __index = inv })
end

-- 12345 -> "1g 23s 45c"
-- "a Leatherworking trainer", "an Alchemy trainer".
function P.A(word)
  word = tostring(word)
  return (word:find("^[AEIOUaeiou]") and "an " or "a ") .. word
end

function P.Money(copper)
  if copper == nil then return "?" end
  copper = floor(copper + 0.5)
  local sign = copper < 0 and "-" or ""
  copper = math.abs(copper)
  local g, s, c = floor(copper / 10000), floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
  return sign .. table.concat(parts, " ")
end
local Money = P.Money

-- Whole number of crafts or items: 3.0000001 is 3, 3.2 is 4.
local function whole(n) return ceil(n - 1e-6) end
P.whole = whole

-- Pauses the plan being worked out until the next frame, when it has used up this frame's time.
function P.Yield() end

----------------------------------------------------------------------
-- Reading the recorded data
----------------------------------------------------------------------

function P.Char(key)
  return ns.db and ns.db.chars[key] or nil
end

local function info(key)
  local c = P.Char(key)
  return c and type(c.info) == "table" and c.info or {}
end
P.Info = info

-- Gold on hand. In game it's asked for live (see PlannerJobs.lua).
function P.Gold(key)
  return info(key).money or 0
end

-- How many of a currency (Merchant's Favor) the character has.
function P.Currency(key, id)
  local c = P.Char(key)
  for _, cur in ipairs(list(c and c.currencies and c.currencies.list)) do
    if cur.id == id then return cur.n or 0, cur.name end
  end
  return 0, nil
end

-- Two characters can mail and trade only on the same ruleset and faction.
function P.CanShare(a, b)
  local ia, ib = info(a), info(b)
  return ia.ruleset ~= nil and ia.ruleset == ib.ruleset and ia.faction == ib.faction
end

-- Whether a recorded vendor, trainer or NPC is one this character can use.
local function usable(record, who)
  if record.ruleset and who.ruleset and (record.ruleset ~= who.ruleset or record.faction ~= who.faction) then
    return false
  end
  return true
end

-- { [item] = { total, bags, bank, mail, accountBank } } for one character.
function P.Owned(key)
  local c = P.Char(key) or {}
  local out = {}
  local function add(item, n, where)
    if not item or not n or n == 0 then return end
    local e = out[item]
    if not e then
      e = { total = 0, bags = 0, bank = 0, mail = 0, accountBank = 0 }
      out[item] = e
    end
    e[where] = e[where] + n
    e.total = e.total + n
  end
  for _, where in ipairs({ "bags", "bank", "accountBank" }) do
    for _, it in ipairs(list(c[where] and c[where].items)) do add(it.id, it.n or 1, where) end
  end
  for _, msg in ipairs(list(c.mail and c.mail.messages)) do
    for _, it in ipairs(list(msg.items)) do add(it.id, it.n or 1, "mail") end
  end
  return out
end

-- How many of an item your other characters hold, where they could mail it:
-- "+12 on Ana Brightwood", or nil.
function P.Elsewhere(key, item)
  local parts = {}
  local others = {}
  for other in pairs(ns.db.chars) do others[#others + 1] = other end
  table.sort(others)
  for _, other in ipairs(others) do
    local c = ns.db.chars[other]
    if other ~= key and c.own and P.CanShare(key, other) then
      local n = 0
      for _, where in ipairs({ "bags", "bank", "accountBank" }) do
        for _, it in ipairs(list(c[where] and c[where].items)) do
          if it.id == item and not it.bound then n = n + (it.n or 1) end
        end
      end
      for _, msg in ipairs(list(c.mail and c.mail.messages)) do
        for _, it in ipairs(list(msg.items)) do
          if it.id == item then n = n + (it.n or 1) end
        end
      end
      if n > 0 then parts[#parts + 1] = "+" .. n .. " on " .. (other:gsub("%-", " ")) end
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or nil
end

function P.Item(item)
  local items = ns.db.account.items
  return (item and (items[item] or items[tostring(item)])) or {}
end

-- The character level an item needs: recorded, or asked from the game (PlannerJobs.lua), or nil.
function P.ItemLevel(item)
  local req = P.Item(item).req
  if type(req) == "number" and req > 0 then return req end
  local live = P.LiveLevel(item)
  return (type(live) == "number" and live > 0) and live or nil
end
function P.LiveLevel() return nil end

-- An item's name: recorded, or asked from the game, or "item 123".
function P.LiveName() return nil end
function P.ItemName(item)
  return P.Item(item).name or P.LiveName(item) or ("item " .. tostring(item))
end

function P.Npc(id)
  local npcs = ns.db.account.npcs
  return (id ~= nil and (npcs[id] or npcs[tostring(id)])) or {}
end

----------------------------------------------------------------------
-- Places: where things are, and which is nearest
----------------------------------------------------------------------

-- Where the character is standing: { map, x, y } (x and y in 0 to 100), or nil when that isn't
-- known (outside the game, or inside an instance). In game it's asked live (PlannerJobs.lua).
function P.Here() return nil end

-- How far apart two places are, or nil when that can't be told (different maps, here). In game
-- it's measured in the world's own coordinates, so places on neighboring maps compare too.
function P.Distance(a, b)
  if a.map and a.map == b.map and a.x and b.x then
    local dx, dy = a.x - b.x, a.y - b.y
    return math.sqrt(dx * dx + dy * dy)
  end
  return nil
end

-- Whether place a is the better one to send someone to than place b: the nearer one when both
-- distances are known, one with a known distance over one without, else the one seen most
-- recently (seenA and seenB are when).
local function better(a, seenA, b, seenB, here)
  if not b then return true end
  local da = here and a and a.x and P.Distance(here, a) or nil
  local db = here and b.x and P.Distance(here, b) or nil
  if da and db and da ~= db then return da < db end
  if (da ~= nil) ~= (db ~= nil) then return da ~= nil end
  return (seenA or 0) > (seenB or 0)
end
P.Better = better

-- A vendor that sells an item, for an item no vendor you've opened sells, from another addon's
-- data (Questie, in PlannerJobs.lua): { unit = estimated price for one, name, map, x, y }, or
-- nil. The price is an estimate (four times what a vendor pays for the item); opening the
-- vendor replaces it with the real one.
function P.VendorGuess() return nil end

-- Where an NPC that hasn't been recorded stands, from another addon's data: a list of
-- { map, x, y, name }, or nil. (PlannerJobs.lua asks Questie when it's installed.)
function P.NpcPlaces() return nil end

-- The reputation a character has earned with a faction (by name), in all: Neutral starts at 0,
-- Friendly at 3000. Nil when it isn't recorded.
function P.Reputation(key, faction)
  local c = P.Char(key)
  local r = c and c.reputations and c.reputations.list and c.reputations.list[faction]
  return type(r) == "table" and tonumber(r.earned) or nil
end

-- Every Craftsman's Writ there is, from another addon's data (Questie, in PlannerJobs.lua), in
-- order of quest: { { quest, writ (the writ's item), title, items = { { item, n } }, rep, npc
-- (who takes it) } }, or nil when there's nothing to ask.
function P.Writs() return nil end

-- Skill where each rank tops out. The next rank can be trained 25 points before that in Classic;
-- Forever hasn't confirmed it.
P.RANKS = { { 75, "Apprentice" }, { 150, "Journeyman" }, { 225, "Expert" }, { 300, "Artisan" } }
P.RANK_BAND = 25

-- The ranks to train on the way from a cap to a target skill, in order: { name, cap (the skill
-- the rank before it stops at), who, map, x, y, zone }. The place is a recorded trainer of the
-- profession this character can use: the nearest, or without a position the one seen last.
function P.Ranks(key, profession, cap, target)
  local out, at = {}, cap
  -- A profession not learned yet: the first rank is learning it.
  local fresh = cap == 0 and (P.Prof(key, profession) or {}).unlearned
  for _, rank in ipairs(P.RANKS) do
    if rank[1] > at and at < target then
      if at > 0 or fresh then out[#out + 1] = { name = rank[2], cap = at } end
      at = rank[1]
    end
  end
  if #out == 0 then return out end
  local who, here = info(key), P.Here()
  local keys = {}
  for npc in pairs(ns.db.account.trainers) do keys[#keys + 1] = npc end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local best, bestName
  for _, id in ipairs(keys) do
    local t = ns.db.account.trainers[id]
    local teaches = false
    if type(t) == "table" and usable(t, who) then
      for _, s in ipairs(list(t.services)) do
        if s.skill == profession then teaches = true break end
      end
    end
    local npc = teaches and P.Npc(id)
    if npc and npc.map and npc.x ~= nil and better(npc, npc.savedAt, best, best and best.savedAt, here) then
      best, bestName = npc, t.name
    end
  end
  if best then
    for _, rank in ipairs(out) do
      rank.who, rank.map, rank.x, rank.y, rank.zone = bestName, best.map, best.x, best.y, best.subzone or best.zone
    end
  end
  return out
end

-- The nearest recorded place of a kind this character can use ("vendor", "banker", "mailbox",
-- "auctioneer", "trainer", "crates"): the record from QuartermasterDB.account.npcs, or nil. Without a
-- position to measure from, the one used most recently.
function P.Nearest(key, kind)
  local who, here = info(key), P.Here()
  local keys = {}
  for id in pairs(ns.db.account.npcs) do keys[#keys + 1] = id end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local best
  for _, id in ipairs(keys) do
    local npc = ns.db.account.npcs[id]
    if type(npc) == "table" and npc.kinds and npc.kinds[kind] and npc.x ~= nil and usable(npc, who) then
      if better(npc, npc.savedAt, best, best and best.savedAt, here) then best = npc end
    end
  end
  return best
end

-- The flight masters this character can fly between: recorded ones (with a place and a flight
-- point) whose flight point the character knows.
function P.FlightMasters(key)
  local c = P.Char(key)
  local nodes = (c and c.flightPaths and c.flightPaths.nodes) or {}
  local who, out = info(key), {}
  local keys = {}
  for id in pairs(ns.db.account.npcs) do keys[#keys + 1] = id end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, id in ipairs(keys) do
    local npc = ns.db.account.npcs[id]
    if type(npc) == "table" and npc.kinds and npc.kinds.flightmaster and npc.x ~= nil and npc.flightNode
      and usable(npc, who) and type(nodes[npc.flightNode]) == "table" and nodes[npc.flightNode].known then
      out[#out + 1] = npc
    end
  end
  return out
end

-- A flight is taken when the walking left (to the flight master, and from where you land) is
-- under this share of going straight there.
local FLIGHT_WORTH = 0.6

-- The way to a place from where the character stands, as stops in order:
-- { { map, x, y, title, fly = <flight point to take from here> }, ... }. The last stop is the
-- place itself. When flying clearly beats going straight there, the first stop is the nearest
-- flight master, to fly to the flight point nearest the place.
function P.Route(key, dest)
  local stops = { { map = dest.map, x = dest.x, y = dest.y, title = dest.name } }
  local here = P.Here()
  if not here then return stops end
  local direct = P.Distance(here, dest)
  local from, fromD, to, toD
  for _, fm in ipairs(P.FlightMasters(key)) do
    local d = P.Distance(here, fm)
    if d and (not fromD or d < fromD) then from, fromD = fm, d end
    local e = P.Distance(fm, dest)
    if e and (not toD or e < toD) then to, toD = fm, e end
  end
  if from and to and from ~= to and from.flightNode ~= to.flightNode and P.Distance(from, to)
    and direct and fromD + toD < direct * FLIGHT_WORTH then
    table.insert(stops, 1, { map = from.map, x = from.x, y = from.y, fly = to.flightNode,
      title = ("%s: fly to %s"):format(tostring(from.name or "Flight master"), tostring(to.flightNode)) })
  end
  return stops
end

-- The nearest auctioneer this character has used (a recorded NPC with a position), or {}.
function P.AuctionHouse(key)
  return P.Nearest(key, "auctioneer") or {}
end

-- Recorded vendors, in a fixed order, so the same data always gives the same plan.
local function vendorsInOrder()
  local keys = {}
  for npc in pairs(ns.db.account.vendors) do keys[#keys + 1] = npc end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local i = 0
  return function()
    i = i + 1
    local npc = keys[i]
    if npc ~= nil then return npc, ns.db.account.vendors[npc] end
  end
end
P.Vendors = vendorsInOrder

-- Cheapest recorded gold price per item at vendors this character can use:
-- { [item] = { unit, npc, name } }. Items that cost anything besides gold, or that the vendor
-- stocks in limited numbers, are left out.
function P.VendorPrices(key)
  local who, out, here = info(key), {}, P.Here()
  for npc, v in vendorsInOrder() do
    if type(v) == "table" and usable(v, who) then
      local spot = P.Npc(npc)
      for _, it in ipairs(list(v.items)) do
        local price, item = it.price, it.id
        -- Something a vendor stocks only one or two of (it restocks slowly) isn't a place to buy
        -- materials: a plan can't count on it.
        if item and price and price > 0 and not it.costs and it.stock == nil then
          local unit = price / max(1, it.stack or 1)
          local old = out[item]
          -- At the same price, the nearest vendor (or the one you visited most recently, when
          -- there's nowhere to measure from).
          if not old or unit < old.unit
            or (unit == old.unit and better(spot, v.savedAt, old.spot, old.seen, here)) then
            out[item] = { unit = unit, npc = npc, name = v.name, stock = it.stock, seen = v.savedAt or 0, spot = spot }
          end
        end
      end
    end
  end
  return out
end

-- What recorded trainers teach, by recipe name: { [name] = { npc, trainer, cost, skill, level,
-- item } }. Cheapest wins. Only trainers this character can use.
function P.TrainerOffers(key, profession)
  local who, out = info(key), {}
  local keys = {}
  for npc in pairs(ns.db.account.trainers) do keys[#keys + 1] = npc end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, npc in ipairs(keys) do
    local t = ns.db.account.trainers[npc]
    if type(t) == "table" and usable(t, who) then
      for _, s in ipairs(list(t.services)) do
        if not profession or s.skill == profession then
          local offer = { npc = npc, trainer = t.name, cost = s.cost or 0, skill = s.skillRank or 0,
            level = s.level or 0, item = s.item, seen = t.savedAt or 0 }
          -- Cheapest wins; at the same fee, the trainer opened most recently.
          local old = s.name and out[s.name]
          if s.name and (not old or offer.cost < old.cost or (offer.cost == old.cost and offer.seen > old.seen)) then
            out[s.name] = offer
          end
        end
      end
    end
  end
  return out
end

----------------------------------------------------------------------
-- Auction prices: Auctionator's own scans
----------------------------------------------------------------------

-- Auctionator's record for an item ({ m = lowest price last seen, a = { [day] = how many were
-- listed }, h = { [day] = price } }), or nil. Replaced outside the game.
function P.PriceEntry(item)
  local db = Auctionator and Auctionator.Database and Auctionator.Database.db
  local e = type(db) == "table" and db[tostring(item)] or nil
  return type(e) == "table" and e or nil
end

-- Whether there are auction prices at all (Auctionator is installed). Without it, nothing the
-- addon shows or says mentions the auction house.
function P.HasAuctions()
  return type(Auctionator) == "table" and type(Auctionator.Database) == "table"
end

-- Auctionator's number for today.
function P.ScanDay()
  local zero = Auctionator and Auctionator.Constants and Auctionator.Constants.SCAN_DAY_0
  return zero and floor((time() - zero) / 86400) or 0
end

local function lastDay(t)
  local best
  for day in pairs(list(t)) do
    local n = tonumber(day)
    if n and (not best or n > best) then best = n end
  end
  return best
end

-- Lowest buyout last seen for one, in copper, or nil.
function P.Price(item)
  local e = item and P.PriceEntry(item)
  local p = e and e.m
  if type(p) == "number" and p > 0 then return p end
  return nil
end

-- How many were listed on the last day this item was seen, or nil.
function P.Listed(item)
  local e = item and P.PriceEntry(item)
  local day = e and lastDay(e.a)
  if not day then return nil end
  return e.a[tostring(day)] or e.a[day]
end

function P.SeenDaysAgo(item)
  local e = item and P.PriceEntry(item)
  local day = e and lastDay(e.h)
  return day and (P.ScanDay() - day) or nil
end

----------------------------------------------------------------------
-- Recipes
----------------------------------------------------------------------

-- Professions this character hasn't learned that the plan window was asked to show: name -> the
-- skill line in Recipes.lua. In memory only.
P.browse = {}

-- A profession's record: skill, max (the cap), skillLine. For one the character hasn't learned
-- but is looking at, a stand-in: skill 1 (where learning it starts), cap 0, unlearned = true.
function P.Prof(key, profession)
  local c = P.Char(key)
  local prof = c and c.professions and c.professions.list and c.professions.list[profession]
  if prof then return prof end
  local line = P.browse[profession]
  if line and ns.recipeData and ns.recipeData[line] then
    return { skill = 1, max = 0, skillLine = line, unlearned = true }
  end
  return nil
end

-- A profession's name as the game shows it, from its skill line (PlannerJobs.lua asks the game).
function P.LocalName() return nil end

-- Every profession in the built-in recipe data this character hasn't learned:
-- { { name, line } }, by name.
function P.Unlearned(key)
  local c = P.Char(key)
  local names, lines = {}, {}
  for name, prof in pairs(list(c and c.professions and c.professions.list)) do
    names[name] = true
    if type(prof) == "table" and prof.skillLine then lines[prof.skillLine] = true end
  end
  local out = {}
  for line, d in pairs(ns.recipeData or {}) do
    local name = P.LocalName(line) or d.name
    if not lines[line] and not names[name] and not names[d.name] then out[#out + 1] = { name = name, line = line } end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- The recipe data for a profession (Recipes.lua): { [spell] = { n, i, d, s, p, m } }.
function P.RecipeDB(key, profession)
  local prof = P.Prof(key, profession)
  local data = prof and prof.skillLine and ns.recipeData and ns.recipeData[prof.skillLine]
  if not data then
    for _, d in pairs(ns.recipeData or {}) do
      if d.name == profession then data = d end
    end
  end
  return data and data.r or {}
end

-- Whether the character knows a recipe, asked from the game (PlannerJobs.lua). Used when
-- nothing about the profession has been recorded yet.
function P.Knows() return false end

-- A character's recipes for a profession: { savedAt, recipes = { [spell] = { name, item, min,
-- known, reagents = { { id, n } } } } }, or nil when the built-in recipe data has nothing for
-- the profession.
-- From the profession window when it's been opened (exact). Otherwise from the built-in recipe
-- data (Recipes.lua), with which recipes the character knows taken from what's recorded or,
-- failing that, asked from the game: so a profession can be planned at once, before anything
-- about it has been opened or recorded. Then fromDatabase is true and every recipe is assumed
-- to make one item.
function P.Recipes(key, profession)
  local c = P.Char(key)
  if not c then return nil end
  local seen = c.recipes and c.recipes[profession]
  if seen and type(seen.recipes) == "table" and next(seen.recipes) then
    -- The list is as the profession window last showed it. A recipe learned since (a pattern
    -- bought at a vendor) is known now, whatever the list says.
    local learned
    for spell, r in pairs(seen.recipes) do
      if type(spell) == "number" and type(r) == "table" and not r.known and P.Knows(key, spell) then
        learned = learned or {}
        learned[spell] = true
      end
    end
    if not learned then return seen end
    local out = copy(seen)
    out.recipes = copy(seen.recipes)
    for spell in pairs(learned) do
      local r = copy(seen.recipes[spell])
      r.known = true
      out.recipes[spell] = r
    end
    return out
  end
  local db = P.RecipeDB(key, profession)
  if not next(db) then return nil end
  local fresh = (P.Prof(key, profession) or {}).unlearned
  local auto = (ns.recipeSources and ns.recipeSources.auto) or {}
  local known = not fresh and c.knownRecipes and c.knownRecipes.list and c.knownRecipes.list[profession]
  local ids
  if known then
    ids = {}
    for _, spell in ipairs(list(known.ids)) do ids[spell] = true end
  end
  local out = {}
  for spell, ref in pairs(db) do
    local reagents = {}
    for i = 1, #list(ref.m), 2 do reagents[#reagents + 1] = { id = ref.m[i], n = ref.m[i + 1] } end
    local knows
    if fresh then
      -- Not learned yet: what learning the profession teaches with it counts as known.
      knows = auto[spell] and true or false
    elseif ids then knows = ids[spell] or false else knows = P.Knows(key, spell) and true or false end
    out[spell] = { name = ref.n or ("recipe " .. spell), item = ref.i, min = 1, known = knows, reagents = reagents }
  end
  return { savedAt = known and c.knownRecipes.savedAt or nil, recipes = out, fromDatabase = true }
end

----------------------------------------------------------------------
-- Camp stations: things a recipe has to be made beside that no town has. Players make them
-- (or buy them at the auction house) and place them at a campfire, where they're used up.
-- The plan counts one as a material, bought or made once.
----------------------------------------------------------------------

-- Station name (as the profession window names the requirement) -> the item you place.
-- "Anvil" isn't here: towns have anvils.
P.STATIONS = {
  ["Tanning Rack"] = 279941, ["Sewing Machine"] = 279945, ["Spinning Wheel"] = 279943, ["Loom"] = 279959,
  ["Fermenter"] = 279970, ["Alchemy Laboratory"] = 279990, ["Arcane Forge"] = 279987,
  ["Anarchist's Workbench"] = 279989, ["Iron Oven"] = 279982, ["Molten Foundry"] = 279952,
  ["Master Forge"] = 279955, ["Plague Doctor's Laboratory"] = 279951, ["Trapper's Workbench"] = 279938,
  ["Seed Hybridizer"] = 279947,
}
-- Leatherworking recipes that need a Tanning Rack, for before the profession window has said
-- so itself (from a players' guide, not the game's data).
local TANNING = {}
for _, spell in ipairs({ 1255087,1255085,1255086,1255084,1255083,1255082,1255081,1255080,1255078,1255079,1255077,1255076,1255075,1255071,1255070,1255068,1255069,1255067,1255066,1255065,1255064,1255063,1255062,1255061,1255060,1255011,1255009,1255010,1255008,1255007,1255005,1255006,1255004,1255003,1255001,1255002,1255000,23399,3778,22711,10619,10621,10630,19047,10647,10632,10650,19050 }) do TANNING[spell] = true end

-- Things towns have, which a recipe may name but nobody has to bring.
local FIXTURES = { ["Anvil"] = true, ["Forge"] = true, ["Black Anvil"] = true, ["Black Forge"] = true,
  ["Cooking Fire"] = true }

-- The item with this name: something a recipe makes, or an item on record. The lowest ID wins.
local byName
function P.ItemByName(name)
  if not byName then
    byName = {}
    local function note(n, item)
      if type(n) == "string" and type(item) == "number" and (not byName[n] or item < byName[n]) then byName[n] = item end
    end
    for _, d in pairs(ns.recipeData or {}) do
      for _, r in pairs(d.r or {}) do note(r.n, r.i) end
    end
    for item, it in pairs(ns.db and ns.db.account and ns.db.account.items or {}) do
      if type(it) == "table" then note(it.name, item) end
    end
  end
  return byName[name]
end
function P.ForgetNames() byName = nil end

-- What a recipe has to be made with or beside, beyond its materials: { { item, keep } }, or nil.
-- keep = true is a tool you hold on to (a Runed Silver Rod); false is a camp station, used up
-- when placed. What the profession window recorded wins over the built-in list.
function P.Needs(key, profession, spell)
  local c = P.Char(key)
  local seen = c and c.recipes and c.recipes[profession]
  local r = seen and type(seen.recipes) == "table" and seen.recipes[spell]
  local out = {}
  if type(r) == "table" and type(r.needs) == "table" then
    for _, name in ipairs(r.needs) do
      if P.STATIONS[name] then
        out[#out + 1] = { P.STATIONS[name], false }
      elseif not FIXTURES[name] then
        local item = P.ItemByName(name)
        if item then out[#out + 1] = { item, true } end
      end
    end
  elseif profession == "Leatherworking" and TANNING[spell] then
    out[1] = { P.STATIONS["Tanning Rack"], false }
  end
  return #out > 0 and out or nil
end

----------------------------------------------------------------------
-- The market: where to buy one item, and for how much
----------------------------------------------------------------------

function P.Market(key)
  local m = { vendors = P.VendorPrices(key), cache = {} }
  -- (price for one, "vendor" or "ah") for the cheapest place to buy, or nil.
  function m.buy(item)
    local hit = m.cache[item]
    if hit == nil then
      local unit, source
      local v = m.vendors[item]
      if v and not v.guess then
        unit, source = v.unit, "vendor"
        -- An ordinary vendor good costs the same everywhere, so the price you've seen is used
        -- with the nearest vendor that sells it, even one you haven't opened, when that one is
        -- clearly closer.
        local here = P.Here()
        local near = here and v.stock == nil and P.VendorGuess(key, item) or nil
        if near then
          local toNear = P.Distance(here, near)
          local toSeen = v.spot and v.spot.x and P.Distance(here, v.spot) or nil
          if toNear and (not toSeen or toNear < toSeen * 0.8) then
            v.name, v.npc = near.name, nil
            v.spot = { map = near.map, x = near.x, y = near.y, zone = near.zone }
          end
        end
      end
      local p = P.Price(item)
      if p and (not unit or p < unit) then unit, source = p, "ah" end
      if not unit then
        -- No vendor you've opened sells it and it has no auction price: a vendor from Questie's
        -- data, at an estimated price. An estimate never beats a real price: those vendors
        -- often stock only one or two (Strange Dust, Copper Modulators), and the guess can be low.
        local guess = P.VendorGuess(key, item)
        if guess then
          v = { unit = guess.unit, name = guess.name, guess = true,
            spot = { map = guess.map, x = guess.x, y = guess.y, zone = guess.zone } }
          m.vendors[item] = v
          unit, source = v.unit, "vendor"
        end
      end
      hit = unit and { unit, source } or false
      m.cache[item] = hit
    end
    if hit then return hit[1], hit[2] end
    return nil
  end
  function m.value(item)
    return (m.buy(item)) or 0
  end
  return m
end

-- Chance that one craft gives a skill point. d = { orange, yellow, green, grey }.
local function chance(skill, d)
  local yellow, grey = d[2], d[4]
  if skill >= grey then return 0 end
  if skill < yellow then return 1 end
  return (grey - skill) / (grey - yellow)
end
P.Chance = chance

function P.Color(skill, d)
  if skill >= d[4] then return "grey" end
  if skill >= d[3] then return "green" end
  if skill >= d[2] then return "yellow" end
  return "orange"
end

-- Every recipe of the profession this character could use: ones it knows, and ones it can learn
-- from a recorded trainer, a recorded vendor (for gold), or a pattern on the auction house.
-- Returns the recipes (sorted by spell) and how many were left out, by reason. Nil when the
-- profession's recipes aren't recorded.
function P.BuildRecipes(key, profession, includeAHPatterns, market)
  local recorded = P.Recipes(key, profession)
  if not recorded then return nil end
  local level = info(key).level or 0
  local db = P.RecipeDB(key, profession)
  local trainers = P.TrainerOffers(key, profession)
  market = market or P.Market(key)
  local who = info(key)
  local vendors = {}
  for npc, v in vendorsInOrder() do
    if type(v) == "table" then
      for _, it in ipairs(list(v.items)) do
        if it.id then
          vendors[it.id] = vendors[it.id] or {}
          table.insert(vendors[it.id], { npc, v, it })
        end
      end
    end
  end
  local recipes, skipped = {}, {}
  local function skip(why) skipped[why] = (skipped[why] or 0) + 1 end
  for spell, r in pairs(recorded.recipes) do
    local ref = db[spell]
    if type(spell) ~= "number" then
      -- not a recipe
    elseif not ref or #list(ref.d) ~= 4 then
      skip("no thresholds in the recipe database")
    else
      local required = ref.s or ref.d[1]
      local reagents = {}
      for _, g in ipairs(list(r.reagents)) do
        if g.id and g.n then reagents[#reagents + 1] = { g.id, g.n } end
      end
      if #reagents > 0 then
        local known = r.known and true or false
        local learn, ok = nil, true
        if not known then
          local offer = trainers[r.name]
          local scroll = ref.p
          if offer then
            if offer.level > level then
              skip("needs a higher character level")
              ok = false
            else
              learn = { how = "trainer", cost = offer.cost, skill = offer.skill > 0 and offer.skill or required,
                npc = offer.npc, who = offer.trainer }
              required = max(required, offer.skill)
            end
          elseif scroll and vendors[scroll] then
            local best
            for _, entry in ipairs(vendors[scroll]) do
              local it = entry[3]
              if not it.costs and (it.price or 0) > 0 and (not best or it.price < best[3].price) then best = entry end
            end
            if not best then
              skip("costs something other than gold")
              ok = false
            else
              learn = { how = "vendor", cost = best[3].price, skill = required, npc = best[1], who = best[2].name,
                item = scroll }
            end
          else
            -- Nothing you've opened teaches it: the built-in data (Recipes.lua).
            local refs = ns.recipeSources or {}
            local costs = refs.costs and refs.costs[spell]
            local dataVendor, dataGold
            if costs then
              -- A vendor in Forever's own list, when it sells the pattern for gold alone.
              local npcs = {}
              for npc in pairs(costs) do npcs[#npcs + 1] = npc end
              table.sort(npcs)
              for _, npc in ipairs(npcs) do
                local gold, other = 0, false
                for _, cost in ipairs(costs[npc]) do
                  if cost.g then gold = gold + cost.g else other = true end
                end
                if not other and gold > 0 and (not dataGold or gold < dataGold) then dataVendor, dataGold = npc, gold end
              end
            end
            local trainers = refs.src and refs.src[spell] and refs.src[spell].t
            if dataVendor then
              learn = { how = "vendor", cost = dataGold, skill = required, item = scroll, data = { dataVendor },
                who = (refs.names and refs.names[dataVendor]) or "a vendor" }
            elseif scroll and includeAHPatterns and P.Price(scroll) then
              learn = { how = "ah", cost = P.Price(scroll), skill = required, item = scroll, unconfirmed = true }
            elseif trainers then
              -- Taught by trainers, in Classic's data. What it costs isn't known until one is
              -- opened, so it's counted as nothing and the plan says so.
              learn = { how = "trainer", cost = 0, skill = required, data = trainers, unknownCost = true }
            elseif costs then
              skip("costs something other than gold")
              ok = false
            else
              skip("no known way to learn it")
              ok = false
            end
          end
        end
        if ok then
          recipes[#recipes + 1] = {
            spell = spell, name = r.name or ref.n or ("recipe " .. spell), item = r.item,
            makes = max(1, r.min or 1), reagents = reagents, difficulty = ref.d, required = required,
            known = known, learn = learn, points = max(1, r.skillUps or 1),
            needs = P.Needs(key, profession, spell),
          }
        end
      end
    end
  end
  table.sort(recipes, function(a, b) return a.spell < b.spell end)
  return recipes, skipped
end

----------------------------------------------------------------------
-- One simulated walk from the current skill to the target
----------------------------------------------------------------------

local Run = {}
Run.__index = Run
P.Run = Run

function P.NewRun(recipes, market, owned, weight, noMake, prepaid)
  local run = setmetatable({
    prepaid = prepaid or {},       -- recipes whose learning cost doesn't count against them
    noMake = noMake or {},         -- items never to make from sub-materials (buy them instead)
    recipes = recipes, market = market,
    inv = copy(owned),
    weight = weight,               -- how much owned materials are "worth saving" (0 = free)
    learned = {}, makers = {},     -- makers: item -> recipes that produce it
    placed = {},                   -- tools and camp stations already got for this plan
    toolLearns = {},               -- recipes learned to make a tool, in order
    commits = {},                  -- one per skill point gained
    whole = false,                 -- true: sub-crafts are made in whole numbers
  }, Run)
  for _, r in ipairs(recipes) do
    if r.known then run.learned[r.spell] = true end
    if r.item then
      run.makers[r.item] = run.makers[r.item] or {}
      table.insert(run.makers[r.item], r)
    end
  end
  return run
end

-- Gets n of an item out of inv, buying or making what's missing. Returns the gold spent and the
-- weighted cost, and appends what it did to ops. Returns nil if it can't be had at all.
function Run:acquire(item, n, inv, ops, depth, stack)
  depth = depth or 0
  local gold, soft = 0, 0
  local have = inv[item] or 0
  local take = min(have, n)
  if take > EPS then
    inv[item] = have - take
    ops[#ops + 1] = { "use", item, take }
    soft = soft + self.weight * self.market.value(item) * take
  end
  local short = n - take
  if short <= EPS then return gold, soft end

  local bestSoft, bestGold, bestInv, bestOps, bestS
  local unit, source = self.market.buy(item)
  if unit then
    bestSoft, bestGold, bestOps = unit * short, unit * short, { { "buy", item, short, source, unit } }
  end
  if depth < 3 and not (stack and stack[item]) and not self.noMake[item] then
    for _, maker in ipairs(self.makers[item] or {}) do
      if self.learned[maker.spell] then
        local crafts = short / maker.makes
        if self.whole then crafts = whole(crafts) end
        local trial, trialOps = trialOf(inv), {}
        local g, s, ok = 0, 0, true
        local deeper = stack and copy(stack) or {}
        deeper[item] = true
        for _, reagent in ipairs(maker.reagents) do
          local g2, s2 = self:acquire(reagent[1], reagent[2] * crafts, trial, trialOps, depth + 1, deeper)
          if not g2 then
            ok = false
            break
          end
          g, s = g + g2, s + s2
        end
        if ok and (bestSoft == nil or g + s < bestSoft - EPS) then
          -- Anything made beyond what's needed stays in the bags for later.
          local extra = crafts * maker.makes - short
          if extra > EPS then trial[item] = (trial[item] or 0) + extra end
          trialOps[#trialOps + 1] = { "make", maker.spell, crafts }
          bestSoft, bestGold, bestInv, bestOps, bestS = g + s, g, trial, trialOps, s
        end
      end
    end
  end
  if bestSoft == nil then return nil end
  if bestInv then
    -- The winning trial holds only what it changed.
    for k, v in pairs(bestInv) do inv[k] = v end
    soft = soft + bestS
  end
  for _, op in ipairs(bestOps) do ops[#ops + 1] = op end
  return gold + bestGold, soft
end

-- Gets the tools and camp stations a recipe needs that the plan hasn't got yet: one of each,
-- once. A tool you hold costs nothing and stays; a station is used up. Returns gold, weighted
-- cost, and the items that can't be had (no price, no known recipe), if any.
function Run:equip(recipe, inv, ops, commit, skill)
  local gold, soft, missing = 0, 0, nil
  for _, need in ipairs(recipe.needs or {}) do
    local item, keep = need[1], need[2]
    if not self.placed[item] then
      if commit then self.placed[item] = true end
      if not (keep and (inv[item] or 0) >= 1) then
        local g, s = self:acquire(item, 1, inv, ops)
        if not g then
          -- Its own recipe isn't known yet: learn that first, if it can be learned by now.
          for _, maker in ipairs(self.makers[item] or {}) do
            local l = maker.learn
            if not g and not self.learned[maker.spell] and l and l.skill <= (skill or 0) and maker.required <= (skill or 0) then
              self.learned[maker.spell] = true
              g, s = self:acquire(item, 1, inv, ops)
              if g then
                g = g + l.cost
                if commit then
                  self.toolLearns[#self.toolLearns + 1] = maker
                else
                  self.learned[maker.spell] = nil
                end
              else
                self.learned[maker.spell] = nil
              end
            end
          end
        end
        if g then
          gold, soft = gold + g, soft + s
          if keep then inv[item] = (inv[item] or 0) + 1 end
        else
          missing = missing or {}
          missing[#missing + 1] = item
        end
      end
    end
  end
  return gold, soft, missing
end

-- One expected skill point from this recipe at this skill: 1/chance crafts.
-- Returns gold, weighted cost and crafts, or nil.
function Run:craftOnce(recipe, skill, inv, ops)
  local p = chance(skill, recipe.difficulty)
  if p <= 0 then return nil end
  local crafts = 1 / p
  local gold, soft = 0, 0
  for _, reagent in ipairs(recipe.reagents) do
    local g, s = self:acquire(reagent[1], reagent[2] * crafts, inv, ops)
    if not g then return nil end
    gold, soft = gold + g, soft + s
  end
  if recipe.item then inv[recipe.item] = (inv[recipe.item] or 0) + recipe.makes * crafts end
  return gold, soft, crafts
end

-- Lowest average cost per point over the next stretch with this recipe, or nil.
function Run:score(recipe, skill, target)
  if recipe.required > skill then return nil end
  local total = 0
  if not self.learned[recipe.spell] then
    if recipe.learn.skill > skill then return nil end
    if not self.prepaid[recipe.spell] then total = total + recipe.learn.cost end
  end
  local inv = trialOf(self.inv)
  -- A tool or camp station it needs: one, the first time a recipe needs it.
  if recipe.needs then
    local g, soft = self:equip(recipe, inv, {}, false, skill)
    total = total + g + soft
  end
  local best, s = nil, skill
  local scratch = {}
  for _ = 1, min(LOOKAHEAD, target - skill) do
    for i = #scratch, 1, -1 do scratch[i] = nil end
    local g, soft = self:craftOnce(recipe, s, inv, scratch)
    if not g then break end
    total = total + g + soft
    s = s + recipe.points
    local avg = total / (s - skill)
    if best == nil or avg < best - EPS then best = avg end
    if s >= target then break end
  end
  return best
end

function Run:walk(skill, target)
  local current
  while skill < target do
    local options = {}
    for _, r in ipairs(self.recipes) do
      local sc = self:score(r, skill, target)
      if sc ~= nil then
        options[#options + 1] = { floor(sc * 1000 + 0.5) / 1000, r == current and 0 or 1,
          -chance(skill, r.difficulty), r.spell, r }
      end
      P.Yield()
    end
    if #options == 0 then return skill end -- stuck: nothing usable gives points here
    table.sort(options, function(a, b)
      for i = 1, 4 do
        if a[i] ~= b[i] then return a[i] < b[i] end
      end
      return false
    end)
    local recipe = options[1][5]
    local ops, learn = {}, nil
    if not self.learned[recipe.spell] then
      self.learned[recipe.spell] = true
      learn = recipe.learn
    end
    local stationGold = 0
    local learnedBefore = #self.toolLearns
    if recipe.needs then stationGold = self:equip(recipe, self.inv, ops, true, skill) end
    -- Recipes learned just now to make a tool: their fee is counted with the learning, not here.
    local pre
    for i = learnedBefore + 1, #self.toolLearns do
      pre = pre or {}
      pre[#pre + 1] = self.toolLearns[i]
      stationGold = stationGold - self.toolLearns[i].learn.cost
    end
    local g, _, crafts = self:craftOnce(recipe, skill, self.inv, ops)
    g = g + stationGold
    self.commits[#self.commits + 1] = { recipe = recipe, skill = skill, crafts = crafts, gold = g,
      chance = chance(skill, recipe.difficulty), ops = ops, learn = learn, pre = pre }
    skill = skill + recipe.points
    current = recipe
  end
  return skill
end

function Run:gold()
  local total = 0
  for _, c in ipairs(self.commits) do
    total = total + c.gold + (c.learn and c.learn.cost or 0)
    for _, maker in ipairs(c.pre or {}) do total = total + maker.learn.cost end
  end
  return total
end

----------------------------------------------------------------------
-- The skill plan
----------------------------------------------------------------------

-- A plan for taking `profession` to `target`. opts: includeAHPatterns (default true), noMake,
-- weights (the "save owned materials" weights to try), market, recipes (to reuse).
-- Returns nil and a reason when it can't be planned at all.
function P.PlanSkill(key, profession, target, opts)
  opts = opts or {}
  local prof = P.Prof(key, profession)
  if not prof then return nil, key .. " doesn't have " .. profession end
  local skill, cap = prof.skill or 0, prof.max or 0
  local warnings = {}
  if target == nil then target = cap end
  -- Past the cap: the plan trains each rank on the way, at the point the skill gets there.
  local ranks, rankAt = P.Ranks(key, profession, cap, target), {}
  for _, rank in ipairs(ranks) do
    rankAt[rank.cap] = true
    if rank.cap == 0 then
      warnings[#warnings + 1] = ("You haven't learned %s: the plan starts with learning it at %s trainer. "
        .. "What that costs isn't counted."):format(profession, P.A(profession))
    else
      warnings[#warnings + 1] = ("Going past %d needs %s %s, trained at %s trainer. What that costs isn't counted.")
        :format(rank.cap, rank.name, profession, P.A(profession))
    end
  end
  local market = opts.market or P.Market(key)
  local recipes, skipped = opts.recipes, opts.skipped
  if not recipes then
    recipes, skipped = P.BuildRecipes(key, profession, opts.includeAHPatterns ~= false, market)
  end
  if not recipes then return nil, profession .. "'s recipes aren't recorded yet" end
  local ownedFull = P.Owned(key)
  local owned = {}
  for item, e in pairs(ownedFull) do owned[item] = e.total end

  local run, reached, bestGold
  for _, weight in ipairs(opts.weights or OWNED_WEIGHTS) do
    local trial = P.NewRun(recipes, market, owned, weight, opts.noMake)
    local got = trial:walk(skill, target)
    local trials = { { trial, got } }
    -- A recipe the walk ends up learning is paid for either way. Walk again with those counted
    -- as paid, so each is switched to where it's cheapest, not where it has paid itself off.
    local paid, any = {}, false
    for _, commit in ipairs(trial.commits) do
      if commit.learn then paid[commit.recipe.spell] = true; any = true end
    end
    if any then
      local again = P.NewRun(recipes, market, owned, weight, opts.noMake, paid)
      trials[2] = { again, again:walk(skill, target) }
    end
    for _, t in ipairs(trials) do
      local gold = t[1]:gold()
      -- Furthest skill first, then least gold.
      if not run or t[2] > reached or (t[2] == reached and gold < bestGold) then
        run, reached, bestGold = t[1], t[2], gold
      end
    end
  end
  if reached < target then
    warnings[#warnings + 1] = ("No recorded recipe gives skill points past %d, so the plan stops there. "
      .. "Visiting more trainers and vendors may open more recipes."):format(reached)
  end

  -- ---- put the walk together ----------------------------------------------------------
  local names = P.ItemName
  local bySpell = {}
  for _, r in ipairs(recipes) do bySpell[r.spell] = r end
  local budget = P.Gold(key)

  -- 1. Stretches: consecutive points gained with the same recipe.
  local stretches, learns = {}, {}
  local spent, affordableTo = 0, skill
  for _, commit in ipairs(run.commits) do
    local r = commit.recipe
    if commit.learn then
      local l = copy(commit.learn)
      l.spell, l.name, l.at = r.spell, r.name, commit.skill
      learns[#learns + 1] = l
    end
    local last = stretches[#stretches]
    if last and last.spell == r.spell and last.to == commit.skill and not rankAt[commit.skill] then
      last.to = last.to + r.points
      last.expected = last.expected + commit.crafts
      last.low = min(last.low, commit.chance)
    else
      stretches[#stretches + 1] = { spell = r.spell, name = r.name, item = r.item, from = commit.skill,
        to = commit.skill + r.points, expected = commit.crafts, high = commit.chance, low = commit.chance,
        color = P.Color(commit.skill, r.difficulty), learn = commit.learn and commit.learn.cost or 0 }
    end
    -- Recipes learned to make a tool these crafts need.
    for _, maker in ipairs(commit.pre or {}) do
      local l = copy(maker.learn)
      l.spell, l.name, l.at, l.tool, l.icon = maker.spell, maker.name, commit.skill, true, maker.item
      learns[#learns + 1] = l
      local st = stretches[#stretches]
      st.pre = st.pre or {}
      st.pre[#st.pre + 1] = l
      st.learn = st.learn + l.cost
      spent = spent + l.cost
    end
    spent = spent + commit.gold + (commit.learn and commit.learn.cost or 0)
    if spent <= budget + EPS then affordableTo = commit.skill + r.points end
  end

  -- 2. Whole numbers: each stretch is a whole number of crafts, and its materials are worked
  --    out again for exactly that many, so the shopping list always covers the craft counts.
  local final = P.NewRun(recipes, market, owned, run.weight, opts.noMake)
  final.whole = true
  local buys, uses, makes = {}, {}, {}
  local makeOrder = {}
  for _, st in ipairs(stretches) do
    local r = bySpell[st.spell]
    final.learned[r.spell] = true
    st.crafts = whole(st.expected)
    st.difficulty, st.reagents = r.difficulty, r.reagents
    local ops = {}
    -- The camp station these crafts are made beside: one, before the first stretch that needs it.
    if r.needs then
      for _, need in ipairs(r.needs) do
        if not need[2] and not final.placed[need[1]] then st.station = need[1] end
      end
      for _, l in ipairs(st.pre or {}) do final.learned[l.spell] = true end
      local _, _, missing = final:equip(r, final.inv, ops, true, st.from)
      st.missing = missing
    end
    for _, reagent in ipairs(r.reagents) do
      final:acquire(reagent[1], reagent[2] * st.crafts, final.inv, ops)
    end
    if r.item then final.inv[r.item] = (final.inv[r.item] or 0) + r.makes * st.crafts end
    st.buyN, st.makeN, st.makeOrder, st.gold = {}, {}, {}, st.learn
    for _, op in ipairs(ops) do
      if op[1] == "buy" then
        local k = op[2] .. ":" .. op[4]
        local e = buys[k]
        if not e then
          e = { item = op[2], source = op[4], n = 0, unit = op[5] }
          buys[k] = e
        end
        e.n = e.n + op[3]
        st.buyN[k] = (st.buyN[k] or 0) + op[3]
        st.gold = st.gold + op[3] * op[5]
      elseif op[1] == "use" then
        uses[op[2]] = (uses[op[2]] or 0) + op[3]
      elseif op[1] == "make" then
        if not makes[op[2]] then makeOrder[#makeOrder + 1] = op[2] end
        makes[op[2]] = (makes[op[2]] or 0) + op[3]
        if not st.makeN[op[2]] then st.makeOrder[#st.makeOrder + 1] = op[2] end
        st.makeN[op[2]] = (st.makeN[op[2]] or 0) + op[3]
      end
    end
    P.Yield()
  end
  run = final

  local function bySourceThenName(a, b)
    if a.source ~= b.source then return a.source < b.source end
    if a.name ~= b.name then return a.name < b.name end
    return a.item < b.item
  end
  local shopping, byKey = {}, {}
  for k, e in pairs(buys) do
    local n = whole(e.n)
    local row = { item = e.item, name = names(e.item), source = e.source, n = n, unit = e.unit, total = n * e.unit }
    shopping[#shopping + 1] = row
    byKey[k] = row
  end
  table.sort(shopping, bySourceThenName)
  for _, row in ipairs(shopping) do
    local e, n = row, row.n
    if e.source == "vendor" then
      local v = market.vendors[e.item]
      local npc = v.spot or P.Npc(v.npc)
      row.npc, row.who, row.map, row.x, row.y = v.npc, v.name, npc.map, npc.x, npc.y
      row.zone = npc.subzone or npc.zone
      if v.guess then
        row.guess = true
        warnings[#warnings + 1] = ("%s: the price is an estimate. You haven't opened %s yet; opening it records "
          .. "the real price."):format(row.name, tostring(v.name or "that vendor"))
      end
      if v.stock ~= nil and v.stock < n then
        warnings[#warnings + 1] = ("%s only had %d %s in stock; it restocks over time."):format(
          tostring(v.name), v.stock, row.name)
      end
    else
      local avail, age = P.Listed(e.item), P.SeenDaysAgo(e.item)
      row.available, row.seenDaysAgo = avail, age
      if avail ~= nil and avail < n then
        warnings[#warnings + 1] = ("Only %d %s were listed when last scanned, and the plan needs %d. The price may "
          .. "be higher than shown: search the auction house before buying."):format(avail, row.name, n)
      end
      if age ~= nil and age > 2 then
        warnings[#warnings + 1] = ("The %s price is %d days old."):format(row.name, age)
      end
    end
    row.elsewhere = P.Elsewhere(key, e.item)
  end

  for _, learn in ipairs(learns) do
    if learn.npc ~= nil then
      local npc = P.Npc(learn.npc)
      learn.map, learn.x, learn.y, learn.zone = npc.map, npc.x, npc.y, npc.subzone or npc.zone
    end
    if learn.data and learn.map == nil then
      -- A trainer or vendor you haven't opened: the nearest one Questie's data has a place for.
      local here, best = P.Here(), nil
      for _, id in ipairs(learn.data) do
        for _, spot in ipairs(P.NpcPlaces(id) or {}) do
          if not best or better(spot, 0, best, 0, here) then best = spot end
        end
      end
      if best then
        learn.map, learn.x, learn.y = best.map, best.x, best.y
        learn.who = learn.who or best.name
      end
    end
    if learn.unknownCost then
      warnings[#warnings + 1] = ("%s: taught by a trainer you haven't opened (Classic's data). What it costs "
        .. "isn't counted until you open one."):format(learn.name)
    end
    if learn.unconfirmed then
      warnings[#warnings + 1] = ("%s: the pattern is on the auction house; the skill it needs (%d) comes from "
        .. "Classic data and isn't confirmed for Forever."):format(learn.name, learn.skill)
    end
  end

  -- What to buy and make for each stretch on its own, for buying in stages.
  local anyLuck = false
  for _, st in ipairs(stretches) do
    local rows = {}
    for k, n in pairs(st.buyN) do
      if n > 1e-6 then
        local row = copy(byKey[k])
        row.n = whole(n)
        row.total = row.n * row.unit
        rows[#rows + 1] = row
      end
    end
    table.sort(rows, bySourceThenName)
    st.buys = rows
    local made = {}
    for _, spell in ipairs(st.makeOrder) do
      local r = bySpell[spell]
      local from = {}
      for _, reagent in ipairs(r.reagents) do from[#from + 1] = names(reagent[1]) end
      made[#made + 1] = { spell = spell, name = r.name, item = r.item, n = whole(st.makeN[spell]), from = from }
    end
    st.makes = made
    st.buyN, st.makeN, st.makeOrder = nil, nil, nil
    if st.low < 1 then anyLuck = true end
  end
  if anyLuck then warnings[#warnings + 1] = P.CHANCE_NOTE end


  -- What's left at the end that the plan made (products).
  local leftovers, leftBy = {}, {}
  for _, st in ipairs(stretches) do
    local r = bySpell[st.spell]
    if r.item and not leftBy[r.item] then
      local made = (run.inv[r.item] or 0) - (owned[r.item] or 0)
      if made >= 1 - 1e-6 then
        local l = { item = r.item, name = names(r.item), n = floor(made + 1e-6) }
        leftovers[#leftovers + 1] = l
        leftBy[r.item] = l
      end
    end
  end

  -- Money over time: each stretch's materials, bought in order. Nothing comes back: what's
  -- crafted is never counted as sold.
  local wallet, tightest, tightAt = budget, 0, nil
  for _, st in ipairs(stretches) do
    wallet = wallet - st.gold
    if wallet < tightest - EPS then
      if tightAt == nil then tightAt = st.from end
      tightest = wallet
    end
  end
  local cashflow = { needExtra = tightest < 0 and ceil(-tightest) or 0, tightAt = tightAt,
    endGold = floor(wallet + 0.5) }

  -- Sub-crafts made from bought materials: what each one saves, and how many crafts it adds.
  local tradeoffs = {}
  for _, spell in ipairs(makeOrder) do
    local r = bySpell[spell]
    local direct = market.buy(r.item)
    local sub = 0
    for _, reagent in ipairs(r.reagents) do sub = sub + market.value(reagent[1]) * reagent[2] end
    sub = sub / r.makes
    local crafts = whole(makes[spell])
    if direct and sub < direct and crafts >= 20 then
      tradeoffs[#tradeoffs + 1] = { item = r.item, name = names(r.item), crafts = crafts,
        saves = floor((direct - sub) * crafts * r.makes + 0.5) }
    end
  end

  local used = {}
  for item, n in pairs(uses) do
    if owned[item] and n >= 1 - 1e-6 then
      local o = ownedFull[item] or {}
      used[#used + 1] = { item = item, name = names(item), n = whole(n), bags = o.bags or 0, bank = o.bank or 0,
        mail = o.mail or 0 }
    end
  end
  table.sort(used, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.item < b.item
  end)

  local buyTotal, learnTotal = 0, 0
  for _, row in ipairs(shopping) do buyTotal = buyTotal + row.total end
  for _, l in ipairs(learns) do learnTotal = learnTotal + l.cost end
  local total = buyTotal + learnTotal
  return {
    char = key, profession = profession, from = skill, to = reached, target = target, cap = cap,
    stretches = stretches, learns = learns, ranks = ranks, shopping = shopping, used = used, leftovers = leftovers,
    cost = { buy = buyTotal, learn = learnTotal, total = total },
    gold = budget, short = max(0, total - budget), affordableTo = affordableTo,
    cashflow = cashflow, tradeoffs = tradeoffs, warnings = warnings, skipped = skipped,
    recipesConsidered = #recipes,
    -- The simulation at the end of the plan (what's left in the bags, what's been learned), for
    -- working out what comes after it.
    final = run,
  }
end
