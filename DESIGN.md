# Chronos

Chronos records where your time goes on your Mac: which app has focus, for how long, and for browsers, which site. It
lives in the menu bar, stays dormant between focus changes, and keeps everything in a local SQLite file.

## Goals

- **Dormant.** No polling and no timers in the steady state. Chronos wakes only when macOS tells it focus or session
  state changed, writes, and goes back to sleep. The exceptions are one-shot: the one-second settle, and, while
  something with an allowance is in front, a wake-up for the moment it runs out.
- **Local.** One SQLite file on disk. Nothing leaves the Mac.
- **Never lose data.** The schema is versioned, and migrations back up the old file before touching it.
- **Never invent time.** When the true end of a slot is unknown, record less time, not more.

## Architecture

One app on disk, two processes:

```
Chronos.app/                          recorder: menu bar icon, events, writes SQLite
└── Contents/
    ├── MacOS/Chronos
    ├── Helpers/Chronos.app/          viewer: reads SQLite, draws charts, forgets sites
    └── Info.plist
```

| | Recorder (`com.kingbuzzman.chronos`) | Viewer (`com.kingbuzzman.chronos.viewer`) |
|---|---|---|
| Runs | Always, as a background agent (`LSUIElement`) | Only while open |
| Owns | Menu bar icon, event listeners, all recording, allowance notifications | Charts, forgetting a site, Settings |
| Database | Read-write | Read-only (`SQLITE_OPEN_READONLY`), plus a read-write connection only to forget a site |
| Permissions | Accessibility, Automation (per browser), Notifications | None |
| UI frameworks | AppKit only, no SwiftUI or Charts | SwiftUI and Swift Charts |

- Both are named "Chronos" and share the icon. The recorder never shows in the Dock; the viewer does, only while
  its window is open.
