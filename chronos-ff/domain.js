// The only part of a tab's address chronos-ff ever passes on: its domain. Mirrors Chronos's own rules (Host.swift),
// which apply again when the domain arrives.
//
//   https://www.github.com/a/b?c  → github.com
//   http://localhost:8000/admin   → localhost:8000
//   about:newtab                  → about:newtab
//   file:///Users/me/notes.html   → file://
//   moz-extension://abc/page.html → moz-extension://abc
//   anything unreadable           → ""
function domainOf(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return "";
  }
  switch (parsed.protocol) {
    case "http:":
    case "https:":
      return parsed.host.toLowerCase().replace(/^www\./, "");
    case "file:":
      return "file://";
    case "about:":
      return "about:" + parsed.pathname;
    default:
      return parsed.host ? `${parsed.protocol}//${parsed.host.toLowerCase()}` : parsed.protocol;
  }
}

if (typeof module !== "undefined") module.exports = { domainOf };
