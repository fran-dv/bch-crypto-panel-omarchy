.pragma library

// Pure helpers for the crypto panel: response parsing and number formatting.

var API = "https://api.coingecko.com/api/v3"

// curl is run with `-w "\n%{http_code}"`, so the last line is the status.
function splitResponse(raw) {
  var text = String(raw || "")
  var cut = text.lastIndexOf("\n")
  if (cut < 0) return { status: Number(text.trim()) || 0, body: "" }
  return { status: Number(text.slice(cut + 1).trim()) || 0, body: text.slice(0, cut) }
}

function marketsUrl(id) {
  return API + "/coins/markets?vs_currency=usd&ids=" + encodeURIComponent(id)
}

function chartUrl(id, days) {
  return API + "/coins/" + encodeURIComponent(id) + "/market_chart?vs_currency=usd&days=" + days
}

function searchUrl(query) {
  return API + "/search?query=" + encodeURIComponent(query)
}

function num(v) {
  var n = Number(v)
  return isFinite(n) ? n : NaN
}

function parseMarkets(body) {
  try {
    var arr = JSON.parse(body)
    var c = Array.isArray(arr) ? arr[0] : null
    if (!c || !isFinite(num(c.current_price))) return null
    return {
      id: String(c.id || ""),
      name: String(c.name || ""),
      symbol: String(c.symbol || "").toUpperCase(),
      price: num(c.current_price),
      change24h: num(c.price_change_percentage_24h),
      high24h: num(c.high_24h),
      low24h: num(c.low_24h),
      marketCap: num(c.market_cap),
      rank: num(c.market_cap_rank),
      volume: num(c.total_volume)
    }
  } catch (e) {
    return null
  }
}

// Disk cache of the pinned quote: `{ at, data }`. 1.0.0 wrote the bare quote
// object; that is still accepted with `at: 0` so it shows immediately but is
// refreshed on the first check.
function parsePinnedCache(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    if (!parsed || typeof parsed !== "object") return null
    if (parsed.data && isFinite(num(parsed.data.price)))
      return { at: isFinite(num(parsed.at)) ? num(parsed.at) : 0, data: parsed.data }
    if (isFinite(num(parsed.price))) return { at: 0, data: parsed }
    return null
  } catch (e) {
    return null
  }
}

// Returns [{ t, p }] ordered by time, downsampled to at most `maxPoints`.
function parseChart(body, maxPoints) {
  try {
    var data = JSON.parse(body)
    var prices = data && Array.isArray(data.prices) ? data.prices : []
    var out = []
    for (var i = 0; i < prices.length; i++) {
      var pair = prices[i]
      if (!pair || pair.length < 2 || !isFinite(num(pair[1]))) continue
      out.push({ t: num(pair[0]), p: num(pair[1]) })
    }
    var cap = maxPoints || 300
    if (out.length <= cap) return out
    var step = out.length / cap
    var sampled = []
    for (var j = 0; j < cap - 1; j++) sampled.push(out[Math.floor(j * step)])
    sampled.push(out[out.length - 1])
    return sampled
  } catch (e) {
    return []
  }
}

function parseSearch(body, limit) {
  try {
    var data = JSON.parse(body)
    var coins = data && Array.isArray(data.coins) ? data.coins : []
    var out = []
    for (var i = 0; i < coins.length && out.length < (limit || 6); i++) {
      var c = coins[i]
      if (!c || !c.id) continue
      out.push({
        id: String(c.id),
        name: String(c.name || c.id),
        symbol: String(c.symbol || "").toUpperCase(),
        rank: num(c.market_cap_rank)
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// Reads `green = "#..."` / `red = "#..."` from the theme's colors.toml.
function parseThemeColors(text) {
  var out = { green: "", red: "" }
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*(green|red)\s*=\s*"([^"]+)"/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

function withCommas(s) {
  var parts = s.split(".")
  parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return parts.join(".")
}

// Adaptive precision: big prices get cents, sub-dollar coins keep enough
// significant digits to be useful.
function formatPrice(v) {
  var n = num(v)
  if (!isFinite(n)) return "—"
  var abs = Math.abs(n)
  var s
  if (abs >= 1) s = n.toFixed(2)
  else if (abs >= 0.01) s = n.toFixed(4)
  else if (abs === 0) s = "0.00"
  else s = n.toPrecision(4)
  return "$" + withCommas(s)
}

// Bar pill: no currency sign, whole units once cents stop mattering.
function formatPillPrice(v) {
  var n = num(v)
  if (!isFinite(n)) return "—"
  if (Math.abs(n) >= 100) return withCommas(Math.round(n).toString())
  return formatPrice(n).slice(1)
}

function formatCompact(v) {
  var n = num(v)
  if (!isFinite(n)) return "—"
  var abs = Math.abs(n)
  if (abs >= 1e12) return "$" + (n / 1e12).toFixed(2) + "T"
  if (abs >= 1e9) return "$" + (n / 1e9).toFixed(2) + "B"
  if (abs >= 1e6) return "$" + (n / 1e6).toFixed(2) + "M"
  if (abs >= 1e3) return "$" + (n / 1e3).toFixed(1) + "K"
  return "$" + n.toFixed(2)
}

function formatPct(v, digits) {
  var n = num(v)
  if (!isFinite(n)) return ""
  return (n >= 0 ? "▲" : "▼") + Math.abs(n).toFixed(digits === undefined ? 2 : digits) + "%"
}

function rangeChange(points) {
  if (!points || points.length < 2) return NaN
  var first = points[0].p
  if (!first) return NaN
  return (points[points.length - 1].p - first) / first * 100
}
