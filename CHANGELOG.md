# Changelog

Each release's notes on GitHub come from its section here (see `.github/workflows/release.yml`).

## 0.2.0

Settings, for the hours you keep and the time you allow.

- Label parts of your week in Settings, like Work from 9 to 5 on weekdays and Part-time on Monday evenings. The
  viewer splits your time by label, with everything else as Unscheduled, and shows one label's apps at a click.
  Labels only change how time is shown, so they apply to everything already recorded.
- Allowances: give an app, a site or a Terminal program so much time a day, week or month, any time or only during a
  label. Go over and a notification says so, then again every 15 minutes you stay. Chronos never closes or blocks
  anything. Browsers have no allowance of their own; their sites do, in every browser.
- Settings opens from the menu bar ("Settings…") or with ⌘, in the viewer. Its About pane shows the version, links to
  the project, and how much has been recorded since when.
- Fixed: recording could stay paused after unlocking the Mac until Chronos was restarted. An unlock now always
  resumes it.
- Building it yourself now takes Xcode 27, and signs with a `Chronos Local` certificate you create once in Keychain
  Access, so macOS keeps Chronos's permissions across rebuilds.

## 0.1.0

The first release.

- Lives in the menu bar and records which app is in front, and for how long, while your Mac is in use. It stops
  counting when the Mac sleeps, locks, shows the screensaver or switches to another user.
- For browsers, records the site: Safari, Chrome, Arc, Brave, Edge and Vivaldi, and Firefox through its companion
  extension, `chronos-ff`. Only the site's name is kept, never the page.
- For Terminal, records the program in front, such as `claude` or `vim`. Only its name is kept, never what you typed.
- The menu shows today's total and your top app. The viewer lists every app by time for a day, week, month or year,
  with its sites or programs inside.
- Forget a site from the viewer, and it's cleared from your history for good.
- Everything stays in one file on your Mac.
