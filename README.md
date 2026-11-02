# WFSync

WoW-Forever-Add-on, mit dem eine kleine Spielgruppe (lois, mf, …) und ihre r00ms-Agents den Fortschritt der anderen sehen: Level, XP, Zone, Quests, Dungeons, Tode. Ziel: Vorschläge, was ihr als Nächstes zusammen machen könnt.

```
WoW-Client ── WFSync (Lua) ──► SavedVariables/WFSync.lua ──► companion/ (MCP) ──► Agent ──► r00ms-Room
     ▲              │  Addon-Messages (Party/Gilde, live)                                     │
     │              ▼                                                                         │
     └──── WFSync_Data/Remote.lua ◄──────────── companion schreibt Stand der anderen ◄────────┘
```

## Aufbau

| Ordner | Inhalt | Zuständig |
|---|---|---|
| `addon/WFSync/` | Das Add-on: sammelt Daten, Live-Sync, Ingame-UI | AddonBuilder |
| `companion/` | Liest SavedVariables, MCP-Server, schreibt `WFSync_Data` | wow-forever-builder |
| `tests/` | Tests mit WoW-API-Attrappe (`luajit tests/run.lua`) | alle |

## Ingame

- **`/wf`**: Fenster mit allen Mitspielern (Level, XP %, Zone, online oder „vor X Std“, letzte Quest)
- **Questlog und Quest-Dialog**: Seitenpanel mit Status pro Mitspieler (erledigt, im Questlog, offen)
- **Quest-Links im Chat**: Tooltip mit demselben Status
- **Login**: Hinweis wie „mf: Level 20 → 23, zuletzt in Silberwald (vor 3 Std)“
- `/wf sync` · `/wf status` · `/wf quest <id>` · `/wf debug`

## Installation (Add-on)

`addon/WFSync` nach `World of Warcraft/_<flavor>_/Interface/AddOns/WFSync` kopieren oder symlinken. `WFSync_Data` legt der Companion selbst an. Solange Forever keine eigene Interface-Nummer hat: im Add-on-Menü „Veraltete Add-ons laden“ anhaken.

## Tests

```sh
brew install luajit   # Lua 5.1 wie in WoW
luajit tests/run.lua
```

Die Tests lassen zwei Clients (Lois, Mf) über einen Mock-Bus miteinander sprechen. Sie schreiben außerdem `tests/fixtures/SavedVariables/WFSync.lua`, eine echte Beispieldatei für den Companion.

## Datenschema v1

### Ausgehend: `WTF/Account/<ACC>/SavedVariables/WFSync.lua`

```lua
WFSync_DB = {
  schema = 1,
  chars = {
    ["Name-Realm"] = {
      updated = 1793000000,             -- time()
      class = "WARRIOR", race = "Orc", faction = "Horde",
      level = 23, xp = 4120, xpMax = 9800, rested = 1200,
      zone = "Ashenvale", subzone = "Astranaar", mapID = 1440,
      pos = { x = 0.412, y = 0.633 },   -- nil in Instanzen
      money = 154321, guild = "Gildenname",
      completed = { [1234] = true },    -- abgeschlossene Quest-IDs
      log = { [1250] = { title = "...", level = 22, accepted = ts, ready = true } },
      events = { { t = ts, type = "...", ... } },  -- Ringpuffer, max. 500
      sessions = { { start, stop, levelFrom, levelTo, xpGained, quests, deaths } },
    },
  },
  peers = { ["Name-Realm"] = { ... } },  -- live gesehene Mitspieler (intern)
  seen = { [handle] = { level, updated } }, -- für Login-Hinweis (intern)
  settings = { debug = false },
}
```

Event-Typen: `login`, `zone`, `levelup`, `quest_accept`, `quest_turnin`, `quest_abandon`, `death` (mit `killer`), `dungeon_enter`, `dungeon_leave`.

### Eingehend: `Interface/AddOns/WFSync_Data/Remote.lua`

Eigenes Mini-Add-on (nur `WFSync_Data.toc` + `Remote.lua`), das allein der Companion schreibt, atomar per tmp + rename.

```lua
WFSync_Remote = {
  schema = 1, generated = ts,
  players = {
    ["mf"] = {                        -- r00ms-Personen-Handle
      char = "Name-Realm", level = 22, xp = 0, xpMax = 0, zone = "...", updated = ts,
      completed = { [id] = true }, log = { [id] = { title = "..." } },
      recent = { <letzte 20 events> },
    },
  },
}
```

Regeln: Unbekannte Felder werden ignoriert. Bei Breaking Changes steigt `schema`.

### Live-Protokoll (Addon-Messages, Prefix `WFSync`)

| Nachricht | Bedeutung |
|---|---|
| `H^1` | Hallo, bitte schick deinen Status (Antwort per Whisper) |
| `S^1^lvl^xp^xpMax^mapID^x^y^updated^completedCount^zone^subzone` | Status |
| `R^1` | bitte schick deine abgeschlossenen Quests |
| `C^1^seq^i^n^id,id,…` | Teil i von n der abgeschlossenen Quests |
| `T^1^questID^title` | Quest gerade abgegeben |

Jede Nachricht hat höchstens 255 Byte. Gesendet wird gedrosselt mit 5 Nachrichten pro Sekunde. Status-Updates werden 10 s entprellt.

## Offene Punkte

- Interface-Nummer und API-Abweichungen von WoW Forever, sobald der Client da ist (Launch 4.11.2026)
- Karten-Pins „hier war mf zuletzt“
- Quest- und Dungeon-Datenbank für Vorschläge (Companion)
