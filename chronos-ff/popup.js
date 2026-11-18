// The toolbar button's popup: how the channel to Chronos is doing, and what to do when Chronos isn't getting sites.

const STATES = {
  connecting: "Connecting to Chronos's helper…",
  connected: "Connected to Chronos's helper",
  down: "Not connected to Chronos's helper",
};

function ago(ms) {
  if (ms === null) return "never";
  const seconds = Math.max(Math.round((Date.now() - ms) / 1000), 0);
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  return `${Math.floor(seconds / 3600)}h ago`;
}

function hint(status) {
  if (status.state === "down" && /no such native application/i.test(status.error)) {
    return "Firefox can't find Chronos's helper. Run make ff-register in the Chronos folder, then try again.";
  }
  if (status.state === "down") {
    return "Chronos's helper stopped or couldn't start. Check Chronos.app is still where make ff-register pointed, then try again.";
  }
  if (status.state === "connecting") {
    return "Waiting for Chronos's helper. If this doesn't change, it may be older than this extension: run make ff-register again.";
  }
  if (status.asked === null) {
    return "Connected, but Chronos hasn't asked for a site yet. Is Chronos running? It asks each time Firefox comes to the front.";
  }
  return "Chronos is getting the site in front.";
}

function show(status) {
  const rows = [["Channel", STATES[status.state]]];
  if (status.state === "down") rows.push(["Why", status.error]);
  rows.push(
    ["Chronos asked", ago(status.asked)],
    ["Last sent", status.sent === null ? "never" : `${status.domain || "no site"}, ${ago(status.sent)}`],
    ["Version", browser.runtime.getManifest().version]
  );
  document.getElementById("status").replaceChildren(
    ...rows.flatMap(([term, detail]) => {
      const dt = document.createElement("dt");
      dt.textContent = term;
      const dd = document.createElement("dd");
      dd.textContent = detail;
      return [dt, dd];
    })
  );
  document.getElementById("hint").textContent = hint(status);
  document.getElementById("again").textContent = status.state === "connected" ? "Send the site now" : "Try again";
}

document.getElementById("again").addEventListener("click", async () => {
  show(await browser.runtime.sendMessage("retry"));
  // A reconnect's hello takes a moment.
  setTimeout(async () => show(await browser.runtime.sendMessage("status")), 500);
});

browser.runtime.sendMessage("status").then(show);
