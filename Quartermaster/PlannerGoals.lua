-- The planner, part 2: the goals in the plan window's dropdown.
--
-- G.Catalog(key, profession) lists every goal of a profession: its skill checkpoints and every
-- recipe, each with where it comes from and what it costs (gold or any other currency), in the
-- groups the dropdown shows. That part is quick.
-- G.PlanGoal(plan, id) then works out one goal's plan when it's picked: the cheapest steps to
-- the skill it needs (Planner.lua) and, for a recipe, the steps after that (earn any Merchant's
-- Favor the pattern costs, learn it, get the materials for one, craft it).
-- All the wording the plan window shows is decided here.
--
-- Places: a step that sends you to one particular NPC carries map, x, y and where (its name).
-- A step that any place of a kind will do for carries near = "vendor", "mailbox", "banker",
-- "auctioneer" or "crates" (where crates are handed in); the plan window then points at the nearest one from wherever you're standing.

local _, ns = ...

local P = ns.P
local G = {}
ns.Goals = G

local list, copy, Money, whole = P.list, P.copy, P.Money, P.whole
local floor, max, min = math.floor, math.max, math.min

-- Skill where each rank tops out, and how far before it the next can be trained (Planner.lua).
local RANKS, BAND = P.RANKS, P.RANK_BAND

-- Professions whose skill comes from doing the thing, not from crafting: what you do, and what
-- doing it is called. (By the profession's English name, as Recipes.lua has it.)
local GATHERING = { Fishing = { "Fish", "fishing" }, Skinning = { "Skin", "skinning" },
  Herbalism = { "Gather herbs", "gathering herbs" }, Mining = { "Mine", "mining" } }

-- Professions whose every list is split under the profession window's own headings (food by
-- its buff). Elsewhere only "Recipes you know" is.
local BY_CATEGORY = { Cooking = true }

-- What a tier of gear is called, by the slot the item goes in.
local SLOT_NAMES = { INVTYPE_HEAD = "Head", INVTYPE_SHOULDER = "Shoulders", INVTYPE_CHEST = "Chest",
  INVTYPE_ROBE = "Chest", INVTYPE_WAIST = "Belt", INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Boots",
  INVTYPE_WRIST = "Bracers", INVTYPE_HAND = "Gloves", INVTYPE_CLOAK = "Cloak", INVTYPE_WEAPON = "Weapon",
  INVTYPE_2HWEAPON = "Weapon", INVTYPE_SHIELD = "Shield", INVTYPE_FINGER = "Ring", INVTYPE_NECK = "Neck",
  INVTYPE_TRINKET = "Trinket", INVTYPE_WEAPONMAINHAND = "Weapon", INVTYPE_WEAPONOFFHAND = "Off-hand",
  INVTYPE_HOLDABLE = "Off-hand", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged", INVTYPE_THROWN = "Ranged",
  INVTYPE_BAG = "Bag", INVTYPE_QUIVER = "Quiver", INVTYPE_BODY = "Shirt", INVTYPE_TABARD = "Tabard" }

local function plural(n) return n == 1 and "" or "s" end
local function inZone(zone) return zone and (" in " .. zone) or "" end

-- The profession's English name (the recipe data's), for the tables above.
local function englishName(key, profession)
  local c = P.Char(key)
  local prof = c and c.professions and c.professions.list and c.professions.list[profession]
  local data = prof and prof.skillLine and ns.recipeData and ns.recipeData[prof.skillLine]
  return data and data.name or profession
end

----------------------------------------------------------------------
-- Materials and steps of a skill plan, as the plan window shows them
----------------------------------------------------------------------

-- One material: how many the plan needs, what one costs and where, so the window can show what
-- you have, what you're short, and what the shortfall costs.
local function matEntry(key, item, need, market, elsewhere)
  local entry = { item = item, name = P.ItemName(item), need = need }
  local unit, source = market.buy(item)
  if unit then
    entry.each = floor(unit * 100 + 0.5) / 100
    entry.where = source == "ah" and "auction house" or (market.vendors[item].name or "vendor")
    -- An estimated price, from a vendor you haven't opened.
    if source ~= "ah" and market.vendors[item].guess then entry.guess = true end
    -- Where to get it: that vendor, or the nearest auctioneer.
    if source == "ah" then
      entry.near = "auctioneer"
    else
      local npc = market.vendors[item].spot or P.Npc(market.vendors[item].npc)
      if npc.map and npc.x ~= nil then entry.map, entry.x, entry.y = npc.map, npc.x, npc.y end
    end
  end
  -- "(+12 on Ana Brightwood)": what your other characters could mail over.
  if elsewhere then entry.also = P.Elsewhere(key, item) end
  return entry
end

local function place(row)
  if row and row.map and row.x ~= nil then
    return { map = row.map, x = row.x, y = row.y, where = row.who }
  end
  return {}
end

local function put(step, spot)
  for k, v in pairs(spot) do step[k] = v end
  return step
end

local function withWho(spot, who)
  local out = copy(spot or {})
  out.who = who
  return out
end

-- The step for training a rank: done once the profession's cap is past where it was.
local function rankStep(profession, rank)
  local step = { k = "rank", profession = profession, cap = rank.cap,
    title = ("Train %s %s"):format(rank.name, profession),
    sub = ("At %s. It raises the cap past %d"):format(
      rank.who and (rank.who .. inZone(rank.zone)) or ("a " .. profession .. " trainer"), rank.cap) }
  return put(step, place(rank))
end

