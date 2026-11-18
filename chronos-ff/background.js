// chronos-ff: tells Chronos the domain of the tab you're looking at, whenever it changes and whenever Chronos asks.
// Only the domain ever leaves Firefox: never the address, title or anything else about the tab. Chronos decides what
// to do with it; if Chronos isn't running, the domain goes nowhere.

// Firefox starts this helper, which ships inside Chronos.app, and keeps a channel to it open.
const HOST = "com.kingbuzzman.chronos";
// If the channel closes (the helper ended, or isn't installed), try again after this long, so Chronos can still ask.
const RECONNECT_MS = 30_000;

let port = null;
let last = null;
let retry = null;
// How the channel to Chronos is doing, for the toolbar button: a "!" badge while it's down, and the rest in its popup,
// to tell why Chronos isn't getting sites. Kept in memory only, like everything else here.
const status = {
  // "connecting" until the helper says hello, "connected" after, and "down" once the channel closes.
  state: "connecting",
  // Why the channel last closed, as Firefox put it, such as "No such native application com.kingbuzzman.chronos".
  error: null,
  // When Chronos last asked for the domain, and when one was last passed on, in ms since the epoch; null if never.
  asked: null,
  sent: null,
  // The domain last passed on.
  domain: null,
};

function connect() {
  retry = null;
  status.state = "connecting";
  port = browser.runtime.connectNative(HOST);
  port.onMessage.addListener((message) => {
    if (message && message.hello) {
      status.state = "connected";
      status.error = null;
      console.info("chronos-ff: connected to Chronos's helper");
      showStatus();
      // The tab may have changed while the channel was down.
      report(true);
    }
    if (message && message.ask === "domain") {
      status.asked = Date.now();
      report(true);
    }
  });
  port.onDisconnect.addListener((closed) => {
    port = null;
    status.state = "down";
    status.error = (closed.error && closed.error.message) || "the helper ended";
    console.warn(`chronos-ff: lost Chronos's helper (${status.error}); trying again in ${RECONNECT_MS / 1000}s`);
    showStatus();
    retry = setTimeout(connect, RECONNECT_MS);
  });
  showStatus();
}

function showStatus() {
  const down = status.state === "down";
  browser.browserAction.setBadgeText({ text: down ? "!" : "" });
  browser.browserAction.setBadgeBackgroundColor({ color: "#d70022" });
  browser.browserAction.setTitle({ title: down ? `Chronos: not connected (${status.error})` : "Chronos" });
}

// The tab in front: the active tab of the window that last had focus. "" when there's none, or it's a private window
// the extension isn't allowed in.
async function currentDomain() {
  const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
  return tab && tab.url ? domainOf(tab.url) : "";
}

// Changes are reported once; Chronos's questions are always answered, even when nothing changed.
async function report(always) {
  try {
    const domain = await currentDomain();
    if (!always && domain === last) return;
    last = domain;
    if (!port) return;
    port.postMessage({ domain });
    status.sent = Date.now();
    status.domain = domain;
  } catch (error) {
    console.error("chronos-ff: couldn't report the domain:", error);
  }
}

// The popup asks how things are, or to try again now: reconnect if the channel is down, otherwise send the domain.
browser.runtime.onMessage.addListener(async (message) => {
  if (message === "retry") {
    if (port) {
      await report(true);
    } else {
      clearTimeout(retry);
      connect();
    }
  }
  if (message === "status" || message === "retry") return { ...status };
});

browser.tabs.onActivated.addListener(() => report(false));
browser.tabs.onUpdated.addListener(
  (tabId, change, tab) => {
    if (tab.active) report(false);
  },
  { properties: ["url"] }
);
browser.windows.onFocusChanged.addListener((windowId) => {
  if (windowId !== browser.windows.WINDOW_ID_NONE) report(false);
});

connect();
report(false);
