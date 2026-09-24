// Unit tests for the plugin's pure JS (request gate, caches, parsing).
// Run from the repo root: node --test tests/
//
// The sources are QML `.pragma library` scripts, so they are evaluated in a
// fresh vm context per test instead of being required as CommonJS modules.
// Top-level `var` bindings stay live on the context object.

const { test } = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

function load(file) {
  const src = fs.readFileSync(path.join(__dirname, "..", file), "utf8").replace(/^\.pragma library\s*$/m, "")
  const ctx = vm.createContext({})
  vm.runInContext(src, ctx, { filename: file })
  return ctx
}

const T = 1_000_000

test("in-flight dedupe blocks duplicate requests and expires stale claims", () => {
  const S = load("Shared.js")
  assert.ok(S.needsQuote("bch", S.QUOTE_MANUAL_AGE_MS, T))
  assert.ok(S.tryBegin(S.quoteKey("bch"), T))
  assert.ok(!S.tryBegin(S.quoteKey("bch"), T + 100))
  assert.ok(!S.needsQuote("bch", S.QUOTE_MANUAL_AGE_MS, T + 100))
  assert.ok(S.tryBegin(S.quoteKey("bch"), T + S.IN_FLIGHT_TIMEOUT_MS + 1))
})

test("fresh quotes suppress manual refetches; older data never wins", () => {
  const S = load("Shared.js")
  assert.ok(S.storeQuote("bch", { price: 1 }, T))
  assert.ok(!S.needsQuote("bch", S.QUOTE_MANUAL_AGE_MS, T + 29_000))
  assert.ok(S.needsQuote("bch", S.QUOTE_MANUAL_AGE_MS, T + 30_000))
  assert.ok(!S.storeQuote("bch", { price: 0 }, T - 1))
  assert.equal(S.quote("bch").price, 1)
  assert.ok(S.storeQuote("eth", { price: 5 }, 0), "legacy cache with at=0 fills an empty slot")
})

test("backoff gate: 60s, 120s, capped at 240s; 404 ignored; success resets", () => {
  const S = load("Shared.js")
  S.recordResult(429, T)
  assert.ok(!S.canRequest(T + 59_999))
  assert.ok(S.canRequest(T + 60_000))
  assert.ok(S.gate.rateLimited)
  S.recordResult(0, T)
  assert.equal(S.gate.blockedUntil - T, 120_000)
  assert.ok(!S.gate.rateLimited)
  S.recordResult(503, T)
  assert.equal(S.gate.blockedUntil - T, 240_000)
  S.recordResult(429, T)
  assert.equal(S.gate.blockedUntil - T, 240_000)
  assert.ok(!S.needsQuote("bch", 0, T + 1000), "closed gate blocks quotes")
  assert.ok(!S.needsChart("bch", "1", true, T + 1000), "closed gate blocks charts")
  const blocked = S.gate.blockedUntil
  S.recordResult(404, T)
  assert.equal(S.gate.blockedUntil, blocked)
  assert.ok(S.recordResult(200, T))
  assert.ok(S.canRequest(T))
  assert.equal(S.gate.failures, 0)
})

test("chart TTLs: 1D 60s, longer ranges 5min, forced refresh 30s", () => {
  const S = load("Shared.js")
  S.storeChart("bch", "1", [1, 2], T)
  S.storeChart("bch", "7", [1, 2], T)
  assert.ok(!S.needsChart("bch", "1", false, T + 59_000))
  assert.ok(S.needsChart("bch", "1", false, T + 60_000))
  assert.ok(!S.needsChart("bch", "7", false, T + 299_000))
  assert.ok(!S.needsChart("bch", "7", true, T + 29_000))
  assert.ok(S.needsChart("bch", "7", true, T + 30_000))
})

test("search cache normalizes queries, expires and stays bounded", () => {
  const S = load("Shared.js")
  S.storeSearch(" ETH ", [{ id: "ethereum" }], T)
  assert.ok(S.cachedSearch("eth", T + 1))
  assert.equal(S.cachedSearch("eth", T + S.SEARCH_TTL_MS), null)
  for (let i = 0; i < 60; i++) S.storeSearch("q" + i, [], T + i)
  assert.equal(Object.keys(S.searches).length, S.SEARCH_MAX_ENTRIES)
  assert.ok(S.cachedSearch("q59", T + 60), "newest entries survive pruning")
})

test("listeners: dead ones are dropped, live ones keep firing", () => {
  const S = load("Shared.js")
  let hits = 0
  const ok = () => hits++
  S.subscribe(ok)
  S.subscribe(() => { throw new Error("destroyed owner") })
  S.notify()
  S.notify()
  assert.equal(hits, 2)
  assert.equal(S.listeners.length, 1)
  S.unsubscribe(ok)
  assert.equal(S.listeners.length, 0)
})

test("pinned disk cache: current format, 1.0.0 format, garbage", () => {
  const M = load("Model.js")
  assert.equal(M.parsePinnedCache('{"at":5,"data":{"price":2}}').at, 5)
  const legacy = M.parsePinnedCache('{"price":3}')
  assert.equal(legacy.at, 0)
  assert.equal(legacy.data.price, 3)
  assert.equal(M.parsePinnedCache("nope"), null)
  assert.equal(M.parsePinnedCache(""), null)
  assert.equal(M.parsePinnedCache('{"data":{}}'), null)
})

test("curl output splitting and formatting", () => {
  const M = load("Model.js")
  const res = M.splitResponse('{"a":1}\n429')
  assert.equal(res.status, 429)
  assert.equal(res.body, '{"a":1}')
  assert.equal(M.splitResponse("").status, 0)
  assert.equal(M.formatPillPrice(267.89), "267.89")
  assert.equal(M.formatPillPrice(12345.6), "12,345.60")
  assert.equal(M.formatPillPrice(0.123456), "0.1235")
  assert.equal(M.formatPrice(1234.5), "$1,234.50")
  assert.equal(M.formatCompact(5.3e9), "$5.30B")
  assert.equal(M.formatPct(-1.234), "▼1.23%")
})
