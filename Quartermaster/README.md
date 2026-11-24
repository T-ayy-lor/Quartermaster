# Quartermaster

A profession companion for World of Warcraft: Forever. Pick a goal (a skill level, a recipe, a
gear upgrade) and it works out the cheapest way there from what you own, vendor and trainer
prices, and auction prices. The steps appear beside your profession window and tick themselves
off as you go.

**Version 1.0.3.**

## Requirements

- **Auctionator**: auction prices and the shopping list.
- **Questie** (with QuestieDB): where vendors and trainers are.
- **TomTom** (optional): arrows to each step, by flight master when that's quicker.

## Install

Download `Quartermaster-<version>.zip` from the
[Releases page](https://github.com/T-ayy-lor/Quartermaster/releases), unzip it into
`World of Warcraft/_forever_/Interface/AddOns/`, and restart the game.

## Use

1. Open a profession window. The plan opens beside it.
2. Pick a goal from the dropdown. Nothing is worked out until you do. Another dropdown appears
   under it to add a second goal, and so on: they're planned together, so nothing is bought twice.
3. At the auction house, buy what's missing from Auctionator's "Quartermaster" shopping list. It's
   made for you as soon as a goal is picked.
4. Work through the steps. Click a crafting step to craft it; click any other step to point
   the way.

`/qm` or the minimap button opens and closes the window. **Refresh** works the plan out again.

Curious about a profession you don't have? Pick it under "Professions you haven't learned" in
the profession dropdown to see what any skill level would cost, starting from learning it.

Item tooltips also say how many you have on each of your characters (bags, bank, mail) that
could mail it to you: the same ruleset and faction. Banks and mail count from your last visit.

## Good to know

- Prices at a vendor you haven't opened are estimates, marked "about". A trainer's fee isn't
  counted until you've opened that trainer.
- Skill-up chances for yellow and green recipes, and what each Waylaid Crate takes and pays,
  are estimates.

## License

MIT (see `LICENSE`). Recipe data from LibProfessionDB by Pimptasty, MIT (see
`THIRD-PARTY-NOTICES.txt`).
