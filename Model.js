.pragma library

// `nmcli -t` escapes ':' as '\:' and '\' as '\\' inside values. Split a terse
// line on unescaped colons only, then unescape each field.
function splitTerse(line) {
  var fields = []
  var current = ""
  for (var i = 0; i < line.length; i++) {
    var ch = line[i]
    if (ch === "\\" && i + 1 < line.length) {
      current += line[i + 1]
      i++
    } else if (ch === ":") {
      fields.push(current)
      current = ""
    } else {
      current += ch
    }
  }
  fields.push(current)
  return fields
}

// Terse `device show` output is `KEY:value`, and the key never contains a
// colon, so a single split at the first one is enough.
function terseKeyValue(line) {
  var at = line.indexOf(":")
  if (at === -1) return null
  return { key: line.substring(0, at), value: unescapeTerse(line.substring(at + 1)) }
}

function unescapeTerse(value) {
  return String(value || "").replace(/\\(.)/g, "$1")
}

function humanBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) return ""
  if (n < 1024) return n + " B"
  var units = ["KB", "MB", "GB", "TB"]
  var value = n / 1024
  var unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return (value >= 10 ? Math.round(value) : value.toFixed(1)) + " " + units[unit]
}

// A tunnel carrying a default route is a full tunnel; anything narrower is
// split. IPv6 ::/0 counts the same as IPv4 0.0.0.0/0.
function isDefaultRoute(destination) {
  var d = String(destination || "").trim()
  return d === "0.0.0.0/0" || d === "::/0" || d === "0.0.0.0" || d === "default"
}

// The endpoint is not a secret, so it survives a `nmcli connection show`
// without --show-secrets. nmcli has printed the peer list in more than one
// shape across versions, so match the attribute wherever it lands rather
// than depending on one layout.
function extractEndpoint(raw) {
  var text = String(raw || "")
  var match = text.match(/endpoint[=:]\s*([^\s,;\\]+)/i)
  return match ? match[1] : ""
}

function extractAllowedIps(raw) {
  var text = String(raw || "")
  var match = text.match(/allowed-ips[=:]\s*([^\s,\\]+)/i)
  if (!match) return []
  return match[1].split(";").filter(function (entry) { return entry !== "" })
}

// The poll script emits one blob with `#TAG value` section markers so the
// whole refresh costs a single process instead of four per tunnel.
function parsePoll(raw, previous) {
  var text = String(raw || "")
  var lines = text.split("\n")
  var conns = []
  var details = {}
  var section = ""
  var argument = ""

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length === 0) continue
    if (line.charAt(0) === "#") {
      var space = line.indexOf(" ")
      section = space === -1 ? line.substring(1) : line.substring(1, space)
      argument = space === -1 ? "" : line.substring(space + 1)
      if (section === "PEER" || section === "DEV" || section === "STAT") {
        if (!details[argument]) details[argument] = { peerRaw: "", addresses: [], routes: [], rx: -1, tx: -1 }
      }
      continue
    }
    if (section === "CONNS") {
      var fields = splitTerse(line)
      // Count from the end: NAME may contain escaped colons, but UUID, TYPE,
      // ACTIVE, DEVICE and STATE cannot.
      if (fields.length < 6) continue
      var state = fields[fields.length - 1]
      var device = fields[fields.length - 2]
      var active = fields[fields.length - 3]
      var type = fields[fields.length - 4]
      if (type !== "wireguard") continue
      var uuid = fields[0]
      var name = fields.slice(1, fields.length - 4).join(":")
      conns.push({
        uuid: uuid,
        name: name,
        device: device,
        state: state,
        active: active === "yes",
        activating: active === "yes" && state !== "activated"
      })
    } else if (section === "PEER") {
      details[argument].peerRaw += line + "\n"
    } else if (section === "DEV") {
      var kv = terseKeyValue(line)
      if (!kv) continue
      if (kv.key.indexOf("IP4.ADDRESS") === 0 || kv.key.indexOf("IP6.ADDRESS") === 0) {
        if (kv.value !== "") details[argument].addresses.push(kv.value)
      } else if (kv.key.indexOf("IP4.ROUTE") === 0 || kv.key.indexOf("IP6.ROUTE") === 0) {
        // `dst = 0.0.0.0/0, nh = 0.0.0.0, mt = 50`
        var dst = kv.value.match(/dst\s*=\s*([^,]+)/)
        if (dst) details[argument].routes.push(dst[1].trim())
      }
    } else if (section === "STAT") {
      if (details[argument].rx === -1) details[argument].rx = Number(line)
      else if (details[argument].tx === -1) details[argument].tx = Number(line)
    }
  }

  var tunnels = []
  for (var c = 0; c < conns.length; c++) {
    var conn = conns[c]
    var byUuid = details[conn.uuid] || { peerRaw: "", addresses: [], routes: [], rx: -1, tx: -1 }
    var byDev = conn.device !== "" && details[conn.device] ? details[conn.device] : null
    var routes = byDev ? byDev.routes : []
    var fullTunnel = false
    for (var r = 0; r < routes.length; r++) if (isDefaultRoute(routes[r])) fullTunnel = true

    var allowed = extractAllowedIps(byUuid.peerRaw)
    if (!byDev) for (var a = 0; a < allowed.length; a++) if (isDefaultRoute(allowed[a])) fullTunnel = true

    tunnels.push({
      uuid: conn.uuid,
      name: conn.name,
      device: conn.device,
      state: conn.state,
      active: conn.active,
      activating: conn.activating,
      endpoint: extractEndpoint(byUuid.peerRaw),
      allowedIps: allowed,
      addresses: byDev ? byDev.addresses : [],
      routes: routes,
      fullTunnel: fullTunnel,
      rx: byDev ? byDev.rx : -1,
      tx: byDev ? byDev.tx : -1
    })
  }
  return tunnels
}

function primaryTunnel(tunnels, preference) {
  if (!tunnels || tunnels.length === 0) return null
  var want = String(preference || "").trim()
  if (want !== "") {
    for (var i = 0; i < tunnels.length; i++) {
      if (tunnels[i].uuid === want || tunnels[i].name === want) return tunnels[i]
    }
  }
  // No stated preference: whatever is already up wins, so the right-click
  // toggle always acts on the tunnel the user can actually see is on.
  for (var j = 0; j < tunnels.length; j++) if (tunnels[j].active) return tunnels[j]
  return tunnels[0]
}

function tunnelDetail(tunnel) {
  if (!tunnel) return ""
  if (!tunnel.active) {
    if (tunnel.endpoint !== "") return tunnel.endpoint
    return "Not connected"
  }
  if (tunnel.activating) return "Connecting…"
  var parts = []
  if (tunnel.addresses.length > 0) parts.push(tunnel.addresses[0])
  parts.push(tunnel.fullTunnel ? "all traffic" : "split tunnel")
  return parts.join(" · ")
}

function transferDetail(tunnel) {
  if (!tunnel || !tunnel.active || tunnel.rx < 0 || tunnel.tx < 0) return ""
  return "↓ " + humanBytes(tunnel.rx) + "   ↑ " + humanBytes(tunnel.tx)
}

function statusSummary(tunnels, loaded) {
  if (!loaded) return "Checking…"
  if (!tunnels || tunnels.length === 0) return "No tunnels configured"
  var up = []
  for (var i = 0; i < tunnels.length; i++) if (tunnels[i].active) up.push(tunnels[i].name)
  if (up.length === 0) return tunnels.length === 1 ? "Disconnected" : "All tunnels off"
  if (up.length === 1) return "Connected to " + up[0]
  return up.length + " tunnels up"
}