-- Turns a skill plan into the checklist the plan window shows: steps, materials and a summary.
local function delivery(plan, key, market)
  local owned = P.Owned(key)
  local ah = P.AuctionHouse(key)
  local steps = {}
  local function at(row) return (row.who or "a vendor") .. inZone(row.zone) end

  for _, u in ipairs(plan.used) do
    if u.mail > 0 and u.n > u.bags + u.bank then
      local take = min(u.mail, u.n - u.bags - u.bank)
      steps[#steps + 1] = { k = "collect", title = ("Take %d %s"):format(take, u.name), sub = "From your mailbox",
        icon = u.item, item = u.item, n = take, target = u.bags + u.bank + take, near = "mailbox" }
    end
  end

  local function buyStep(row, first)
    local step = { k = "buy", title = ("Buy %d %s"):format(row.n, row.name),
      sub = at(row) .. ", " .. (row.guess and "about " or "") .. Money(row.total) .. (row.guess and " (estimate)" or ""),
      icon = row.item, item = row.item, n = row.n }
    -- Known from what's recorded: done once you hold this many. Later stages can't be known
    -- ahead (materials get used up in between), so the window counts from when the step comes up.
    if first then step.target = ((owned[row.item] or {}).total or 0) + row.n end
    return put(step, place(row))
  end

  -- When the gold on hand covers everything, buy it all in one trip. Otherwise buy in stages:
  -- each stretch's materials right before it, so selling what you craft pays for the next.
  -- Auction house buys aren't steps: they're in the materials list, where the plan window turns
  -- them into one shopping list to buy all at once at the start. Vendor buys are trips to a place.
  local staged = plan.short > 0
  if not staged then
    for _, row in ipairs(plan.shopping) do
      if row.source ~= "ah" then steps[#steps + 1] = buyStep(row, true) end
    end
  end

  local learnAt = {}
  for _, l in ipairs(plan.learns) do
    if not learnAt[l.spell] then learnAt[l.spell] = l end
  end
  local ranks, nextRank = list(plan.ranks), 1
  for index, st in ipairs(plan.stretches) do
    -- A rank is trained right before the first crafts that go past its cap.
    while ranks[nextRank] and st.to > ranks[nextRank].cap do
      steps[#steps + 1] = rankStep(plan.profession, ranks[nextRank])
      nextRank = nextRank + 1
    end
    local l = learnAt[st.spell]
    learnAt[st.spell] = nil
    if l then
      local step = { k = "learn", title = "Learn " .. l.name, icon = st.item, spell = l.spell }
      if l.how == "ah" then
        step.sub = "Buy the pattern at the auction house (it's on your shopping list), about " .. Money(l.cost)
        put(step, place(withWho(ah, "Auction house")))
        step.near = "auctioneer"
      else
        if l.unknownCost then
          step.sub = "At a " .. plan.profession .. " trainer. What it costs isn't known until you open one"
        else
          step.sub = at(l) .. ", " .. Money(l.cost)
        end
        put(step, place(l))
      end
      steps[#steps + 1] = step
    end
    if staged then
      for _, row in ipairs(st.buys) do
        if row.source ~= "ah" then steps[#steps + 1] = buyStep(row, index == 1) end
      end
    end
    for _, m in ipairs(st.makes) do
      steps[#steps + 1] = { k = "make", title = ("Make %d %s"):format(m.n, m.name),
        sub = "From " .. table.concat(#m.from > 0 and m.from or { "what you have" }, ", "),
        icon = m.item, spell = m.spell, n = m.n }
    end
    local about = st.low >= 1 and "" or "about "
    steps[#steps + 1] = { k = "craft", spell = st.spell, skill = st.to, profession = plan.profession,
      title = "Craft " .. st.name,
      sub = ("Until %s %d, %s%d craft%s"):format(plan.profession, st.to, about, st.crafts, plural(st.crafts)),
      icon = st.item, n = st.crafts }
    if st.sell then
      local sl = st.sell
      steps[#steps + 1] = { k = "sell", item = sl.item, icon = sl.item, n = sl.n,
        title = ("Sell %d %s"):format(sl.n, sl.name), sub = "To any vendor, " .. Money(sl.vendor), near = "vendor" }
    end
  end

  local need = {}
  for _, u in ipairs(plan.used) do need[u.item] = (need[u.item] or 0) + u.n end
  for _, row in ipairs(plan.shopping) do need[row.item] = (need[row.item] or 0) + row.n end
  -- Patterns bought at the auction house go on the shopping list too.
  local patternNames = {}
  for _, l in ipairs(plan.learns) do
    if l.how == "ah" and l.item then
      need[l.item] = (need[l.item] or 0) + 1
      patternNames[l.item] = P.Item(l.item).name or ("Pattern: " .. l.name)
    end
  end
  local mats = {}
  for item, n in pairs(need) do
    local m = matEntry(key, item, n, market, true)
    if patternNames[item] then m.name = patternNames[item] end
    mats[#mats + 1] = m
  end
  table.sort(mats, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.item < b.item
  end)

  local summary = ("Cost %s. You have %s."):format(Money(plan.cost.total), Money(plan.gold))
  if plan.short > 0 then
    summary = summary .. (plan.cashflow.needExtra == 0 and " Buy in stages and sell what you craft."
      or (" %s short even when selling what you craft."):format(Money(plan.cashflow.needExtra)))
  end
  -- What the cheapest plan hides, and what to watch for.
  local notes = {}
  for _, t in ipairs(plan.tradeoffs) do
    notes[#notes + 1] = ("Making %s yourself saves %s but adds %d crafts."):format(t.name, Money(t.saves), t.crafts)
  end
  for _, w in ipairs(plan.warnings) do notes[#notes + 1] = w end
  return steps, mats, summary, notes
end
G.Delivery = delivery

----------------------------------------------------------------------
-- Where a recipe comes from
----------------------------------------------------------------------

local function costText(gold, others)
  local parts = {}
  if gold and gold > 0 then parts[#parts + 1] = Money(gold) end
  for _, o in ipairs(others or {}) do parts[#parts + 1] = tostring(o.n) .. " " .. tostring(o.name) end
  return table.concat(parts, ", ")
end

-- Everything a catalog needs to look sources up quickly: built once per catalog.
local function sourceContext(key, profession)
  local who = P.Info(key)
  local ctx = { key = key, profession = profession, trainers = P.TrainerOffers(key, profession),
    byScroll = {}, byName = {}, refs = ns.recipeSources or {} }
  local seq = 0
  for npc, v in P.Vendors() do
    local ok = type(v) == "table"
      and not (v.ruleset and who.ruleset and (v.ruleset ~= who.ruleset or v.faction ~= who.faction))
    if ok then
      for _, it in ipairs(list(v.items)) do
        seq = seq + 1
        local entry = { seq = seq, npc = npc, v = v, it = it }
        if it.id then
          ctx.byScroll[it.id] = ctx.byScroll[it.id] or {}
          table.insert(ctx.byScroll[it.id], entry)
        end
        -- "Pattern: Fine Leather Boots" teaches Fine Leather Boots.
        local taught = type(it.name) == "string" and it.name:match("^.-: (.+)$")
        if taught then
          ctx.byName[taught] = ctx.byName[taught] or {}
          table.insert(ctx.byName[taught], entry)
        end
      end
    end
  end
  return ctx
end

local function escape(text)
  return (tostring(text):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

-- Where an unknown recipe comes from and what it costs. Returns a table:
--   how      "trainer" | "vendor" | "ah" | "drop" | "quest" | "auto" | "unknown"
--   gold     copper, when it costs gold
--   others   { { n, name, currency or item } } for costs that aren't gold
--   skill    profession skill needed to learn it, when known
--   reqs     other requirements, as the game words them ("Requires Friendly with this faction.")
--   npc, who, map, x, y, zone   when the place is known
--   confirmed  true when it comes from your own game or Forever's own data
--   label    short text for the dropdown ("5s", "30 Merchant's Favor", "drop")
--   lines    full sentences for the tooltip
local function recipeSource(ctx, spell, name, ref)
  ref = ref or {}
  local key, profession = ctx.key, ctx.profession
  local scroll = ref.p
  local ah = scroll and P.Price(scroll) or nil

  local function spot(src, npcId)
    local npc = P.Npc(npcId)
    src.npc, src.map, src.x, src.y, src.zone = npcId, npc.map, npc.x, npc.y, npc.subzone or npc.zone
  end
  -- For a trainer or vendor you haven't opened: the nearest of these NPCs whose place another
  -- addon knows (Questie's data, when it's installed). Says so in the tooltip.
  local function locate(src, ids, names)
    local here, best = P.Here(), nil
    for _, id in ipairs(ids) do
      for _, spot in ipairs(P.NpcPlaces(id) or {}) do
        if not best or P.Better(spot, 0, best, 0, here) then
          best = { map = spot.map, x = spot.x, y = spot.y, name = spot.name or names[id] }
        end
      end
    end
    if best then
      src.map, src.x, src.y = best.map, best.x, best.y
      src.who = src.who or best.name or "NPC"
      src.lines[#src.lines + 1] = ("Where %s stands comes from Questie's data."):format(tostring(best.name or src.who))
    end
    return src
  end
  local function done(src)
    if src.skill == nil then src.skill = ref.s end
    if ah and src.how ~= "ah" then
      src.ah = ah
      src.lines[#src.lines + 1] = ("The pattern is also on the auction house for %s."):format(Money(ah))
    end
    return src
  end

  -- 1. A trainer you've opened.
  local offer = ctx.trainers[name]
  if offer then
    local src = { how = "trainer", gold = offer.cost, skill = offer.skill > 0 and offer.skill or ref.s,
      who = offer.trainer, confirmed = true, label = Money(offer.cost) }
    spot(src, offer.npc)
    src.lines = { ("Taught by %s%s for %s."):format(tostring(offer.trainer), inZone(src.zone), Money(offer.cost)) }
    return done(src)
  end

  -- 2. A vendor you've opened, selling the pattern.
  local found, seen = {}, {}
  for _, entries in ipairs({ scroll and ctx.byScroll[scroll] or {}, name and ctx.byName[name] or {} }) do
    for _, entry in ipairs(entries) do
      if not seen[entry] then
        seen[entry] = true
        found[#found + 1] = entry
      end
    end
  end
  table.sort(found, function(a, b) return a.seq < b.seq end)
  local best, bestRank
  for _, entry in ipairs(found) do
    local it = entry.it
    local others = {}
    for _, o in ipairs(list(it.costs)) do
      others[#others + 1] = { n = o.n, name = o.name or "?", currency = o.currency, item = o.item }
    end
    local gold = it.price or 0
    local skill, reqs = nil, {}
    for _, line in ipairs(list(it.tip)) do
      local n = type(line) == "string" and line:match("^Requires " .. escape(profession) .. " %((%d+)%)$")
      if n then
        skill = tonumber(n)
      elseif type(line) == "string" and line:find("^Requires ") and line:find("faction", 1, true) then
        reqs[#reqs + 1] = line
      end
    end
    local label = costText(gold, others)
    local cand = { how = "vendor", gold = gold, others = others, skill = skill or ref.s, reqs = reqs,
      who = entry.v.name, confirmed = true, label = label ~= "" and label or "free", item = it.id, stock = it.stock }
    spot(cand, entry.npc)
    -- Prefer a gold price over other currencies, then the cheaper one.
    -- At the same price, the vendor you visited most recently.
    local rank, seenAt = (#others > 0 and 1 or 0) * 1e12 + gold, entry.v.savedAt or 0
    if not best or rank < bestRank or (rank == bestRank and seenAt > best.seenAt) then
      best, bestRank = cand, rank
      cand.seenAt = seenAt
    end
  end
  if best then
    best.lines = { ("Sold by %s%s for %s."):format(tostring(best.who), inZone(best.zone), best.label) }
    for _, o in ipairs(best.others) do
      if o.currency then
        best.lines[#best.lines + 1] = ("You have %d %s."):format(P.Currency(key, o.currency), o.name)
      end
    end
    for _, line in ipairs(best.reqs) do best.lines[#best.lines + 1] = line end
    return done(best)
  end

  local refs = ctx.refs
  local known = (refs.src and refs.src[spell]) or {}
  local names = refs.names or {}
  local function whoList(ids, count)
    local shown = {}
    for i = 1, min(3, #ids) do shown[i] = names[ids[i]] or ("NPC " .. tostring(ids[i])) end
    local more = (count or #ids) - #shown
    return table.concat(shown, ", ") .. (more > 0 and (" and %d more"):format(more) or "")
  end

  -- 3. A vendor in Forever's own data that you haven't opened yet.
  local costs = refs.costs and refs.costs[spell]
  if costs then
    local npcs = {}
    for npc, cost in pairs(costs) do
      local hasGold = false
      for _, c in ipairs(cost) do
        if c.g then hasGold = true end
      end
      npcs[#npcs + 1] = { hasGold and 0 or 1, npc, cost }
    end
    table.sort(npcs, function(a, b)
      if a[1] ~= b[1] then return a[1] < b[1] end
      return a[2] < b[2]
    end)
    local npc, cost = npcs[1][2], npcs[1][3]
    local gold, others = 0, {}
    for _, c in ipairs(cost) do gold = gold + (c.g or 0) end
    for _, c in ipairs(cost) do
      if c.c then
        local _, curName = P.Currency(key, c.c)
        others[#others + 1] = { n = c.n, name = curName or ("currency " .. c.c), currency = c.c }
      end
    end
    for _, c in ipairs(cost) do
      if c.i then others[#others + 1] = { n = c.n or 1, name = P.ItemName(c.i), item = c.i } end
    end
    local label = costText(gold, others)
    if label == "" then label = "?" end
    local vendor = names[npc] or "a vendor"
    return done(locate({ how = "vendor", gold = gold, others = others, who = vendor, confirmed = true, label = label,
      lines = { ("Sold by %s for %s. You haven't opened this vendor yet, so the place isn't recorded.")
        :format(vendor, label) } }, { npc }, names))
  end

  -- 4. Learned with the profession itself.
  if refs.auto and refs.auto[spell] then
    return done({ how = "auto", confirmed = true, label = "", lines = { "Learned with the profession." } })
  end

  -- 5. Classic's data, which Forever may have changed.
  local note = " (Classic data, not confirmed for Forever)"
  if known.t then
    return done(locate({ how = "trainer", confirmed = false, label = "trainer",
      lines = { ("Taught by trainers such as %s%s. The cost isn't known until you open one.")
        :format(whoList(known.t, known.tn), note) } }, known.t, names))
  end
  if known.v then
    return done(locate({ how = "vendor", confirmed = false, label = "vendor",
      lines = { ("Sold by %s%s."):format(whoList(known.v, known.vn), note) } }, known.v, names))
  end
  if known.q then
    return done({ how = "quest", confirmed = false, label = "quest", lines = { "A quest reward" .. note .. "." } })
  end
  if known.d then
    if ah then
      return done({ how = "ah", gold = ah, confirmed = false, label = Money(ah) .. " at the AH", item = scroll,
        lines = { ("The pattern is on the auction house for %s."):format(Money(ah)),
          ("It drops from %s%s."):format(whoList(known.d, known.dn), note) } })
    end
    return done({ how = "drop", confirmed = false, label = "drop",
      lines = { ("Drops from %s%s."):format(whoList(known.d, known.dn), note) } })
  end
  if ah then
    return done({ how = "ah", gold = ah, confirmed = false, label = Money(ah) .. " at the AH", item = scroll,
      lines = { ("The pattern is on the auction house for %s."):format(Money(ah)) } })
  end
  return done({ how = "unknown", confirmed = false, label = "?",
    lines = { "No source is known yet. Opening more trainers and vendors may find it." } })
end

----------------------------------------------------------------------
-- Merchant's Favor: the cheapest way to earn a given amount
--
-- Favor comes from Waylaid Crates. You get an empty crate (looted, or from the auction house),
-- fill it with one of the materials it accepts, and hand it in. What you already own is used
-- first (crates and materials, free), then the cheapest crates and fills at auction house and
-- vendor prices, making materials from sub-materials where the character can.
--
-- What each crate takes and pays comes from a community guide and players' reports, not from
-- the game's own data, so it's flagged as unconfirmed wherever it's shown:
--   - fills: wow-professions.com's Merchant's Favor guide
--   - every crate pays a flat 5 Favor, with about a 15% chance of double (players' reports)
--   - Artisan crates (level 35) are left out: their fills aren't recorded here
----------------------------------------------------------------------

local FAVOR = 3402
local PER_CRATE = 5
G.FAVOR = FAVOR

-- { crate item, name, character level needed, { { material item, name, count }, ... } }
local CRATES = {
  { 248684, "Waylaid Crate: Apprentice Textiles", 10, { { 2589, "Linen Cloth", 40 }, { 2318, "Light Leather", 20 } } },
  { 248683, "Waylaid Crate: Apprentice Ore", 10, { { 2770, "Copper Ore", 20 }, { 2771, "Tin Ore", 20 } } },
  { 248682, "Waylaid Crate: Apprentice Herbs", 10, { { 2447, "Peacebloom", 20 }, { 765, "Silverleaf", 20 },
    { 2449, "Earthroot", 10 }, { 785, "Mageroyal", 10 }, { 2450, "Briarthorn", 10 } } },
  { 248685, "Waylaid Crate: Apprentice Curiosities", 10, { { 10940, "Strange Dust", 20 },
    { 10939, "Greater Magic Essence", 4 }, { 10978, "Small Glimmering Shard", 6 }, { 11084, "Large Glimmering Shard", 2 } } },
  { 248702, "Waylaid Crate: Apprentice Fabrics", 10, { { 4231, "Cured Light Hide", 2 }, { 2996, "Bolt of Linen Cloth", 20 } } },
  { 248703, "Waylaid Crate: Apprentice Ingots", 10, { { 2840, "Copper Bar", 20 }, { 3576, "Tin Bar", 20 },
    { 2841, "Bronze Bar", 10 } } },
  { 248704, "Waylaid Crate: Apprentice Parts", 10, { { 4359, "Handful of Copper Bolts", 16 }, { 4361, "Copper Tube", 16 },
    { 4363, "Copper Modulator", 4 } } },
  { 248688, "Waylaid Crate: Journeyman Textiles", 10, { { 2592, "Wool Cloth", 40 }, { 4306, "Silk Cloth", 40 },
    { 2319, "Medium Leather", 20 } } },
  { 248687, "Waylaid Crate: Journeyman Ore", 10, { { 2775, "Silver Ore", 10 }, { 2772, "Iron Ore", 20 } } },
  { 248686, "Waylaid Crate: Journeyman Herbs", 10, { { 3820, "Stranglekelp", 10 }, { 2453, "Bruiseweed", 10 },
    { 3355, "Wild Steelbloom", 10 }, { 3369, "Grave Moss", 10 }, { 3356, "Kingsblood", 10 } } },
  { 248689, "Waylaid Crate: Journeyman Curiosities", 10, { { 11083, "Soul Dust", 20 },
    { 11082, "Greater Astral Essence", 4 }, { 11138, "Small Glowing Shard", 6 }, { 11139, "Large Glowing Shard", 2 } } },
  { 248705, "Waylaid Crate: Journeyman Fabrics", 10, { { 2997, "Bolt of Woolen Cloth", 6 },
    { 4305, "Bolt of Silk Cloth", 10 }, { 4233, "Cured Medium Hide", 2 } } },
  { 248706, "Waylaid Crate: Journeyman Ingots", 10, { { 2842, "Silver Bar", 10 }, { 3575, "Iron Bar", 20 } } },
  { 248707, "Waylaid Crate: Journeyman Parts", 10, { { 4371, "Bronze Tube", 8 }, { 4375, "Whirring Bronze Gizmo", 7 },
    { 4382, "Bronze Framework", 4 }, { 10558, "Gold Power Core", 45 } } },
  { 248693, "Waylaid Crate: Expert Textiles", 20, { { 4338, "Mageweave Cloth", 40 }, { 4234, "Heavy Leather", 20 } } },
  { 248692, "Waylaid Crate: Expert Ore", 20, { { 2776, "Gold Ore", 10 }, { 3858, "Mithril Ore", 20 } } },
  { 248690, "Waylaid Crate: Earthly Expert Herbs", 20, { { 3357, "Liferoot", 20 }, { 3818, "Fadeleaf", 10 },
    { 3821, "Goldthorn", 10 }, { 3358, "Khadgar's Whisker", 10 } } },
  { 248691, "Waylaid Crate: Flowering Expert Herbs", 20, { { 3819, "Wintersbite", 10 }, { 4625, "Firebloom", 10 },
    { 8831, "Purple Lotus", 20 }, { 8836, "Arthas' Tears", 10 } } },
  { 248694, "Waylaid Crate: Expert Curiosities", 20, { { 11137, "Vision Dust", 20 },
    { 11135, "Greater Mystic Essence", 4 }, { 11177, "Small Radiant Shard", 6 }, { 11178, "Large Radiant Shard", 2 } } },
  { 248708, "Waylaid Crate: Expert Fabrics", 20, { { 4339, "Bolt of Mageweave", 8 }, { 4236, "Cured Heavy Hide", 2 } } },
  { 248709, "Waylaid Crate: Expert Ingots", 20, { { 3860, "Mithril Bar", 20 }, { 3859, "Steel Bar", 15 },
    { 3577, "Gold Bar", 10 } } },
  { 248710, "Waylaid Crate: Expert Parts", 20, { { 4387, "Iron Strut", 8 }, { 10559, "Mithril Tube", 5 },
    { 10560, "Unstable Trigger", 12 }, { 10561, "Mithril Casing", 5 } } },
}
G.CRATES = CRATES

local FAVOR_NOTE = "What each crate takes and pays (5 Favor each, sometimes double) comes from a guide and "
  .. "players' reports, not the game's data. Check the crate's tooltip before filling it."

local CRATE_NAMES = {}
for _, crate in ipairs(CRATES) do
  CRATE_NAMES[crate[1]] = crate[2]
  for _, fill in ipairs(crate[4]) do CRATE_NAMES[fill[1]] = fill[2] end
end

local function nameOf(item)
  return P.Item(item).name or CRATE_NAMES[item] or P.LiveName(item) or ("item " .. tostring(item))
end

-- A buying-and-making simulation for this character: the given materials, the market, and the
-- recipes it knows in every profession (for making fills from sub-materials).
local function favorSimulation(key, inventory, market, cache)
  local recipes = cache and cache.favorRecipes
  if not recipes then
    recipes = {}
    local c = P.Char(key)
    local profs = {}
    for prof in pairs(list(c and c.professions and c.professions.list)) do profs[#profs + 1] = prof end
    table.sort(profs)
    for _, prof in ipairs(profs) do
      for _, r in ipairs(P.BuildRecipes(key, prof, false, market) or {}) do
        if r.known then recipes[#recipes + 1] = r end
      end
    end
    if cache then cache.favorRecipes = recipes end
  end
  local sim = P.NewRun(recipes, market, inventory, 0)
  sim.whole = true
  return sim
end

-- What a run of buying and making comes to, from the simulation's operations: what to buy
-- (with where), what's used of what you own, what to make, and the gold.
local function opRows(sim, allOps, market, warnings)
  local buys, uses, makes, makeOrder = {}, {}, {}, {}
  for _, op in ipairs(allOps) do
    if op[1] == "buy" then
      local k = op[2] .. ":" .. op[4]
      buys[k] = buys[k] or { item = op[2], name = nameOf(op[2]), source = op[4], n = 0, unit = op[5] }
      buys[k].n = buys[k].n + op[3]
    elseif op[1] == "use" then
      uses[op[2]] = (uses[op[2]] or 0) + op[3]
    elseif op[1] == "make" then
      if not makes[op[2]] then makeOrder[#makeOrder + 1] = op[2] end
      makes[op[2]] = (makes[op[2]] or 0) + op[3]
    end
  end
  local bySpell = {}
  for _, r in ipairs(sim.recipes) do bySpell[r.spell] = r end
  local buyRows, gold = {}, 0
  for _, e in pairs(buys) do
    local row = copy(e)
    row.n = whole(e.n)
    row.total = row.n * e.unit
    buyRows[#buyRows + 1] = row
    gold = gold + row.total
  end
  table.sort(buyRows, function(a, b)
    if a.source ~= b.source then return a.source < b.source end
    if a.name ~= b.name then return a.name < b.name end
    return a.item < b.item
  end)
  for _, row in ipairs(buyRows) do
    if row.source == "vendor" then
      local v = market.vendors[row.item]
      local npc = v.spot or P.Npc(v.npc)
      row.who, row.map, row.x, row.y, row.zone = v.name, npc.map, npc.x, npc.y, npc.subzone or npc.zone
      row.guess = v.guess
    else
      local listed = P.Listed(row.item)
      if listed ~= nil and listed < row.n then
        warnings[#warnings + 1] = ("Only %d %s were listed when last scanned, and this needs %d.")
          :format(listed, row.name, row.n)
      end
    end
  end
  local useRows = {}
  for item, n in pairs(uses) do useRows[#useRows + 1] = { item = item, name = nameOf(item), n = whole(n) } end
  table.sort(useRows, function(a, b) return a.item < b.item end)
  local makeRows = {}
  for _, spell in ipairs(makeOrder) do
    local r = bySpell[spell]
    local from = {}
    for _, reagent in ipairs(r.reagents) do from[#from + 1] = nameOf(reagent[1]) end
    makeRows[#makeRows + 1] = { spell = spell, name = r.name, item = r.item, n = whole(makes[spell]), from = from }
  end
  return buyRows, useRows, makeRows, gold
end

-- The cheapest crates to reach `need` Merchant's Favor in total. Returns:
--   need, have, crateCount, short (Favor still missing when crates run out)
--   crates   { { item, name, n, fill = { item, name, n (per crate) } } }
--   buys     { { item, name, source, n, unit, total, who, map, x, y, zone } }
--   uses     { { item, name, n } }      owned crates and materials used
--   makes    { { spell, name, item, n, from } }
--   gold, warnings, inventory (what's left afterwards)
function G.PlanFavor(key, need, inventory, market, cache)
  local level = P.Info(key).level or 0
  local have = P.Currency(key, FAVOR)
  local sim = favorSimulation(key, inventory, market, cache)
  local left = max(0, need - have)
  local wanted = math.ceil(left / PER_CRATE)
  local inv = copy(sim.inv)
  local boughtCrates, picked, allOps, warnings = {}, {}, {}, {}
  for _ = 1, wanted do
    local best
    for _, crate in ipairs(CRATES) do
      local item, name, minLevel, fills = crate[1], crate[2], crate[3], crate[4]
      -- A crate bought at the auction house can't be bought more often than it's listed.
      local listed = P.Listed(item)
      local skip = minLevel > level
        or ((inv[item] or 0) < 1 and listed ~= nil and (boughtCrates[item] or 0) >= listed)
      if not skip then
        local trial, ops = copy(inv), {}
        local g = sim:acquire(item, 1, trial, ops)
        if g then
          for _, fill in ipairs(fills) do
            local t2, o2 = copy(trial), {}
            local g2 = sim:acquire(fill[1], fill[3], t2, o2)
            if g2 then
              local total = g + g2
              if not best or total < best.total - 1e-9 then
                local all = {}
                for _, op in ipairs(ops) do all[#all + 1] = op end
                for _, op in ipairs(o2) do all[#all + 1] = op end
                best = { total = total, inv = t2, ops = all, item = item, name = name, fill = fill }
              end
            end
          end
        end
      end
      P.Yield()
    end
    if not best then break end
    inv = best.inv
    for _, op in ipairs(best.ops) do
      if op[1] == "buy" and op[2] == best.item then boughtCrates[best.item] = (boughtCrates[best.item] or 0) + 1 end
      allOps[#allOps + 1] = op
    end
    picked[#picked + 1] = best
  end
  sim.inv = inv

  local crates, crateBy = {}, {}
  for _, pick in ipairs(picked) do
    local k = pick.item .. ":" .. pick.fill[1]
    local e = crateBy[k]
    if not e then
      e = { item = pick.item, name = pick.name, n = 0, seq = #crates,
        fill = { item = pick.fill[1], name = nameOf(pick.fill[1]), n = pick.fill[3] } }
      crateBy[k] = e
      crates[#crates + 1] = e
    end
    e.n = e.n + 1
  end
  table.sort(crates, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.seq < b.seq
  end)
  local buyRows, useRows, makeRows, gold = opRows(sim, allOps, market, warnings)
  -- Crates you own that the plan leaves alone, and what filling one would cost: so it's clear
  -- they were looked at.
  local usedItems = {}
  for _, pick in ipairs(picked) do usedItems[pick.item] = true end
  for _, crate in ipairs(CRATES) do
    local item, name, minLevel, fills = crate[1], crate[2], crate[3], crate[4]
    if (sim.inv[item] or 0) >= 1 and not usedItems[item] and wanted > 0 then
      local cheapest
      for _, fill in ipairs(fills) do
        local g = sim:acquire(fill[1], fill[3], copy(sim.inv), {})
        if g and (not cheapest or g < cheapest[1]) then cheapest = { g, fill[2], fill[3] } end
      end
      if minLevel > level then
        warnings[#warnings + 1] = ("Your %s isn't used: it needs level %d."):format(name, minLevel)
      elseif cheapest then
        warnings[#warnings + 1] = ("Your %s isn't used: filling it (%d %s, about %s) costs more than a whole "
          .. "cheaper crate."):format(name, cheapest[3], cheapest[2], Money(cheapest[1]))
      else
        warnings[#warnings + 1] = ("Your %s isn't used: nothing that fills it has a price."):format(name)
      end
    end
  end
  return { need = need, have = have, crateCount = #picked, short = max(0, left - #picked * PER_CRATE),
    crates = crates, buys = buyRows, uses = useRows, makes = makeRows, gold = gold, warnings = warnings,
    inventory = inv, note = FAVOR_NOTE }
end

-- The vendor trips and the crafts of a Favor or reputation plan, as steps. (Auction house buys
-- aren't steps: they're in the materials list.)
local function tripSteps(plan, key, first)
  local owned = P.Owned(key)
  local steps = {}
  for _, row in ipairs(plan.buys) do
    if row.source ~= "ah" then
      local step = { k = "buy", item = row.item, icon = row.item, n = row.n,
        title = ("Buy %d %s"):format(row.n, row.name),
        sub = (row.who or "a vendor") .. inZone(row.zone) .. ", " .. (row.guess and "about " or "") .. Money(row.total)
          .. (row.guess and " (estimate)" or "") }
      if first then step.target = ((owned[row.item] or {}).total or 0) + row.n end
      steps[#steps + 1] = put(step, place(row))
    end
  end
  for _, m in ipairs(plan.makes) do
    steps[#steps + 1] = { k = "make", spell = m.spell, n = m.n, icon = m.item,
      title = ("Make %d %s"):format(m.n, m.name), sub = "From " .. table.concat(m.from, ", ") }
  end
  return steps
end

local function favorSteps(plan, key, first)
  local steps = tripSteps(plan, key, first)
  -- One step for each kind of crate and what it's filled with, then the trip to hand them in
  -- (where you last earned Favor from an NPC, recorded when it happens).
  for _, e in ipairs(plan.crates) do
    local short = (e.name:gsub("Waylaid Crate: ", ""))
    steps[#steps + 1] = { k = "fill", item = e.fill.item, icon = e.item, n = e.n * e.fill.n, cur = FAVOR, favor = plan.need,
      title = ("Fill %d %s crate%s"):format(e.n, short, plural(e.n)),
      sub = ("With %d %s each%s"):format(e.fill.n, e.fill.name, e.n > 1 and (" (%d in all)"):format(e.n * e.fill.n) or "") }
  end
  if #plan.crates > 0 then
    steps[#steps + 1] = { k = "currency", cur = FAVOR, n = plan.need, icon = plan.crates[1].item, near = "crates",
      title = ("Hand in %d crate%s"):format(plan.crateCount, plural(plan.crateCount)),
      sub = ("Until you have %d Merchant's Favor (5 a crate, sometimes double)"):format(plan.need) }
  end
  return steps
end

----------------------------------------------------------------------
-- Reputation a pattern's vendor asks for: the cheapest Craftsman's Writs to earn it
----------------------------------------------------------------------

-- Reputation, in all, where each standing starts.
local STANDING_START = { Friendly = 3000, Honored = 9000, Revered = 21000, Exalted = 42000 }
-- The faction that Merchant's Favor vendors belong to, by side.
local COMMERCE = { Horde = "Durotar Supply and Logistics", Alliance = "Azeroth Commerce Authority" }
local REP_NOTE = "Craftsman's Writs: each order is said to count once a day (players' reports, not the game's "
  .. "data), and a writ may ask for more than one of its item. Read the writ before buying for it."

-- The faction and standing a pattern's vendor asks for, or nil. ("Requires Honored with this
-- faction." on a Merchant's Favor vendor means the side's commerce faction.)
local function repNeeded(key, src)
  local favor = false
  for _, o in ipairs(list(src.others)) do
    if o.currency == FAVOR then favor = true end
  end
  for _, line in ipairs(list(src.reqs)) do
    local faction
    local standing = line:match("^Requires (%a+) with this faction")
    if standing then
      faction = favor and COMMERCE[P.Info(key).faction or ""] or nil
    else
      faction, standing = line:match("^Requires (.+) %- (%a+)$")
    end
    if faction and STANDING_START[standing] then return faction, standing end
  end
end

-- The higher of two standings (either may be nil).
local function higher(a, b)
  if not a or not b then return a or b end
  return STANDING_START[a] >= STANDING_START[b] and a or b
end

-- The cheapest Craftsman's Writs to reach a standing with a faction: for each, the writ (owned,
-- or bought) and the item it asks for (owned, bought or made), least gold per reputation first,
-- each order once. Returns:
--   faction, standing, need (reputation where the standing starts), have (nil when it isn't
--   recorded), left, short (still missing after these writs)
--   writs    { { quest, writ, title, items, rep, npc, upTo (reputation after it), map, x, y, who } }
--   buys, uses, makes, gold, warnings, inventory   as G.PlanFavor
function G.PlanRep(key, faction, standing, inventory, market, cache)
  local need = STANDING_START[standing]
  local have = P.Reputation(key, faction)
  local out = { faction = faction, standing = standing, need = need, have = have, left = 0, short = 0, writs = {},
    buys = {}, uses = {}, makes = {}, gold = 0, warnings = {}, inventory = inventory, note = REP_NOTE }
  if have == nil then return out end
  local left = max(0, need - have)
  out.left, out.short = left, left
  local all = left > 0 and P.Writs(key) or nil
  if not all then return out end
  local sim = favorSimulation(key, inventory, market, cache)
  local inv = copy(sim.inv)
  -- Only writs you hold or that have a price can be delivered.
  local writs = {}
  for _, w in ipairs(all) do
    if (w.rep or 0) > 0 and ((inv[w.writ] or 0) >= 1 or market.buy(w.writ)) then writs[#writs + 1] = w end
  end
  local picked, allOps, used, gained = {}, {}, {}, 0
  while gained < left do
    local best
    for _, w in ipairs(writs) do
      if not used[w.quest] then
        local trial, ops = copy(inv), {}
        local g = sim:acquire(w.writ, 1, trial, ops)
        for _, it in ipairs(w.items) do
          local more = g and sim:acquire(it[1], it[2], trial, ops)
          g = more and (g + more) or nil
        end
        if g and (not best or g / w.rep < best.per - 1e-9) then
          best = { per = g / w.rep, inv = trial, ops = ops, writ = w }
        end
      end
      P.Yield()
    end
    if not best then break end
    inv = best.inv
    used[best.writ.quest] = true
    for _, op in ipairs(best.ops) do allOps[#allOps + 1] = op end
    gained = gained + best.writ.rep
    local w = copy(best.writ)
    w.upTo = min(need, have + gained)
    -- Where it's handed in: the nearest place the other addon has for who takes it.
    local here, spot = P.Here(), nil
    for _, place in ipairs(w.npc and P.NpcPlaces(w.npc) or {}) do
      if not spot or P.Better(place, 0, spot, 0, here) then spot = place end
    end
    if spot then w.map, w.x, w.y, w.who = spot.map, spot.x, spot.y, spot.name end
    picked[#picked + 1] = w
  end
  sim.inv = inv
  out.writs, out.short, out.inventory = picked, max(0, left - gained), inv
  out.buys, out.uses, out.makes, out.gold = opRows(sim, allOps, market, out.warnings)
  return out
end

-- The reputation plan as steps: the trips and crafts, one delivery for each writ, and when the
-- writs don't get all the way, a step for the rest.
local function repSteps(rep, key, first)
  local steps = tripSteps(rep, key, first)
  for _, w in ipairs(rep.writs) do
    local wants = {}
    for _, it in ipairs(w.items) do wants[#wants + 1] = it[2] .. " " .. nameOf(it[1]) end
    steps[#steps + 1] = put({ k = "writ", quest = w.quest, icon = w.writ, faction = rep.faction, n = w.upTo,
      title = "Deliver " .. table.concat(wants, ", "),
      sub = ("%s, +%d reputation"):format(w.title, w.rep) }, place(w))
  end
  if rep.have == nil then
    steps[#steps + 1] = { k = "rep", faction = rep.faction, n = rep.need,
      title = ("Reach %s with %s"):format(rep.standing, rep.faction),
      sub = "Your standing with them isn't recorded yet" }
  elseif rep.short > 0 then
    steps[#steps + 1] = { k = "rep", faction = rep.faction, n = rep.need,
      title = ("Reach %s with %s"):format(rep.standing, rep.faction),
      sub = (#rep.writs > 0 and "%d more reputation after these writs. More orders count tomorrow"
        or "%d more reputation, from Craftsman's Writs. None you hold or with an auction price was found")
        :format(rep.short) }
  end
  return steps
end

-- What a reputation plan adds to a goal's summary line and its notes.
local function repWords(rep)
  local words
  if rep.have == nil then
    words = (" Also needs %s with %s."):format(rep.standing, rep.faction)
  elseif #rep.writs > 0 then
    words = (" That includes about %s for %d writ%s toward %s with %s (%d reputation to go)."):format(
      Money(rep.gold), #rep.writs, plural(#rep.writs), rep.standing, rep.faction, rep.left)
  else
    words = (" Also needs %s with %s (%d reputation to go)."):format(rep.standing, rep.faction, rep.left)
  end
  local notes = {}
  if rep.have ~= nil and rep.short > 0 then
    notes[#notes + 1] = ("%d reputation with %s is still missing after the writs found."):format(rep.short, rep.faction)
  end
  for _, w in ipairs(rep.warnings) do notes[#notes + 1] = w end
  notes[#notes + 1] = rep.note
  return words, notes
end

----------------------------------------------------------------------
-- Gear upgrades: which crafted items beat what a character wears
--
-- Each piece is scored with rough per-class stat weights and compared with what's in that slot
-- now. The weights are a starting point, not a simulation: they sort obvious upgrades from
-- obvious sidegrades, and every result shows the stat changes so you can judge.
-- Weapons, shields, rings, trinkets and necks are left out.
----------------------------------------------------------------------

-- On Forever an item's "+1% crit" (or hit, dodge, parry) is recorded as 14 points of rating. The
-- weights below for those are per 1%, and are divided by this when scoring.
local RATING_PER_PERCENT = 14
local PERCENT = { CRIT_RATING = true, HIT_RATING = true, DODGE_RATING = true, PARRY_RATING = true }

-- Points per point of each stat, by class (per 1% for the ratings above). Armor is per point.
local WEIGHTS = {
  HUNTER = { AGILITY = 1.0, STAMINA = 0.4, INTELLECT = 0.35, SPIRIT = 0.05, STRENGTH = 0.05,
    ATTACK_POWER = 0.3, RANGED_ATTACK_POWER = 0.45, CRIT_RATING = 10, HIT_RATING = 10, ARMOR = 0.02 },
  ROGUE = { AGILITY = 1.0, STRENGTH = 0.5, STAMINA = 0.4, ATTACK_POWER = 0.45, CRIT_RATING = 10,
    HIT_RATING = 10, ARMOR = 0.02 },
  WARRIOR = { STRENGTH = 1.0, STAMINA = 0.8, AGILITY = 0.6, ATTACK_POWER = 0.45, DEFENSE_SKILL_RATING = 0.8,
    DODGE_RATING = 8, PARRY_RATING = 8, CRIT_RATING = 8, HIT_RATING = 8, ARMOR = 0.05 },
  PALADIN = { STRENGTH = 1.0, STAMINA = 0.6, INTELLECT = 0.5, AGILITY = 0.4, SPIRIT = 0.2,
    SPELL_POWER = 0.5, SPELL_HEALING_DONE = 0.3, ATTACK_POWER = 0.45, CRIT_RATING = 8, ARMOR = 0.03 },
  SHAMAN = { INTELLECT = 0.8, STRENGTH = 0.6, AGILITY = 0.5, STAMINA = 0.5, SPIRIT = 0.4,
    SPELL_POWER = 0.7, SPELL_DAMAGE_DONE = 0.6, SPELL_HEALING_DONE = 0.4, ATTACK_POWER = 0.3, ARMOR = 0.02 },
  DRUID = { AGILITY = 0.7, STRENGTH = 0.6, INTELLECT = 0.6, STAMINA = 0.5, SPIRIT = 0.3,
    SPELL_POWER = 0.5, SPELL_HEALING_DONE = 0.3, ATTACK_POWER = 0.3, ARMOR = 0.02 },
  MAGE = { INTELLECT = 1.0, SPIRIT = 0.5, STAMINA = 0.5, SPELL_POWER = 0.9, SPELL_DAMAGE_DONE = 0.9,
    CRIT_RATING = 8, HIT_RATING = 8, ARMOR = 0.005 },
  PRIEST = { INTELLECT = 1.0, SPIRIT = 0.8, STAMINA = 0.5, SPELL_POWER = 0.8, SPELL_HEALING_DONE = 0.6,
    SPELL_DAMAGE_DONE = 0.5, ARMOR = 0.005 },
  WARLOCK = { INTELLECT = 0.9, STAMINA = 0.8, SPIRIT = 0.4, SPELL_POWER = 0.9, SPELL_DAMAGE_DONE = 0.9,
    ARMOR = 0.005 },
}

-- Armor kinds (item subclass of armor): 1 cloth, 2 leather, 3 mail, 4 plate, and the level
-- from which the class can wear each.
local WEARS = {
  HUNTER = { [1] = 1, [2] = 1, [3] = 40 }, SHAMAN = { [1] = 1, [2] = 1, [3] = 40 },
  WARRIOR = { [1] = 1, [2] = 1, [3] = 1, [4] = 40 }, PALADIN = { [1] = 1, [2] = 1, [3] = 1, [4] = 40 },
  ROGUE = { [1] = 1, [2] = 1 }, DRUID = { [1] = 1, [2] = 1 },
  MAGE = { [1] = 1 }, PRIEST = { [1] = 1 }, WARLOCK = { [1] = 1 },
}

-- Item slot -> the character's equipment slot number.
local GEAR_SLOT = { INVTYPE_HEAD = 1, INVTYPE_SHOULDER = 3, INVTYPE_CHEST = 5, INVTYPE_ROBE = 5,
  INVTYPE_WAIST = 6, INVTYPE_LEGS = 7, INVTYPE_FEET = 8, INVTYPE_WRIST = 9, INVTYPE_HAND = 10, INVTYPE_CLOAK = 15 }

local NICE = { AGILITY = "Agi", STRENGTH = "Str", STAMINA = "Sta", INTELLECT = "Int", SPIRIT = "Spi",
  ARMOR = "armor", ATTACK_POWER = "AP", RANGED_ATTACK_POWER = "RAP", SPELL_POWER = "spell power",
  SPELL_DAMAGE_DONE = "spell damage", SPELL_HEALING_DONE = "healing", CRIT_RATING = "crit",
  HIT_RATING = "hit", DODGE_RATING = "dodge", PARRY_RATING = "parry", DEFENSE_SKILL_RATING = "defense" }

local LEVEL_AHEAD = 5 -- items this many levels above the character still count, as "soon"
local UPGRADE_NOTE = "Scored with rough stat weights for the class, counting the enchant on what's worn (a new "
  .. "piece starts without one). Weapons, rings, trinkets and necks aren't compared."

-- Stat names as enchant lines spell them ("Enchanted: Stamina +2 and Armor +16").
local ENCHANT_STATS = { agility = "AGILITY", strength = "STRENGTH", stamina = "STAMINA", intellect = "INTELLECT",
  spirit = "SPIRIT", armor = "ARMOR", ["attack power"] = "ATTACK_POWER",
  ["ranged attack power"] = "RANGED_ATTACK_POWER", ["spell power"] = "SPELL_POWER",
  healing = "SPELL_HEALING_DONE", ["all stats"] = "ALL" }

-- The stats an enchant adds, from the worn item's "Enchanted: ..." line. Unknown wording adds
-- nothing.
local function enchantStats(line)
  local out = {}
  if type(line) ~= "string" or not line:find("^Enchanted:") then return out end
  local text = line:sub(#"Enchanted:" + 1):gsub(" and ", ",")
  for piece in text:gmatch("[^,]+") do
    local part = piece:lower():match("^%s*(.-)%s*$")
    local n, name = part:match("^%+?(%d+) (.+)$")
    if not n then name, n = part:match("^(.-) %+(%d+)$") end
    local stat = name and ENCHANT_STATS[name:match("^%s*(.-)%s*$")]
    n = tonumber(n)
    if stat == "ALL" then
      for _, k in ipairs({ "AGILITY", "STRENGTH", "STAMINA", "INTELLECT", "SPIRIT" }) do out[k] = (out[k] or 0) + n end
    elseif stat then
      out[stat] = (out[stat] or 0) + n
    end
  end
  return out
end
G.EnchantStats = enchantStats

-- { AGILITY = 4, ARMOR = 45, ... } from an item cache entry.
local function statsOf(item)
  local out = {}
  for k, v in pairs(list(item.stats)) do
    if type(v) == "number" then
      if k == "RESISTANCE0_NAME" then
        out.ARMOR = (out.ARMOR or 0) + v
      else
        local name = type(k) == "string" and k:match("^ITEM_MOD_(.+)_SHORT$")
        if name then out[name] = (out[name] or 0) + v end
      end
    end
  end
  return out
end

local function score(stats, class)
  local w, total = WEIGHTS[class] or {}, 0
  for k, v in pairs(stats) do
    total = total + (w[k] or 0) * (PERCENT[k] and v / RATING_PER_PERCENT or v)
  end
  return total
end

local function diffText(new, old)
  local keys, seen = {}, {}
  for _, t in ipairs({ new, old }) do
    for k in pairs(t) do
      if not seen[k] then
        seen[k] = true
        keys[#keys + 1] = k
      end
    end
  end
  table.sort(keys, function(a, b)
    if (a == "ARMOR") ~= (b == "ARMOR") then return b == "ARMOR" end
    return (NICE[a] or a) < (NICE[b] or b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    local d = (new[k] or 0) - (old[k] or 0)
    if d ~= 0 and PERCENT[k] then
      parts[#parts + 1] = ("%+g%% %s"):format(floor(d / RATING_PER_PERCENT * 10 + 0.5) / 10, NICE[k])
    elseif d ~= 0 and NICE[k] then
      parts[#parts + 1] = ("%+d %s"):format(floor(d + 0.5), NICE[k])
    end
  end
  return table.concat(parts, ", ")
end

-- For each character the crafter can make gear for (itself, and your others on the same ruleset
-- and faction): { { who, items = { { id, gain, diff, soon } } } }, the crafter first.
-- entries are the recipe goals: { id, item }.
local function findUpgrades(crafter, entries)
  local wearers = {}
  for key, c in pairs(ns.db.chars) do
    local who = type(c) == "table" and type(c.info) == "table" and c.info or {}
    if c.own and who.classFile and c.gear and type(c.gear.slots) == "table" and next(c.gear.slots)
      and (key == crafter or P.CanShare(crafter, key)) then
      wearers[#wearers + 1] = key
    end
  end
  table.sort(wearers, function(a, b)
    if (a == crafter) ~= (b == crafter) then return a == crafter end
    return a < b
  end)
  local result = {}
  for _, who in ipairs(wearers) do
    local c = ns.db.chars[who]
    local class, level = c.info.classFile, c.info.level or 0
    local wears, worn = WEARS[class] or {}, c.gear.slots
    local found = {}
    for _, e in ipairs(entries) do
      local item = e.item and P.Item(e.item) or {}
      local slot = GEAR_SLOT[item.loc]
      local ok = slot and item.stats
      if ok and item.classID == 4 and wears and item.subID and item.subID >= 1 and item.subID <= 4 then
        ok = wears[item.subID] and wears[item.subID] <= level
      end
      local req = item.req or 0
      if ok and req > level + LEVEL_AHEAD then ok = false end
      -- Binds when picked up: only the crafter can wear what it makes.
      if ok and item.bind == 1 and who ~= crafter then ok = false end
      if ok then
        local new, old = statsOf(item), {}
        local oldSlot = worn[slot] or worn[tostring(slot)]
        if type(oldSlot) == "table" and oldSlot.id then
          old = statsOf(P.Item(oldSlot.id))
          -- The enchant stays on the old piece, so it counts for what's worn and not for the new one.
          for k, v in pairs(enchantStats(oldSlot.enchant)) do old[k] = (old[k] or 0) + v end
        end
        local gain = score(new, class) - score(old, class)
        if gain > 0.5 then
          found[#found + 1] = { id = e.id, gain = floor(gain * 10 + 0.5) / 10, diff = diffText(new, old),
            soon = req > level and req or nil, loc = item.loc }
        end
      end
    end
    table.sort(found, function(a, b)
      if (a.soon ~= nil) ~= (b.soon ~= nil) then return b.soon ~= nil end
      if a.gain ~= b.gain then return a.gain > b.gain end
      return a.id < b.id
    end)
    if #found > 0 then result[#result + 1] = { who = who, items = found } end
  end
  return result
end

----------------------------------------------------------------------
-- The catalog: every goal of a profession
----------------------------------------------------------------------

-- Skill levels worth aiming for: where the next rank can be trained, and the top of each rank.
local function checkpoints(skill, profession)
  local out = {}
  for i, rank in ipairs(RANKS) do
    local top, name = rank[1], rank[2]
    local nextRank = RANKS[i + 1] and RANKS[i + 1][2]
    if nextRank and top - BAND > 0 then
      out[#out + 1] = { skill = top - BAND, name = ("%s %d: %s can be trained"):format(profession, top - BAND, nextRank),
        lines = { ("From here a trainer can teach %s, which raises the cap past %d."):format(nextRank, top),
          "This is Classic's rule; Forever hasn't confirmed it." } }
    end
    local lines = { ("The top of %s."):format(name) }
    if top == 150 then lines[#lines + 1] = "Reaching 150 earns a Legacy point." end
    out[#out + 1] = { skill = top, name = ("%s %d: top of %s%s"):format(profession, top, name,
      top == 150 and " (Legacy point)" or ""), lines = lines }
  end
  local ahead = {}
  for _, m in ipairs(out) do
    if m.skill > skill then ahead[#ahead + 1] = m end
  end
  return ahead
end

-- Item IDs that any of your characters wears or carries (bags, bank, mail). Used to tell which
-- recipes have already been crafted: the result is on someone.
local function heldItems()
  local out = {}
  for _, c in pairs(ns.db.chars) do
    if type(c) == "table" then
      for _, slot in pairs(list(c.gear and c.gear.slots)) do
        if type(slot) == "table" and slot.id then out[slot.id] = true end
      end
      for _, where in ipairs({ "bags", "bank", "accountBank" }) do
        for _, it in ipairs(list(c[where] and c[where].items)) do
          if it.id then out[it.id] = true end
        end
      end
      for _, msg in ipairs(list(c.mail and c.mail.messages)) do
        for _, it in ipairs(list(msg.items)) do
          if it.id then out[it.id] = true end
        end
      end
    end
  end
  return out
end

-- Which dropdown group a recipe belongs in: sort order, who, label, kind.
local function sourceGroup(known, src)
  if known then return 0, "", "Recipes you know", "known" end
  local how, sure, who = src.how, src.confirmed, src.who or "?"
  if how == "trainer" and sure then return 1, who, "Trainer: " .. who, "trainer" end
  if how == "vendor" and sure then
    local others = src.others or {}
    if #others > 0 then return 3, who, tostring(others[1].name) .. ": " .. who, "currency" end
    return 2, who, "Vendor: " .. who, "vendor"
  end
  if how == "ah" then return 4, "", "Auction house", "ah" end
  if how == "trainer" then return 5, "", "Trainers you haven't opened", "trainer" end
  if how == "vendor" then return 6, "", "Vendors you haven't opened", "vendor" end
  if how == "quest" then return 7, "", "Quest rewards", "quest" end
  if how == "drop" then return 8, "", "World drops", "drop" end
  if how == "auto" then return 9, "", "Learned with the profession", "auto" end
  return 10, "", "Source not known yet", "unknown"
end

-- Splits a group into tiers: one section per slot at each level, with every stat option in it.
-- The heading says when one of them has already been made.
local function tierSections(ids, tierOf, byId)
  local tiers, order = {}, {}
  for _, id in ipairs(ids) do
    local tier = tierOf[id]
    local k = ("%05d:%05d:%s"):format(tier[1], tier[2], tier[3])
    if not tiers[k] then
      tiers[k] = { tier = tier, ids = {} }
      order[#order + 1] = k
    end
    table.insert(tiers[k].ids, id)
  end
  table.sort(order)
  local out = {}
  for _, k in ipairs(order) do
    local tier, members = tiers[k].tier, tiers[k].ids
    table.sort(members, function(a, b)
      if byId[a].name ~= byId[b].name then return byId[a].name < byId[b].name end
      return a < b
    end)
    local label = ("%s: skill %d%s"):format(tier[3], tier[2], tier[1] > 0 and (", level %d"):format(tier[1]) or "")
    for _, id in ipairs(members) do
      if byId[id].made then
        label = label .. " (made)"
        break
      end
    end
    out[#out + 1] = { label = label, ids = members }
  end
  return out
end

-- Splits a group under the profession window's own headings, in the window's order. Recipes
-- whose heading has no recorded name go under "Other".
local function categorySections(ids, categoryOf, categories, byId)
  local found, order = {}, {}
  for _, id in ipairs(ids) do
    local cat = categories[categoryOf[id]] or {}
    local name = cat.name or "Other"
    local k = (name == "Other" and "1" or "0") .. ("%06d"):format(cat.order or 9999) .. name
    if not found[k] then
      found[k] = { label = name, ids = {} }
      order[#order + 1] = k
    end
    table.insert(found[k].ids, id)
  end
  table.sort(order)
  local out = {}
  for _, k in ipairs(order) do
    local members = found[k].ids
    table.sort(members, function(a, b)
      local sa, sb = byId[a].skill or 0, byId[b].skill or 0
      if sa ~= sb then return sa < sb end
      if byId[a].name ~= byId[b].name then return byId[a].name < byId[b].name end
      return a < b
    end)
    out[#out + 1] = found[k]
  end
  return out
end

-- Builds a profession's goals for the plan window: targets (every skill checkpoint and recipe),
-- the groups the dropdown lists them in, and each material's name and price. The plan for a
-- goal is added by G.PlanGoal when it's picked. Returns nil if the character doesn't have the
-- profession.
function G.Catalog(key, profession)
  local c = P.Char(key)
  local prof = c and c.professions and c.professions.list and c.professions.list[profession]
  if not prof then return nil end
  local recorded = P.Recipes(key, profession) or {}
  local skill, cap = prof.skill or 0, prof.max or 0
  local db = P.RecipeDB(key, profession)
  local english = englishName(key, profession)
  local gathering = GATHERING[english]
  local title = profession .. " goals"
  local plan = { key = key, profession = profession, title = title, skill = skill, cap = cap,
    gathering = gathering, levels = {}, plans = {}, items = {}, targets = {}, groups = {},
    fromDatabase = recorded.fromDatabase, cache = {} }
  local marks = checkpoints(skill, profession)

  -- A crafting profession the built-in recipe data knows nothing about, whose window has never
  -- been opened: nothing can be planned yet. The checkpoints are listed, with what to do.
  if not (recorded.recipes and next(recorded.recipes)) and not gathering then
    plan.summary = "Quartermaster has no built-in recipes for " .. profession .. ". Open the " .. profession
      .. " window once and its recipes will be read from there."
    plan.unrecorded = true
    local ids = {}
    for _, m in ipairs(marks) do
      local id = "skill:" .. m.skill
      plan.targets[#plan.targets + 1] = { id = id, kind = "skill", name = m.name, skill = m.skill, tip = m.lines,
        no = "Quartermaster has no recipes for this profession yet. Open its window once." }
      ids[#ids + 1] = id
    end
    plan.groups[1] = { label = "Skill checkpoints", flat = true, ids = ids }
    return plan
  end

  local market = P.Market(key)
  plan.market = market
  local ctx = sourceContext(key, profession)

  -- ---- every recipe, with its source ---------------------------------------------------
  local held = heldItems()
  local crafted = (c.craftLog and c.craftLog[profession]) or {}
  local entries = {}
  for spell, r in pairs(list(recorded.recipes)) do
    if type(spell) == "number" then
      local ref = db[spell] or {}
      local known = r.known and true or false
      local name = r.name or ref.n or ("recipe " .. spell)
      local src = recipeSource(ctx, spell, r.name, ref)
      local reagents = {}
      for _, g in ipairs(list(r.reagents)) do
        if g.id and g.n then reagents[#reagents + 1] = { g.id, g.n } end
      end
      entries[#entries + 1] = { spell = spell, name = name, item = r.item, known = known, src = src,
        skill = src.skill or ref.s or (ref.d and ref.d[1]),
        -- Made already: you know it, and the item is on one of your characters or in the craft
        -- tally. (An item crafted and then sold or given away can't be seen.)
        made = known and ((r.item and held[r.item]) or crafted[spell] ~= nil) and true or false,
        reagents = reagents, makes = r.min or 1, category = r.category }
      P.Yield()
    end
  end
  table.sort(entries, function(a, b)
    local sa, sb = a.skill or 999, b.skill or 999
    if sa ~= sb then return sa < sb end
    if a.name ~= b.name then return a.name < b.name end
    return a.spell < b.spell
  end)

  -- ---- how far the recorded recipes can take the skill ---------------------------------
  -- As far as any goal goes: the top rank, or a recipe that needs more than that.
  local top = max(cap, RANKS[#RANKS][1])
  for _, e in ipairs(entries) do top = max(top, e.skill or 0) end
  local reach = top
  if not gathering then
    local recipes, skipped = P.BuildRecipes(key, profession, true, market)
    plan.recipes, plan.skipped = recipes, skipped
    local owned = {}
    for item, e in pairs(P.Owned(key)) do owned[item] = e.total end
    reach = P.NewRun(recipes, market, owned, 0):walk(skill, top)
  end
  plan.reach = reach

  -- ---- goals ---------------------------------------------------------------------------
  local targets, groups, byId = plan.targets, plan.groups, {}
  local function whyNot(level)
    if level > reach then return ("No recorded recipe gives skill points past %d yet."):format(reach) end
  end
  local ids = {}
  for _, m in ipairs(marks) do
    local t = { id = "skill:" .. m.skill, kind = "skill", name = m.name, skill = m.skill, tip = m.lines,
      title = ("%s %d to %d"):format(profession, skill, m.skill) }
    -- "no" says why a goal can't be planned yet; goals without it can be picked.
    t.no = whyNot(m.skill)
    if not t.no then t.level = m.skill end
    targets[#targets + 1] = t
    byId[t.id] = t
    ids[#ids + 1] = t.id
  end
  groups[#groups + 1] = { label = "Skill checkpoints", flat = true, ids = ids }

  -- Recipes you know go in one group. The rest are grouped by where they come from.
  local bySource, order, tierOf, categoryOf = {}, {}, {}, {}
  local categories = list(recorded.categories)
  plan.entries = {}
  for _, e in ipairs(entries) do
    local src = e.src
    local id = "recipe:" .. e.spell
    plan.entries[id] = e
    -- A recipe you know only needs its source said when that's something you've seen yourself.
    local tip = {}
    if e.skill then tip[#tip + 1] = ("Needs %s %d."):format(profession, e.skill) end
    if not e.known or src.confirmed then
      for _, line in ipairs(src.lines) do tip[#tip + 1] = line end
    end
    local t = { id = id, name = e.name, skill = e.skill, known = e.known or nil, icon = e.item, tip = tip,
      cost = (not e.known and src.label ~= "" and src.label) or nil,
      -- The crafted item's quality, for the color of its name.
      q = e.item and P.Item(e.item).q or nil,
      made = e.made or nil,
      -- What one craft takes: { item, count } pairs. Names and prices are in the plan's "items".
      req = #e.reagents > 0 and e.reagents or nil }
    for _, reagent in ipairs(e.reagents) do
      if not plan.items[reagent[1]] then
        local m = matEntry(key, reagent[1], 0, market)
        plan.items[reagent[1]] = { name = m.name, each = m.each, where = m.where }
      end
    end
    if e.known then
      -- The color it has in the profession window right now: 0 orange, 1 yellow, 2 green, 3 grey.
      local d = db[e.spell] and db[e.spell].d
      if d and #d == 4 then
        t.diff = ({ orange = 0, yellow = 1, green = 2, grey = 3 })[P.Color(skill, d)]
      end
    else
      -- What it costs, as numbers, so the window can show live whether you can afford it.
      if src.gold and src.gold > 0 then t.gold = floor(src.gold) end
      for _, o in ipairs(list(src.others)) do
        if o.currency then
          t.cur, t.curN = o.currency, o.n
          break
        end
      end
    end
    if e.skill == nil then
      t.no = "The skill it needs isn't known."
    else
      local level = max(skill, e.skill)
      t.no = whyNot(level)
      if not t.no then t.level = level end
    end
    targets[#targets + 1] = t
    byId[id] = t

    local homes = { { sourceGroup(e.known, src) } }
    -- A recipe you know also stays in its currency vendor's list (greyed once made), so each
    -- tier there shows every option.
    if e.known and src.how == "vendor" and src.confirmed and #list(src.others) > 0 then
      homes[#homes + 1] = { sourceGroup(false, src) }
    end
    for _, home in ipairs(homes) do
      local k = ("%02d:%s:%s"):format(home[1], home[2], home[3])
      if not bySource[k] then
        bySource[k] = { label = home[3], kind = home[4], ids = {} }
        order[#order + 1] = k
      end
      table.insert(bySource[k].ids, id)
    end
    local item = e.item and P.Item(e.item) or {}
    tierOf[id] = { item.req or 0, e.skill or 0, SLOT_NAMES[item.loc] or "Other" }
    categoryOf[id] = e.category
  end

  table.sort(order)
  for _, k in ipairs(order) do
    local g = bySource[k]
    if g.kind == "known" then
      table.sort(g.ids, function(a, b)
        if byId[a].name ~= byId[b].name then return byId[a].name < byId[b].name end
        return a < b
      end)
    end
    g.label = ("%s (%d)"):format(g.label, #g.ids)
    local sections
    if g.kind == "currency" then
      sections = tierSections(g.ids, tierOf, byId)
    elseif next(categories) and (g.kind == "known" or BY_CATEGORY[english]) then
      -- Under the profession window's own headings ("Stamina Food", "Agility Food"...).
      sections = categorySections(g.ids, categoryOf, categories, byId)
      if #sections <= 1 then sections = nil end
    end
    if sections then
      g.sections, g.ids = sections, {}
      for _, section in ipairs(sections) do
        for _, id in ipairs(section.ids) do g.ids[#g.ids + 1] = id end
      end
    end
    groups[#groups + 1] = g
  end

  -- Upgrades within reach: gear this profession can make, now or soon, that beats what one of
  -- your characters (on a ruleset and faction it can trade with) wears. Listed right after the
  -- checkpoints, one heading per character, best first.
  local reachable = {}
  for _, t in ipairs(targets) do
    if t.kind ~= "skill" and not t.no and not t.made then reachable[#reachable + 1] = { id = t.id, item = t.icon } end
  end
  local sections, listed, count = {}, {}, 0
  for _, found in ipairs(findUpgrades(key, reachable)) do
    local who = found.who
    local whoInfo = P.Info(who)
    local perSlot, upIds = {}, {}
    for _, f in ipairs(found.items) do
      local slot = f.loc or "?"
      if (perSlot[slot] or 0) < 3 then -- the best three for each slot
        perSlot[slot] = (perSlot[slot] or 0) + 1
        upIds[#upIds + 1] = f.id
        if not listed[f.id] then
          listed[f.id] = true
          count = count + 1
        end
        local t = byId[f.id]
        local line = ("Upgrade for %s: %s"):format((who:gsub("%-", " ")), f.diff)
        if f.soon then line = line .. (" (wearable at level %d)"):format(f.soon) end
        local tip = { line }
        for _, old in ipairs(t.tip) do tip[#tip + 1] = old end
        t.tip = tip
      end
    end
    sections[#sections + 1] = { label = ("%s (%s %s)"):format((who:gsub("%-", " ")),
      tostring(whoInfo.class or "?"), tostring(whoInfo.level or "?")), ids = upIds }
  end
  if count > 0 then
    local all = {}
    for _, section in ipairs(sections) do
      for _, id in ipairs(section.ids) do all[#all + 1] = id end
    end
    table.insert(groups, 2, { label = ("Upgrades within reach (%d)"):format(count), kind = "upgrade",
      sections = sections, ids = all, note = UPGRADE_NOTE })
  end

  -- The goal showing first: the cap if it can be planned, else the first that can.
  local capGoal = byId["skill:" .. cap]
  if capGoal and not capGoal.no then
    plan.selected = capGoal.id
  else
    for _, t in ipairs(targets) do
      if not t.no then
        plan.selected = t.id
        break
      end
    end
  end
  -- Shown when no goal is picked (or none can be).
  if skill >= cap and not plan.selected then
    plan.summary = ("%s is at its cap of %d. Train the next rank at a trainer to go further."):format(profession, cap)
  else
    plan.summary = "Pick a goal from the list above."
  end
  return plan
end

----------------------------------------------------------------------
-- One goal's plan
----------------------------------------------------------------------

-- A goal's cost in parts, for the window to show with the gold you have at that moment:
-- { total = copper, parts = { { label, copper } }, notes = { text }, sellBack }.
local function costsOf(level, skill, to, profession)
  local out = { total = floor((level.cost or 0) + 0.5), parts = {}, notes = {} }
  if to > skill and (level.cost or 0) > 0 then
    out.parts[1] = { ("Leveling %s %d to %d"):format(profession, skill, to), floor(level.cost + 0.5) }
  end
  local back = (to > skill and level.plan and level.plan.cost and level.plan.cost.vendorBack) or 0
  if back > 0 then
    -- Gold that comes back on the way, so the window can say whether paying as you go works.
    out.sellBack = floor(back)
    out.notes[#out.notes + 1] = ("Selling what you craft on the way to a vendor brings back about %s.")
      :format(Money(back))
  end
  for _, note in ipairs(list(level.notes)) do out.notes[#out.notes + 1] = note end
  return out
end

-- The skill plan to one level, worked out once per catalog.
local function levelPlan(plan, level)
  if plan.levels[level] then return plan.levels[level], plan.plans[level] end
  local key, profession, skill = plan.key, plan.profession, plan.skill
  local entry, skillPlan
  if plan.gathering then
    -- Skill here comes from doing it, so the "plan" to a level is one step: keep going until
    -- you're there. Recipes (bait, smelting) are still planned from what's in the bags.
    if not plan.gatherBase and plan.recipes == nil and P.Recipes(key, profession) then
      plan.gatherBase = P.PlanSkill(key, profession, skill, { market = plan.market }) or false
    end
    skillPlan = plan.gatherBase and copy(plan.gatherBase) or { learns = {} }
    skillPlan.to = level
    local verb, doing = plan.gathering[1], plan.gathering[2]
    local steps = {}
    local function upTo(to)
      if to > skill then
        steps[#steps + 1] = { k = "craft", profession = profession, skill = to,
          title = ("%s until %s %d"):format(verb, profession, to),
          sub = "This skill comes from " .. doing .. ", not from crafting" }
      end
    end
    -- Past the cap: each rank is trained when the skill gets to where it stops.
    for _, rank in ipairs(P.Ranks(key, profession, plan.cap, level)) do
      upTo(rank.cap)
      steps[#steps + 1] = rankStep(profession, rank)
    end
    upTo(level)
    entry = { steps = steps, mats = {}, cost = 0, to = level,
      summary = "Nothing to buy: this skill comes from " .. doing .. "." }
  else
    skillPlan = P.PlanSkill(key, profession, level,
      { market = plan.market, recipes = plan.recipes, skipped = plan.skipped })
    local steps, mats, summary, notes = delivery(skillPlan, key, plan.market)
    entry = { steps = steps, mats = mats, summary = summary, to = skillPlan.to, cost = skillPlan.cost.total,
      plan = skillPlan, notes = notes }
  end
  plan.levels[level], plan.plans[level] = entry, skillPlan
  return entry, skillPlan
end

-- The steps after the skill is reached: earn any Merchant's Favor the pattern costs, learn the
-- recipe, get materials for one, craft it.
-- Returns the steps, the materials, the gold it adds, the costs that aren't gold, and the Favor
-- plan (or nil).
-- With `carry` (several goals planned together), materials come out of carry.inv, what's left
-- goes back into it for the next goal, and any Merchant's Favor is earned once for all of them
-- beforehand (so not here).
local function tail(plan, skillPlan, e, first, carry)
  local key, market, src = plan.key, plan.market, e.src
  local run = skillPlan.final
  local ahPlace = P.AuctionHouse(key)
  local steps, gold, others, earn, rep = {}, 0, {}, nil, nil
  local inventory = (carry and carry.inv) or (run and run.inv) or {}
  local already = {}
  for _, l in ipairs(skillPlan.learns) do already[l.spell] = true end
  local learning = not e.known and not already[e.spell] and not (carry and carry.learned[e.spell])
  if learning then
    local how = src.how
    local step = { k = "learn", spell = e.spell, icon = e.item, title = "Learn " .. e.name }
    if how == "trainer" and src.confirmed then
      step.sub = tostring(src.who) .. inZone(src.zone) .. ", " .. Money(src.gold)
      gold = gold + src.gold
      put(step, place(src))
    elseif how == "vendor" and src.confirmed then
      step.sub = ("Buy the pattern from %s%s, %s"):format(tostring(src.who), inZone(src.zone), src.label)
      gold = gold + (src.gold or 0)
      others = list(src.others)
      put(step, place(src))
      -- A vendor that asks for a standing: the cheapest writs to earn the reputation come first.
      local faction, standing = repNeeded(key, src)
      if faction and not carry then
        rep = G.PlanRep(key, faction, standing, copy(inventory), market, plan.cache)
        if rep.have ~= nil and rep.left <= 0 then
          rep = nil
        else
          for _, s in ipairs(repSteps(rep, key, first)) do steps[#steps + 1] = s end
          gold = gold + rep.gold
          inventory = rep.inventory
        end
      end
      -- A pattern paid for in Merchant's Favor: the cheapest crates to earn what's missing come
      -- next, from what's left after the skill plan.
      local wanted = 0
      for _, o in ipairs(others) do
        if o.currency == FAVOR then wanted = wanted + (o.n or 0) end
      end
      if not carry and wanted > P.Currency(key, FAVOR) then
        earn = G.PlanFavor(key, wanted, copy(inventory), market, plan.cache)
        for _, s in ipairs(favorSteps(earn, key, first and not rep)) do steps[#steps + 1] = s end
        gold = gold + earn.gold
        inventory = earn.inventory
      end
    elseif how == "ah" then
      step.sub = "Buy the pattern at the auction house (it's on your shopping list), about " .. Money(src.gold)
      gold = gold + src.gold
      put(step, place(withWho(ahPlace, "Auction house")))
      step.near = "auctioneer"
    elseif how == "auto" then
      step = nil
    else
      step.sub = src.lines[1] or "Where to learn it isn't known"
      -- A trainer or vendor you haven't opened, when another addon knows where it stands.
      put(step, place(src))
    end
    if step then steps[#steps + 1] = step end
  end

  -- Materials for one craft, from what's left after the skill plan.
  local sim = P.NewRun(run and run.recipes or {}, market, inventory, 0, run and run.noMake)
  sim.whole = true
  sim.learned = copy((carry and carry.learned) or (run and run.learned) or {})
  local ops, short = {}, {}
  for _, reagent in ipairs(e.reagents) do
    if not sim:acquire(reagent[1], reagent[2], sim.inv, ops) then short[#short + 1] = reagent end
  end
  local need, made, madeOrder = {}, {}, {}
  local owned = P.Owned(key)
  local function up(n) return floor(n + 0.4999 + 0.5) end
  for _, op in ipairs(ops) do
    if op[1] == "buy" then
      local item, n, source, unit = op[2], up(op[3]), op[4], op[5]
      need[item] = (need[item] or 0) + n
      gold = gold + n * unit
      -- Auction house buys are in the materials list, bought with everything else at the start.
      if source == "vendor" then
        local v = market.vendors[item]
        local npc = v.spot or P.Npc(v.npc)
        local step = { k = "buy", item = item, icon = item, n = n, title = ("Buy %d %s"):format(n, P.ItemName(item)),
          sub = tostring(v.name) .. inZone(npc.zone and (npc.subzone or npc.zone)) .. ", "
            .. (v.guess and "about " or "") .. Money(n * unit) .. (v.guess and " (estimate)" or "") }
        if first and not earn and not rep and not carry then step.target = ((owned[item] or {}).total or 0) + n end
        if carry then
          -- So the same purchase for several goals can be folded into one step.
          step.unit, step.guess = unit, v.guess
          step.at = tostring(v.name) .. inZone(npc.zone and (npc.subzone or npc.zone))
        end
        steps[#steps + 1] = put(step, place({ map = npc.map, x = npc.x, y = npc.y, who = v.name }))
      end
    elseif op[1] == "use" then
      need[op[2]] = (need[op[2]] or 0) + up(op[3])
    elseif op[1] == "make" then
      if not made[op[2]] then madeOrder[#madeOrder + 1] = op[2] end
      made[op[2]] = (made[op[2]] or 0) + up(op[3])
    end
  end
  local bySpell = {}
  for _, r in ipairs(sim.recipes) do bySpell[r.spell] = r end
  for _, spell in ipairs(madeOrder) do
    local r = bySpell[spell]
    local from = {}
    for _, reagent in ipairs(r.reagents) do from[#from + 1] = P.ItemName(reagent[1]) end
    steps[#steps + 1] = { k = "make", spell = spell, n = made[spell], icon = r.item,
      title = ("Make %d %s"):format(made[spell], r.name), sub = "From " .. table.concat(from, ", ") }
  end
  for _, reagent in ipairs(short) do
    local item, n = reagent[1], reagent[2]
    need[item] = (need[item] or 0) + n
    steps[#steps + 1] = { k = "buy", item = item, icon = item, n = n,
      title = ("Get %d %s"):format(n, P.ItemName(item)),
      sub = P.HasAuctions() and "No price is known: not at a recorded vendor or in your auction scans"
        or "Not sold by any vendor you've visited" }
  end
  steps[#steps + 1] = { k = "make", spell = e.spell, n = 1, icon = e.item, title = "Craft " .. e.name,
    sub = carry and "One of your goals" or "The goal of this plan" }
  if carry then
    -- What's left, and what's now been learned and made, for the next goal.
    if e.item then sim.inv[e.item] = (sim.inv[e.item] or 0) + (e.makes or 1) end
    sim.learned[e.spell] = true
    carry.inv, carry.learned = sim.inv, sim.learned
  end
  -- The crates and what goes in them count as materials too, and so do writs and their items.
  for _, part in ipairs({ earn or false, rep or false }) do
    if part then
      for _, rows in ipairs({ part.buys, part.uses }) do
        for _, row in ipairs(rows) do need[row.item] = (need[row.item] or 0) + row.n end
      end
    end
  end
  -- A pattern bought at the auction house goes on the shopping list too.
  local pattern = learning and src.how == "ah" and src.item or nil
  if pattern then need[pattern] = (need[pattern] or 0) + 1 end
  local mats = {}
  for item, n in pairs(need) do
    local m = matEntry(key, item, n, market, true)
    m.name = nameOf(item)
    mats[#mats + 1] = m
  end
  table.sort(mats, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.item < b.item
  end)
  for _, m in ipairs(mats) do
    if m.item == pattern then m.name = P.Item(m.item).name or ("Pattern: " .. e.name) end
  end
  return steps, mats, gold, others, earn, rep
end

-- Works out the plan for one goal and puts it on the goal: its level (the skill to reach first,
-- whose steps are in plan.levels), tail (its own steps), mats, summary and costs.
-- Returns the goal, or nil if there's no such goal.
-- Several goals picked together, as one goal of its own ("3 goals: A, B, C"). Its plan is
-- worked out by G.PlanMulti.
function G.NewMulti(plan, ids)
  local names, level, kept = {}, plan.skill or 0, {}
  for _, id in ipairs(ids) do
    for _, t in ipairs(plan.targets) do
      if t.id == id and not t.no and t.level then
        kept[#kept + 1] = id
        names[#names + 1] = t.kind == "skill" and (plan.profession .. " " .. t.skill) or t.name
        level = max(level, t.level)
      end
    end
  end
  local name = ("%d goals: %s"):format(#kept, table.concat(names, ", "))
  return { id = "multi", kind = "multi", ids = kept, name = name, title = name, level = level }
end

-- Works out one plan for several goals: the skill plan to the highest skill any of them needs,
-- then each recipe in turn, each using what's left after the one before, so nothing is bought
-- twice. Merchant's Favor for all of them is earned in one go, and purchases at the same
-- vendor are folded into one step.
function G.PlanMulti(plan)
  local m = plan.multi
  if not m or m.planned or m.no then return m end
  local key, profession, skill, market = plan.key, plan.profession, plan.skill, plan.market
  local goals, byId = {}, {}
  for _, t in ipairs(plan.targets) do byId[t.id] = t end
  local top = skill
  for _, id in ipairs(m.ids) do
    local t = byId[id]
    if t and not t.no and t.level then
      goals[#goals + 1] = t
      top = max(top, t.level)
    end
  end
  if #goals == 0 then
    m.no = "None of these goals can be planned right now."
    return m
  end
  local level, skillPlan = levelPlan(plan, top)
  if level.to < top then
    m.no = ("No recorded recipe gives skill points past %d yet."):format(level.to)
    return m
  end
  m.level = top
  table.sort(goals, function(a, b)
    if (a.skill or 0) ~= (b.skill or 0) then return (a.skill or 0) < (b.skill or 0) end
    return a.id < b.id
  end)
  local run = skillPlan.final
  local carry = { inv = copy(run and run.inv or {}), learned = copy(run and run.learned or {}) }
  local first = #level.steps == 0
  local already = {}
  for _, l in ipairs(skillPlan.learns) do already[l.spell] = true end

  -- Merchant's Favor: what all the patterns cost together, earned once.
  local steps, gold, earn, favorName = {}, 0, nil, "Merchant's Favor"
  local wanted = 0
  local repFaction, repStanding, rep
  for _, t in ipairs(goals) do
    local e = plan.entries and plan.entries[t.id]
    if e and not e.known and not already[e.spell] and e.src.how == "vendor" and e.src.confirmed then
      -- The highest standing any of the patterns' vendors asks for.
      local faction, standing = repNeeded(key, e.src)
      if faction and (not repFaction or faction == repFaction) then
        repFaction, repStanding = faction, higher(repStanding, standing)
      end
      for _, o in ipairs(list(e.src.others)) do
        if o.currency == FAVOR then
          wanted = wanted + (o.n or 0)
          favorName = o.name or favorName
        end
      end
    end
  end
  local need = {} -- item -> material entry, summed over every goal
  local function addNeed(entry)
    local old = need[entry.item]
    if old then old.need = old.need + entry.need else need[entry.item] = entry end
  end
  local function addRows(part)
    for _, rows in ipairs({ part.buys, part.uses }) do
      for _, row in ipairs(rows) do
        local entry = matEntry(key, row.item, row.n, market, true)
        entry.name = nameOf(row.item)
        addNeed(entry)
      end
    end
  end
  -- Reputation for all of them, earned once, before the Favor.
  if repFaction then
    rep = G.PlanRep(key, repFaction, repStanding, copy(carry.inv), market, plan.cache)
    if rep.have ~= nil and rep.left <= 0 then
      rep = nil
    else
      for _, st in ipairs(repSteps(rep, key, first)) do steps[#steps + 1] = st end
      gold = gold + rep.gold
      carry.inv = rep.inventory
      addRows(rep)
    end
  end
  if wanted > P.Currency(key, FAVOR) then
    earn = G.PlanFavor(key, wanted, copy(carry.inv), market, plan.cache)
    for _, st in ipairs(favorSteps(earn, key, first and not rep)) do steps[#steps + 1] = st end
    gold = gold + earn.gold
    carry.inv = earn.inventory
    addRows(earn)
  end

  -- Each recipe in turn.
  local buys, buyOrder, body, otherCosts, recipes = {}, {}, {}, {}, 0
  local unsure = false
  for _, t in ipairs(goals) do
    local e = plan.entries and plan.entries[t.id]
    if e then
      recipes = recipes + 1
      local tailSteps, mats, extra, others = tail(plan, skillPlan, e, first, carry)
      gold = gold + extra
      for _, st in ipairs(tailSteps) do
        if st.k == "buy" and st.unit then
          local k = st.item .. ":" .. tostring(st.at)
          if not buys[k] then
            buys[k] = st
            buyOrder[#buyOrder + 1] = k
          else
            buys[k].n = buys[k].n + st.n
          end
        else
          body[#body + 1] = st
        end
      end
      for _, entry in ipairs(mats) do addNeed(entry) end
      for _, o in ipairs(others) do
        if o.currency ~= FAVOR or not earn then otherCosts[#otherCosts + 1] = o end
      end
      if not e.known and (e.src.how == "drop" or e.src.how == "quest" or e.src.how == "unknown" or not e.src.confirmed) then
        unsure = true
      end
    end
    P.Yield()
  end
  -- One trip to each vendor for everything the goals need there.
  local owned = P.Owned(key)
  for _, k in ipairs(buyOrder) do
    local st = buys[k]
    st.title = ("Buy %d %s"):format(st.n, P.ItemName(st.item))
    st.sub = st.at .. ", " .. (st.guess and "about " or "") .. Money(st.n * st.unit) .. (st.guess and " (estimate)" or "")
    if first and not earn and not rep then st.target = ((owned[st.item] or {}).total or 0) + st.n end
    st.unit, st.at, st.guess = nil, nil, nil
    steps[#steps + 1] = st
  end
  for _, st in ipairs(body) do steps[#steps + 1] = st end

  local mats = {}
  for _, entry in pairs(need) do mats[#mats + 1] = entry end
  table.sort(mats, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.item < b.item
  end)

  local total = level.cost + gold
  local costs = costsOf(level, skill, top, profession)
  local summary = ("Cost %s. You have %s."):format(Money(total), Money(P.Gold(key)))
  if earn and earn.crateCount > 0 then
    costs.parts[#costs.parts + 1] = { ("%d crate%s for %d %s"):format(earn.crateCount, plural(earn.crateCount),
      earn.need, favorName), floor(earn.gold + 0.5) }
    summary = summary .. (" That includes about %s for %d crate%s, to earn the %d %s these cost.")
      :format(Money(earn.gold), earn.crateCount, plural(earn.crateCount), earn.need, favorName)
  end
  local repNotes
  if rep then
    local words
    words, repNotes = repWords(rep)
    summary = summary .. words
    if #rep.writs > 0 then
      costs.parts[#costs.parts + 1] = { ("%d writ%s toward %s with %s"):format(#rep.writs, plural(#rep.writs),
        rep.standing, rep.faction), floor(rep.gold + 0.5) }
    end
  end
  local rest = gold - (earn and earn.gold or 0) - (rep and rep.gold or 0)
  if rest > 0.5 then
    costs.parts[#costs.parts + 1] = { ("Learning and materials for %d item%s"):format(recipes, plural(recipes)),
      floor(rest + 0.5) }
  end
  costs.total = floor(total + 0.5)
  if earn and earn.short > 0 then
    costs.notes[#costs.notes + 1] = ("Crates for %d of the %d %s couldn't be found or priced.")
      :format(earn.short, earn.need, favorName)
  end
  for _, o in ipairs(otherCosts) do
    costs.notes[#costs.notes + 1] = ("Also %s %s."):format(tostring(o.n), tostring(o.name))
  end
  if unsure then costs.notes[#costs.notes + 1] = "Where to learn one of these isn't confirmed." end
  if earn then
    for _, w in ipairs(earn.warnings) do costs.notes[#costs.notes + 1] = w end
    costs.notes[#costs.notes + 1] = earn.note
  end
  for _, note in ipairs(repNotes or {}) do costs.notes[#costs.notes + 1] = note end
  m.tail, m.mats, m.summary, m.costs, m.planned = steps, (#mats > 0 and mats or nil), summary, costs, true
  return m
end

function G.PlanGoal(plan, id)
  if id == "multi" then return G.PlanMulti(plan) end
  local t
  for _, target in ipairs(plan.targets) do
    if target.id == id then t = target end
  end
  if not t then return nil end
  if t.no or t.planned or not t.level then return t end
  local key, profession, skill = plan.key, plan.profession, plan.skill
  local level, skillPlan = levelPlan(plan, t.level)
  if level.to < t.level then
    -- The recipes ran out before this skill.
    t.no = ("No recorded recipe gives skill points past %d yet."):format(level.to)
    t.level = nil
    return t
  end
  local goldHave = P.Gold(key)
  if t.kind == "skill" then
    t.summary = level.summary
    t.costs = costsOf(level, skill, t.level, profession)
  else
    local e = plan.entries[id]
    local src = e.src
    local steps, mats, extraGold, others, earn, rep = tail(plan, skillPlan, e, #level.steps == 0)
    local total = level.cost + extraGold
    local summary = ("Cost %s. You have %s."):format(Money(total), Money(goldHave))
    local costs = costsOf(level, skill, t.level, profession)
    local unsure = not e.known and (src.how == "drop" or src.how == "quest" or src.how == "unknown"
      or not src.confirmed)
    for _, o in ipairs(others) do
      local have = o.currency and P.Currency(key, o.currency) or nil
      local isFavor = earn and o.currency == FAVOR
      if isFavor and earn.crateCount == 0 then
        summary = summary .. (" Also %s %s (you have %d). No crates to earn it could be found or priced.")
          :format(tostring(o.n), o.name, have)
      elseif isFavor then
        summary = summary .. (" That includes about %s for %d crate%s, to earn the %s %s it costs (you have %d).")
          :format(Money(earn.gold), earn.crateCount, plural(earn.crateCount), tostring(o.n), o.name, have)
        if earn.short > 0 then
          summary = summary .. (" Crates for %d of that couldn't be found or priced."):format(earn.short)
        end
      else
        summary = summary .. (" Also %s %s%s."):format(tostring(o.n), o.name,
          have and (" (you have %d)"):format(have) or "")
      end
    end
    local repNotes
    if rep then
      local words
      words, repNotes = repWords(rep)
      summary = summary .. words
    end
    if unsure then summary = summary .. " Where to learn it isn't confirmed." end
    local learnGold = extraGold - (earn and earn.gold or 0) - (rep and rep.gold or 0)
    if rep and #rep.writs > 0 then
      costs.parts[#costs.parts + 1] = { ("%d writ%s toward %s with %s"):format(#rep.writs, plural(#rep.writs),
        rep.standing, rep.faction), floor(rep.gold + 0.5) }
    end
    if earn and earn.crateCount > 0 then
      costs.parts[#costs.parts + 1] = { ("%d crate%s for %d Merchant's Favor"):format(earn.crateCount,
        plural(earn.crateCount), earn.need), floor(earn.gold + 0.5) }
    end
    local label = "Materials for one"
    if not e.known then
      label = (src.how == "vendor" or src.how == "ah") and "Pattern and materials" or "Learning it and materials"
    end
    if learnGold > 0.5 then costs.parts[#costs.parts + 1] = { label, floor(learnGold + 0.5) } end
    costs.total = floor(total + 0.5)
    for _, o in ipairs(others) do
      local have = o.currency and P.Currency(key, o.currency) or nil
      if o.currency == FAVOR and earn and earn.short > 0 then
        costs.notes[#costs.notes + 1] = ("Crates for %d of the %s %s couldn't be found or priced.")
          :format(earn.short, tostring(o.n), o.name)
      elseif not earn or o.currency ~= FAVOR then
        costs.notes[#costs.notes + 1] = ("Also %s %s%s."):format(tostring(o.n), o.name,
          have and (" (you have %d)"):format(have) or "")
      end
    end
    if unsure then costs.notes[#costs.notes + 1] = "Where to learn it isn't confirmed." end
    if earn then
      for _, w in ipairs(earn.warnings) do costs.notes[#costs.notes + 1] = w end
      costs.notes[#costs.notes + 1] = earn.note
    end
    for _, note in ipairs(repNotes or {}) do costs.notes[#costs.notes + 1] = note end
    t.tail, t.mats, t.summary, t.costs = steps, (#mats > 0 and mats or nil), summary, costs
  end
  t.planned = true
  return t
end
