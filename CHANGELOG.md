# Changelog

Each release's notes on GitHub come from its section here (see `.github/workflows/release.yml`).

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
