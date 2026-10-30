import QtQuick
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  property var settings: ({})

  property var tunnels: []
  property bool loaded: false
  property string lastError: ""
  property string actionStatus: ""

  // Optimistic state, keyed by uuid, so a click flips the switch immediately
  // instead of waiting up to refreshIntervalSec for nmcli to catch up.
  property var pending: ({})

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 5, 2, 3600)
  readonly property string preferredPrimary: String(setting("primary", ""))
  readonly property var primary: Model.primaryTunnel(tunnels, preferredPrimary)
  readonly property bool anyActive: {
    for (var i = 0; i < tunnels.length; i++) if (isActive(tunnels[i])) return true
    return false
  }
  readonly property bool busy: pollProcess.running || actionProcess.running
  readonly property string statusText: Model.statusSummary(tunnels, loaded)
  readonly property string scriptPath: decodeURIComponent(String(Qt.resolvedUrl("poll.sh")).replace(/^file:\/\//, ""))

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // The tunnel's shown state: a pending toggle wins until reality agrees.
  function isActive(tunnel) {
    if (!tunnel) return false
    var want = pending[tunnel.uuid]
    return want === undefined ? tunnel.active === true : want === true
  }

  function isPending(tunnel) {
    if (!tunnel) return false
    return pending[tunnel.uuid] !== undefined || tunnel.activating === true
  }

  function setPending(uuid, desired) {
    var next = {}
    for (var key in pending) next[key] = pending[key]
    next[uuid] = desired
    pending = next
    pendingTimeout.restart()
  }

  function clearPending(uuid) {
    if (pending[uuid] === undefined) return
    var next = {}
    for (var key in pending) if (key !== uuid) next[key] = pending[key]
    pending = next
  }

  function refresh() {
    if (pollProcess.running) return
    pollProcess.command = ["bash", scriptPath]
    pollProcess.running = true
  }

  function applyPoll(raw) {
    var parsed = Model.parsePoll(raw)
    tunnels = parsed
    loaded = true
    // Drop optimistic state for any tunnel whose real state caught up, and for
    // any tunnel that vanished from the profile list entirely.
    var stillPending = {}
    for (var i = 0; i < parsed.length; i++) {
      var tunnel = parsed[i]
      var want = pending[tunnel.uuid]
      if (want === undefined) continue
      if (tunnel.active !== want) stillPending[tunnel.uuid] = want
    }
    pending = stillPending
  }

  function toggleTunnel(uuid) {
    var target = uuid ? findTunnel(uuid) : primary
    if (!target) return
    if (isActive(target)) down(target.uuid)
    else up(target.uuid)
  }

  function findTunnel(uuid) {
    var want = String(uuid || "")
    for (var i = 0; i < tunnels.length; i++) {
      if (tunnels[i].uuid === want || tunnels[i].name === want) return tunnels[i]
    }
    return null
  }

  function up(uuid) {
    var target = findTunnel(uuid)
    if (!target) return
    setPending(target.uuid, true)
    runAction(["nmcli", "connection", "up", "uuid", target.uuid])
  }

  function down(uuid) {
    var target = findTunnel(uuid)
    if (!target) return
    setPending(target.uuid, false)
    runAction(["nmcli", "connection", "down", "uuid", target.uuid])
  }

  function runAction(command) {
    if (actionProcess.running) return
    lastError = ""
    actionProcess.command = command
    actionProcess.running = true
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    // A refresh right after an action, so the panel settles without waiting a
    // whole interval; nmcli returns before the link is fully up.
    id: settleTimer
    interval: 700
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    // An optimistic state that never reconciles (the tunnel failed to come up,
    // or nmcli hung) must not stick forever, or the switch lies about reality.
    id: pendingTimeout
    interval: 20000
    repeat: false
    onTriggered: root.pending = ({})
  }

  Timer {
    // A poll that never exits silently stops every later refresh, since each
    // one is skipped while its process is still running. Reap it well inside
    // the interval so the next tick starts clean.
    id: pollWatchdog
    interval: 12000
    repeat: false
    onTriggered: if (pollProcess.running) pollProcess.running = false
  }

  Timer {
    id: actionStatusTimer
    interval: 3000
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: pollProcess
    running: false
    command: []
    stdout: StdioCollector { id: pollStdout; waitForEnd: true }
    stderr: StdioCollector { id: pollStderr; waitForEnd: true }
    onRunningChanged: if (running && !pollWatchdog.running) pollWatchdog.start()
    onExited: function (exitCode) {
      pollWatchdog.stop()
      if (exitCode === 0) {
        root.applyPoll(String(pollStdout.text || ""))
        root.lastError = ""
      } else {
        root.loaded = true
        root.lastError = String(pollStderr.text || "").trim() || "Could not read WireGuard state"
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        // The optimistic state was wrong — drop it so the switch snaps back.
        root.pending = ({})
        root.lastError = String(actionStderr.text || "").trim() || "nmcli failed"
        root.actionStatus = ""
      } else {
        root.actionStatus = ""
        actionStatusTimer.stop()
      }
      settleTimer.restart()
    }
  }
}
