-- Item cache: name, quality, level needed, vendor value and, for gear, slot, kind and stats of
-- every item the recorder comes across (bags, bank, mail, gear, vendors, every profession's
-- materials and products). Shared by the whole account in QuartermasterDB.account.items, keyed
-- by item ID (or "id:suffix" for "of the Bear" style items).

local _, ns = ...

local Items = {}
ns.Items = Items

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemStats = (C_Item and C_Item.GetItemStats) or GetItemStats
local RequestLoad = C_Item and C_Item.RequestLoadItemDataByID

local REFRESH_AFTER = 7 * 24 * 3600 -- re-read an item after a week, in case a patch changed it
local PER_TICK = 12

-- A queue read from `head` on, so taking the next item is cheap however long the queue is.
local queue, head, queued = {}, 1, {}
local ticker

-- Cache key and a plain link for an item ID or item link.
local function KeyOf(item)
  if type(item) == "number" then return item, "item:" .. item end
  if type(item) ~= "string" or not ns.Plain(item) then return nil end
  local id = tonumber(item:match("item:(%d+)"))
  if not id then return nil end
  -- item:id:enchant:gem1:gem2:gem3:gem4:suffix:...
  local suffix = item:match("item:%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d+)")
  if suffix and suffix ~= "0" then return id .. ":" .. suffix, item:match("(item:[%-%d:]+)") or ("item:" .. id) end
  return id, "item:" .. id
end
Items.KeyOf = KeyOf

local function Record(key, link)
  local name, _, quality, _, reqLevel, _, _, _, equipLoc, _, sell, classID, subID, bind = GetItemInfo(link)
  if not name then return false end
  local e = {
    name = name, q = quality, req = (reqLevel and reqLevel > 0) and reqLevel or nil,
    loc = (equipLoc ~= nil and equipLoc ~= "") and equipLoc or nil,
    sell = (sell and sell > 0) and sell or nil, bind = (bind and bind > 0) and bind or nil,
  }
  -- Gear only: its kind (cloth, leather...) and stats, for the upgrade list.
  if e.loc then
    e.classID, e.subID = classID, subID
    if GetItemStats then
      local ok, stats = pcall(GetItemStats, link)
      if ok and type(stats) == "table" then
        local s = ns.Scalars(stats)
        if next(s) then e.stats = s end
      end
    end
  end
  local items = ns.db.account.items
  local old = items[key]
  if old and ns.Same(old, e) then
    old.savedAt = time()
  else
    e.savedAt = time()
    items[key] = e
    ns.MarkDirty("items")
  end
  return true
end

local function Process()
  if ns.InCombat() then return end
  local done, retry = 0, {}
  while done < PER_TICK and head <= #queue do
    local job = queue[head]
    queue[head] = false
    head = head + 1
    done = done + 1
    local ok, recorded = pcall(Record, job.key, job.link)
    if ok and recorded then
      queued[job.key] = nil
    elseif ok and job.tries < 8 then
      -- Not loaded yet: ask the game for it and try again on a later pass.
      job.tries = job.tries + 1
      if RequestLoad then pcall(RequestLoad, job.id) end
      retry[#retry + 1] = job
    else
      queued[job.key] = nil
      if not ok then ns.Error("item " .. tostring(job.key), recorded) end
    end
  end
  for _, job in ipairs(retry) do queue[#queue + 1] = job end
  if head > #queue then
    queue, head = {}, 1
    if ticker then
      ticker:Cancel()
      ticker = nil
    end
  end
end

-- Remembers an item (ID or link). Safe to call for the same item again and again.
function Items.Note(item)
  if not ns.db then return end
  local key, link = KeyOf(item)
  if not key or queued[key] then return end
  local old = ns.db.account.items[key]
  if old and old.savedAt and time() - old.savedAt < REFRESH_AFTER then return end
  queued[key] = true
  queue[#queue + 1] = { key = key, link = link, id = tonumber(tostring(key):match("^(%d+)")), tries = 0 }
  if not ticker then ticker = C_Timer.NewTicker(0.25, function() ns.Run("items", Process) end) end
end

function Items.Pending()
  return #queue - head + 1
end
