// chronos-ff: tells Chronos the domain of the tab you're looking at, whenever it changes and whenever Chronos asks.
// Only the domain ever leaves Firefox: never the address, title or anything else about the tab. Chronos decides what
// to do with it; if Chronos isn't running, the domain goes nowhere.

// Firefox starts this helper, which ships inside Chronos.app, and keeps a channel to it open.
const HOST = "com.kingbuzzman.chronos";
// If the channel closes (the helper ended, or isn't installed), try again after this long, so Chronos can still ask.
const RECONNECT_MS = 30_000;

let port = null;
let last = null;

function connect() {
  port = browser.runtime.connectNative(HOST);
  port.onMessage.addListener((message) => {
    if (message && message.ask === "domain") report(true);
  });
  port.onDisconnect.addListener(() => {
    port = null;
    setTimeout(connect, RECONNECT_MS);
  });
}

// The tab in front: the active tab of the window that last had focus. "" when there's none, or it's a private window
// the extension isn't allowed in.
async function currentDomain() {
  const [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
  return tab && tab.url ? domainOf(tab.url) : "";
}

// Changes are reported once; Chronos's questions are always answered, even when nothing changed.
async function report(always) {
  const domain = await currentDomain();
  if (!always && domain === last) return;
  last = domain;
  if (port) port.postMessage({ domain });
}

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
