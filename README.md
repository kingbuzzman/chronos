# Chronos

**Know where your day actually went.**

You sit down at nine, look up at six, and wonder what happened to the hours in between. Chronos answers that
question. It quietly keeps track of which app you're using and for how long. In a browser it also notes which site
you're on, and in Terminal which program. At any point you can open it and see your day, week, month or year laid
out plainly: what took the most time, and how much.

### Why Chronos

- **It stays out of your way.** A small watch icon in the menu bar is all you see. There's nothing to start, stop
  or tag. Chronos only does something when you switch to a different app, tab or site, so it doesn't slow your Mac
  down or drain the battery.
- **Your data stays on your Mac.** No account, no cloud and no sign-up. Everything is kept in one file on your
  computer, and nothing is ever sent anywhere.
- **It's private by design.** For websites, Chronos keeps only the site's name, such as `github.com`. It never keeps
  the page you were reading, what you searched for, or window titles. For Terminal, it records the name of the
  program and never what you typed.
- **It doesn't invent time.** If your Mac sleeps, locks, shows the screensaver or switches to another user, Chronos
  stops counting. If it can't tell exactly when something ended, it records less time rather than more, so the
  numbers you see are real.
- **You can forget a site.** If you don't want a site in your history, hover over it and click ✕. Its name is gone
  for good.
- **It works with the browsers you use:** Safari, Chrome, Arc, Brave, Edge, Vivaldi and Firefox.

### What you see

- **In the menu bar:** click the watch to see today's total and the app you've spent the most time in.
- **In the viewer:** every app you've used, ranked by time, with a bar for each. Open a browser to see its sites,
  or Terminal to see its programs.

---

## How to use it

### What you need

- A Mac running macOS 14 (Sonoma) or later.
- To build it yourself: Xcode 26 or later, and Node.js to run the Firefox extension's tests.

### Get Chronos

**Build it yourself** (recommended):

```sh
git clone https://github.com/kingbuzzman/chronos.git
cd chronos
make install        # builds Chronos and copies it to ~/Applications
```

**Or download a build:** every passing build on GitHub is saved for two days. Open the
[Actions tab](https://github.com/kingbuzzman/chronos/actions), choose the latest green run, and download the `chronos`
file under **Artifacts**. Unzip it and move `Chronos.app` to your Applications folder. These builds aren't signed by
Apple, so the first time you open one, macOS will refuse. Go to **System Settings → Privacy & Security** and click
**Open Anyway**.

### Start it

1. Open **Chronos** from your Applications folder. A watch appears in the menu bar. There's no window and no Dock
   icon.
2. Allow what macOS asks for:
   - **Accessibility** lets Chronos notice when you switch tabs or start a program in Terminal. Without it, Chronos
     still tracks apps, just not sites or programs.
   - **Automation** is asked once per browser, and once for Terminal, the first time Chronos needs it. It lets Chronos
     read which site or program is in front.
3. Use your Mac as usual.

To have Chronos start every time you log in, add it under **System Settings → General → Login Items**.

### See your time

- Click the watch in the menu bar for today's total and your top app.
- Choose **Open Viewer** for the full picture. Pick a day, week, month or year, and click an app's arrow to see
  what's inside it.
- To remove a site from your history, hover over it in the viewer and click the ✕ on its left. This can't be undone.

### Using Firefox?

Firefox needs a small companion extension before Chronos can see which site you're on:

```sh
make ff-register    # tells Firefox where to find Chronos
```

Then in Firefox, go to `about:debugging` → **This Firefox** → **Load Temporary Add-on**, and choose
`build/chronos-ff.xpi`. Until the extension is signed by Mozilla, Firefox forgets it when it quits, so you'll need to
load it again after each restart.

### Stop it

Click the watch and choose **Quit**. Chronos only records while it's running.

### Where your data lives

Everything is in `~/Library/Application Support/Chronos/chronos.sqlite`. Delete that file to start over.

### For developers

| Command | What it does |
|---|---|
| `make` | Builds `build/Chronos.app` and the Firefox extension |
| `make run` | Runs the build against a test database in `build/`, leaving your real data alone |
| `make test` | Runs every test |
| `make lint` | Checks formatting (`make format` fixes it) |
| `make install` | Copies the app to `~/Applications` |
| `make clean` | Deletes everything the build made |

How Chronos works inside, and why, is in [DESIGN.md](DESIGN.md).
