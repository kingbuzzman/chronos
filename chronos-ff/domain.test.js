// node --test chronos-ff/*.test.js
const assert = require("node:assert");
const test = require("node:test");
const { domainOf } = require("./domain.js");

test("keeps only the domain", () => {
  const cases = {
    "https://www.github.com/multimediallc/chaturbate/pull/123": "github.com",
    "https://docs.google.com/document/d/abc?tab=t.0#heading": "docs.google.com",
    "HTTPS://WWW.Example.COM/Path": "example.com",
    "http://localhost:8000/admin": "localhost:8000",
    "https://user:secret@example.com/": "example.com",
    "about:newtab": "about:newtab",
    "about:blank": "about:blank",
    "file:///Users/javier/notes.html": "file://",
    "moz-extension://abc-123/popup.html": "moz-extension://abc-123",
    "data:text/html,<p>secret</p>": "data:",
  };
  for (const [url, domain] of Object.entries(cases)) assert.strictEqual(domainOf(url), domain, url);
});

test("nothing for what isn't an address", () => {
  for (const url of ["", "not a url", undefined]) assert.strictEqual(domainOf(url), "");
});
