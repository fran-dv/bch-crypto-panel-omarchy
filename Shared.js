.pragma library

// Process-wide request state shared by every panel instance.
//
// The bar is instantiated once per monitor, and each instance loads its own
// Panel.qml. A `.pragma library` script is created once per QML engine, so
// keeping caches, in-flight markers and the backoff gate here means N monitors
// still cost one request per refresh window, and a rate limit seen by one
// instance pauses all of them.

// ---- Tuning ---------------------------------------------------------------

var QUOTE_POLL_AGE_MS = 55 * 1000        // background refresh when older than this
var QUOTE_MANUAL_AGE_MS = 30 * 1000      // open/refresh won't refetch anything younger
var CHART_TTL_1D_MS = 60 * 1000
var CHART_TTL_MS = 5 * 60 * 1000
var CHART_MANUAL_AGE_MS = 30 * 1000
var SEARCH_TTL_MS = 10 * 60 * 1000
var SEARCH_MAX_ENTRIES = 40
var BACKOFF_BASE_MS = 60 * 1000          // 60s -> 120s -> 240s
var BACKOFF_MAX_STEPS = 3
var IN_FLIGHT_TIMEOUT_MS = 20 * 1000     // curl --max-time is 8s; covers a destroyed owner

// ---- State ----------------------------------------------------------------

var quotes = {}      // coin id -> { at, data }
var charts = {}      // "id:days" -> { at, points }
var searches = {}    // lowercased query -> { at, results }
var inFlight = {}    // request key -> started-at ms
var gate = { failures: 0, blockedUntil: 0, rateLimited: false }

var listeners = []

// ---- Change notification --------------------------------------------------

function subscribe(fn) {
  if (listeners.indexOf(fn) === -1) listeners.push(fn)
}

function unsubscribe(fn) {
  var i = listeners.indexOf(fn)
  if (i !== -1) listeners.splice(i, 1)
}

function notify() {
  var alive = []
  for (var i = 0; i < listeners.length; i++) {
    try {
      listeners[i]()
      alive.push(listeners[i])
    } catch (e) {
      // Owner was torn down (plugin reload) without unsubscribing; drop it.
    }
  }
  listeners = alive
}

// ---- Backoff gate ---------------------------------------------------------

function canRequest(now) {
  return now >= gate.blockedUntil
}

function retryInMs(now) {
  return Math.max(0, gate.blockedUntil - now)
}

// Transport errors, 429 and 5xx are the API telling everyone to slow down.
// Other 4xx (e.g. an unknown coin id) are specific to that request.
function isBackoffStatus(status) {
  return status === 0 || status === 429 || status >= 500
}

function recordResult(status, now) {
  if (status >= 200 && status < 300) {
    if (gate.failures !== 0 || gate.blockedUntil !== 0) {
      gate = { failures: 0, blockedUntil: 0, rateLimited: false }
    }
    return true
  }
  if (isBackoffStatus(status)) {
    var failures = Math.min(gate.failures + 1, BACKOFF_MAX_STEPS)
    gate = {
      failures: failures,
      blockedUntil: now + BACKOFF_BASE_MS * Math.pow(2, failures - 1),
      rateLimited: status === 429
    }
  }
  return false
}

// ---- In-flight dedupe -----------------------------------------------------

function tryBegin(key, now) {
  var started = inFlight[key]
  if (started && now - started < IN_FLIGHT_TIMEOUT_MS) return false
  inFlight[key] = now
  return true
}

function end(key) {
  delete inFlight[key]
}

function isInFlight(key, now) {
  var started = inFlight[key]
  return !!started && now - started < IN_FLIGHT_TIMEOUT_MS
}

// ---- Quotes ---------------------------------------------------------------

function quote(id) {
  var q = quotes[id]
  return q ? q.data : null
}

function quoteAt(id) {
  var q = quotes[id]
  return q ? q.at : 0
}

function quoteKey(id) {
  return "quote:" + id
}

function needsQuote(id, maxAge, now) {
  return now - quoteAt(id) >= maxAge
    && canRequest(now)
    && !isInFlight(quoteKey(id), now)
}

// Newer data wins, so a slow response or an old disk cache never overwrites
// a fresher quote.
function storeQuote(id, data, at) {
  if (!data) return false
  if (quotes[id] && at <= quotes[id].at) return false
  quotes[id] = { at: at, data: data }
  return true
}

// ---- Charts ---------------------------------------------------------------

function chartKey(id, days) {
  return id + ":" + days
}

function chartTtl(days) {
  return days === "1" ? CHART_TTL_1D_MS : CHART_TTL_MS
}

function chart(id, days) {
  var c = charts[chartKey(id, days)]
  return c ? c.points : null
}

function needsChart(id, days, force, now) {
  var c = charts[chartKey(id, days)]
  var age = c ? now - c.at : Infinity
  var maxAge = force ? CHART_MANUAL_AGE_MS : chartTtl(days)
  return age >= maxAge
    && canRequest(now)
    && !isInFlight("chart:" + chartKey(id, days), now)
}

function storeChart(id, days, points, at) {
  charts[chartKey(id, days)] = { at: at, points: points }
}

// ---- Search ---------------------------------------------------------------

function searchKey(query) {
  return String(query || "").trim().toLowerCase()
}

function cachedSearch(query, now) {
  var s = searches[searchKey(query)]
  return s && now - s.at < SEARCH_TTL_MS ? s.results : null
}

function storeSearch(query, results, at) {
  searches[searchKey(query)] = { at: at, results: results }
  var keys = Object.keys(searches)
  if (keys.length <= SEARCH_MAX_ENTRIES) return
  keys.sort(function(a, b) { return searches[a].at - searches[b].at })
  for (var i = 0; i < keys.length - SEARCH_MAX_ENTRIES; i++) delete searches[keys[i]]
}
