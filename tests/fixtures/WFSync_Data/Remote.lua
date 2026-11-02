-- Beispiel, wie der Companion Remote.lua schreibt (Schema v1)
WFSync_Remote = {
  schema = 1,
  generated = 1792990000,
  players = {
    ["mf"] = {
      char = "Mf-Forever",
      class = "MAGE", race = "Undead", faction = "Horde",
      level = 22, xp = 3000, xpMax = 9000,
      zone = "Silberwald", subzone = "Grabesmoor",
      updated = 1792980000,
      completed = { [100] = true, [101] = true },
      log = { [102] = { title = "Die Verlassenen" } },
      recent = {
        { t = 1792979000, type = "quest_turnin", id = 101, title = "Ratten im Keller", zone = "Silberwald" },
      },
    },
    ["lois"] = {
      char = "Lois-Forever",
      level = 20, xp = 0, xpMax = 8000, zone = "Brachland", updated = 1792980000,
      completed = {},
    },
  },
}
