-- The plan window: shows a profession's goals and the plan for the goal you pick, as a
-- checklist, and ticks steps off as you do them in game. The planning itself is in the Planner
-- files; this file shows what they work out and tracks progress.
--
-- Each profession has its own goals (ns.Planner.Plans()[profession], worked out in game and
-- kept in memory). The ones showing are the open profession window's, or the last you looked at:
--   targets = { { id, name, skill, known, cost, tip = {lines}, icon, no = "why it can't be
--                 picked yet", level = <skill to reach first>, tail = {steps after that},
--                 mats, title, summary, costs, planned } }   every recipe and skill checkpoint
--   groups  = { { label, ids = {...}, flat,     how the dropdown lists them; "sections" split a
--                 sections = { { label, ids } } } }   group under headings (tiers of gear)
--   a target with made = true has already been crafted: it's greyed in the dropdown
--   levels  = { [skill] = { steps, mats } }     the steps to reach each skill level
--   items   = { [itemID] = { name, each, where } }   every material's name and cheapest price
--   a target's req = { { itemID, count }, ... } is what one craft of it takes
--   selected = the goal showing now
-- The steps shown are the selected goal's: its level's steps, then its own. A goal's plan is
-- worked out when it's picked (planned = true once it is). Each step is
--   { k = kind, title = "...", sub = "...", icon = itemID, done = true|nil, ... }
--       "collect" / "buy": done when you hold `target` of `item` (bags and bank), or, without a
--                          target, `n` more than you held when the step came up
--       "learn":           done when you know `spell`
--       "make":            done after `n` crafts of `spell`
--       "craft":           done when `profession` reaches `skill`
--       "sell":            done when none of `item` is left in your bags (after the step before it)
--       "currency":        done when you hold `n` of currency `cur` (Merchant's Favor)
--       "bank":            added here, first in the list, for a material the plan needs that's
--                          in your bank: done once it's in your bags (or the bank has none left)
--       a step with map, x and y has a place, for the optional waypoint; a step with
--       near = "vendor" | "mailbox" | "banker" | "auctioneer" | "crates" goes to the nearest one of those
--       from where you're standing (worked out when the arrow is set)
--
-- The window appears beside your profession window whenever the plan's profession is open
-- (a Leatherworking plan with Leatherworking), and goes away when that window closes. You can
-- drag it from there; the next time it opens it's beside the profession window again. The
-- minimap button and /qm show or hide it anywhere.
-- It's built from the game's own window parts (the portrait window, inset, scroll frame, tick
-- box and small button WoW Forever uses). Rows follow the old CraftMatch panel: an icon, a
-- title, a colored detail line, and progress on the right.
-- Clicking a row does the step, as far as an addon can:
--   a crafting step  selects the recipe in the profession window, fills in how many, and starts
--   a buying step    searches the auction house for the item when it's open; otherwise points
--                    the way (a TomTom arrow) when the step has a place
--   a learning step  points the way
-- Pointing the way is there only when TomTom is installed, and only on a click: the plan
-- never sets an arrow by itself.
--   /qm   show or hide the window

local _, ns = ...

local Try = ns.Try
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon

local window, rows = nil, {}
local dismissed = false -- you closed it while the profession window was open

local GREY, WHITE, GREEN, RED, GOLD = "|cff808080", "|cffffffff", "|cff40ff40", "|cffff4040", "|cffffd100"
-- The detail line's color says what kind of step it is.
local KIND_COLOR = {
  buy = "|cffff8040", collect = "|cffff8040",   -- getting materials (orange, like "need ..." in CraftMatch)
  bank = "|cffff8040",
  learn = "|cff66bbff",                           -- a trip to a trainer
  make = GREEN, craft = GREEN,                    -- crafting
  currency = "|cffff8040",                        -- earning a currency
  fill = "|cffff8040", writ = "|cffff8040", rep = "|cffff8040",   -- crates and writs
  sell = GOLD,                                    -- gold coming back
}
local QUESTION_MARK = 134400

-- Auction prices, auction searches and the shopping list are Auctionator's: without it
-- installed, nothing in the window mentions the auction house.
local function HasAuctionator()
  return type(Auctionator) == "table"
end

local function Valid(p)
  return type(p) == "table" and type(p.targets) == "table"
end

-- Every profession's goals for this character, by profession.
local function Plans()
  if not ns.Char() then return nil end
  return ns.Planner.Plans()
end

local active -- the profession whose plan is showing

-- The names of the professions that have a plan, in order.
local function PlanNames()
  local names = {}
  for name, p in pairs(Plans() or {}) do
    if Valid(p) then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

-- The plan that's showing: the one picked, else the one you last looked at, else the first.
local function Plan()
  local plans = Plans()
  if not plans then return nil end
  if active and Valid(plans[active]) then return plans[active] end
  local c = ns.Char()
  if c.planShown and Valid(plans[c.planShown]) then
    active = c.planShown
    return plans[active]
  end
  active = PlanNames()[1]
  return active and plans[active] or nil
end

local function Target(plan, id)
  if type(plan.targets) ~= "table" or id == nil then return nil end
  -- Several goals picked together are one goal of their own.
  if id == "multi" then return plan.multi end
  for _, t in ipairs(plan.targets) do
    if t.id == id then return t end
  end
end

-- What's showing: the plan itself, or the selected goal's steps (the steps to reach its skill
-- level, then its own). Built once per selection; the step tables are the saved ones, so
-- progress is kept on them.
local views = setmetatable({}, { __mode = "k" })

local BankSteps

-- What to call a place a step goes to when it's "the nearest one of these".
local NEAR_LABEL = { vendor = "Vendor", mailbox = "Mailbox", banker = "Bank", auctioneer = "Auction house",
  crates = "Crate hand-in" }

-- Where a step sends you: map, x, y and a name for the arrow, or nil when it's nowhere in
-- particular. A step that any place of a kind will do for (near) gets the nearest one you've
-- recorded, from where you're standing now.
local function PlaceOf(step)
  if step.near and ns.P and ns.P.Nearest then
    local npc = ns.P.Nearest(ns.PlayerKey(), step.near)
    if npc and type(npc.map) == "number" and type(npc.x) == "number" and type(npc.y) == "number" then
      local name = npc.name
      if step.near == "auctioneer" or step.near == "mailbox" or not name then name = NEAR_LABEL[step.near] end
      return npc.map, npc.x, npc.y, name, npc
    end
  end
  if type(step.map) == "number" and type(step.x) == "number" and type(step.y) == "number" then
    return step.map, step.x, step.y, step.where
  end
end

-- "Take it from your bank" steps, first in the list: one for each material the plan needs that's
-- in your bank while your bags don't hold enough. They're kept with the goals (per goal), so a
-- step stays ticked once done even after crafting uses the materials up.
BankSteps = function(plan, v)
  local GetItemCountFn = GetItemCount
  plan.bankSteps = type(plan.bankSteps) == "table" and plan.bankSteps or {}
  local goal = tostring(plan.selected or "plan")
  local kept = plan.bankSteps[goal]
  if type(kept) ~= "table" then kept = {} end
  local out = {}
  for _, mat in ipairs(v.mats or {}) do
    local step = kept[mat.item]
    if not step and GetItemCountFn and mat.item then
      local total = Try(GetItemCountFn, mat.item, true) or 0
      local bags = Try(GetItemCountFn, mat.item, false) or 0
      local need = mat.need or 0
      local take = math.min(total, need) - bags
      if total > bags and take > 0 then
        -- Any bank will do: the arrow goes to the nearest banker you've used.
        step = { k = "bank", item = mat.item, icon = mat.item, n = take, want = math.min(total, need),
          title = "Take " .. take .. " " .. tostring(mat.name or "") .. " from your bank",
          sub = "From your bank into your bags", near = "banker" }
        kept[mat.item] = step
      end
    end
    if step then out[#out + 1] = step end
  end
  if next(kept) then plan.bankSteps[goal] = kept end
  -- The auction house stop, after the bank: everything the plan buys there, in one visit (the
  -- Shopping list). Kept per goal like the bank steps, so it stays ticked once it's bought.
  plan.auctionSteps = type(plan.auctionSteps) == "table" and plan.auctionSteps or {}
  local stop = plan.auctionSteps[goal]
  if not stop and HasAuctionator() and GetItemCountFn then
    local items, names = {}, {}
    for _, mat in ipairs(v.mats or {}) do
      if mat.where == "auction house" and mat.item then
        local have = Try(GetItemCountFn, mat.item, true) or 0
        if (mat.need or 0) > have then
          items[#items + 1] = { item = mat.item, want = mat.need }
          names[#names + 1] = (mat.need - have) .. " " .. tostring(mat.name or "")
        end
      end
    end
    if #items > 0 then
      stop = { k = "auction", items = items, icon = items[1].item, near = "auctioneer",
        title = "Buy " .. #items .. (#items == 1 and " material" or " materials") .. " at the auction house",
        sub = table.concat(names, ", ") }
      plan.auctionSteps[goal] = stop
    end
  end
  if stop then out[#out + 1] = stop end
  for _, step in ipairs(v.steps or {}) do out[#out + 1] = step end
  return out
end
local function ViewOf(plan)
  local seen = views[plan]
  if seen and seen.selected == plan.selected then return seen end
  local v = { plan = plan, selected = plan.selected, steps = {}, mats = {} }
  local t = Target(plan, plan.selected)
  -- A goal's plan is there once it's been worked out.
  local ready = t and (t.planned or plan.fixed) and not t.no
  local level = ready and t.level and type(plan.levels) == "table" and plan.levels[t.level] or nil
  v.target = t
  local need, order = {}, {}
  if ready then
    local lead = level and type(level.steps) == "table" and level.steps or {}
    local tail = type(t.tail) == "table" and t.tail or {}
    -- One trip per vendor: the goal's own purchases join the skill plan's earlier trip there.
    if ns.Goals and ns.Goals.FoldBuys then
      plan.folds = type(plan.folds) == "table" and plan.folds or {}
      local goal = tostring(plan.selected)
      plan.folds[goal] = plan.folds[goal] or {}
      local ok, a, b = pcall(ns.Goals.FoldBuys, lead, tail, plan.folds[goal])
      if ok and type(a) == "table" and type(b) == "table" then lead, tail = a, b end
    end
    for _, list in ipairs({ lead, tail }) do
      for _, step in ipairs(list) do v.steps[#v.steps + 1] = step end
    end
    for _, list in ipairs({ level and level.mats or {}, t.mats or {} }) do
      for _, mat in ipairs(type(list) == "table" and list or {}) do
        if mat.item then
          if not need[mat.item] then
            need[mat.item] = { item = mat.item, name = mat.name, need = 0, each = mat.each, where = mat.where,
              also = mat.also, map = mat.map, x = mat.x, y = mat.y, near = mat.near, guess = mat.guess }
            order[#order + 1] = need[mat.item]
          end
          need[mat.item].need = need[mat.item].need + (mat.need or 0)
        end
      end
    end
  end
  -- What the plan's crafts have used up since it was worked out is no longer needed.
  local used = type(plan.usedMats) == "table" and plan.usedMats[tostring(plan.selected)] or nil
  if used then
    for _, mat in ipairs(order) do mat.need = math.max(0, mat.need - (used[mat.item] or 0)) end
  end
  table.sort(order, function(a, b) return tostring(a.name) < tostring(b.name) end)
  v.mats = order
  v.ready = ready and true or false
  v.title = t and (t.title or t.name) or plan.title
  if not t then
    v.summary = plan.summary
  elseif ready then
    v.summary = t.summary
  else
    v.summary = t.no or "Working out the cheapest plan..."
  end
  v.steps = BankSteps(plan, v)
  views[plan] = v
  return v
end

-- Forgets the built views, so the next look rebuilds them (after the bank changes).
local function ForgetViews()
  for plan in pairs(views) do views[plan] = nil end
end
ns.PlanForgetViews = ForgetViews

local function View()
  local plan = Plan()
  return plan and ViewOf(plan) or nil
end

-- 12345 -> "1g 23s 45c"
local function Money(copper)
  copper = math.floor((copper or 0) + 0.5)
  local g, sv, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if sv > 0 then parts[#parts + 1] = sv .. "s" end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
  return table.concat(parts, " ")
end

-- The cost line under the dropdowns: what the goal costs against the gold you have right now.
-- What the cost is made of is in its tooltip.
local function CostText(v)
  local costs = v and v.ready and v.target and type(v.target.costs) == "table" and v.target.costs or nil
  if not costs then return nil end
  local total = costs.total or 0
  local have = Try(GetMoney) or 0
  return "Cost |cffffffff" .. Money(total) .. "|r   You have "
    .. (have >= total and "|cff40ff40" or "|cffff4040") .. Money(have) .. "|r"
end

-- How much gold the goal is short, for the line under the materials' total: "37s 66c short".
-- Nil when you have enough.
local function ShortText(v)
  local costs = v and v.ready and v.target and type(v.target.costs) == "table" and v.target.costs or nil
  if not costs then return nil end
  local total = costs.total or 0
  local have = Try(GetMoney) or 0
  if have >= total then return nil end
  return "|cffff4040" .. Money(total - have) .. " short|r"
end

local function CostTooltip(self)
  local v = View()
  local costs = v and v.ready and v.target and type(v.target.costs) == "table" and v.target.costs or nil
  if not costs then return end
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
  GameTooltip:AddLine("What " .. tostring(v.target.name) .. " costs")
  for _, part in ipairs(type(costs.parts) == "table" and costs.parts or {}) do
    GameTooltip:AddDoubleLine(tostring(part[1]), Money(part[2]), 1, 1, 1, 1, 1, 1)
  end
  GameTooltip:AddDoubleLine("Total", Money(costs.total or 0), 1, 0.82, 0, 1, 0.82, 0)
  GameTooltip:AddDoubleLine("You have", Money(Try(GetMoney) or 0), 0.7, 0.7, 0.7, 1, 1, 1)
  for _, note in ipairs(type(costs.notes) == "table" and costs.notes or {}) do
    GameTooltip:AddLine(note, 0.7, 0.7, 0.7, true)
  end
  if not HasAuctionator() then
    GameTooltip:AddLine("No Auctionator data: this counts vendor and trainer prices only.", 1, 0.5, 0.25, true)
  end
  GameTooltip:Show()
end

local function Count(item, withBank)
  if not (item and GetItemCount) then return 0 end
  return Try(GetItemCount, item, withBank and true or false) or 0
end

-- "3/10" in red or green, and how much of what you have is in the bank rather than your bags.
local function HaveText(item, need)
  local total = Count(item, true)
  local inBank = math.max(0, total - Count(item, false))
  local text = (total >= need and "|cff40ff40" or "|cffff4040") .. total .. "/" .. need .. "|r"
  if inBank > 0 then text = text .. " |cff9d9d9d(" .. inBank .. " in bank)|r" end
  return text, total
end

-- How many of a recipe the materials you hold right now would make (bags and bank together).
-- Nil when the recipe's materials aren't known.
local function CanMake(t)
  if type(t.req) ~= "table" or #t.req == 0 then return nil end
  local most
  for _, pair in ipairs(t.req) do
    local n = math.floor(Count(pair[1], true) / math.max(1, pair[2] or 1))
    if not most or n < most then most = n end
  end
  return most
end

-- The first step that isn't done yet.
local function CurrentStep(v)
  for i, step in ipairs(v.steps) do
    if not step.done then return i, step end
  end
end

----------------------------------------------------------------------
-- Progress
----------------------------------------------------------------------

-- How far along a step is, as (have, need), for the kinds that count something.
local function Progress(step)
  local k = step.k
  if k == "buy" or k == "collect" then
    local have = Count(step.item, true)
    if step.target then return have, step.target end
    if step.base and step.n then return math.max(0, have - step.base), step.n end
    return nil, step.n
  elseif k == "currency" then
    local info = step.cur and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo
      and Try(C_CurrencyInfo.GetCurrencyInfo, step.cur)
    return info and info.quantity or nil, step.n
  elseif k == "writ" or k == "rep" then
    -- Reputation earned with the faction, against where the step should bring it.
    return step.faction and ns.Reputation and ns.Reputation(step.faction) or nil, step.n
  elseif k == "bank" then
    return Count(step.item, false), step.want or step.n
  elseif k == "auction" then
    -- How many of its materials you now hold enough of.
    local have = 0
    for _, it in ipairs(step.items or {}) do
      if Count(it.item, true) >= (it.want or 0) then have = have + 1 end
    end
    return have, #(step.items or {})
  elseif k == "make" then
    return step.made or 0, step.n or 1
  elseif k == "craft" then
    return ns.profSkill and step.profession and ns.profSkill[step.profession] or nil, step.skill
  end
end

local function IsDone(v, i, step)
  local k = step.k
  if k == "bank" then
    -- In your bags, or nothing of it left in the bank to take.
    local bags, total = Count(step.item, false), Count(step.item, true)
    return bags >= (step.want or step.n or 0) or total <= bags
  elseif k == "buy" or k == "collect" or k == "make" or k == "craft" or k == "currency" or k == "auction" or k == "writ" or k == "rep" then
    local have, need = Progress(step)
    return have ~= nil and need ~= nil and have >= need
  elseif k == "fill" then
    -- Filled once that much of the material has gone since the step came up, or (in case the
    -- game doesn't work that way) once the Favor it was for is there.
    if step.base and step.item and step.n and Count(step.item, true) <= step.base - step.n then return true end
    local info = step.cur and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo
      and Try(C_CurrencyInfo.GetCurrencyInfo, step.cur)
    return info ~= nil and step.favor ~= nil and (info.quantity or 0) >= step.favor
  elseif k == "learn" then
    return step.spell ~= nil and Try(IsPlayerSpell, step.spell) and true or false
  elseif k == "rank" then
    -- Trained once the profession's cap is past where it was.
    local cap = ns.profMax and step.profession and ns.profMax[step.profession]
    return cap ~= nil and step.cap ~= nil and cap > step.cap
  elseif k == "sell" then
    local before = v.steps[i - 1]
    return step.item ~= nil and (before == nil or before.done) and step.had and Count(step.item, false) == 0
  end
  return false
end

local Refresh

-- Ticks off every step that's now finished. A step you ticked or unticked by hand is left alone.
local function CheckSteps(v)
  local changed = false
  -- Buying steps without a fixed target count from what you hold when they come up. A run of
  -- them in a row starts counting together, since you'll buy them in one trip.
  local first = CurrentStep(v)
  for i = first or (#v.steps + 1), #v.steps do
    local step = v.steps[i]
    if step.k ~= "buy" and step.k ~= "collect" and step.k ~= "learn" then break end
    if (step.k == "buy" or step.k == "collect") and not step.done and not step.target and not step.base and step.item then
      step.base = Count(step.item, true)
      changed = true
    end
  end
  -- Crate fills count what's used from when they come up; fills in a row start together.
  for i = first or (#v.steps + 1), #v.steps do
    local step = v.steps[i]
    if step.k ~= "fill" then break end
    if not step.done and not step.base and step.item then
      step.base = Count(step.item, true)
      changed = true
    end
  end
  for i, step in ipairs(v.steps) do
    -- A "sell" step can only finish once you've actually had the items.
    if step.k == "sell" and not step.had and step.item and Count(step.item, false) > 0 then
      step.had = true
      changed = true
    end
    if not step.done and step.byHand == nil and IsDone(v, i, step) then
      step.done = true
      changed = true
    end
  end
  return changed
end

-- Ticks off every step that's now finished, in every profession's plan (so nothing is missed
-- on the ones that aren't showing). A step you ticked or unticked by hand is left alone.
local function Check()
  local plans = Plans()
  if not plans or not next(plans) then return end
  if ns.SaveSkills then ns.SaveSkills() end
  for _, plan in pairs(plans) do
    if Valid(plan) then CheckSteps(ViewOf(plan)) end
  end
  Refresh()
end
ns.PlanCheck = Check

function ns.PlanToggleStep(i)
  local v = View()
  local step = v and v.steps[i]
  if not step then return end
  step.done = (not step.done) and true or nil
  step.byHand = step.done and true or false
  Refresh()
end

-- A craft of a recipe counts toward the first unfinished "make" step for it.
local function OnCraft(_, unit, _, spellID)
  if unit ~= "player" or not ns.Plain(spellID) then return end
  local plans = Plans()
  if not plans or not next(plans) then return end
  for _, plan in pairs(plans) do
    if Valid(plan) then
      -- Crafting a recipe marks it as made in the dropdown straight away.
      local crafted = Target(plan, "recipe:" .. tostring(spellID))
      if crafted and not crafted.made then crafted.made = true end
      local counted, planned = false, false
      for _, step in ipairs(ViewOf(plan).steps) do
        if step.spell == spellID and not step.done and (step.k == "make" or step.k == "craft") then
          planned = true
          if step.k == "make" and not counted then
            step.made = (step.made or 0) + 1
            counted = true
          end
        end
      end
      -- A craft the plan asked for used its materials up: the plan needs that much less of
      -- them now. (The materials list would otherwise ask for them all over again.)
      if planned and crafted and type(crafted.req) == "table" then
        local goal = tostring(plan.selected)
        plan.usedMats = type(plan.usedMats) == "table" and plan.usedMats or {}
        local used = plan.usedMats[goal] or {}
        plan.usedMats[goal] = used
        for _, pair in ipairs(crafted.req) do
          if pair[1] then used[pair[1]] = (used[pair[1]] or 0) + (pair[2] or 1) end
        end
        views[plan] = nil
      end
    end
  end
  ns.Later("planCheck", 1, Check)
end

-- For the minimap button's tooltip: the plan's title, steps done and steps in all.
function ns.PlanStatus()
  local v = View()
  if not v then return nil end
  local done = 0
  for _, step in ipairs(v.steps) do
    if step.done then done = done + 1 end
  end
  return v.title or "Plan", done, #v.steps
end

----------------------------------------------------------------------
-- Pointing the way: an arrow to a step's place, set only when you click the step
----------------------------------------------------------------------

local function HasTomTom()
  return type(TomTom) == "table" and type(TomTom.AddWaypoint) == "function"
end

-- Arrows are TomTom's: without TomTom installed there are none, and nothing in the window
-- offers them (no "click to point the way").
-- Each is a route: one stop, or several when flying is quicker (the nearest flight
-- master first, then the place itself). TomTom shows one stop at a time; when you reach it, the
-- arrow moves on to the next. There is one, "click": the one a click on a row sets.
local arrows = {} -- name -> { stops, leg, uid }

-- A click takes TomTom's arrow. What the arrow pointed at before (a waypoint of yours, or
-- another addon's) gets it back when the route ends.
local arrowTarget, prior

function ns.PlanArrowTarget(uid)
  arrowTarget = uid
end

local function GiveBack()
  local was = prior
  prior = nil
  if not (type(was) == "table" and HasTomTom() and TomTom.SetCrazyArrow and TomTom.IsValidWaypoint) then return end
  local ok, valid = pcall(TomTom.IsValidWaypoint, TomTom, was)
  if ok and valid then pcall(TomTom.SetCrazyArrow, TomTom, was, was.arrivaldistance, was.title) end
end

local function ShowStop(arrow)
  local stop = arrow.stops[arrow.leg]
  if HasTomTom() then
    local ok, uid = pcall(TomTom.AddWaypoint, TomTom, stop.map, stop.x / 100, stop.y / 100, {
      title = stop.title or "Quartermaster", from = "Quartermaster", persistent = false, crazy = true,
    })
    arrow.uid = ok and uid or nil
  end
end

local function ClearArrow(name)
  local arrow = arrows[name]
  arrows[name] = nil
  if arrow and arrow.uid and HasTomTom() and TomTom.RemoveWaypoint then
    pcall(TomTom.RemoveWaypoint, TomTom, arrow.uid)
  end
end

-- The way to a place from where you stand: its stops, in order.
local function RouteTo(map, x, y, name)
  local dest = { map = map, x = x, y = y, name = name }
  if ns.P and ns.P.Route then
    local ok, stops = pcall(ns.P.Route, ns.PlayerKey(), dest)
    if ok and type(stops) == "table" and #stops > 0 then return stops end
  end
  return { { map = map, x = x, y = y, title = name } }
end

-- "Dungar Longdrink: fly to Lakeshire, then on to Kalsey Sanden"
local function RouteText(stops)
  local parts = {}
  for i, stop in ipairs(stops) do
    parts[#parts + 1] = (i > 1 and "then on to " or "") .. tostring(stop.title or "the next stop")
  end
  return table.concat(parts, ", ")
end

local function StartArrow(name, stops)
  -- Remember whose arrow this takes (a second click keeps what the first one remembered).
  if type(arrowTarget) ~= "table" then
    prior = nil
  elseif arrowTarget.from ~= "Quartermaster" then
    prior = arrowTarget
  end
  ClearArrow(name)
  local arrow = { stops = stops, leg = 1 }
  arrows[name] = arrow
  ShowStop(arrow)
  return arrow
end

-- TomTom took an arrow away (you arrived, or removed it). On a route with more stops the arrow
-- moves on to the next; at the end, the arrow goes back to what it pointed at before.
function ns.PlanWaypointRemoved(uid)
  if uid == nil then return end
  for name, arrow in pairs(arrows) do
    if arrow.uid == uid then
      arrow.uid = nil
      if arrow.leg < #arrow.stops then
        local reached = arrow.stops[arrow.leg]
        arrow.leg = arrow.leg + 1
        ShowStop(arrow)
        if reached.fly then
          ns.Print("take the flight to " .. tostring(reached.fly) .. ". The arrow now points at "
            .. tostring(arrow.stops[arrow.leg].title or "your stop") .. ".")
        end
      else
        arrows[name] = nil
        GiveBack()
      end
      return
    end
  end
end

----------------------------------------------------------------------
-- Which profession's plan is showing
----------------------------------------------------------------------

-- Switches to a profession's plan. Returns false if it has none.
local function SetActive(name)
  local plans = Plans()
  if not (plans and name and Valid(plans[name])) then return false end
  if active ~= name then
    active = name
  end
  local c = ns.Char()
  if c.planShown ~= name then
    c.planShown = name
    ns.MarkDirty("plan")
  end
  return true
end

-- Asks for the goals showing to be worked out, or brought up to date.
local function Want()
  if active then ns.Planner.Want(active) end
end

function ns.PlanShowProfession(name)
  if not SetActive(name) then return false end
  Want()
  ns.PlanCheck()
  return true
end

----------------------------------------------------------------------
-- Goals: the dropdown at the top of the window
----------------------------------------------------------------------

-- For a recipe you know, the skill number takes the color the recipe has in the profession
-- window (orange, yellow, green, grey).
local DIFF_COLOR = { [0] = "|cffff8040", [1] = "|cffffff00", [2] = "|cff40c040", [3] = "|cff808080" }
-- Names take the crafted item's quality color: grey, white, green, blue, purple, orange.
local QUALITY_HEX = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee",
  [5] = "ff8000", [6] = "e6cc80", [7] = "00ccff" }

local function QualityColor(t)
  local q = t.q
  if q == nil and t.icon and C_Item and C_Item.GetItemQualityByID then q = Try(C_Item.GetItemQualityByID, t.icon) end
  -- The game's own color table first, so it follows the client (and its colorblind setting).
  local color = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  if type(color) == "table" and type(color.hex) == "string" and color.hex:find("^|c") then return color.hex end
  return "|cff" .. (QUALITY_HEX[q or 1] or "ffffff")
end
-- A group's color says what kind of source it is.
local GROUP_COLOR = {
  upgrade = "|cff40ff40", known = WHITE, trainer = "|cff66bbff", vendor = GOLD, currency = "|cffff8040", ah = "|cffe6cc80",
  quest = "|cffffff00", drop = "|cffa335ee", auto = WHITE, unknown = GREY,
}

local function IconText(item)
  local texture = item and Try(GetItemIcon, item)
  return texture and ("|T" .. texture .. ":16:16:0:0|t ") or ""
end

-- Whether you can pay for a recipe right now: true, false, or nil when its cost isn't a number.
local function CanAfford(t)
  if not t.gold and not t.cur then return nil end
  if t.gold and (Try(GetMoney) or 0) < t.gold then return false end
  if t.cur then
    local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo and Try(C_CurrencyInfo.GetCurrencyInfo, t.cur)
    if ((info and info.quantity) or 0) < (t.curN or 0) then return false end
  end
  return true
end

-- One line of the dropdown: icon, the skill needed, the name in its item quality color and, for
-- a recipe you don't know, its cost in whatever it's paid in (green if you can pay it now, red
-- if not). In a list, a recipe you know also says how many you could make right now.
local function GoalLabel(t, plan, inList)
  if t.kind == "skill" or t.kind == "multi" then return GOLD .. tostring(t.name) .. "|r" end
  local ready = ""
  if inList and (t.known or t.made) then
    local n = CanMake(t)
    if n and n > 0 then ready = "   " .. GREEN .. "can make " .. n .. "|r" end
  end
  local have = plan and plan.profession and ns.profSkill and ns.profSkill[plan.profession]
  -- Already crafted: the whole line is grey.
  if t.made then
    return IconText(t.icon) .. GREY .. (t.skill and (t.skill .. "  ") or "") .. tostring(t.name) .. "   made|r" .. ready
  end
  local name = QualityColor(t) .. tostring(t.name) .. "|r"
  local skill = ""
  if t.skill then
    local color = (have and t.skill > have) and RED or WHITE
    if t.known then color = DIFF_COLOR[t.diff] or WHITE end
    skill = color .. t.skill .. "|r  "
  end
  if t.known then return IconText(t.icon) .. skill .. name .. ready end
  local cost = ""
  if t.cost and t.cost ~= "" then
    local afford = CanAfford(t)
    cost = "   " .. (afford == true and GREEN or (afford == false and RED or GOLD)) .. t.cost .. "|r"
  end
  return IconText(t.icon) .. skill .. name .. cost
end

-- Selects a recipe in the profession window, when that window is open on the same profession.
-- (With another profession's window open it's left alone: selecting there would switch it.)
local function SelectInProfessionWindow(plan, id)
  local spell = tonumber(tostring(id):match("^recipe:(%d+)$") or "")
  local host = _G.ProfessionsFrame or _G.TradeSkillFrame
  if not (spell and host and host.IsShown and host:IsShown()) then return false end
  if not (plan.profession and ns.PlanOpenProfession and ns.PlanOpenProfession() == plan.profession) then return false end
  local T = C_TradeSkillUI
  local page = type(host.CraftingPage) == "table" and host.CraftingPage or nil
  local list = page and type(page.RecipeList) == "table" and page.RecipeList or nil
  local info = T and T.GetRecipeInfo and Try(T.GetRecipeInfo, spell)
  if list and type(list.SelectRecipe) == "function" and info and pcall(list.SelectRecipe, list, info, true) then
    return true
  end
  if T and T.OpenRecipe then return (pcall(T.OpenRecipe, spell)) end
  return false
end

-- Whether a goal is one of those picked (the one showing, or one of several).
local function IsPicked(plan, id)
  if plan.selected == id then return true end
  if plan.selected == "multi" and plan.multi then
    for _, picked in ipairs(plan.multi.ids) do
      if picked == id then return true end
    end
  end
  return false
end

-- The goals picked, in the order of their dropdowns.
local function PickedIds(plan)
  if plan.selected == "multi" and plan.multi then
    local ids = {}
    for i, id in ipairs(plan.multi.ids) do ids[i] = id end
    return ids
  end
  return plan.selected and { plan.selected } or {}
end

-- Sets the goals picked: one is an ordinary goal; two or more are planned together as one.
local function SetPicked(plan, ids)
  local prefs = plan.profession and ns.Planner.Prefs(plan.profession) or {}
  if #ids == 1 then
    plan.multi, plan.picked, plan.selected = nil, nil, ids[1]
    prefs.picked, prefs.selected = nil, ids[1]
  else
    plan.multi = ns.Goals.NewMulti(plan, ids)
    plan.picked, plan.selected = plan.multi.ids, "multi"
    prefs.picked, prefs.selected = plan.multi.ids, "multi"
  end
  ns.MarkDirty("plan")
  ForgetViews()
  -- The plan is worked out now, from what you have at this moment.
  if active then ns.Planner.Want(active) end
  ns.PlanCheck()
end

-- How many goals can be picked together (one dropdown each).
local MAX_GOALS = 5

-- Puts a goal in one of the goal dropdowns: index 1 is the first, and the next index after the
-- last picked goal adds another. With no id, that dropdown's goal is taken out. Returns true if
-- anything changed.
function ns.PlanPick(index, id)
  local plan = Plan()
  if not plan or plan.fixed and index ~= 1 then return false end
  local ids = PickedIds(plan)
  if id == nil then
    if #ids <= 1 or not ids[index] then return false end -- the last goal stays
    table.remove(ids, index)
  else
    local t = Target(plan, id)
    if not t or t.no or id == "multi" or index < 1 or index > math.min(#ids + 1, MAX_GOALS) then return false end
    for i, picked in ipairs(ids) do
      if picked == id and i ~= index then return false end -- already in another dropdown
    end
    ids[index] = id
  end
  if plan.fixed then
    -- Ready-made goals can't be combined: just the one.
    return ns.PlanSelect(ids[1])
  end
  if id and #ids == 1 then SelectInProfessionWindow(plan, id) end
  SetPicked(plan, ids)
  return true
end

-- Picks one goal, replacing whatever was picked.
function ns.PlanSelect(id)
  local plan = Plan()
  local t = plan and Target(plan, id)
  if not t or t.no or id == "multi" then return false end
  local prefs = plan.profession and ns.Planner.Prefs(plan.profession) or {}
  SelectInProfessionWindow(plan, id)
  if plan.selected ~= id then
    plan.selected = id
    plan.multi, plan.picked = nil, nil
    prefs.selected, prefs.picked = id, nil
    ns.MarkDirty("plan")
  end
  -- Its plan is worked out now, from what you have at this moment.
  Want()
  ns.PlanCheck()
  return true
end

-- Fills a tooltip with an item's own tooltip, the one the game shows for it anywhere: its
-- stats, armor, level and so on. Returns true if the game had it to show.
local function ItemTooltip(tooltip, item)
  if not (item and tooltip and tooltip.SetHyperlink) then return false end
  local ok = pcall(tooltip.SetHyperlink, tooltip, "item:" .. tostring(item))
  return ok and (tooltip.NumLines and (tooltip:NumLines() or 0) > 0) or false
end

-- The materials one craft takes: for each, what you have against what's needed (bags and
-- bank), and the price of the part you're missing. Then the total still to buy.
local function AddMaterials(tooltip, t, plan)
  if type(t.req) ~= "table" or #t.req == 0 then return end
  local info = type(plan.items) == "table" and plan.items or {}
  tooltip:AddLine("Materials", 1, 0.82, 0)
  local total, unpriced = 0, false
  for _, pair in ipairs(t.req) do
    local item, need = pair[1], pair[2] or 1
    local meta = info[item] or {}
    local right, have = HaveText(item, need)
    local short = math.max(0, need - have)
    if short > 0 then
      if meta.each then
        total = total + short * meta.each
        right = right .. "   " .. GOLD .. Money(short * meta.each) .. "|r"
      elseif HasAuctionator() then
        unpriced = true
        right = right .. "   " .. GREY .. "no price|r"
      end
    end
    local name = meta.name or (C_Item and C_Item.GetItemNameByID and Try(C_Item.GetItemNameByID, item))
      or ("item " .. tostring(item))
    tooltip:AddDoubleLine(IconText(item) .. tostring(name), right, 1, 1, 1, 1, 1, 1)
  end
  if total > 0 or unpriced then
    tooltip:AddDoubleLine("Still to buy", GOLD .. "about " .. Money(total) .. "|r" .. (unpriced and " +" or ""),
      0.7, 0.7, 0.7, 1, 1, 1)
  else
    tooltip:AddLine("You have enough to make " .. (CanMake(t) or 1) .. " (bags and bank).", 0.25, 1, 0.25)
  end
  tooltip:AddLine(" ")
end

-- A goal's tooltip: the crafted item's own tooltip with its stats, then the materials (what
-- you have, what's needed, what the rest costs), then where the recipe comes from and what
-- the plan for it comes to.
local function GoalTooltip(t, plan)
  return function(tooltip)
    if ItemTooltip(tooltip, t.icon) then
      tooltip:AddLine(" ")
    else
      tooltip:AddLine(tostring(t.name), 1, 1, 1)
    end
    AddMaterials(tooltip, t, plan)
    for _, line in ipairs(type(t.tip) == "table" and t.tip or {}) do
      tooltip:AddLine(line, 1, 0.82, 0, true)
    end
    if t.no then
      tooltip:AddLine(t.no, 1, 0.25, 0.25, true)
    elseif t.summary then
      tooltip:AddLine(t.summary, 0.7, 0.7, 0.7, true)
    end
  end
end

-- After a pick, every level of the dropdown closes: the list you picked from and the one it
-- opened out of. ("Close" alone only shuts the innermost list.)
local function CloseDropdowns()
  if window then
    for _, dropdown in ipairs(window.goals or {}) do
      if type(dropdown.CloseMenu) == "function" then pcall(dropdown.CloseMenu, dropdown) end
    end
    if window.prof and type(window.prof.CloseMenu) == "function" then pcall(window.prof.CloseMenu, window.prof) end
  end
  return MenuResponse and (MenuResponse.CloseAll or MenuResponse.Close) or nil
end

-- Fills the goal dropdown each time it opens: the skill checkpoints first, then the recipes
-- in groups by where they come from. A goal that can't be planned yet is listed but can't be
-- picked.
-- `index` is which goal dropdown this is: the first, or one added below it for another goal.
local function GoalMenu(_, root, index)
  index = index or 1
  local plan = Plan()
  if not plan then return end
  if type(plan.targets) ~= "table" then plan = { targets = {}, groups = {} } end
  if type(plan.groups) ~= "table" then return end
  local byId = {}
  for _, t in ipairs(plan.targets) do byId[t.id] = t end
  local picked = PickedIds(plan)
  local elsewhere = {}
  for i, id in ipairs(picked) do
    if i ~= index then elsewhere[id] = true end
  end
  -- A dropdown holding one of several goals can give its goal up.
  if picked[index] and #picked > 1 and root.CreateButton then
    root:CreateButton("|cffff8040Remove this goal|r", function()
      ns.PlanPick(index, nil)
      return CloseDropdowns()
    end)
  end
  local function add(parent, t)
    local radio = parent:CreateRadio(GoalLabel(t, plan, true),
      function() return picked[index] == t.id end,
      function()
        ns.PlanPick(index, t.id)
        return CloseDropdowns()
      end, t.id)
    -- A goal already in another dropdown can't be picked twice.
    if elsewhere[t.id] and radio.SetEnabled then radio:SetEnabled(false) end
    if t.no and radio.SetEnabled then radio:SetEnabled(false) end
    if radio.SetTooltip then radio:SetTooltip(GoalTooltip(t, plan)) end
  end
  local recipesTitled = false
  for _, group in ipairs(plan.groups) do
    local ids = type(group.ids) == "table" and group.ids or {}
    if group.flat then
      root:CreateTitle(tostring(group.label))
      for _, id in ipairs(ids) do
        if byId[id] then add(root, byId[id]) end
      end
    else
      if not recipesTitled then
        root:CreateTitle("Recipes")
        recipesTitled = true
      end
      local sub = root:CreateButton((GROUP_COLOR[group.kind] or WHITE) .. tostring(group.label) .. "|r")
      -- Long groups scroll.
      if sub.SetScrollMode and #ids > 20 then sub:SetScrollMode(20 * 20) end
      if type(group.sections) == "table" and #group.sections > 0 then
        -- Tiers: a heading for each slot at each level, then every option for it.
        for _, section in ipairs(group.sections) do
          sub:CreateTitle(tostring(section.label))
          for _, id in ipairs(type(section.ids) == "table" and section.ids or {}) do
            if byId[id] then add(sub, byId[id]) end
          end
        end
      else
        for _, id in ipairs(ids) do
          if byId[id] then add(sub, byId[id]) end
        end
      end
    end
  end
end

-- The profession dropdown, above the goals: every profession that has goals.
local function ProfessionMenu(_, root)
  for _, name in ipairs(PlanNames()) do
    root:CreateRadio(name,
      function() return active == name end,
      function()
        ns.PlanShowProfession(name)
        return CloseDropdowns()
      end, name)
  end
end

----------------------------------------------------------------------
-- The window
----------------------------------------------------------------------

local WIDTH, HEIGHT = 384, 512
-- The header: everything shares one left edge (clear of the portrait) and one right edge, in
-- rows the same distance apart.
local HEADER_LEFT, HEADER_RIGHT, HEADER_ROW = 70, 14, 28
local ROW_WIDTH = WIDTH - 20 - 16 - 22 -- inset, padding, scroll bar

local function ProfessionIcon(name)
  if name and GetProfessions and GetProfessionInfo then
    for _, index in ipairs({ GetProfessions() }) do
      local profName, icon = GetProfessionInfo(index)
      if profName == name and icon then return icon end
    end
  end
  return [[Interface\Icons\INV_Misc_Note_01]]
end

local function Host()
  return _G.ProfessionsFrame or _G.TradeSkillFrame
end

-- The profession whose window is open right now, or nil.
local function OpenProfession()
  local host = Host()
  if not (host and host.IsShown and host:IsShown()) then return nil end
  local T = C_TradeSkillUI
  if T and T.GetBaseProfessionInfo then
    local base = Try(T.GetBaseProfessionInfo)
    local name = base and base.professionName
    if type(name) == "string" and name ~= "" then return name end
    local child = T.GetChildProfessionInfo and Try(T.GetChildProfessionInfo)
    name = child and child.professionName
    if type(name) == "string" and name ~= "" then return name end
    -- The game doesn't always name the profession. Its recipe list still says which it is:
    -- every recipe belongs to one profession.
    for i, recipe in ipairs(Try(T.GetAllRecipeIDs) or {}) do
      local known = ns.recipeProf and ns.recipeProf[recipe]
      if known then return known end
      if i >= 40 then break end
    end
  end
  if GetTradeSkillLine then
    local line = Try(GetTradeSkillLine)
    if type(line) == "string" and line ~= "" and line ~= "UNKNOWN" then return line end
  end
  return nil
end

ns.PlanOpenProfession = OpenProfession

-- How far past the profession window's right edge its own pieces stick out (the profession
-- tabs down its right side), so the plan sits beside them and not on top.
local function HostOverhang(host)
  local right = Try(host.GetRight, host)
  if not right then return 0 end
  local scale = host:GetEffectiveScale() or 1
  local top, bottom = host:GetTop() or 0, host:GetBottom() or 0
  local most = right
  local function scan(frame, depth)
    for _, child in ipairs({ frame:GetChildren() }) do
      -- Some of the game's frames are off limits to addons; touching them is an error.
      local forbidden = child.IsForbidden and child:IsForbidden()
      if not forbidden and child ~= window and child.IsShown and child:IsShown() then
        local r, t, b = child:GetRight(), child:GetTop(), child:GetBottom()
        if r and t and b then
          local k = (child:GetEffectiveScale() or scale) / scale
          r, t, b = r * k, t * k, b * k
          -- Only pieces level with the window count, not tooltips far above or below.
          if t <= top + 5 and b >= bottom - 5 and r > most and r < right + 150 then most = r end
        end
        if depth < 3 then scan(child, depth + 1) end
      end
    end
  end
  pcall(scan, host, 1)
  return most - right
end

-- The game windows the plan comes up beside (which steps each serves: StepAt, further down).
local VENUES = {
  auction  = { frames = { "AuctionHouseFrame", "AuctionFrame" } },
  merchant = { frames = { "MerchantFrame" } },
  trainer  = { frames = { "ClassTrainerFrame" } },
  bank     = { frames = { "BankFrame" } },
  mail     = { frames = { "MailFrame" } },
}
local venue -- the kind opened last and still open, or nil

-- A venue's window (whichever kind this client has), when it's open.
local function VenueWindow(kind)
  for _, name in ipairs(VENUES[kind] and VENUES[kind].frames or {}) do
    local frame = _G[name]
    if frame and frame.IsShown and frame:IsShown() then return frame end
  end
end

-- Where the window goes: beside the vendor, trainer, bank, mailbox or auction house you have
-- open; else beside the profession window, as tall as it is; else the right of the screen.
local function Place()
  local host = (venue and VenueWindow(venue)) or Host()
  window:ClearAllPoints()
  if host and host.IsShown and host:IsShown() then
    local gap = HostOverhang(host) + 2
    window:SetWidth(WIDTH)
    window:SetPoint("TOPLEFT", host, "TOPRIGHT", gap, 0)
    window:SetPoint("BOTTOMLEFT", host, "BOTTOMRIGHT", gap, 0)
  else
    window:SetSize(WIDTH, HEIGHT)
    window:SetPoint("RIGHT", UIParent, "RIGHT", -120, 40)
  end
end

local function RowTooltip(self)
  local step = self.step
  if not step then return end
  GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
  -- The item's own tooltip first (stats and all), then what this row is about.
  local shown = ItemTooltip(GameTooltip, step.icon or step.item)
  if shown then GameTooltip:AddLine(" ") end
  if step.title then
    GameTooltip:AddLine(step.title, 1, 1, 1, true)
    if step.sub then GameTooltip:AddLine(step.sub, 1, 0.82, 0, true) end
  elseif not shown or step.k then
    GameTooltip:AddLine(step.text or "", 1, 1, 1, true)
  end
  if step.note then GameTooltip:AddLine(step.note, 1, 0.82, 0, true) end
  -- Where it sends you, when any place of a kind will do: the nearest one you've been to.
  local place, _, _, placeName, npc = PlaceOf(step)
  if step.near then
    if place then
      GameTooltip:AddLine("Nearest: " .. tostring(npc and npc.name or placeName)
        .. ((npc and (npc.subzone or npc.zone)) and (" in " .. tostring(npc.subzone or npc.zone)) or ""), 0.7, 0.7, 0.7, true)
    else
      GameTooltip:AddLine(step.near == "crates" and "Where crates are handed in isn't recorded yet: it's remembered the first time you hand one in."
        or ("No " .. (NEAR_LABEL[step.near] or "place"):lower() .. " is recorded yet: visit one and it will be."),
        0.7, 0.7, 0.7, true)
    end
  end
  -- Pointing the way is TomTom's: without it, clicks only craft or search the auction house.
  if not HasTomTom() then place = nil end
  -- By way of a flight master, when that's quicker.
  if place then
    local _, px, py = PlaceOf(step)
    local stops = RouteTo(place, px, py, placeName or step.where or step.title)
    if #stops > 1 then GameTooltip:AddLine("Quickest: " .. RouteText(stops), 0.5, 0.8, 1, true) end
  end
  -- What a click does here.
  local hint
  if (step.k == "make" or step.k == "craft") and step.spell then
    hint = "Click to go to the recipe, fill in the amount and start crafting."
  elseif step.k == "collect" or step.k == "bank" then
    hint = place and "Click to point the way there." or nil
  elseif (step.k == "buy" or step.k == nil) and HasAuctionator() then
    hint = "Click to search the auction house when it's open" .. (place and ", or to point the way there." or ".")
  elseif place then
    hint = "Click to point the way there."
  end
  if hint then GameTooltip:AddLine(hint, 0.5, 0.8, 1, true) end
  GameTooltip:Show()
end

----------------------------------------------------------------------
-- Clicking a row
----------------------------------------------------------------------

-- How many of a recipe the materials on hand allow (bags and bank), from the recipe as the
-- profession window listed it. Nil when that isn't recorded.
local function Craftable(plan, spell)
  local c = ns.Char()
  local seen = c and c.recipes and plan.profession and c.recipes[plan.profession]
  local recipe = seen and seen.recipes and seen.recipes[spell]
  if not (recipe and type(recipe.reagents) == "table" and #recipe.reagents > 0) then return nil end
  local can
  for _, r in ipairs(recipe.reagents) do
    local times = math.floor(Count(r.id, true) / math.max(1, r.n or 1))
    if not can or times < can then can = times end
  end
  return can
end

-- Puts a number in the profession window's "how many" box.
local function FillAmount(count)
  local host = Host()
  local page = host and type(host.CraftingPage) == "table" and host.CraftingPage or nil
  local box = page and type(page.CreateMultipleInputBox) == "table" and page.CreateMultipleInputBox or nil
  if box and type(box.SetValue) == "function" and count and count > 0 then
    return (pcall(box.SetValue, box, count))
  end
  return false
end

-- Points TomTom's arrow at a step's place (by way of a flight master when that's quicker).
-- Returns false if the step has no place, or TomTom isn't installed.
local function PointTo(step)
  if not HasTomTom() then return false end
  local map, x, y, name = PlaceOf(step)
  if not map then return false end
  local stops = RouteTo(map, x, y, name or step.title or "the next stop")
  StartArrow("click", stops)
  ns.Print("arrow set to " .. RouteText(stops) .. ".")
  return true
end

-- With the auction house open, searches it for an item (through Auctionator). Returns false
-- when it isn't open or Auctionator isn't there.
local function AuctionSearch(plan, item)
  local open = (AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown())
    or (AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown())
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not (open and api and api.MultiSearchExact and item) then return false end
  local meta = type(plan.items) == "table" and plan.items[item] or nil
  local name = (meta and meta.name) or (C_Item and C_Item.GetItemNameByID and Try(C_Item.GetItemNameByID, item))
  if not name then return false end
  return (pcall(api.MultiSearchExact, "Quartermaster", { name }))
end

-- A crafting step: go to the recipe, fill in how many, start. The game only lets a craft be
-- started from a click, and only in the window of the recipe's own profession, so when that
-- window isn't open the first click opens it and the next one starts.
local function CraftStep(plan, step)
  local spell = step.spell
  local want = step.n or tonumber(tostring(step.sub or ""):match("(%d+) craft")) or 1
  if step.k == "make" then want = math.max(1, (step.n or 1) - (step.made or 0)) end
  local T = C_TradeSkillUI
  if not SelectInProfessionWindow(plan, "recipe:" .. tostring(spell)) then
    if T and T.OpenRecipe then pcall(T.OpenRecipe, spell) end
    C_Timer.After(0.6, function() ns.Run("planCraft", FillAmount, want) end)
    ns.Print("opening " .. tostring(plan.profession or "the profession") .. ". Click the step again to start crafting.")
    return
  end
  local can = Craftable(plan, spell)
  local count = (can and can < want) and can or want
  if can == 0 then
    ns.Print("you don't have the materials for that yet.")
    return
  end
  FillAmount(count)
  if T and T.CraftRecipe then
    if pcall(T.CraftRecipe, spell, count) then
      if can and can < want then
        ns.Print(("crafting %d of %d: that's what your materials allow."):format(count, want))
      end
      return
    end
  end
  ns.Print("the amount is filled in. Press Create to start.")
end

-- What the plan still needs from the auction house: { { item, name, n } }, the shortfall of every
-- material whose cheapest source is the auction house.
function ns.PlanShoppingItems()
  local v = View()
  local out = {}
  for _, mat in ipairs(v and v.mats or {}) do
    if mat.where == "auction house" and mat.item then
      local short = (mat.need or 0) - Count(mat.item, true)
      if short > 0 then
        local name = mat.name
        local real = C_Item and C_Item.GetItemNameByID and Try(C_Item.GetItemNameByID, mat.item)
        if type(real) == "string" and real ~= "" then name = real end
        out[#out + 1] = { item = mat.item, name = name, n = short }
      end
    end
  end
  return out
end

-- Hands the shopping list to Auctionator as one saved list, "Quartermaster", replaced each time,
-- with how many of each item is still needed. With the auction house open it also opens that
-- list in Auctionator's Shopping tab and searches it. (Auctionator's own quick-search makes a
-- separate "(temporary)" list without the counts, so that isn't used, and any left over from
-- an earlier version is removed.)
local LIST_NAME = "Quartermaster"
function ns.PlanShoppingList()
  local items = ns.PlanShoppingItems()
  if #items == 0 then
    ns.Print("nothing left to buy at the auction house for this plan.")
    return false
  end
  local api = Auctionator and Auctionator.API and Auctionator.API.v1
  if not (api and api.CreateShoppingList) then
    ns.Print("Auctionator isn't loaded, so there's no shopping list to make.")
    return false
  end
  local strings = {}
  for _, it in ipairs(items) do
    local str
    if api.ConvertToSearchString then
      local ok, made = pcall(api.ConvertToSearchString, "Quartermaster",
        { searchString = it.name, isExact = true, quantity = it.n })
      if ok then str = made end
    end
    strings[#strings + 1] = str or ('"' .. it.name .. '"')
  end
  if not pcall(api.CreateShoppingList, "Quartermaster", LIST_NAME, strings) then
    ns.Print("Auctionator couldn't make the shopping list.")
    return false
  end
  local manager = Auctionator.Shopping and Auctionator.Shopping.ListManager
  pcall(function()
    -- Lists from earlier versions of this addon.
    for _, old in ipairs({ "Quartermaster (temporary)", "Quartermaster (Temporary)" }) do
      if manager:GetIndexForName(old) then manager:Delete(old) end
    end
    for i = manager:GetCount(), 1, -1 do
      local name = manager:GetByIndex(i):GetName()
      if type(name) == "string" and name:find("^Quartermaster: ") then manager:Delete(name) end
    end
  end)
  ns.Print(('Auctionator shopping list "%s" has %d item%s, with how many of each you need.'):format(
    LIST_NAME, #items, #items == 1 and "" or "s"))
  local open = (AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown())
    or (AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown())
  if open then
    pcall(function()
      if AuctionatorTabs_Shopping then AuctionatorTabs_Shopping:Click() end
      local list = manager:GetByName(LIST_NAME)
      local bus = Auctionator.EventBus
      bus:RegisterSource(ns.PlanShoppingList, "Quartermaster shopping list")
        :Fire(ns.PlanShoppingList, Auctionator.Shopping.Tab.Events.ListSearchRequested, list)
        :UnregisterSource(ns.PlanShoppingList)
    end)
  else
    -- Not at the auction house: point the way to the nearest one you've used.
    PointTo({ near = "auctioneer" })
  end
  return true
end

-- What clicking a row does.
local function RowClick(self)
  local step, v = self.step, View()
  if not (step and v) then return end
  local plan, k = v.plan, step.k
  if (k == "make" or k == "craft") and step.spell then
    CraftStep(plan, step)
  elseif k == "auction" then
    -- The auction house stop: with it open, the Shopping list (made and searched); else the way there.
    local open = (AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown())
      or (AuctionFrame and AuctionFrame.IsShown and AuctionFrame:IsShown())
    if open then
      ns.PlanShoppingList()
    elseif not PointTo(step) then
      ns.Print("open the auction house and click this again for the shopping list.")
    end
  elseif k == "buy" or k == nil then
    -- A buying step, or a material: the auction house if it's open, else the way there.
    if AuctionSearch(plan, step.item) then return end
    if not PointTo(step) and k then
      if step.where then
        ns.Print("that's at " .. step.where .. ".")
      elseif HasAuctionator() then
        ns.Print("open the auction house and click this again to search for it.")
      end
    end
  elseif (k == "learn" or k == "rank" or k == "writ" or k == "sell" or k == "currency" or k == "collect" or k == "bank") and HasTomTom() then
    if not PointTo(step) then
      if step.near then
        ns.Print(step.near == "crates" and "where crates are handed in isn't recorded yet. It's remembered the first time you hand one in."
          or ("no " .. (NEAR_LABEL[step.near] or "place"):lower() .. " is recorded yet. Visit one and the arrow will know the way next time."))
      elseif step.sub then
        ns.Print(step.sub .. ".")
      end
    end
  end
end

local function NewRow(parent)
  local row = CreateFrame("Button", nil, parent)
  row:SetWidth(ROW_WIDTH)
  row:EnableMouse(true)
  if row.RegisterForClicks then row:RegisterForClicks("LeftButtonUp") end
  -- A faint highlight under the pointer, so rows read as clickable.
  local glow = row:CreateTexture(nil, "HIGHLIGHT")
  glow:SetAllPoints()
  glow:SetColorTexture(1, 1, 1, 0.08)
  row:SetScript("OnClick", RowClick)
  row:SetScript("OnEnter", RowTooltip)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  local ok, check = pcall(CreateFrame, "CheckButton", nil, row, "UICheckButtonTemplate")
  if ok and check then
    check:SetSize(22, 22)
    check:SetPoint("TOPLEFT", 0, -6)
    check:SetScript("OnClick", function(self) ns.PlanToggleStep(self.index) end)
    row.check = check
  end
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.top = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.top:SetJustifyH("LEFT")
  row.top:SetWordWrap(false)
  row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.tag:SetJustifyH("RIGHT")
  row.tag:SetWordWrap(false)
  row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.sub:SetJustifyH("LEFT")
  row.sub:SetWordWrap(true)
  return row
end

-- How old the auction prices behind a plan are: "Auction prices: today", "... 1 day old",
-- "... up to 3 days old" (orange past two days). Auctionator keeps prices by the day, so that's
-- as fine as it gets. Nil when nothing in the plan is priced at the auction house.
local function PriceAgeText(mats)
  if not (ns.P and ns.P.SeenDaysAgo) then return nil end
  local oldest
  for _, mat in ipairs(mats or {}) do
    if mat.where == "auction house" and mat.item then
      local ok, age = pcall(ns.P.SeenDaysAgo, mat.item)
      if ok and type(age) == "number" and (not oldest or age > oldest) then oldest = age end
    end
  end
  if not oldest then return nil end
  if oldest <= 0 then return GREY .. "Auction prices: today|r" end
  if oldest == 1 then return GREY .. "Auction prices: 1 day old|r" end
  return (oldest > 2 and "|cffff8040" or GREY) .. "Auction prices: up to " .. oldest .. " days old|r"
end

-- The materials table's columns, right to left: { key, label, right edge offset, width }.
-- The cost column is wide enough for "12g 34s 56c" on one line.
local MAT_COLS = {
  { "cost", "Cost", -4, 68 }, { "buy", "Buy", -74, 28 }, { "need", "Need", -104, 28 },
  { "bank", "Bank", -134, 28 }, { "bags", "Bags", -164, 28 },
}
local MAT_NAME_RIGHT = -196

-- Spacing inside the list, the same everywhere: the edge padding, and the gap between blocks.
local PAD, GAP = 4, 10

local function MatColumns(row)
  if row.cols then return row.cols end
  row.cols = {}
  for _, col in ipairs(MAT_COLS) do
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH("RIGHT")
    fs:SetWidth(col[4])
    if fs.SetWordWrap then fs:SetWordWrap(false) end
    fs:SetPoint("TOPRIGHT", row, "TOPRIGHT", col[3], -4)
    row.cols[col[1]] = fs
  end
  return row.cols
end

local function HideColumns(row)
  for _, fs in pairs(row.cols or {}) do fs:Hide() end
end

-- One step: tick box, icon, numbered title, progress on the right, colored detail below.
local function LayoutStep(row, i, step, current)
  row.step = step
  HideColumns(row)
  row.icon:ClearAllPoints(); row.top:ClearAllPoints(); row.tag:ClearAllPoints(); row.sub:ClearAllPoints()
  if row.check then
    row.check.index = i
    row.check:SetChecked(step.done and true or false)
    row.check:Show()
  end
  row.icon:SetSize(28, 28)
  row.icon:SetPoint("TOPLEFT", 24, -3)
  row.icon:SetTexture((step.icon and Try(GetItemIcon, step.icon)) or (step.item and Try(GetItemIcon, step.item))
    or QUESTION_MARK)
  if row.icon.SetDesaturated then row.icon:SetDesaturated(step.done and true or false) end
  row:SetAlpha(step.done and 0.6 or 1)

  -- Progress, on the right: red while short, green when there.
  local tag = ""
  if step.done then
    tag = GREEN .. "done|r"
  else
    local have, need = Progress(step)
    if have and need then
      tag = (have >= need and GREEN or RED) .. have .. "/" .. need .. "|r"
    elseif step.k == "sell" and step.item then
      local left = Count(step.item, false)
      if left > 0 then tag = GOLD .. left .. " in bags|r" end
    end
  end
  row.tag:SetPoint("TOPRIGHT", -2, -4)
  row.tag:SetText(tag)

  -- The step you're on is gold, like a tracked quest; later ones white; finished ones grey.
  local title = tostring(step.title or step.text or "")
  row.top:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -1)
  row.top:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
  row.top:SetText((step.done and GREY or (i == current and GOLD or WHITE)) .. i .. ". " .. title .. "|r")

  local sub = step.sub
  row.sub:SetPoint("TOPLEFT", row.top, "BOTTOMLEFT", 0, -3)
  row.sub:SetPoint("RIGHT", row, "RIGHT", -2, 0)
  row.sub:SetText(sub and ((step.done and GREY or KIND_COLOR[step.k] or WHITE) .. sub .. "|r") or "")
  local h = math.max(34, 20 + (sub and (row.sub:GetStringHeight() or 10) or 0) + 4)
  row:SetHeight(h)
  return h
end

-- One material: small icon, name, what you have against what the plan needs, and what the
-- part you're short would cost. Returns the row's height and that cost.
-- One material as a table row: name, then how many are in your bags, in your bank, how many the
-- plan needs, how many you still have to buy (red), and what those cost.
-- Returns the row's height and that cost.
local function LayoutMat(row, mat)
  local need = mat.need or 0
  local bags = Count(mat.item, false)
  local bank = math.max(0, Count(mat.item, true) - bags)
  local short = math.max(0, need - bags - bank)
  local cost = (short > 0 and mat.each) and short * mat.each or 0
  -- Where to get it, for a click: its vendor, or the nearest auctioneer.
  row.step = { item = mat.item, text = mat.name, map = mat.map, x = mat.x, y = mat.y, near = mat.near,
    where = mat.where ~= "auction house" and mat.where or nil }
  if mat.each then
    row.step.note = (mat.guess and "About " or "") .. Money(mat.each) .. " each at "
      .. (mat.where == "auction house" and "the auction house" or tostring(mat.where or "a vendor"))
      .. (mat.guess and " (an estimate: you haven't opened this vendor yet)" or "")
  end
  -- What your other characters could mail over: "(+12 on Ana Brightwood)".
  if mat.also then row.step.note = (row.step.note and (row.step.note .. "  ") or "") .. "(" .. mat.also .. ")" end
  row.icon:ClearAllPoints(); row.top:ClearAllPoints(); row.tag:ClearAllPoints(); row.sub:ClearAllPoints()
  if row.check then row.check:Hide() end
  row:SetAlpha(1)
  row.icon:SetSize(16, 16)
  row.icon:SetPoint("TOPLEFT", 4, -2)
  row.icon:SetTexture(Try(GetItemIcon, mat.item) or QUESTION_MARK)
  if row.icon.SetDesaturated then row.icon:SetDesaturated(false) end
  row.tag:SetText("")
  row.top:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 5, -2)
  row.top:SetPoint("RIGHT", row, "RIGHT", MAT_NAME_RIGHT, 0)
  row.top:SetText(WHITE .. tostring(mat.name or ("item " .. tostring(mat.item))) .. "|r")
  row.sub:SetText("")
  local cols = MatColumns(row)
  local function num(n, color) return n > 0 and (color .. n .. "|r") or (GREY .. "-|r") end
  cols.bags:SetText(num(bags, WHITE))
  cols.bank:SetText(num(bank, WHITE))
  cols.need:SetText(WHITE .. need .. "|r")
  cols.buy:SetText(short > 0 and (RED .. short .. "|r") or (GREEN .. "0|r"))
  cols.cost:SetText(short == 0 and "" or (mat.each and (GOLD .. Money(cost) .. "|r")
    or (HasAuctionator() and (GREY .. "no price|r") or "")))
  for _, fs in pairs(cols) do fs:Show() end
  row:SetHeight(20)
  return 20, cost
end

local function Build()
  if window then return window end
  local name = "QuartermasterPlanFrame"
  local frame = CreateFrame("Frame", name, UIParent, "PortraitFrameTemplate")
  -- Escape closes it, like the game's own windows.
  if UISpecialFrames then table.insert(UISpecialFrames, name) end
  frame:SetSize(WIDTH, HEIGHT)
  frame:SetFrameStrata("MEDIUM")
  frame:SetToplevel(true)
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  -- Dragged, it stays where you put it until it next opens. Where it was dragged to is never
  -- remembered: it opens beside the profession window, or at the right of the screen.
  frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  -- Closing it yourself keeps it closed until the profession window is opened again, or you
  -- ask for it.
  frame:SetScript("OnHide", function()
    if not frame.hiddenByCode then dismissed = true end
  end)

  -- Two dropdowns at the top, the game's own (as its settings windows use): which profession,
  -- then which goal.
  local okProf, prof = pcall(CreateFrame, "DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
  if okProf and prof and prof.SetupMenu then
    prof:SetPoint("TOPLEFT", HEADER_LEFT, -32)
    prof:SetPoint("RIGHT", frame, "RIGHT", -HEADER_RIGHT, 0)
    prof:SetHeight(24)
    pcall(prof.SetupMenu, prof, ProfessionMenu)
    prof:Hide()
    frame.prof = prof
  end
  -- One goal dropdown for each goal picked, and one more below them to add another.
  frame.goals = {}
  function frame.GoalDropdown(i)
    if frame.goals[i] then return frame.goals[i] end
    local okGoal, goal = pcall(CreateFrame, "DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
    if not (okGoal and goal and goal.SetupMenu) then return nil end
    goal:SetPoint("TOPLEFT", HEADER_LEFT, -32 - i * HEADER_ROW)
    goal:SetPoint("RIGHT", frame, "RIGHT", -HEADER_RIGHT, 0)
    goal:SetHeight(24)
    pcall(goal.SetupMenu, goal, function(dropdown, root) GoalMenu(dropdown, root, i) end)
    goal:Hide()
    frame.goals[i] = goal
    return goal
  end
  frame.goal = frame.GoalDropdown(1)

  frame.summary = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  -- The text lines up with the text inside the dropdowns above it.
  -- One line, in its own row under the goal dropdown.
  frame.summary:SetPoint("TOPLEFT", HEADER_LEFT + 8, -32 - 2 * HEADER_ROW - 6)
  frame.summary:SetPoint("RIGHT", frame, "RIGHT", -HEADER_RIGHT - 4, 0)
  frame.summary:SetJustifyH("LEFT")
  frame.summary:SetWordWrap(true)
  -- Hovering the cost line shows the full breakdown.
  local hover = CreateFrame("Frame", nil, frame)
  hover:SetPoint("TOPLEFT", frame.summary, "TOPLEFT", 0, 2)
  hover:SetPoint("BOTTOMRIGHT", frame.summary, "BOTTOMRIGHT", 0, -2)
  hover:EnableMouse(true)
  hover:SetScript("OnEnter", CostTooltip)
  hover:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.costHover = hover

  local inset = CreateFrame("Frame", nil, frame, "InsetFrameTemplate")
  inset:SetPoint("TOPLEFT", 10, -32 - 3 * HEADER_ROW)
  inset:SetPoint("BOTTOMRIGHT", -10, 34)
  frame.inset = inset

  local scroll = CreateFrame("ScrollFrame", nil, inset, "ScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -8)
  scroll:SetPoint("BOTTOMRIGHT", -28, 8)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(ROW_WIDTH, 10)
  scroll:SetScrollChild(content)
  frame.content = content

  frame.matsTitle = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  frame.matsTitle:SetJustifyH("LEFT")
  frame.matsTitle:SetText("Materials")
  frame.matsNote = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  frame.matsNote:SetJustifyH("RIGHT")
  -- Beside the total, on the left: how old the auction prices are.
  frame.priceAge = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  frame.priceAge:SetJustifyH("LEFT")
  frame.priceAge:Hide()
  -- Under the total: how much gold you're short, when you are.
  frame.matsShort = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  frame.matsShort:SetJustifyH("RIGHT")
  frame.matsShort:SetWidth(ROW_WIDTH - 2 * PAD)
  frame.matsShort:SetWordWrap(true)
  frame.matsShort:Hide()
  -- Column headings for the materials table.
  local head = CreateFrame("Frame", nil, content)
  head:SetSize(ROW_WIDTH, 14)
  head.labels = {}
  for _, col in ipairs(MAT_COLS) do
    local fs = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetJustifyH("RIGHT")
    fs:SetWidth(col[4])
    fs:SetPoint("TOPRIGHT", head, "TOPRIGHT", col[3], 0)
    fs:SetText(col[2])
    head.labels[col[1]] = fs
  end
  head:Hide()
  frame.matsHead = head
  -- Shown under the materials when Auctionator isn't installed, so a low cost isn't mistaken
  -- for the whole cost.
  frame.noAuction = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  frame.noAuction:SetJustifyH("LEFT")
  frame.noAuction:SetText("No Auctionator data: costs count vendor prices only.")
  frame.noAuction:Hide()
  frame.stepsTitle = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  frame.stepsTitle:SetJustifyH("LEFT")
  frame.stepsTitle:SetText("Steps")

  -- Everything still to buy at the auction house, as one Auctionator shopping list.
  local okShop, shop = pcall(CreateFrame, "Button", nil, content, "SharedButtonSmallTemplate")
  if not okShop or not shop then shop = CreateFrame("Button", nil, content, "UIPanelButtonTemplate") end
  shop:SetSize(96, 20)
  shop:SetText("Shopping list")
  shop:SetScript("OnClick", function() ns.PlanShoppingList() end)
  shop:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Auction house shopping list")
    GameTooltip:AddLine("Puts everything this plan still needs from the auction house into Auctionator's "
      .. "\"Quartermaster\" shopping list, with how many of each. With the auction house open, it searches it too.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  shop:SetScript("OnLeave", function() GameTooltip:Hide() end)
  shop:Hide()
  frame.shop = shop

  local okButton, clear = pcall(CreateFrame, "Button", nil, frame, "SharedButtonSmallTemplate")
  if not okButton or not clear then clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate") end
  clear:SetSize(110, 22)
  clear:SetPoint("BOTTOMRIGHT", -12, 8)
  clear:SetText("Refresh")
  clear:SetScript("OnClick", function() ns.PlanRefresh() end)
  clear:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Refresh")
    GameTooltip:AddLine("Works the plan out again from what you have right now: your bags, bank, gold, skill, "
      .. "and the latest vendor and auction prices. It also happens by itself each time this window opens "
      .. "or you pick a goal.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  clear:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.refresh = clear

  frame.progress = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  frame.progress:SetPoint("BOTTOMLEFT", 14, 14)

  frame.hiddenByCode = true
  frame:Hide()
  frame.hiddenByCode = nil
  window = frame
  return frame
end

-- Hides the window without it counting as you closing it.
local function HideQuietly()
  if window and window:IsShown() then
    window.hiddenByCode = true
    window:Hide()
    window.hiddenByCode = nil
  end
end

function Refresh()
  if not window or not window:IsShown() then return end
  local v = View()
  if not v then
    HideQuietly()
    return
  end
  local plan = v.plan
  if window.SetTitle then window:SetTitle(v.title or plan.title or "Plan") end
  -- The profession dropdown always shows which profession this is.
  if window.prof then
    window.prof:Show()
    local set = window.prof.OverrideText or window.prof.SetDefaultText or window.prof.SetText
    if set then pcall(set, window.prof, tostring(active or plan.profession or "Plan")) end
  end
  -- A goal dropdown for each goal picked, and one more under them to add another. Everything
  -- below moves down a row for each.
  local goalRows = 0
  local hasGoals = type(plan.targets) == "table" and #plan.targets > 0
  if hasGoals then
    local picked = PickedIds(plan)
    goalRows = math.min(#picked + ((plan.fixed or #picked == 0) and 0 or 1), MAX_GOALS)
    if goalRows < 1 then goalRows = 1 end
    for i = 1, goalRows do
      local dropdown = window.GoalDropdown(i)
      if dropdown then
        local t = picked[i] and Target(plan, picked[i])
        local label = t and GoalLabel(t, plan)
          or (i == 1 and (tostring(plan.profession or "Plan") .. ": pick a goal") or (GREY .. "Add another goal...|r"))
        local set = dropdown.OverrideText or dropdown.SetDefaultText or dropdown.SetText
        if set then pcall(set, dropdown, label) end
        dropdown:Show()
      end
    end
  end
  for i = goalRows + 1, #window.goals do window.goals[i]:Hide() end
  window.headerRows = goalRows
  window.summary:ClearAllPoints()
  window.summary:SetPoint("TOPLEFT", HEADER_LEFT + 8, -32 - (goalRows + 1) * HEADER_ROW - 6)
  window.summary:SetPoint("RIGHT", window, "RIGHT", -HEADER_RIGHT - 4, 0)
  local icon = ProfessionIcon(plan.profession)
  if window.SetPortraitToAsset then
    window:SetPortraitToAsset(icon)
  elseif window.GetPortrait then
    local portrait = window:GetPortrait()
    if portrait then portrait:SetTexture(icon) end
  end
  window.summary:SetText(CostText(v) or v.summary or "")
  if window.inset then
    window.inset:ClearAllPoints()
    window.inset:SetPoint("TOPLEFT", 10, -32 - (goalRows + 2) * HEADER_ROW)
    window.inset:SetPoint("BOTTOMRIGHT", -10, 34)
  end

  local current = CurrentStep(v)
  local y, used, done = 0, 0, 0
  local function row()
    used = used + 1
    local r = rows[used]
    if not r then
      r = NewRow(window.content)
      rows[used] = r
    end
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", 0, -y)
    r:Show()
    return r
  end

  -- Materials first: what you have, what the plan needs, and what the missing part costs.
  local mats = v.mats or {}
  if #mats > 0 then
    y = y + PAD
    window.matsTitle:ClearAllPoints()
    window.matsTitle:SetPoint("TOPLEFT", PAD, -y)
    window.matsTitle:Show()
    y = y + 18
    window.matsHead:ClearAllPoints()
    window.matsHead:SetPoint("TOPLEFT", 0, -y)
    window.matsHead:Show()
    y = y + 16
    local toBuy, unpriced = 0, false
    for _, mat in ipairs(mats) do
      local h, cost = LayoutMat(row(), mat)
      y = y + h
      toBuy = toBuy + cost
      if not mat.each and HasAuctionator() and Count(mat.item, true) < (mat.need or 0) then unpriced = true end
    end
    -- The total sits under the table, at the foot of the Cost column; under it, how much gold
    -- you're short, if you are.
    y = y + PAD
    window.matsNote:SetText(toBuy > 0 and (GOLD .. "about " .. Money(toBuy) .. " still to buy|r" .. (unpriced and " +" or ""))
      or (unpriced and (GREY .. "some have no price|r") or (GREEN .. "you have everything|r")))
    window.matsNote:ClearAllPoints()
    window.matsNote:SetPoint("TOPRIGHT", window.content, "TOPRIGHT", -PAD, -y)
    window.matsNote:Show()
    local age = PriceAgeText(mats)
    window.priceAge:SetShown(age ~= nil)
    if age then
      window.priceAge:SetText(age)
      window.priceAge:ClearAllPoints()
      window.priceAge:SetPoint("TOPLEFT", PAD, -y)
    end
    y = y + 14
    local short = ShortText(v)
    window.matsShort:SetShown(short ~= nil)
    if short then
      window.matsShort:SetText(short)
      window.matsShort:ClearAllPoints()
      window.matsShort:SetPoint("TOPRIGHT", window.content, "TOPRIGHT", -PAD, -y - 2)
      y = y + 2 + math.max(12, window.matsShort:GetStringHeight() or 12)
    end
    if window.noAuction then
      window.noAuction:ClearAllPoints()
      window.noAuction:SetPoint("TOPLEFT", PAD, -y - 2)
      window.noAuction:SetShown(not HasAuctionator())
      if not HasAuctionator() then y = y + 16 end
    end
    -- The shopping list button, centered under that, when there's anything to get at the auction house.
    local ahShort = HasAuctionator() and #ns.PlanShoppingItems() > 0
    if window.shop then
      window.shop:ClearAllPoints()
      window.shop:SetPoint("TOP", window.content, "TOP", 0, -y - GAP)
      window.shop:SetShown(ahShort)
      if ahShort then y = y + GAP + 20 end
    end
    y = y + GAP
    window.stepsTitle:ClearAllPoints()
    window.stepsTitle:SetPoint("TOPLEFT", PAD, -y)
    window.stepsTitle:Show()
    y = y + 18 + PAD
  else
    window.matsTitle:Hide()
    window.matsNote:Hide()
    window.matsShort:Hide()
    window.priceAge:Hide()
    if window.noAuction then window.noAuction:Hide() end
    if window.matsHead then window.matsHead:Hide() end
    window.stepsTitle:Hide()
  end

  for i, step in ipairs(v.steps) do
    y = y + LayoutStep(row(), i, step, current)
    if step.done then done = done + 1 end
  end
  for i = used + 1, #rows do rows[i]:Hide() end
  window.content:SetHeight(math.max(10, y + 8))
  local working = ns.Planner.Pending(plan) or (active and ns.Planner.Busy(active))
  window.progress:SetText(working and "Working it out..." or (done .. " of " .. #v.steps .. " steps done"))
end

-- When the profession window closes, the plan goes with it, however it was opened.
local hooked = {}
local lastOpen -- the profession the profession window was last seen showing
local function OnHostHidden()
  dismissed = false
  lastOpen = nil
  -- A plan you opened yourself stays until you close it; it only moves.
  if window and window:IsShown() and not window.auto then
    Place()
  else
    HideQuietly()
  end
end
-- A "Plan" button on the profession window itself, top right, level with the skill bar, to
-- show or hide the plan. It's built on the game's own small button and drawn above the
-- profession window's own pieces so nothing can cover it. To mark it as an addon's and not the
-- game's, it's tinted blue and carries the addon's scroll icon.
local function MakeToggle(host)
  if ns.planToggle or not host then return end
  local ok, b = pcall(CreateFrame, "Button", "QuartermasterPlanToggle", host, "SharedButtonSmallTemplate")
  if not ok or not b then b = CreateFrame("Button", "QuartermasterPlanToggle", host, "UIPanelButtonTemplate") end
  ns.planToggle = b
  b:SetSize(64, 22)
  b:SetText("Plan")
  b:SetPoint("TOPRIGHT", host, "TOPRIGHT", -24, -38)
  -- The game's button art is red; grey it and tint it blue. The pieces differ between button
  -- templates, so every one that exists is tinted.
  local function tint(texture)
    if texture and texture.SetVertexColor then
      if texture.SetDesaturated then texture:SetDesaturated(true) end
      texture:SetVertexColor(0.35, 0.65, 1)
    end
  end
  pcall(function()
    for _, key in ipairs({ "Left", "Middle", "Right", "Center" }) do tint(b[key]) end
    for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture" }) do
      if b[get] then tint(b[get](b)) end
    end
  end)
  -- The addon's icon at the left, with the label moved over to make room.
  pcall(function()
    local icon = b:CreateTexture(nil, "OVERLAY")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", b, "LEFT", 8, 0)
    icon:SetTexture([[Interface\Icons\INV_Scroll_03]])
    b.icon = icon
    local label = b.GetFontString and b:GetFontString()
    if label then
      label:ClearAllPoints()
      label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
      if label.SetTextColor then label:SetTextColor(1, 1, 1) end
    end
  end)
  b:SetFrameStrata("HIGH")
  b:SetFrameLevel(50)
  b:SetScript("OnClick", function() ns.PlanToggleFromProfession() end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Quartermaster plan")
    GameTooltip:AddLine("Click to show or hide your plan for this profession.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:Show()
  -- Where it ended up, kept in the saved data so a problem can be worked out from there.
  C_Timer.After(1, function()
    ns.Run("planToggle", function()
      if not ns.db then return end
      ns.db.account.ui.toggle = {
        host = host.GetName and host:GetName() or "?", hostShown = host.IsShown and host:IsShown() and true or false,
        hostWidth = ns.Round(host.GetWidth and host:GetWidth(), 0), hostHeight = ns.Round(host.GetHeight and host:GetHeight(), 0),
        hostRight = ns.Round(host.GetRight and host:GetRight(), 0), hostTop = ns.Round(host.GetTop and host:GetTop(), 0),
        left = ns.Round(b.GetLeft and b:GetLeft(), 0), top = ns.Round(b.GetTop and b:GetTop(), 0),
        visible = b.IsVisible and b:IsVisible() and true or false,
        template = b.template or nil, at = time(),
      }
    end)
  end)
end

local function HookHost()
  local host = Host()
  if host and not ns.planToggle then ns.Run("planToggle", MakeToggle, host) end
  if host and not hooked[host] and host.HookScript then
    hooked[host] = true
    pcall(host.HookScript, host, "OnHide", OnHostHidden)
    -- Some clients don't send the "profession window opened" event every time; the window
    -- showing is the surest sign.
    pcall(host.HookScript, host, "OnShow", function()
      if ns.PlanQueueFollow then ns.PlanQueueFollow() end
    end)
  end
end

-- Shows the window. `auto` means a game window brought it up (the profession window, or with
-- `byVenue` a vendor, trainer, bank, mailbox or the auction house), so it leaves with it.
local function Show(auto, byVenue)
  if not Plan() then return false end
  HookHost()
  Build()
  window.auto = auto and true or nil
  window.byVenue = (auto and byVenue) and true or nil
  Place()
  window:Show()
  -- Each time it comes up, the goals are brought up to date with what you have now.
  Want()
  Refresh()
  return true
end

function ns.ShowPlan()
  dismissed = false
  return Show(false)
end

function ns.TogglePlan()
  if window and window:IsShown() then
    window:Hide()
    return false
  end
  return ns.ShowPlan()
end

-- Brings up the plan of whichever profession's window is open, and takes it away when that
-- window closes or shows a profession with no plan.
local followTries = 0
local FollowProfession
function FollowProfession()
  HookHost()
  local host = Host()
  local hostShown = host and host.IsShown and host:IsShown()
  local open = OpenProfession()
  if hostShown and not open then
    -- The window is open but the game hasn't said which profession it is yet. That takes a
    -- moment some of the time; look again shortly, without hiding anything.
    if followTries < 20 then
      followTries = followTries + 1
      C_Timer.After(0.25, function() ns.Run("planFollow", FollowProfession) end)
    end
    return
  end
  followTries = 0
  if not open then
    if window and window:IsShown() and window.auto then HideQuietly() end
    return
  end
  if open ~= lastOpen then
    -- The profession window opened, or switched to another profession: show that one's goals.
    lastOpen = open
    dismissed = false
    if SetActive(open) then
      if window and window:IsShown() then
        Place()
        Want()
        Refresh()
      else
        Show(true)
      end
    elseif window and window:IsShown() and window.auto then
      HideQuietly()
    end
  elseif not dismissed and not (window and window:IsShown()) and SetActive(open) then
    -- Same profession window as before, and the plan isn't up though it should be.
    Show(true)
  end
  -- Otherwise the profession window hasn't changed: whatever you're browsing in the plan
  -- (another profession's goals, say) stays as it is.
end

-- The button on the profession window: shows or hides the plan.
function ns.PlanToggleFromProfession()
  if window and window:IsShown() then
    window:Hide()
    return false
  end
  local open = OpenProfession()
  if open then SetActive(open) end
  if ns.ShowPlan() then return true end
  ns.Print("this character has no professions to plan for yet.")
  return false
end

-- Works the goals that are showing out again, from what you have right now.
function ns.PlanRefresh()
  if not active then Plan() end
  if active then ns.Planner.Rebuild(active) end
  Refresh()
end

-- Called when a profession's goals, or a goal's plan, have been worked out.
function ns.PlanUpdated(profession, rebuilt)
  ForgetViews()
  if profession == active then
    -- A dropdown left open would go on showing the goals as they were.
    if rebuilt then CloseDropdowns() end
  end
  Check()
end

-- At a vendor, trainer, bank, mailbox or the auction house: the plan you last looked at comes
-- up beside that window only when that very window serves a step still to do, and goes away
-- with it. A plan that's already up moves beside such a window and stays. A window with nothing
-- for the plan (a class or pet trainer, Beast Training, a vendor selling none of it) is left alone.
local function NpcName()
  local name = Try(UnitName, "npc")
  return ns.Plain(name) and name or nil
end

-- What a "Learn X" step teaches.
local function LearnName(step)
  return type(step.title) == "string" and step.title:match("^Learn (.+)$") or nil
end

-- Does the open vendor sell this item, or (by name) the pattern for this recipe?
local function MerchantSells(item, recipe)
  for i = 1, Try(GetMerchantNumItems) or 0 do
    local id = (GetMerchantItemID and Try(GetMerchantItemID, i)) or ns.ItemID(GetMerchantItemLink and Try(GetMerchantItemLink, i))
    if item and id == item then return true end
    if recipe then
      local info = C_MerchantFrame and C_MerchantFrame.GetItemInfo and Try(C_MerchantFrame.GetItemInfo, i)
      local name = (info and info.name) or (GetMerchantItemInfo and Try(GetMerchantItemInfo, i))
      if ns.Plain(name) and type(name) == "string" and (name == recipe or name:sub(-#recipe - 2) == ": " .. recipe) then
        return true
      end
    end
  end
  return false
end

-- Does the open trainer teach this profession, or this recipe by name? Never a class or pet
-- trainer, and never a trainer window with no NPC behind it (Beast Training).
local function TrainerTeaches(profession, recipe)
  if not NpcName() then return false end
  if IsTradeskillTrainer and not Try(IsTradeskillTrainer) then return false end
  for i = 1, Try(GetNumTrainerServices) or 0 do
    local name = Try(GetTrainerServiceInfo, i)
    if recipe and ns.Plain(name) and name == recipe then return true end
    if profession then
      local skill = Try(GetTrainerServiceSkillReq, i)
      local line = GetTrainerServiceSkillLine and Try(GetTrainerServiceSkillLine, i)
      if (ns.Plain(skill) and skill == profession) or (ns.Plain(line) and line == profession) then return true end
    end
  end
  return false
end

local function StepAt(kind, step)
  local k = step.k
  if kind == "auction" then return k == "auction" or step.near == "auctioneer" end
  if kind == "bank" then return k == "bank" end
  if kind == "mail" then return k == "collect" end
  if step.near == "auctioneer" then return false end
  local npc = NpcName()
  local named = npc and step.where == npc
  if kind == "merchant" then
    if k == "buy" then return named or MerchantSells(step.item) end
    if k == "learn" then return named or MerchantSells(nil, LearnName(step)) end
  elseif kind == "trainer" then
    if k == "rank" then return TrainerTeaches(step.profession or active) end
    if k == "learn" then return TrainerTeaches(nil, LearnName(step)) or (named and TrainerTeaches(active)) end
  end
  return false
end

local function VenueWanted(kind)
  local v = View()
  for _, step in ipairs(v and v.steps or {}) do
    if not step.done and StepAt(kind, step) then return true end
  end
  return false
end

local function OnVenueOpen(kind)
  -- Only once you've looked at a plan on this character, and only at a window the plan has
  -- something to do at.
  local c = ns.Char()
  if not (c and c.planShown) or not Plan() or not VenueWanted(kind) then return end
  venue = kind
  if window and window:IsShown() then
    Place()
  else
    Show(true, true)
  end
end

local function OnVenueClosed(kind)
  if venue ~= kind then return end
  venue = nil
  if not (window and window:IsShown()) then return end
  local host = Host()
  if window.auto and window.byVenue and not (host and host.IsShown and host:IsShown()) then
    HideQuietly()
  else
    window.byVenue = nil
    Place()
  end
end

----------------------------------------------------------------------
-- When to look
----------------------------------------------------------------------

for _, event in ipairs({ "BAG_UPDATE_DELAYED", "SKILL_LINES_CHANGED", "NEW_RECIPE_LEARNED",
  "TRADE_SKILL_LIST_UPDATE", "PLAYERBANKSLOTS_CHANGED", "MERCHANT_UPDATE", "PLAYER_MONEY",
  "CURRENCY_DISPLAY_UPDATE", "UPDATE_FACTION" }) do
  ns.On(event, function() if Plan() then ns.Later("planCheck", 1, Check) end end)
end
ns.On("UNIT_SPELLCAST_SUCCEEDED", OnCraft)
ns.On("PLAYER_ENTERING_WORLD", function()
  ns.Later("planCheck", 5, Check)
  -- TomTom says when you reach (or remove) the arrow, and what its arrow points at.
  if HasTomTom() and TomTom.RegisterCallback and not ns.tomtomHooked then
    ns.tomtomHooked = pcall(TomTom.RegisterCallback, ns, "WaypointRemoved", function(_, uid)
      ns.PlanWaypointRemoved(uid)
    end)
    pcall(TomTom.RegisterCallback, ns, "ArrowTargetChanged", function(_, uid)
      ns.PlanArrowTarget(uid)
    end)
  end
end)
ns.On("PLAYER_LOGIN", function()
  -- Window positions saved by earlier versions aren't used any more.
  local ui = ns.db and ns.db.account.ui
  if ui then ui.plan, ui.planClosed, ui.planLayout = nil, nil, nil end
end)

-- The plan follows the profession window in and out of combat alike (it's an ordinary window),
-- so this doesn't wait for combat to end the way the recording does.
local followQueued = false
local function QueueFollow()
  if followQueued or not Plan() then return end
  followQueued = true
  C_Timer.After(0.15, function()
    followQueued = false
    followTries = 0
    ns.Run("planFollow", FollowProfession)
  end)
end
ns.PlanQueueFollow = QueueFollow
for _, event in ipairs({ "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED" }) do
  ns.On(event, function() ForgetViews() if Plan() then ns.Later("planCheck", 1, Check) end end)
end
-- The game's window shows a moment after its event, so the plan waits before going beside it.
for kind, events in pairs({ auction = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" },
  merchant = { "MERCHANT_SHOW", "MERCHANT_CLOSED" }, trainer = { "TRAINER_SHOW", "TRAINER_CLOSED" },
  bank = { "BANKFRAME_OPENED", "BANKFRAME_CLOSED" }, mail = { "MAIL_SHOW", "MAIL_CLOSED" } }) do
  ns.On(events[1], function() C_Timer.After(0.3, function() ns.Run("planVenue", OnVenueOpen, kind) end) end)
  ns.On(events[2], function() ns.Run("planVenue", OnVenueClosed, kind) end)
end
-- A trainer's list can arrive after its window: look again when it does.
ns.On("TRAINER_UPDATE", function()
  if venue ~= "trainer" and VenueWindow("trainer") then ns.Run("planVenue", OnVenueOpen, "trainer") end
end)
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_DATA_SOURCE_CHANGED", "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_DETAILS_UPDATE" }) do
  ns.On(event, QueueFollow)
end
-- The profession window exists only once the game has loaded it; hook it as soon as it does.
ns.On("ADDON_LOADED", function() if Host() then HookHost() end end)
ns.On("PLAYER_ENTERING_WORLD", function() if Host() then HookHost() end end)
ns.On("TRADE_SKILL_CLOSE", OnHostHidden)
