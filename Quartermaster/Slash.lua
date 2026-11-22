-- The one chat command: /qm shows or hides the plan window (same as the minimap button).

local _, ns = ...

SLASH_QUARTERMASTER1 = "/qm"
SLASH_QUARTERMASTER2 = "/quartermaster"
SlashCmdList.QUARTERMASTER = function()
  if not ns.db then return end
  ns.PlanClick()
end