- They're built, versioned and signed together, so they can't be mismatched.
- The database and `schedule.json` are the only data they share. The recorder passes nothing to the viewer except,
  when testing, the database path; the rest are nudges by distributed notification ("show Settings", "the schedule
  was saved", and opening at login's question and answer).
- Focus time on any `com.kingbuzzman.chronos.*` bundle ID is recorded as Chronos.
- Quitting the recorder quits the viewer.
- The recorder is a background app in your login session, not a launchd daemon: a daemon can't see the user's windows.

## What is recorded

- **Every app**, by bundle ID and display name. Nothing is excluded yet, including `loginwindow` and
  `ScreenSaverEngine`; excluding things is a display decision for later.
- **For browsers, the host only.** Paths, query strings and fragments are dropped in memory and never written.
  - `https://www.github.com/multimediallc/chaturbate/pull/123` → `github.com`
  - `https://docs.google.com/document/d/abc` → `docs.google.com`
  - `http://localhost:8000/admin` → `localhost:8000` (the port is kept, to tell dev servers apart)
  - `chrome://settings/privacy` → `chrome://settings`
  - `file:///Users/javier/notes.html` → `file://` (a local path is private)
  - `about:blank` → `about:blank`
  - Only a leading `www.` is stripped. Subdomains are kept. Grouping into top-level domains (`google.com`) happens when
    reading, not when writing.
- **Private and incognito windows are recorded like any other,** with their host. If they're ever treated
  differently, here's how to detect them:
  - **Chrome-based browsers:** AppleScript reports the window's `mode` as `"incognito"`.
  - **Firefox:** the window title ends in "— Private Browsing". The suffix is translated into Firefox's interface
    language (for example "Navegación privada" in Spanish), so match every language in use.
  - **Safari:** needs testing.
- **For Terminal, the program in front** in the focused tab: `claude`, `vim`, `ssh`, or `zsh` when nothing else is
  running. Only its name; never its arguments or the window title. The program is an app of its own in `apps`
  (`kind = 'program'`), and the slot points at it with `sub_app_id`, next to Terminal's `app_id`: "Terminal, running
  claude". Browsers keep their host as text in `domain`; a slot never has both.
- **Nothing else for other apps:** app-level time only, no window titles.

### Browsers

| Browser | How the URL is read |
|---|---|
| Chrome, Arc, Brave, Edge, Vivaldi | AppleScript: `URL of active tab of front window` |
| Safari | AppleScript: `URL of current tab of front window` |
| Firefox | chronos-ff, its extension (below). Firefox has no AppleScript support for URLs. |
| Anything else | Not a browser: app-level only |

### Firefox: chronos-ff

Firefox can't be asked for its URL from outside, so it gets an extension, `chronos-ff/`, with two jobs:

1. **Notify:** when the domain of the tab in front changes (a tab switch, a navigation, another Firefox window coming
   forward), report the new domain.
2. **Answer:** when Chronos asks "current domain?", report it, even if it hasn't changed.

**Only the domain ever leaves Firefox**: `domainOf` in `chronos-ff/domain.js` reduces the URL with the same rules as
`Host.swift`, which Chronos applies again on arrival, and anything longer than 255 characters is dropped on both sides.
No address, title, tab ID or private-window flag. A tab with no domain reports `""`.

```
recorder ── "current domain?" ──▶ chronos-ff-host ──▶ chronos-ff
recorder ◀── "github.com" ─────── chronos-ff-host ◀── chronos-ff     (an answer, or a change it noticed)
       distributed notifications        native messaging (stdin/stdout)
```

- **chronos-ff-host** ships inside the app (`Contents/Helpers/chronos-ff-host`). Firefox starts it when the extension
  connects and ends it by closing the channel. It only relays: it keeps nothing and never starts Chronos.
- **If Chronos isn't running,** the reports go nowhere: a distributed notification nobody listens for is dropped.
  Nothing queues, nothing errors.
- **Chronos asks** whenever Firefox comes to the front, when it starts with Firefox in front, and when recording
  resumes. It forgets the last report first, so nothing stale is ever used. The answer replaces the focus while it
  settles (the one-second settle), so Firefox's slot opens with the right domain.
- **If nobody answers** (no extension, or it's disabled, or the helper died), Firefox's time is "Not identified". It
  never guesses.
- **Reports while Firefox isn't in front** are ignored.
- **The extension reconnects** every 30 seconds while its channel is closed, so Chronos can still ask after a helper
  dies.

**Installing:** `make ff-register` writes Firefox's registration file, the one file outside the project, to
`~/Library/Application Support/Mozilla/NativeMessagingHosts/com.kingbuzzman.chronos.json`. It points at this build's
`Chronos.app`, or another with `CHRONOS_APP=…`. Regular Firefox only keeps extensions Mozilla has signed, so until
chronos-ff is, load `build/chronos-ff.xpi` (or `chronos-ff/manifest.json`) in about:debugging → This Firefox → Load
Temporary Add-on. It stays loaded until Firefox quits.

### Terminal

1. AppleScript asks Terminal for the focused tab's terminal device: `tty of selected tab of front window`, such as
   `/dev/ttys012`.
2. System calls (`sysctl` with `KERN_PROC_TTY`) list that device's processes, without running `ps`. The one recorded is
   the leader of the foreground job: what the shell launched, such as `claude`, even while it runs helpers of its own
   like `caffeinate` or `git`. Terminal's own process list and its window title both show those helpers, so neither
   is used.
3. The name is the one it was launched as (its first argument, from `KERN_PROCARGS2`), because the file can differ:
   `claude` runs a file named after its version, such as `2.1.303`. Only that first argument is read: the rest can
   hold paths, hosts or secrets. A login shell's leading dash is dropped (`-zsh` → `zsh`).

Starting or leaving a program changes Terminal's window title, which is the event Chronos already listens for. While a
program like Claude Code works, the title flickers with its helpers, so title changes wait half a second to settle;
each settled change costs one Apple Event and a few system calls.

### Window titles: when, not where

The window title (what the Dock's right-click menu lists) comes from the same Accessibility API and is how Chronos
notices a tab switch. Titles are never stored:

- **They aren't addresses.** The title "refactor: ably reconnect by josh-logue · Pull Request #32666 ·
  multimediallc/chaturbate" doesn't contain `github.com`, and many titles name no site at all ("Inbox (3)",
  "Dashboard"). Every title change is followed by one URL read to get the host.
- **They're more sensitive than URLs.** That title alone exposes a PR name, its author and a private repo.

Storing titles or other metadata can be revisited later as a migration.

## Events

Everything is driven by notifications. The only timer is the one-second blip check below.

| Event | Source | Action |
|---|---|---|
| Frontmost app changed | `NSWorkspace.didActivateApplicationNotification` | Close the row, open a new one |
| Focused window or title changed in the frontmost app | `AXObserver` (`kAXFocusedWindowChangedNotification`, `kAXTitleChangedNotification`), moved to each new frontmost app | Browsers and Terminal, after half a second without further changes: read the host or program; if it changed, close the row and open a new one. Other apps: ignore |
| Mac sleeps / wakes | `NSWorkspace.willSleepNotification` / `didWakeNotification` | Close / resume |
| Display sleeps / wakes | `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification` | Close / resume |
| Screen locks / unlocks | `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` (distributed) | Close / resume |
| Screensaver starts / stops | `com.apple.screensaver.didstart` / `didstop` (distributed) | Close / resume |
| Switched to another user / back | `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification` | Close / resume |
| Logout or shutdown | `NSWorkspace.willPowerOffNotification`, `applicationWillTerminate` | Close. If the logout is cancelled, the next focus change opens a new row |
| Quit from the menu | `applicationWillTerminate` | Close |
| System clock changed | `NSSystemClockDidChangeNotification` | Close at the old time, open at the new time |
| Time zone changed | `NSSystemTimeZoneDidChangeNotification` | Nothing to store; the next midnight cut uses the new zone |
| Accessibility allowed or revoked | `com.apple.accessibility.api` (distributed) | Re-read what's in front and start watching its windows |

Each of these, as it starts or ends, is logged with what's still keeping Chronos from recording, if anything:
`log show --predicate 'subsystem == "com.kingbuzzman.chronos"'`. A gap in the data can be traced to its cause there.

**Resume** means: once the session is active, unlocked, awake, and the screensaver isn't running, open a row for
whatever is frontmost. Waking into a locked screen doesn't resume until it's unlocked.

## Database

`~/Library/Application Support/Chronos/chronos.sqlite`, in WAL mode so the viewer, `sqlite3` or any other tool can read
while the recorder writes.

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;
PRAGMA user_version = 3;

CREATE TABLE apps (
    id        INTEGER PRIMARY KEY,
    bundle_id TEXT NOT NULL UNIQUE,   -- com.google.Chrome: stable across renames and languages
    name      TEXT NOT NULL,          -- Google Chrome: latest display name seen
    kind      TEXT NOT NULL DEFAULT 'app' CHECK (kind IN ('app', 'program'))
                                      -- a program (claude) has its name as bundle_id
);

CREATE TABLE slots (
    id         INTEGER PRIMARY KEY,
    app_id     INTEGER NOT NULL REFERENCES apps(id),
    sub_app_id INTEGER REFERENCES apps(id),   -- the program running inside the app (claude in Terminal), or NULL
    domain     TEXT    NOT NULL DEFAULT '',   -- host for browsers, '' otherwise (NULL would break grouping)
    started_at INTEGER NOT NULL,              -- unix seconds, UTC
    ended_at   INTEGER CHECK (ended_at IS NULL OR ended_at >= started_at),  -- NULL while open
    duration   INTEGER GENERATED ALWAYS AS (ended_at - started_at) STORED,  -- NULL while open; SUM skips it
    continued  INTEGER NOT NULL DEFAULT 0     -- 1 = carried over from the previous day by the midnight split
);

CREATE INDEX slots_started_at ON slots(started_at);

-- At most one open row, enforced by SQLite (verified: a second open row fails with UNIQUE constraint failed).
CREATE UNIQUE INDEX slots_one_open ON slots (ended_at IS NULL) WHERE ended_at IS NULL;
```

### Writing

- **A new focus is written once it has lasted one second** (a one-shot timer, the only one in Chronos). Then, in one
  transaction, the old row is closed (`UPDATE ... SET ended_at`) and the new one opened (`INSERT` with
  `ended_at = NULL`).
  - Both use the moment focus *left* the old row, so the timeline has no gaps. Any sub-second blips passed through on
    the way count toward the new row.
  - Cmd-Tab blips never touch the disk. Coming back to the open row within the second leaves it untouched: no new row,
    no switch.
- **Slots are half-open:** `[started_at, ended_at)`. A closing row and the next row share the same instant, so
  durations add up exactly.
- **Midnight split:** a slot is cut at local midnight, so no row crosses a day.
  - The row before midnight ends at exactly `00:00:00`; a `continued = 1` row starts at the same instant.
  - Example: 22:00 → 00:10 becomes 22:00 → 00:00 (2h, previous day) and 00:00 → 00:10 (10m, `continued = 1`).
  - Local midnight comes from `Calendar`, so 23- and 25-hour days around clock changes are handled.
  - A slot open for several days is cut at each midnight.
  - Day, week, month and year totals are exact. Hour-level views are approximate for long slots; that's accepted.

### Time

- All timestamps are UTC unix seconds. Converting to local time happens only when reading.
- `ended_at` is `started_at` plus the time elapsed on a monotonic clock, so a clock correction during a slot can't
  stretch or shrink it.
- A manual clock change closes the row and opens a new one at the new time.
- Anything else, such as a dead clock battery at boot, isn't defended against.

### Crashes

1. **At crash time, best effort:** handlers for `SIGTERM`, `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGTRAP`, `SIGABRT` and
   uncaught exceptions (`NSSetUncaughtExceptionHandler`) try once to close the open row with the current time. The
   process is in an unknown state, so this may fail; it must never hang (an `alarm(2)` ends it). The handler can't
   split at midnight, so it ends a row at the next local midnight at the latest: time after it is lost rather than
   written into the wrong day.
2. **On the next launch:** any row still open is closed as `ended_at = started_at + 1`. This covers force quit
   (`SIGKILL`), power loss, and anything step 1 missed. The real end is unknown, so no time is invented.

### Reading

```sql
-- Today, by app and domain
SELECT a.name, s.domain, SUM(s.duration) AS seconds, SUM(s.continued = 0) AS switches
FROM slots s JOIN apps a ON a.id = s.app_id
WHERE s.started_at >= unixepoch('now', 'start of day', 'utc')
GROUP BY a.name, s.domain
ORDER BY seconds DESC;
```

- For other periods, group by `date(started_at, 'unixepoch', 'localtime')` (day), `strftime('%Y-W%W', ...)` (week),
  `'%Y-%m'` (month) or `'%Y'` (year).
- **Live numbers:** add `unixepoch() - started_at` for the open row.
- **Switch counts:** `SUM(continued = 0)` doesn't count a midnight carry-over as a switch.

### Migrations

- `PRAGMA user_version` holds the schema version. On launch, the recorder applies each missing step in order.
- Before migrating, it copies the database with `VACUUM INTO 'chronos.v<old>.sqlite'`. Backups are kept until you clear
  them.
- Each step runs in one transaction. A failed step rolls back, and the recorder refuses to run against a half-migrated
  file.
- Steps move all existing data into the new format. A migration never drops data.
- The viewer refuses to open a database newer than it understands. Shipping both in one bundle makes that unlikely.
- **Version 2** renamed `slots.domain` to `detail`, when Terminal programs joined browser hosts in it.
- **Version 3** made each Terminal program an app of its own (`apps.kind = 'program'`), pointed Terminal's slots at it
  with `sub_app_id`, and renamed `detail` back to `domain`, which holds only browser hosts again. "Only one of
  `domain` and `sub_app_id`" is enforced by the recorder, since SQLite can't add a check to an existing table without
  rebuilding it.

```sql
-- Time in claude, whatever it ran in; and Terminal's time, by program
SELECT SUM(s.duration) FROM slots s JOIN apps p ON p.id = s.sub_app_id WHERE p.kind = 'program' AND p.name = 'claude';
SELECT COALESCE(p.name, '-'), SUM(s.duration) FROM slots s JOIN apps a ON a.id = s.app_id
LEFT JOIN apps p ON p.id = s.sub_app_id WHERE a.bundle_id = 'com.apple.Terminal' GROUP BY 1;
```

Anything listing apps filters on `kind = 'app'`, or programs show up as apps. Reports group by the slot's `app_id`, so
Terminal's total includes the time of the programs run in it.

## Menu bar

Clicking the icon shows a menu:

```
Today: 6h 42m                 (not clickable)
Top: Google Chrome — 2h 10m   (not clickable)
Accessibility not granted     (not clickable; shown only while a permission is missing, Notifications too)
───────────────
Open Viewer
───────────────
Settings…                     (⌘,)
Quit
```

- The totals are computed when the menu opens, from today's rows plus the open row. Nothing updates in the background.
- "Open Viewer" launches the viewer, or brings it forward if it's already open.
- "Settings…" opens the viewer's Settings. A running viewer is asked with a distributed notification
  (`com.kingbuzzman.chronos.viewer.settings`); otherwise the viewer is launched with `--settings`, since it would miss
  a notification sent before it starts listening.

## Viewer (v1)

- A regular window with a Dock icon, opened from the menu's "Open Viewer" (or brought forward if it's open).
- Closing the window quits the viewer and removes it from the Dock; the recorder keeps running in the menu bar.
- It reopens where it was last closed, can be resized, and reloads its numbers when it comes to the front, then
  every 10 seconds while it stays there, so the open slot keeps counting. It does nothing while another app is in front.
- It lists every app with its total time for a period (day, week, month or year), most first, each with its icon
  and a bar scaled to the top app.
- Apps Chronos can see into open like an accordion, closed by default: Terminal to the programs run in it, browsers
  to their sites, each with its time and a bar showing its share of the app. Time Chronos couldn't place (before
  program tracking existed, or while a permission was missing) is listed last as "Not identified", however big.
- Hovering a site shows a ✕ at the row's far left, in line with the apps' chevrons. Clicking it forgets the site:
  its name is cleared from every slot of that browser, over all time rather than just the period on screen, and its
  time moves to "Not identified". It takes effect at once, without asking first, and can't be undone. Other browsers
  keep the site, and visiting it again records it again. The viewer runs this as one `UPDATE` while the recorder
  keeps writing, and only on the latest schema, since only the recorder migrates.
- Durations use one unit, rounded down: `42s` under a minute, `14m` under an hour, then `6h`. Hovering a row, the
  total, or the menu's totals shows two decimals in the same unit: `1.15m`, `1.15h`.
- More charts and categories come later.

### Schedule

Labels name parts of the week, such as Work from 9:00 to 17:00 Monday to Friday and Part-time from 18:00 to 20:00 on
Monday, Tuesday and Thursday. The rest of the week is **Unscheduled**.

- **Display only.** Recording never reads the schedule and the database has no column for it: a report is split by
  label when it's read. Changing a label changes every period, past ones included, and deleting one loses nothing.
  The recorder reads the file only for its allowances (below).
- **Stored in `schedule.json`,** next to the database (so `make run` keeps its own), written whole on every change.
  Each label has an ID, a name, a color by name (`blue`, `orange`, ...) and one or more hours, each a set of
  `Calendar` weekdays (1 is Sunday) with a start and end in minutes after midnight. An end at or before the start
  runs past midnight into the next day; the same as the start is a whole day.
- **No overlaps.** Each moment belongs to one label at most, so the labels and Unscheduled add up to the whole. The
  week is checked as minutes from Sunday's midnight, wrapping at Saturday's. Settings names the first clash ("Work
  and Part-time overlap on Monday from 4:00 PM to 5:00 PM") and doesn't save until it's fixed; the viewer keeps using
  the last saved schedule meanwhile.
- **Wall-clock hours.** 9 to 5 is 9 to 5 on the days the clocks change, so those days' labeled time is still 8 hours
  and Unscheduled time absorbs the extra or missing hour.
- **Reading by label:** the period is cut into consecutive windows, one per stretch of a label or between them,
  passed to one query as JSON (`json_each`). Each slot is clipped to every window it overlaps, so a Chrome slot from
  16:30 to 18:30 counts half an hour to Work, an hour to Unscheduled and half an hour to Part-time; it's a switch only
  in the window it started in. Closed slots never cross midnight, so each window reads only the index from a day
  before it; the open slot is read separately.
- **In the viewer,** with any labels, a bar under the total shows each label's share of the period in its color, and
  a chip per label, plus Unscheduled, shows just its apps, with bars in its color. Clicking the chip again shows all
  apps.

### Allowances

An allowance gives an app, a site or a Terminal program so much time a day, week or month, such as reddit.com for 30
minutes a day during Work. Going over brings a notification, and that's all.

- **Never interferes.** Chronos never closes, hides, blocks or slows anything, and recording doesn't change. The
  notification is the whole effect.
- **What can have one:** any app but a browser, by bundle ID; a site, which includes its subdomains (`google.com`
  covers `docs.google.com`, not `notgoogle.com`), in every browser; or a Terminal program, such as `claude`. A
  browser has no allowance of its own: its time is its sites'.
- **When it counts:** any time, during one label, or outside every label (Unscheduled). An allowance during a label
  is deleted with the label, since it could never count again. For more than one label, add one allowance per label.
- **Periods** are the local day, week (from the locale's first weekday) or month, like the viewer's, and the time
  used is read from the database the same way as a report by label: the period's windows that count, cut at their
  edges, plus the open slot up to now.
- **Stored in `schedule.json`** with the labels, under `allowances`: each has an ID, a `subject`
  (`{"site":{"domain":"reddit.com"}}`, `{"app":{"bundleID":…,"name":…}}` or `{"program":{"name":"claude"}}`), an
  `amount` and `unit` (`minutes` or `hours`), `per` (`day`, `week` or `month`) and, if not any time, `during`: a
  label's ID or `unscheduled`. Files from before allowances have none.
- **The recorder watches,** since it's always running and the viewer isn't. After each write it looks at what the
  open slot is for. If any allowance covers it, it works out when that allowance would run out if focus stayed put
  (counting only the windows that count, and no later than the end of the period) and sleeps until then, or until
  the next focus change, whichever comes first. With nothing that has an allowance in front, nothing is scheduled.
- **Notices:** when the time used reaches the allowance in time that counts, and every 15 minutes after that while
  the subject stays in front, or as soon as it comes back if longer than that. Each allowance's notice replaces its
  last one in Notification Center. "Time to stop: reddit.com. You're over its allowance: 34m of 30m today during
  Work."
- **Reloading:** the viewer posts `com.kingbuzzman.chronos.schedule.saved` after each save; the recorder also reads
  the file again whenever its modification date has changed, so hand edits count too.
- **Notifications** are asked for the first time there's an allowance. If they're turned off, the menu says so.
- **In Settings,** each allowance reads as a sentence ("30 minutes a day during Work") under its name, with how much
  is used so far and a bar, red once over. New ones are picked from the apps, sites and programs of the last 30 days,
  or any site by name.

### Settings and About

Settings (⌘, or the app menu in the viewer, or "Settings…" in the menu bar) has four panes, and opens on the first.
**General** turns opening at login on and off (below). **Schedule** edits the
labels above, and **Allowances** the allowances. **About** (also "About Chronos") shows the version from the bundle ("Development build" outside one),
links to the project, this version's release notes and new issues, how much has been recorded since when, and where
the database is. Its icon's hands show the current time.

### Opening at login

- **The recorder registers itself,** with `SMAppService.mainApp`: only an app can make itself a login item, and the
  recorder is what should open. Whichever `Chronos.app` is running is the one registered.
- **The viewer only asks.** General's toggle posts `com.kingbuzzman.chronos.login.set` (on or off) and, when it
  appears, `com.kingbuzzman.chronos.login.ask`. The recorder answers both with `com.kingbuzzman.chronos.login.status`:
  `on`, `off` or `needsApproval`, plus the error if registering failed.
- **No answer in two seconds** means the recorder isn't running; the toggle stays off-limits and says so.
- **`needsApproval`:** registered, but switched off under System Settings → General → Login Items. The toggle shows
  on, with a link to that pane.

## Permissions

- **Accessibility:** needed to see window and title changes, which is how browser tab switches and new Terminal
  programs are detected. Without it, Chronos records app-level time only and shows the warning line in the menu.
- **Firefox:** needs no macOS permission; chronos-ff asks Firefox for "Access browser tabs" when it's loaded.
- **Automation:** asked once per browser and once for Terminal, the first time Chronos asks it. Without it, that app is
  recorded at app level only.
- **Notifications:** asked the first time there's an allowance. Without them, allowances are silent and the menu
  shows a warning line.
- **Info.plist:** `LSUIElement = true`, `NSAppleEventsUsageDescription`.
- **No App Sandbox:** a sandboxed app can't use Accessibility on other apps. This also rules out the Mac App Store.
- **Hardened runtime:** with the `com.apple.security.automation.apple-events` entitlement.
- **Signing:** local builds use a self-signed certificate from the keychain, `Chronos Local` by default
  (`CODESIGN_IDENTITY`), so Accessibility and Automation survive rebuilds. CI builds, and the releases made from them,
  are signed ad hoc, so each one is a new app to macOS and asks for both again.

## Project layout

```
chronos/
├── Package.swift            # macOS 14+
├── Makefile                 # build, bundle (nest viewer, sign inside-out), run, install, test, lint
├── VERSION                  # shared by both bundles
├── DESIGN.md
├── Resources/
│   ├── Chronos-Info.plist
│   ├── Viewer-Info.plist
│   └── Chronos.entitlements
├── Sources/
│   ├── ChronosCore/         # shared: schema, migrations, models, queries, host normalization, midnight split, foreground job
│   ├── Chronos/             # recorder: AppKit status item, event sources, AX observer, detail readers, crash handlers
│   ├── ChronosViewer/       # viewer: SwiftUI + Swift Charts; reads, except forgetting a site
│   ├── ChronosFirefoxHost/  # chronos-ff-host: relays between the Firefox extension and the recorder
│   └── IconMaker/           # build-time only: renders the app icon from ChronosCore's Logo
├── Tests/ChronosCoreTests/
└── chronos-ff/              # the Firefox extension: manifest, domain.js (+ node tests), background.js
```

**Logo:** a wristwatch at ten past ten, white on a black rounded square for the app icon, and the bare watch as a
template image in the menu bar (macOS tints it for light and dark). Both come from `Logo.swift` in `ChronosCore`:
the menu bar draws it at runtime, and `IconMaker`, a build-time tool that isn't shipped, renders the app icon's
iconset, which `make` turns into `AppIcon.icns` with `iconutil`.

`make run` launches the build through `open`, so Chronos asks for its permissions itself rather than through the
terminal, against `build/chronos.sqlite` instead of the real database (`CHRONOS_DATABASE`).

## Tests

`ChronosCore` is unit-tested with an injected clock and time zone:

- **Midnight split:** a normal day; slots crossing midnight and spanning several days; 23- and 25-hour days around
  clock changes.
- **Half-open intervals:** durations add up exactly.
- **Blips:** slots under one second are never written.
- **Open-row constraint:** a second open row is rejected.
- **Crash recovery:** an open row is closed as `started_at + 1`.
- **Migrations:** each step preserves every row, and a backup is written first.
- **Host normalization:** every example in [What is recorded](#what-is-recorded).
- **Terminal programs:** the launch name from `KERN_PROCARGS2`, not the file's name, and nothing past the first
  argument.

- **Schedule:** overlaps (including past midnight and across Saturday night), windows on ordinary days, days off
  and clock-change days, and a report cut at each label's edges.
- **Allowances:** sites with subdomains but not lookalikes, apps and programs, time only during a label or outside
  every label, when one runs out across windows, when to notify and remind, and old schedule files without them.
- **Native messaging framing:** whole, partial and back-to-back messages, and a broken length.
- **chronos-ff's `domainOf`** (`node --test chronos-ff/*.test.js`, part of `make test`): only the domain, never a path, query
  or password.

The event sources and detail readers talk to macOS and are verified by running the app.

## Running

Chronos records while it's running and doesn't while it isn't. There's no Open at Login feature: you launch it
yourself, or add it to Login Items in System Settings.

**Only one recorder ever runs.** At launch, before anything else, it takes an exclusive `flock` on
`~/Library/Application Support/Chronos/chronos.lock` and holds it until it exits. Any other copy, whether a second
bundle (`build/` and `~/Applications`), `open -n`, or the program run directly, can't take it and quits at once, before
recording or showing its icon. The system drops the lock when the process ends, crashes included, so it never goes
stale. The lock ignores `CHRONOS_DATABASE`: one recorder per user, even when trying things out against another
database.

## Later

- **Categories (Work, Communication, ...):** design them when the viewer needs them.
- **Top-level domain grouping:** for the viewer, `github.com` is easy, but `bbc.co.uk` needs a public suffix list.
  Decide when the viewer shows domains.
- **More metadata,** such as window titles: added through a migration if wanted.
- **Excluded apps** and **private-window handling:** display decisions, made once there's data.
- **Signing releases** with a Developer ID, so a downloaded Chronos opens without a warning and keeps its permissions
  across updates.
- **Signing chronos-ff** through Mozilla (unlisted, free with a Mozilla account), so regular Firefox keeps it across
  restarts instead of loading it temporarily.
- **A Screen Time–style viewer**, with a Mac twist: a dashboard (today's time counting up, what's in front, tiles for
  apps used, most used, daily average, top app; a usage-share donut; top apps with bars; today vs yesterday) and
  statistics (7/14/30 days: total, daily average, peak day, trend; daily bars; this week vs last). Modeled on Screen
  Time – Digital Wellbeing for Windows. Everything it shows can be computed from `slots`.
- **Usage warnings, not blocking:** tell the user when an app has been used more than its allowed amount. Chronos
  never closes apps.
- **More terminals:** iTerm2 exposes the focused session's tty the same way; Ghostty, Warp, VS Code's terminal and
  others need their own way in.
- **Inside tmux and ssh:** today the program in front shows as `tmux` or `ssh`, not what runs inside or on the other
  side.
- **Tools installed through npm** run as `node`, so they'd show as `node` rather than their own name.
- **Sites as apps too:** move browser hosts from `domain` into `apps` (`kind = 'site'`) and `sub_app_id`, like
  programs, if usage warnings or reports need sites and programs to work the same way. Until then, keep code that
  depends on the text `domain` to a minimum.
