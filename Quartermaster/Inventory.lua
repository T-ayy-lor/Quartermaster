-- Everything you own that isn't equipped: bags, bank and mailbox.
-- Sections "bags", "bank" (plus "accountBank" where the game has one) and "mail".

local _, ns = ...

local Try = ns.Try

----------------------------------------------------------------------
-- Reading containers
----------------------------------------------------------------------

local function LastBag()
  return NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
end

-- Every slot of the given bags. Each item: id, n (count), link, bound (soulbound), q (quality),
-- bag and slot. Also slot totals; 0 total slots means the bags can't be read right now.
local function ReadBags(bagIDs)
  local items, bags = {}, {}
  local total, used = 0, 0
  for _, bag in ipairs(bagIDs) do
    local slots = Try(C_Container.GetContainerNumSlots, bag) or 0
    if slots > 0 then
      total = total + slots
      local inBag = 0
      for slot = 1, slots do
        local info = Try(C_Container.GetContainerItemInfo, bag, slot)
        if info and info.itemID then
          inBag = inBag + 1
          -- "bound" items can't be mailed to your other characters.
          items[#items + 1] = { id = info.itemID, n = info.stackCount or 1, bound = info.isBound and true or nil }
          ns.Items.Note(info.hyperlink or info.itemID)
        end
      end
      used = used + inBag
      bags[#bags + 1] = { bag = bag, slots = slots, used = inBag }
    end
  end
  return items, total, used, bags
end

----------------------------------------------------------------------
-- Bags
----------------------------------------------------------------------

local BankBagIDs -- defined below

-- The keyring's container number, on clients that have one.
local function Keyring()
  return KEYRING_CONTAINER or (Enum and Enum.BagIndex and Enum.BagIndex.Keyring)
end

local function BagIDs()
  local ids = {}
  for bag = 0, LastBag() do ids[#ids + 1] = bag end
  -- A container the bank uses is never read as a bag, or bank items would be counted as
  -- carried whenever the bank is open.
  local keyring = Keyring()
  if keyring then
    local isBank = false
    for _, id in ipairs(BankBagIDs()) do
      if id == keyring then isBank = true end
    end
    if not isBank then ids[#ids + 1] = keyring end
  end
  return ids
end

local function SaveBags()
  local items, total, used, bags = ReadBags(BagIDs())
  -- Bags that can't be read (0 slots) never replace a good copy.
  if total == 0 then return end
  ns.Save("bags", { items = items, total = total, used = used, bags = bags })
end

ns.SaveBags = SaveBags

----------------------------------------------------------------------
-- Bank
----------------------------------------------------------------------

-- Every bag ID that belongs to your character's bank. WoW Forever numbers the bank as tabs
-- (CharacterBankTab_1 and up; -1 is the keyring there). Older clients use one bank container
-- (-1) plus bank bag slots. IDs that don't exist just have 0 slots.
function BankBagIDs()
  local ids, seen = {}, {}
  local function add(id)
    if id and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  local index = (Enum and Enum.BagIndex) or {}
  local tabs = false
  for i = 1, 12 do
    local id = index["CharacterBankTab_" .. i]
    if id then
      tabs = true
      add(id)
    end
  end
  add(BANK_CONTAINER or index.Bank)
  if not tabs then
    if not (BANK_CONTAINER or index.Bank) and Keyring() ~= -1 then add(-1) end
    local first = LastBag() + 1
    for i = 0, (NUM_BANKBAGSLOTS or 7) - 1 do add(first + i) end
  end
  add(REAGENTBANK_CONTAINER or index.Reagentbank)
  return ids
end

-- The account-wide bank's tabs, on clients that have one.
local function AccountBankIDs()
  local ids = {}
  local index = (Enum and Enum.BagIndex) or {}
  for i = 1, 12 do
    local id = index["AccountBankTab_" .. i]
    if id then ids[#ids + 1] = id end
  end
  return ids
end

local bankOpen = false

local function SaveBank()
  if not bankOpen then return end
  local items, total, used, bags = ReadBags(BankBagIDs())
  if total == 0 then return end
  ns.Save("bank", { items = items, total = total, used = used, bags = bags })
  -- The bank shared by the account, if this client has one and it holds any tabs.
  local shared = AccountBankIDs()
  if #shared > 0 then
    local sItems, sTotal, sUsed, sBags = ReadBags(shared)
    if sTotal > 0 then
      ns.Save("accountBank", { items = sItems, total = sTotal, used = sUsed, bags = sBags })
    end
  end
end

local function IsBanker(kind)
  return Enum and Enum.PlayerInteractionType and kind == Enum.PlayerInteractionType.Banker
end

local function BankOpened()
  bankOpen = true
  SaveBank()
  -- Where this banker stands, for plans that send you to the bank.
  if ns.NoteNpc then ns.Run("banker", ns.NoteNpc, "banker") end
  -- Bank bags can load a moment after the window opens.
  C_Timer.After(1, function() ns.Run("bank", SaveBank) end)
end

-- Nothing is read while the window closes: the game can already be answering "empty" by then,
-- and that must never replace what was really there.
local function BankClosed()
  bankOpen = false
end

----------------------------------------------------------------------
-- Mailbox
----------------------------------------------------------------------

local mailOpen = false

-- Only what's attached and how many: who sent it or what it says isn't recorded.
local function SaveMail()
  if not mailOpen or not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxItem) then return end
  local shown, total = GetInboxNumItems()
  local messages = {}
  for i = 1, shown or 0 do
    local itemCount = select(8, GetInboxHeaderInfo(i))
    local items = {}
    for a = 1, (itemCount and itemCount > 0) and (ATTACHMENTS_MAX_RECEIVE or 16) or 0 do
      local name, itemID, _, count = GetInboxItem(i, a)
      itemID = itemID or ns.ItemID(GetInboxItemLink and GetInboxItemLink(i, a))
      if itemID then
        items[#items + 1] = { id = itemID, n = count or 1 }
        ns.Items.Note(itemID)
      end
    end
    if #items > 0 then messages[#messages + 1] = { items = items } end
  end
  -- "more" counts mail the game is still holding back (it shows 50 at a time).
  local more = (total and shown and total > shown) and (total - shown) or nil
  ns.Save("mail", { messages = messages, more = more })
end

----------------------------------------------------------------------
-- When to read
----------------------------------------------------------------------

ns.On("PLAYER_ENTERING_WORLD", function() ns.Later("bags", 3, SaveBags) end)
ns.On("BAG_UPDATE_DELAYED", function()
  ns.Later("bags", 2, SaveBags)
  if bankOpen then ns.Later("bank", 0.3, SaveBank) end
end)

ns.On("BANKFRAME_OPENED", BankOpened)
ns.On("BANKFRAME_CLOSED", BankClosed)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind) if IsBanker(kind) then BankOpened() end end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind) if IsBanker(kind) then BankClosed() end end)
ns.On("PLAYERBANKSLOTS_CHANGED", function() if bankOpen then ns.Later("bank", 0.3, SaveBank) end end)
ns.On("PLAYERREAGENTBANKSLOTS_CHANGED", function() if bankOpen then ns.Later("bank", 0.3, SaveBank) end end)

ns.On("MAIL_SHOW", function()
  mailOpen = true
  -- Where this mailbox is, for plans that send you to one.
  if ns.NotePlace then ns.Run("mailbox", ns.NotePlace, "mailbox", "Mailbox") end
  ns.Later("mail", 1, SaveMail)
end)
ns.On("MAIL_INBOX_UPDATE", function() if mailOpen then ns.Later("mail", 1, SaveMail) end end)
ns.On("MAIL_CLOSED", function() mailOpen = false end)
