-- Item tooltips: how many of the item you have, and where. One line per character that holds
-- some (bags, bank, mail), for this character and your others on the same ruleset and faction
-- (the ones it could trade or mail with), then a total.
--
-- This character's bags are counted live. Banks and mail are as recorded, so they're only as
-- fresh as the last visit. Nothing is shown when the only ones are in this character's bags:
-- the game already says so.

local _, ns = ...

local Try = ns.Try

local function list(t) return type(t) == "table" and t or {} end

-- How many of an item one recorded section holds ("bags", "bank", "accountBank").
local function InSection(c, section, id)
  local n = 0
  for _, it in ipairs(list(c[section] and c[section].items)) do
    if it.id == id then n = n + (it.n or 1) end
  end
  return n
end

local function InMail(c, id)
  local n = 0
  for _, msg in ipairs(list(c.mail and c.mail.messages)) do
    for _, it in ipairs(list(msg.items)) do
      if it.id == id then n = n + (it.n or 1) end
    end
  end
  return n
end

-- Whether two of your characters could trade or mail: same ruleset and faction.
local function CanShare(a, b)
  local ia = type(a.info) == "table" and a.info or {}
  local ib = type(b.info) == "table" and b.info or {}
  return ia.ruleset ~= nil and ia.ruleset == ib.ruleset and ia.faction ~= nil and ia.faction == ib.faction
end

-- What this character carries right now, asked from the game; nil if it won't say.
local function LiveBags(id)
  local count = (C_Item and C_Item.GetItemCount) or GetItemCount
  local n = Try(count, id)
  return ns.Plain(n) and type(n) == "number" and n or nil
end

-- Everyone who holds the item, this character first:
-- { { key, name, classFile, bags, bank, mail, total, me }, ... }, plus the account bank's count.
function ns.ItemCounts(id)
  local rows, accountBank = {}, nil
  local db = ns.db
  local me = ns.PlayerKey()
  if not (db and me and id) then return rows, 0 end
  local mine = db.chars[me] or {}
  local bankAt = -1
  local keys = {}
  for key, c in pairs(db.chars) do
    if type(c) == "table" and c.own and (key == me or CanShare(mine, c)) then keys[#keys + 1] = key end
  end
  table.sort(keys, function(a, b)
    if (a == me) ~= (b == me) then return a == me end
    return a < b
  end)
  for _, key in ipairs(keys) do
    local c = db.chars[key]
    local bags = key == me and LiveBags(id) or nil
    if bags == nil then bags = InSection(c, "bags", id) end
    local row = { key = key, name = ns.Pretty(key), classFile = c.info and c.info.classFile,
      bags = bags, bank = InSection(c, "bank", id), mail = InMail(c, id), me = key == me }
    row.total = row.bags + row.bank + row.mail
    if row.total > 0 then rows[#rows + 1] = row end
    -- The account bank is shared, so it's counted once, from the freshest record of it.
    local ab = c.accountBank
    if type(ab) == "table" and (ab.savedAt or 0) > bankAt then
      bankAt = ab.savedAt or 0
      accountBank = InSection(c, "accountBank", id)
    end
  end
  return rows, accountBank or 0
end

local function Where(row)
  local parts = {}
  if row.bags > 0 then parts[#parts + 1] = "Bags " .. row.bags end
  if row.bank > 0 then parts[#parts + 1] = "Bank " .. row.bank end
  if row.mail > 0 then parts[#parts + 1] = "Mail " .. row.mail end
  return table.concat(parts, "  ")
end

local function ClassColor(classFile)
  local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
  local c = colors and classFile and colors[classFile]
  if c then return c.r, c.g, c.b end
  return 1, 0.82, 0
end

-- Adds the lines to a tooltip that's showing the item.
function ns.AddItemCounts(tooltip, id)
  if not (tooltip and id and ns.db) then return end
  local rows, accountBank = ns.ItemCounts(id)
  -- Only this character's bags: the game already shows that much.
  local onlyBags = accountBank == 0 and (#rows == 0 or (#rows == 1 and rows[1].me and rows[1].bank == 0 and rows[1].mail == 0))
  if onlyBags then return end
  local total = accountBank
  for _, row in ipairs(rows) do
    local r, g, b = ClassColor(row.classFile)
    tooltip:AddDoubleLine(row.name, Where(row), r, g, b, 1, 1, 1)
    total = total + row.total
  end
  if accountBank > 0 then tooltip:AddDoubleLine("Account bank", tostring(accountBank), 1, 0.82, 0, 1, 1, 1) end
  if #rows + (accountBank > 0 and 1 or 0) > 1 then
    tooltip:AddDoubleLine("Total", tostring(total), 0.7, 0.7, 0.7, 1, 1, 1)
  end
end

----------------------------------------------------------------------
-- Hooking the game's item tooltips
----------------------------------------------------------------------

-- The main tooltip and the one a clicked item link opens. Not the comparison tooltips (they'd
-- repeat the counts for the worn item) and never one the game has locked.
local function Wanted(tooltip)
  if not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then return false end
  return tooltip == GameTooltip or tooltip == ItemRefTooltip
end

local function Add(tooltip, id)
  if not Wanted(tooltip) or not ns.Plain(id) or type(id) ~= "number" then return end
  ns.Run("item tooltip", ns.AddItemCounts, tooltip, id)
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
    Add(tooltip, data and data.id)
  end)
else
  -- Older clients: every tooltip that shows an item says so with OnTooltipSetItem.
  local function OnItem(tooltip)
    local _, link = Try(tooltip.GetItem, tooltip)
    Add(tooltip, ns.ItemID(link))
  end
  for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
    if tooltip and tooltip.HookScript then pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", OnItem) end
  end
end
