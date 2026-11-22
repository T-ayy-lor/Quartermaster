-- Recipes: every recipe the open profession window lists (learned or not), saved under
-- QuartermasterDB.chars[key].recipes[profession]. Also keeps a tally of crafts and skill-ups
-- (craftLog), so the real skill-up chance of yellow and green recipes can be worked out.

local _, ns = ...

local Try = ns.Try


ns.recipeProf = {} -- recipe (spell) ID -> profession name, for this character's saved recipes

local function ReadModern(T)
  local base = Try(T.GetBaseProfessionInfo)
  local child = Try(T.GetChildProfessionInfo)
  local prof = (base and base.professionName ~= "" and base.professionName) or (child and child.professionName)
  local info = (child and (child.maxSkillLevel or 0) > 0) and child or base
  local out = {
    skill = info and info.skillLevel, max = info and info.maxSkillLevel,
    skillLine = base and base.professionID or nil, recipes = {}, categories = {},
  }
  for _, id in ipairs(Try(T.GetAllRecipeIDs) or {}) do
    local r = Try(T.GetRecipeInfo, id)
    if r and not r.isDummyRecipe and not r.isRecraft then
      local sch = Try(T.GetRecipeSchematic, id, false)
      local itemID = sch and sch.outputItemID
      if not itemID and T.GetRecipeOutputItemData then
        local made = Try(T.GetRecipeOutputItemData, id)
        itemID = made and made.itemID
      end
      local reagents = {}
      for _, slot in ipairs((sch and sch.reagentSlotSchematics) or {}) do
        local first = slot.reagents and slot.reagents[1]
        if first and first.itemID and slot.required ~= false and (slot.quantityRequired or 0) > 0 then
          reagents[#reagents + 1] = { id = first.itemID, n = slot.quantityRequired }
          ns.Items.Note(first.itemID)
        end
      end
      out.recipes[id] = {
        name = r.name, item = itemID, min = sch and sch.quantityMin,
        -- Known for real: a spell on your character. (The window's own "learned" flag is wrong
        -- for some vendor patterns on Forever: they show as learned before you buy them.)
        known = Try(IsPlayerSpell, id) and true or false,
        skillUps = (r.numSkillUps and r.numSkillUps > 1) and r.numSkillUps or nil,
        category = r.categoryID, reagents = reagents,
      }
      if itemID then ns.Items.Note(itemID) end
      -- The headings the window files its recipes under ("Stamina Food", "Armor Kits"), by name
      -- and in the window's own order.
      local cat = r.categoryID
      if cat and not out.categories[cat] and T.GetCategoryInfo then
        local info = Try(T.GetCategoryInfo, cat)
        if info and type(info.name) == "string" and info.name ~= "" then
          out.categories[cat] = { name = info.name, order = info.uiOrder, parent = info.parentCategoryID }
        end
      end
    end
  end
  return prof, out
end

local function SaveOpenProfession()
  local c = ns.Char()
  if not c then return end
  local T = C_TradeSkillUI
  if T then
    -- Someone else's linked window, the guild's, or an NPC's: not yours, so not saved.
    if T.IsTradeSkillLinked and T.IsTradeSkillLinked() then return end
    if T.IsTradeSkillGuild and T.IsTradeSkillGuild() then return end
    if T.IsNPCCrafting and T.IsNPCCrafting() then return end
  end
  local prof, data
  if T and T.GetAllRecipeIDs then prof, data = ReadModern(T) end
  -- An empty list means the window is still filling in. So does an empty profession name: the
  -- game can still be listing the last profession's recipes for a moment while it has already
  -- forgotten which profession they belong to.
  if not prof or prof == "" or not data or not next(data.recipes) then return end

  c.recipes = c.recipes or {}
  local old = c.recipes[prof]
  if old and ns.Same(old, data) then
    old.savedAt = time()
  else
    data.savedAt = time()
    c.recipes[prof] = data
    ns.MarkDirty("recipes")
    -- The first exact list for this profession: goals made from the built-in recipe data are
    -- worked out again from it.
    if not old and ns.Planner then ns.Planner.Rebuild(prof) end
  end
  for id in pairs(data.recipes) do
    if type(id) == "number" then ns.recipeProf[id] = prof end
  end
  if data.skill then
    ns.profSkill = ns.profSkill or {}
    ns.profSkill[prof] = data.skill
  end
end

-- Recipe IDs saved in earlier sessions, so crafts can be tallied before the window is opened.
local function IndexSavedRecipes()
  local c = ns.Char()
  -- Versions before 0.5.4 could save a list under an empty name; it's a copy of a real one.
  if c and c.recipes and c.recipes[""] then
    c.recipes[""] = nil
    ns.MarkDirty("recipes")
  end
  for prof, data in pairs((c and c.recipes) or {}) do
    for id in pairs(data.recipes or {}) do
      if type(id) == "number" then ns.recipeProf[id] = prof end
    end
  end
end

----------------------------------------------------------------------
-- Known recipes for every profession, without opening its window (section "knownRecipes").
-- Recipes.lua lists every profession's recipe spells; a recipe you know is a spell on your
-- character, so the game can be asked about each one directly.
----------------------------------------------------------------------

local function SaveKnownRecipes()
  local c = ns.Char()
  local profs = c and c.professions and c.professions.list
  if not (profs and type(ns.recipeData) == "table" and IsPlayerSpell) then return end
  local out = {}
  for name, p in pairs(profs) do
    local data = p.skillLine and ns.recipeData[p.skillLine]
    if not data then
      -- No skill line number from the game: match by the profession's name.
      for _, d in pairs(ns.recipeData) do
        if d.name == name then data = d end
      end
    end
    if data then
      local known = {}
      for _, spell in ipairs(data.spells or {}) do
        if Try(IsPlayerSpell, spell) then known[#known + 1] = spell end
        -- So crafts are tallied for this profession even if its window is never opened.
        if not ns.recipeProf[spell] then ns.recipeProf[spell] = name end
      end
      out[name] = { line = p.skillLine, ids = known }
      -- Remember the items its recipes make and use (names, quality, stats, vendor value).
      for _, item in ipairs(data.items or {}) do ns.Items.Note(item) end
    end
  end
  if next(out) then ns.Save("knownRecipes", { list = out }) end
end

ns.SaveKnownRecipes = SaveKnownRecipes

----------------------------------------------------------------------
-- Craft tally: craftLog[profession][recipeID][skill before the craft] = { c = crafts, u = skill-ups }
----------------------------------------------------------------------

local function OnCraft(_, unit, _, spellID)
  if unit ~= "player" or not ns.Plain(spellID) then return end
  local prof = ns.recipeProf[spellID]
  if not prof then return end
  local before = ns.profSkill and ns.profSkill[prof]
  C_Timer.After(0.8, function()
    ns.Run("craftLog", function()
      ns.SaveSkills()
      local after = ns.profSkill and ns.profSkill[prof]
      local c = ns.Char()
      if not (c and before and after) then return end
      c.craftLog = c.craftLog or {}
      c.craftLog[prof] = c.craftLog[prof] or {}
      local byRecipe = c.craftLog[prof]
      byRecipe[spellID] = byRecipe[spellID] or {}
      local e = byRecipe[spellID][before] or { c = 0, u = 0 }
      byRecipe[spellID][before] = e
      e.c = e.c + 1
      if after > before then e.u = e.u + 1 end
      ns.MarkDirty("craftLog")
    end)
  end)
end

----------------------------------------------------------------------
-- When to read
----------------------------------------------------------------------

ns.On("PLAYER_ENTERING_WORLD", function()
  ns.Later("recipeIndex", 4, IndexSavedRecipes)
  ns.Later("knownRecipes", 10, SaveKnownRecipes)
end)
ns.On("NEW_RECIPE_LEARNED", function() ns.Later("knownRecipes", 3, SaveKnownRecipes) end)
ns.On("SKILL_LINES_CHANGED", function() ns.Later("knownRecipes", 8, SaveKnownRecipes) end)
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
  "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
  ns.On(event, function() ns.Later("recipes", 2, SaveOpenProfession) end)
end
ns.On("UNIT_SPELLCAST_SUCCEEDED", OnCraft)
