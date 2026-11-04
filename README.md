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

- **`/wf`**: Fenster mit allen Mitspielern: Level, XP %, Zone, online oder „vor X Std“, letzte Quest. Zuerst stehen alle, die online sind. Bei mehr als 10 Leuten blättert man mit dem Mausrad, unten steht die Zahl der Mitspieler und wie viele online sind.
- **Questlog und Quest-Dialog**: Seitenpanel mit Status pro Mitspieler (erledigt, im Questlog, offen)
- **Quest-Links im Chat**: Tooltip mit demselben Status
- **Login**: Hinweis wie „mf: Level 20 → 23, zuletzt in Silberwald (vor 3 Std)“
- **Weitergabe über die Gilde**: Wer gerade online ist, gibt den letzten Stand von Gildenmitgliedern weiter, die offline sind. So sieht man mf auch dann, wenn man nie gleichzeitig mit mf online war. Im Fenster steht dann „(über Name)“.
- **`/wf share guild|group|off`** (auch `gilde|gruppe|aus`): mit wem du teilst. `guild` (Standard): Gruppe und Gilde, inklusive Weitergabe. `group`: nur Gruppe oder Raid, wird nicht weitergegeben. `off`: nur empfangen.
- `/wf sync` · `/wf status` · `/wf quest <id>` · `/wf debug`

### Ohne Agent und ohne r00ms

Das Add-on allein reicht schon. Live sieht man alle in Gruppe und Gilde, die WFSync haben. Für Offline-Stände sorgt die Weitergabe über die Gilde. Agent und Companion kommen nur dazu, wenn man Vorschläge und den Austausch außerhalb der Gilde will.

Welcher Stand gewinnt? Jeder Stand trägt `updated`. Das ist der Zeitpunkt der letzten Änderung, gesetzt vom Client des Spielers selbst. Für Level, XP und Zone gewinnt der höchste Wert, egal ob er live, über die Gilde oder per `Remote.lua` kam. Abgeschlossene Quests aus allen Quellen werden zusammengeführt. Weitergegebenes überschreibt nie Neueres und wird nicht angenommen, solange die Person selbst online ist.

## Installation (Add-on)

`addon/WFSync` nach `World of Warcraft/_<flavor>_/Interface/AddOns/WFSync` kopieren oder symlinken. `WFSync_Data` legt der Companion selbst an.

Die TOC enthält `## Interface: 11509, 16001` (Classic Era und, laut Fan-Guides, WoW Forever, offiziell noch nicht bestätigt). Lädt das Add-on nicht:
1. Im Spiel `/dump select(4, GetBuildInfo())` ausführen und die Zahl im Room posten. Wir tragen sie in `addon/WFSync/WFSync.toc` ein, der Companion übernimmt sie für `WFSync_Data`.
2. Bis dahin im Add-on-Menü „Veraltete Add-ons laden“ anhaken.

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
| `S^1^lvl^xp^xpMax^mapID^x^y^updated^completedCount^zone^subzone^share` | Status (`share`: `g` darf weitergegeben werden, `p` nur Gruppe) |
| `R^1^g?` | bitte schick deine abgeschlossenen Quests (`g`: dein Status kam bei mir über die Gilde an). Kommen innerhalb von 3 s mehrere Anfragen mit `g`, wird einmal über die Gilde geantwortet statt jedem einzeln. |
| `C^1^seq^i^n^id,id,…` | Teil i von n der abgeschlossenen Quests |
| `T^1^questID^title` | Quest gerade abgegeben |
| `P^1^char^share^seenAt^lvl^xp^xpMax^mapID^x^y^updated^completedCount^zone^subzone` | weitergegebener Stand von `char` (Antwort auf `H` in der Gilde, höchstens 15, nicht älter als 30 Tage) |
| `Q^1^char` | bitte schick mir die abgeschlossenen Quests von `char` |
| `K^1^char^seq^i^n^id,id,…` | Teil i von n der Quests von `char`. Wird nur vom Absender des übernommenen `P` angenommen. |

Weitergegebene Daten sind nicht signiert: Wer WFSync in der Gilde hat, könnte falsche Stände schicken. Für eine Freundesgruppe ist das in Ordnung. Wer das nicht will, nutzt `/wf share group`.

Jede Nachricht hat höchstens 255 Byte. Status-Updates werden 10 s entprellt.

Drosselung: Der Client erlaubt pro Prefix ein Kontingent von etwa 10 Nachrichten, das sich mit etwa 1 pro Sekunde auffüllt. Was darüber hinausgeht, verwirft er still. WFSync bleibt mit einem eigenen Kontingent darunter (8 Nachrichten auf einmal, dann 1 pro Sekunde). Meldet der Client trotzdem eine Drosselung, wird die Nachricht bis zu 5-mal wiederholt.

In Instanzen ist Addon-Kommunikation in Forever möglicherweise gesperrt. Das `/wf`-Fenster zeigt dann einen Hinweis, und nach dem Verlassen schickt WFSync einmal ein Hallo.

## Offene Punkte

- Interface-Nummer und API-Abweichungen von WoW Forever, sobald der Client da ist (Launch 4.11.2026)
- Karten-Pins „hier war mf zuletzt“
- Quest- und Dungeon-Datenbank für Vorschläge (Companion)
