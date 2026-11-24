-- The minimap button: click to show or hide the plan window (same as /qm). It's always there.
-- It's an ordinary minimap button (LibDBIcon, which TomTom and others already bring), so it sits
-- with your other minimap buttons and can be dragged around the minimap. Where that library
-- isn't loaded, a plain button on the minimap's edge does the same job.

local _, ns = ...

local PLAN_ICON = [[Interface\Icons\INV_Scroll_03]]

----------------------------------------------------------------------
-- What the button says and does
----------------------------------------------------------------------

local function PlanTooltip(tip)
  tip:AddLine("Quartermaster: Plan")
  local title, done, total
  if ns.PlanStatus then title, done, total = ns.PlanStatus() end
  if title then
    tip:AddLine(title, 1, 1, 1)
    if total > 0 then tip:AddLine(done .. " of " .. total .. " steps done", 0.4, 1, 0.4) end
    tip:AddLine("Click to show or hide the plan.", 1, 1, 1, true)
  else
    tip:AddLine("This character has no professions to plan for yet.", 1, 1, 1, true)
  end
  tip:AddLine("Same as /qm", 0.7, 0.7, 0.7)
end

local function PlanClick()
  if not ns.TogglePlan then
    ns.Print("restart the game once to load the plan window.")
  elseif ns.TogglePlan() == false and not (ns.PlanStatus and ns.PlanStatus()) then
    ns.Print("this character has no professions to plan for yet.")
  end
end
ns.PlanClick = PlanClick

local BUTTONS = {
  { name = "QuartermasterPlan", label = "Quartermaster plan", icon = PLAN_ICON, click = PlanClick,
    tooltip = PlanTooltip, angle = 205 },
}

----------------------------------------------------------------------
-- Making the button
----------------------------------------------------------------------

local dbIcon          -- LibDBIcon, when it's loaded
local plain = {}      -- name -> our own button, when it isn't

-- A plain round minimap button, for when LibDBIcon isn't around.
local function PlainButton(spec)
  local b = CreateFrame("Button", spec.name .. "MinimapButton", Minimap or UIParent)
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetSize(20, 20)
  icon:SetPoint("CENTER", 0, 0)
  icon:SetTexture(spec.icon)
  b.icon = icon
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT", 0, 0)
  border:SetTexture([[Interface\Minimap\MiniMap-TrackingBorder]])
  b:SetHighlightTexture([[Interface\Minimap\UI-Minimap-ZoomButton-Highlight]])
  -- On the minimap's edge, at a fixed angle.
  local radius = ((Minimap and Minimap.GetWidth and Minimap:GetWidth()) or 140) / 2 + 5
  local a = math.rad(spec.angle)
  b:SetPoint("CENTER", Minimap or UIParent, "CENTER", math.cos(a) * radius, math.sin(a) * radius)
  b:SetScript("OnClick", function() spec.click() end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    spec.tooltip(GameTooltip)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function Settings(name)
  local ui = ns.db.account.ui
  ui.minimap = type(ui.minimap) == "table" and ui.minimap or {}
  ui.minimap[name] = type(ui.minimap[name]) == "table" and ui.minimap[name] or {}
  return ui.minimap[name]
end

local made = false
local function Create()
  if made or not ns.db then return end
  made = true
  -- The floating Sync button from version 0.1 is gone; forget where it was.
  ns.db.account.ui.sync, ns.db.account.ui.hideSync = nil, nil
  -- So is the Sync minimap button (0.10): the addon plans by itself, and a /reload saves.
  if type(ns.db.account.ui.minimap) == "table" then ns.db.account.ui.minimap.QuartermasterSync = nil end
  -- The button can't be hidden any more (the /qm button command is gone).
  ns.db.account.ui.hideMinimap = nil
  local broker = LibStub and LibStub("LibDataBroker-1.1", true)
  dbIcon = LibStub and LibStub("LibDBIcon-1.0", true)
  for _, spec in ipairs(BUTTONS) do
    local done = false
    if broker and dbIcon then
      done = pcall(function()
        local object = broker:NewDataObject(spec.name, {
          type = "launcher", text = spec.label, icon = spec.icon,
          OnClick = function() spec.click() end,
          OnTooltipShow = function(tip) spec.tooltip(tip) end,
        })
        local settings = Settings(spec.name)
        settings.hide = false
        dbIcon:Register(spec.name, object, settings)
      end)
    end
    if not done then
      plain[spec.name] = PlainButton(spec)
      plain[spec.name]:Show()
    end
  end
end

ns.On("PLAYER_LOGIN", Create)

-- Key binding (Options > Keybindings > Quartermaster).
BINDING_HEADER_QUARTERMASTER = "Quartermaster"
BINDING_NAME_QUARTERMASTER_PLAN = "Show or hide the plan"
function Quartermaster_Plan()
  PlanClick()
end
