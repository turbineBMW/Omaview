import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import qs.Ui
import "MenuModel.js" as MenuModel
import "Navigation.js" as Navigation

// Omaview: a fullscreen niri-style workspace view on top, a GNOME-style grid
// of apps and Omarchy menus in the middle, and a dock at the bottom.
//
//   omarchy-shell shell toggle turbinebmw.omaview '{}'
//
// Payload: {"layout":"scrolling"|"strip"} forces the top section's mode
// instead of following the active workspace's layout; {"menu":"setup"} opens
// straight into an Omarchy submenu.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool stateLoaded: false
  property string layoutOverride: ""

  // The shell's shared app library when the host grants it; otherwise the
  // same behavior is rebuilt from DesktopEntries below.
  readonly property var appLibrary: root.shell && root.shell.appLibrary ? root.shell.appLibrary : null

  function appEntries() {
    var out = []
    if (root.appLibrary) {
      var sorted = root.appLibrary.sortedEntries("")
      for (var i = 0; i < sorted.length; i++) out.push(sorted[i].entry)
      return out
    }
    var values = DesktopEntries.applications.values || []
    for (var j = 0; j < values.length; j++)
      if (values[j] && !values[j].noDisplay && values[j].name) out.push(values[j])
    out.sort(function(a, b) { return String(a.name).toLowerCase().localeCompare(String(b.name).toLowerCase()) })
    return out
  }

  function launchApp(appId, name) {
    if (!appId) return
    if (root.appLibrary) root.appLibrary.launch(appId, name)
    else Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(appId + ".desktop"))
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.layoutOverride = String(payload.layout || "")
    root.filterText = ""
    root.navStack = []
    root.activeMenu = "root"
    root.hoveredDockKey = ""
    root.stateLoaded = false
    root.nativeReady = false
    root.nativeError = ""
    root.modePending = true
    if (root.appLibrary) root.appLibrary.refreshIcons()
    root.evaluateGuards()
    root.mergeAppRows()
    if (payload.menu) root.setActiveMenu(MenuModel.resolveRoute(root.items, root.itemOrder, payload.menu), false)
    root.rebuildDisplay()
    root.opened = true
    nativeLoader.running = true
  }

  // Hyprland already owns the selected window and layout. Closing only
  // removes the layer; Hyprland returns keyboard input to its active window.
  function close() {
    root.opened = false
    refreshDebounce.stop()
  }

  property bool nativeReady: false
  property string nativeError: ""
  Process {
    id: nativeLoader
    command: ["bash", decodeURIComponent(Qt.resolvedUrl("native/ensure-native.sh").toString().replace(/^file:\/\//, ""))]
    stderr: StdioCollector { onStreamFinished: root.nativeError = text.trim() }
    onExited: function(code) {
      if (!root.opened) return
      if (code !== 0) {
        console.warn("Omaview native companion:", root.nativeError)
        root.close()
        Quickshell.execDetached(["notify-send", "Omaview could not open", root.nativeError || "Native Hyprland companion failed to load."])
        return
      }
      root.nativeReady = true
      root.refreshState()
    }
  }

  function status(arg) {
    return JSON.stringify({ opened: root.opened, nativeReady: root.nativeReady,
      workspace: root.activeWsId, focusedAddress: root.focusedAddress,
      filter: root.filterText, clients: root.clientsByWs, error: root.nativeError })
  }

  function refresh() {
    defaultMenuFile.reload()
    userMenuFile.reload()
    return "ok"
  }

  function ping() { return "ok" }

  // ------------------------------------------------------- compositor state

  property var monitor: ({ name: "", x: 0, y: 0, w: 1920, h: 1080 })
  property int activeWsId: 1
  property bool scrollingMode: true
  property string activeLayout: "scrolling"   // tiledLayout of the active workspace
  property var workspaces: []        // [{id, name}] on the focused monitor, by id
  property var clientsByWs: ({})     // wsId -> [client] in monitor-local coords
  property var allClients: []

  readonly property int activeWsIndex: {
    for (var i = 0; i < workspaces.length; i++) if (workspaces[i].id === activeWsId) return i
    return -1
  }
  readonly property var prevWs: activeWsIndex > 0 ? workspaces[activeWsIndex - 1] : null
  // niri always keeps an empty workspace at the bottom; mirror that.
  property int nextFreeWsId: 2
  readonly property var nextWs: activeWsIndex >= 0 && activeWsIndex < workspaces.length - 1
    ? workspaces[activeWsIndex + 1]
    : root.clientsFor(root.activeWsId).length > 0 ? ({ id: nextFreeWsId, name: String(nextFreeWsId) }) : null

  // These are observations of the compositor, never an editable selection.
  property string focusedAddress: ""
  property string lastState: ""
  property bool modePending: false

  function focusDirection(dir) {
    if (!root.opened || ["l", "r", "u", "d"].indexOf(dir) < 0) return
    root.dispatch(Navigation.focus(dir))
  }

  function stepWorkspace(direction) {
    if (!root.opened) return
    root.dispatch(Navigation.stepWorkspace(direction < 0 ? -1 : 1))
  }

  function clientsFor(wsId) {
    return root.clientsByWs[wsId] || []
  }

  function refreshState() {
    if (!root.opened || !root.nativeReady) return
    if (!stateProc.running) stateProc.running = true
    else stateProc.rerun = true
  }

  function applyState(raw) {
    if (!root.opened) return
    // Skip identical observations so captures and dock delegates stay alive.
    if (raw === root.lastState && root.stateLoaded && !root.modePending) return
    var data
    try { data = JSON.parse(raw) } catch (e) { return }

    root.lastState = raw
    root.focusedAddress = String((data.activewindow || {}).address || "")
    var monitors = data.monitors || []
    var mon = null
    for (var i = 0; i < monitors.length; i++) if (monitors[i].focused) mon = monitors[i]
    if (!mon && monitors.length > 0) mon = monitors[0]
    if (!mon) return

    var scale = mon.scale || 1
    var rotated = (mon.transform % 2) === 1
    var w = (rotated ? mon.height : mon.width) / scale
    var h = (rotated ? mon.width : mon.height) / scale
    root.monitor = { name: mon.name, x: mon.x, y: mon.y, w: w, h: h }
    root.activeWsId = mon.activeWorkspace ? mon.activeWorkspace.id : 1

    var wsList = []
    var activeLayout = ""
    var all = data.workspaces || []
    for (var j = 0; j < all.length; j++) {
      var ws = all[j]
      if (ws.id === root.activeWsId) activeLayout = String(ws.tiledLayout || "")
      if (ws.id <= 0 || ws.monitorID !== mon.id) continue
      wsList.push({ id: ws.id, name: String(ws.name || ws.id) })
    }
    wsList.sort(function(a, b) { return a.id - b.id })
    var highestId = 0
    for (var wi = 0; wi < all.length; wi++) highestId = Math.max(highestId, all[wi].id)
    root.nextFreeWsId = highestId + 1
    if (JSON.stringify(wsList) !== JSON.stringify(root.workspaces)) root.workspaces = wsList
    root.activeLayout = activeLayout

    // The mode is chosen once per open, from the workspace you opened on.
    // Workspace layouts are per-workspace in Omarchy, so re-deciding on every
    // switch would flip all of omaview while you move around inside it.
    if (root.modePending) {
      root.modePending = false
      if (root.layoutOverride === "scrolling") root.scrollingMode = true
      else if (root.layoutOverride === "strip") root.scrollingMode = false
      else root.scrollingMode = activeLayout === "scrolling"
    }

    var byWs = ({})
    var flat = []
    var clients = data.clients || []
    for (var k = 0; k < clients.length; k++) {
      var c = clients[k]
      if (!c.mapped || c.hidden) continue
      var client = {
        address: String(c.address || ""),
        x: c.at[0] - mon.x,
        y: c.at[1] - mon.y,
        w: c.size[0],
        h: c.size[1],
        cls: String(c["class"] || ""),
        title: String(c.title || ""),
        floating: c.floating === true,
        focused: c.address === root.focusedAddress,
        focusOrder: c.focusHistoryID,
        wsId: c.workspace ? c.workspace.id : 0
      }
      // Dock data has no geometry: resizing a window must not recreate icons.
      flat.push({ address: client.address, cls: client.cls, title: client.title,
                  focused: client.focused, focusOrder: client.focusOrder, wsId: client.wsId })
      if (client.wsId <= 0 || c.monitor !== mon.id) continue
      if (!byWs[client.wsId]) byWs[client.wsId] = []
      byWs[client.wsId].push(client)
    }
    root.clientsByWs = byWs
    if (JSON.stringify(flat) !== JSON.stringify(root.allClients)) root.allClients = flat

    var screens = Quickshell.screens
    for (var s = 0; s < screens.length; s++) {
      if (screens[s].name === mon.name) { panel.screen = screens[s]; break }
    }
    root.stateLoaded = true
  }

  Process {
    id: stateProc
    property bool rerun: false
    command: ["hyprctl", "omaview-state"]
    stdout: StdioCollector {
      onStreamFinished: root.applyState(text)
    }
    onExited: {
      if (rerun) { rerun = false; Qt.callLater(root.refreshState) }
    }
  }

  Timer {
    id: refreshDebounce
    interval: 16
    onTriggered: root.refreshState()
  }

  Connections {
    target: Hyprland
    enabled: root.opened
    function onRawEvent(event) {
      var n = event.name
      if (n === "omaview" && event.data === "unloaded") {
        root.nativeReady = false
        root.close()
        return
      }
      if (n === "omaview" || n === "openwindow" || n === "closewindow" || n === "movewindowv2" || n === "workspacev2"
          || n === "createworkspacev2" || n === "destroyworkspacev2" || n === "changefloatingmode"
          || n === "focusedmonv2" || n === "activewindowv2" || n === "windowtitlev2" || n === "fullscreen"
          || n === "monitoraddedv2" || n === "monitorremoved" || n === "moveworkspacev2" || n === "configreloaded") {
        // Throttle, not a restarting debounce: continuous drags must refresh.
        if (!refreshDebounce.running) refreshDebounce.start()
      }
    }
  }

  function normalizeAddress(address) {
    return String(address || "").toLowerCase().replace(/^0x/, "")
  }

  function toplevelFor(address) {
    var wanted = root.normalizeAddress(address)
    var tops = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < tops.length; i++) {
      if (root.normalizeAddress(tops[i].address) === wanted) return tops[i].wayland
    }
    return null
  }

  function dispatch(lua) {
    Hyprland.dispatch(lua)
  }

  function focusWindow(address, keepOpen) {
    var addr = String(address || "")
    if (!/^0x[0-9a-fA-F]+$/.test(addr)) return
    root.dispatch("hl.dsp.focus({ window = 'address:" + addr + "' })")
    if (!keepOpen) root.close()
  }

  function closeWindow(address) {
    var top = root.toplevelFor(address)
    if (top && typeof top.close === "function") top.close()
  }

  function focusWorkspace(wsId, keepOpen) {
    var id = parseInt(wsId)
    if (!(id > 0)) return
    root.dispatch("hl.dsp.focus({ workspace = '" + id + "' })")
    if (!keepOpen) root.close()
  }

  readonly property string wallpaper: Util.fileUrl(wallpaperPath)
  property string wallpaperPath: ""

  Process {
    id: wallpaperProc
    command: ["readlink", "-f", (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/current/background"]
    stdout: StdioCollector {
      onStreamFinished: root.wallpaperPath = text.trim()
    }
  }
  onOpenedChanged: if (opened) wallpaperProc.running = true

  // ------------------------------------------------------------ menu model

  property string defaultMenuPath: omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
  property string userMenuPath: root.configHome + "/omarchy/extensions/omarchy-menu.jsonc"
  property var defaultMenuItems: []
  property var userMenuItems: []
  property var items: ({})
  property var itemOrder: []
  property string activeMenu: "root"
  property var navStack: []
  property string filterText: ""
  property var rows: []
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0
  property var whenResults: ({})
  property var checkedResults: ({})
  property bool guardsPending: false

  // Same providers the Omarchy menu knows: label\tvalue\tcurrent per line.
  readonly property var providers: ({
    "fonts": {
      script: "current=$(omarchy-font-current 2>/dev/null); omarchy-font-list 2>/dev/null | while read -r f; do [[ -z $f ]] && continue; printf '%s\\t%s\\t%s\\n' \"$f\" \"$f\" \"$current\"; done",
      icon: "",
      volatile: true,
      actionFor: function(value) { return "omarchy-font-set " + Util.shellQuote(value) }
    },
    "power-profiles": {
      script: "current=$(powerprofilesctl get 2>/dev/null); omarchy-powerprofiles-list 2>/dev/null | while read -r p; do [[ -z $p ]] && continue; printf '%s\\t%s\\t%s\\n' \"$p\" \"$p\" \"$current\"; done",
      icon: "󰐋",
      actionFor: function(value) { return "omarchy-powerprofiles-set autodetect " + Util.shellQuote(value) }
    }
  })

  function item(id) { return MenuModel.item(root.items, id) }

  function isVisible(entry) {
    return MenuModel.isVisible(root.items, root.itemOrder, root.whenResults, entry, 0)
  }

  function rebuildItemsFromSources() {
    var merged = MenuModel.mergeMenuSources(root.defaultMenuItems, root.userMenuItems)
    root.providerRevision += 1
    root.providersLoaded = ({})
    root.providerQueue = []
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    root.mergeAppRows()
    root.evaluateGuards()
    if (root.opened) root.rebuildDisplay()
  }

  function mergeAppRows() {
    var entries = root.appEntries()
    var appRows = []
    for (var j = 0; j < entries.length; j++) {
      var entry = entries[j]
      var appId = String(entry.id || "")
      if (!appId) continue
      var subtext = String(entry.genericName || "")
      var aliases = subtext ? [subtext] : []
      try {
        if (entry.keywords && typeof entry.keywords.join === "function") aliases = aliases.concat(entry.keywords)
      } catch (e) { }
      appRows.push({
        id: "apps." + appId, parent: "apps", kind: "app", icon: "", iconFont: "",
        appIcon: String(entry.icon || ""), appId: appId,
        label: String(entry.name || appId), title: "", target: "",
        description: subtext, action: "", provider: "", aliases: aliases,
        when: "", checked: "", order: 0
      })
    }

    var merged = MenuModel.mergeAppRows(root.items, root.itemOrder, appRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  function rebuildDisplay() {
    var out = []
    var query = root.filterText.trim()
    var i, entry

    if (query) {
      for (i = 0; i < root.itemOrder.length; i++) {
        entry = root.item(root.itemOrder[i])
        if (!entry || entry.id === "apps") continue
        if (!MenuModel.matchesQuery(entry, query, root.isVisible(entry))) continue
        var detail = entry.kind === "app" ? "" : MenuModel.parentPathFor(root.items, entry.id)
        out.push(MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, detail,
          MenuModel.searchScore(root.items, entry, query), ""))
      }
      out.sort(function(a, b) { return a.score - b.score })
    } else if (root.activeMenu === "root") {
      // Every Omarchy menu that isn't Apps gets a tile, then the apps themselves.
      var apps = []
      for (i = 0; i < root.itemOrder.length; i++) {
        entry = root.item(root.itemOrder[i])
        if (!entry || !root.isVisible(entry)) continue
        if (entry.parent === "root" && entry.id !== "apps")
          out.push(MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, "", 0, "menu"))
        else if (entry.kind === "app")
          apps.push(MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, "", 0, "app"))
      }
      apps.sort(function(a, b) { return a.label.localeCompare(b.label) })
      out = out.concat(apps)
    } else {
      for (i = 0; i < root.itemOrder.length; i++) {
        entry = root.item(root.itemOrder[i])
        if (!entry || entry.parent !== root.activeMenu || !root.isVisible(entry)) continue
        out.push(MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, "", 0, ""))
      }
    }

    root.rows = out
    grid.currentIndex = out.length > 0 ? 0 : -1
    grid.positionViewAtBeginning()
  }

  function setFilter(next) {
    if (next === root.filterText) return
    root.filterText = next
    if (next.trim()) root.loadProvidersForSearch()
    root.rebuildDisplay()
  }

  function setActiveMenu(id, pushHistory) {
    var entry = root.item(id)
    if (!entry || id === "apps") id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.filterText = ""
    if (id !== "root") {
      root.invalidateVolatileProvider(id)
      root.loadProviderForMenu(id)
    }
    root.rebuildDisplay()
  }

  function goBack() {
    if (root.activeMenu === "root") return false
    var stack = root.navStack.slice()
    var previous = stack.length > 0 ? stack.pop() : "root"
    root.navStack = stack
    root.setActiveMenu(previous, false)
    return true
  }

  function activateIndex(index) {
    if (index < 0 || index >= root.rows.length) return
    var row = root.rows[index]

    if (row.kind === "app") {
      root.close()
      root.launchApp(row.appId, row.label)
    } else if (row.kind === "menu" || row.kind === "link") {
      root.setActiveMenu(row.target, true)
    } else if (row.action) {
      root.close()
      Util.execDetached(row.action)
    }
  }

  // providers ---------------------------------------------------------------

  function startProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || root.providersLoaded[id]) return
    var spec = root.providers[entry.provider]
    if (!spec) return

    root.providersLoaded[id] = true
    providerProc.menuId = id
    providerProc.providerKey = entry.provider
    providerProc.revision = root.providerRevision
    providerProc.collected = ""
    providerProc.command = ["bash", "-lc", spec.script]
    providerProc.running = true
  }

  function loadProviderForMenu(id) {
    var entry = root.item(id)
    if (!entry || !entry.provider || entry.provider === "apps" || root.providersLoaded[id]) return
    if (providerProc.running) {
      if (root.providerQueue.indexOf(id) < 0) root.providerQueue = root.providerQueue.concat([id])
      return
    }
    root.startProviderForMenu(id)
  }

  function loadProvidersForSearch() {
    for (var i = 0; i < root.itemOrder.length; i++) {
      var entry = root.item(root.itemOrder[i])
      if (entry && entry.provider) root.loadProviderForMenu(entry.id)
    }
  }

  function invalidateVolatileProvider(id) {
    var entry = root.item(id)
    var spec = entry && entry.provider ? root.providers[entry.provider] : null
    if (spec && spec.volatile) root.providersLoaded[id] = false
  }

  function mergeProviderRows(raw, menuId, providerKey) {
    var spec = root.providers[providerKey]
    if (!spec) return
    var lines = String(raw || "").split("\n")
    var providerRows = []
    var taken = ({})
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (!line) continue
      var parts = line.split("\t")
      var label = parts[0] || ""
      var value = parts[1] || parts[0] || ""
      if (!label) continue
      var rowId = menuId + "." + MenuModel.slugify(value)
      while (taken[rowId]) rowId += "-"
      taken[rowId] = true
      providerRows.push({
        id: rowId, parent: menuId, kind: "action",
        icon: (value === (parts[2] || "")) ? "✓" : (spec.icon || ""), iconFont: "",
        label: label, title: "", target: "", description: "",
        action: spec.actionFor(value), provider: "", aliases: [], when: "", checked: "", order: 0
      })
    }
    var merged = MenuModel.swapProviderRows(root.items, root.itemOrder, menuId, providerRows)
    root.items = merged.items
    root.itemOrder = merged.itemOrder
    if (root.opened) root.rebuildDisplay()
  }

  Process {
    id: providerProc
    property string menuId: ""
    property string providerKey: ""
    property int revision: 0
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { providerProc.collected += data + "\n" }
    }
    onExited: {
      if (providerProc.revision === root.providerRevision)
        root.mergeProviderRows(providerProc.collected, providerProc.menuId, providerProc.providerKey)
      Qt.callLater(function() {
        while (!providerProc.running && root.providerQueue.length > 0) {
          var queue = root.providerQueue.slice()
          var id = queue.shift()
          root.providerQueue = queue
          root.startProviderForMenu(id)
        }
      })
    }
  }

  // guards ------------------------------------------------------------------

  function evaluateGuards() {
    if (guardProc.running) { root.guardsPending = true; return }
    root.guardsPending = false

    var script = MenuModel.guardScript(root.items)
    if (!script) { root.whenResults = ({}); root.checkedResults = ({}); return }
    guardProc.collected = ""
    guardProc.command = ["bash", "-lc", script]
    guardProc.running = true
  }

  Process {
    id: guardProc
    property string collected: ""
    stdout: SplitParser {
      onRead: function(data) { guardProc.collected += data + "\n" }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode === 0 && exitStatus === 0) {
        var nextWhen = ({})
        var nextChecked = ({})
        var lines = guardProc.collected.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          var colon = line.lastIndexOf(":")
          if (colon < 0) continue
          var rest = line.substring(0, colon)
          var tagAt = rest.lastIndexOf(":")
          if (tagAt < 0) continue
          var id = rest.substring(0, tagAt)
          var tag = rest.substring(tagAt + 1)
          if (tag === "w") nextWhen[id] = line.substring(colon + 1) === "1"
          else if (tag === "c") nextChecked[id] = line.substring(colon + 1) === "1"
        }
        root.whenResults = nextWhen
        root.checkedResults = nextChecked
        if (root.opened) root.rebuildDisplay()
      }
      if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() { root.mergeAppRows() }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root.classEntryCache = ({})
      if (!root.appLibrary) root.mergeAppRows()
    }
  }
  onAppLibraryChanged: root.mergeAppRows()

  FileView {
    id: defaultMenuFile
    path: root.defaultMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.defaultMenuItems = MenuModel.parseMenuJsonc(text()); root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  FileView {
    id: userMenuFile
    path: root.userMenuPath
    watchChanges: true
    printErrors: false
    onLoaded: { root.userMenuItems = MenuModel.parseMenuJsonc(text()); root.rebuildItemsFromSources() }
    onLoadFailed: { root.userMenuItems = []; root.rebuildItemsFromSources() }
    onFileChanged: reload()
  }

  // ------------------------------------------------------------------ dock

  property string pinnedPath: root.configHome + "/omarchy/omaview-pinned.json"
  property var pinned: []
  property bool pinnedLoaded: false
  property string hoveredDockKey: ""
  readonly property var defaultPinCandidates: [
    "chromium", "firefox", "brave-browser", "com.mitchellh.ghostty", "Alacritty", "kitty", "foot",
    "org.gnome.Nautilus", "nvim", "code", "obsidian", "signal-desktop", "spotify", "1password"
  ]

  function defaultPins() {
    var out = []
    for (var i = 0; i < defaultPinCandidates.length; i++)
      if (DesktopEntries.byId(defaultPinCandidates[i])) out.push(defaultPinCandidates[i])
    return out
  }

  function isPinned(appId) {
    return root.pinned.indexOf(appId) >= 0
  }

  function togglePin(appId) {
    if (!appId) return
    var next = root.pinned.slice()
    var at = next.indexOf(appId)
    if (at >= 0) next.splice(at, 1)
    else next.push(appId)
    root.pinned = next
    pinnedFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  FileView {
    id: pinnedFile
    path: root.pinnedPath
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (Array.isArray(parsed)) root.pinned = parsed.map(String)
      } catch (e) { }
      root.pinnedLoaded = true
    }
    onLoadFailed: { root.pinned = root.defaultPins(); root.pinnedLoaded = true }
  }

  // Apps that arrive after a failed load (DesktopEntries fills in async).
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      if (root.pinnedLoaded && root.pinned.length === 0 && !pinnedFile.loaded) root.pinned = root.defaultPins()
    }
  }

  readonly property var dockItems: {
    var _apps = DesktopEntries.applications.values
    var out = []
    var seen = ({})
    var i

    for (i = 0; i < root.pinned.length; i++) {
      var pinnedEntry = DesktopEntries.byId(root.pinned[i])
      if (!pinnedEntry || seen[pinnedEntry.id] !== undefined) continue
      seen[pinnedEntry.id] = out.length
      out.push({ key: pinnedEntry.id, appId: pinnedEntry.id, name: pinnedEntry.name, icon: pinnedEntry.icon, pinned: true, windows: [], sepBefore: false })
    }

    var firstRunning = true
    for (i = 0; i < root.allClients.length; i++) {
      var c = root.allClients[i]
      if (!c.cls) continue
      var entry = root.entryForClass(c.cls)
      var key = entry ? entry.id : "class:" + c.cls
      if (seen[key] === undefined) {
        seen[key] = out.length
        out.push({
          key: key, appId: entry ? entry.id : "", name: entry ? entry.name : c.cls,
          icon: entry ? entry.icon : c.cls, pinned: false, windows: [],
          sepBefore: firstRunning && out.length > 0
        })
        firstRunning = false
      }
      out[seen[key]].windows.push(c)
    }
    return out
  }

  function iconSource(icon) {
    if (root.appLibrary) return root.appLibrary.iconSource(icon)
    var value = String(icon || "")
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    var themed = value ? Quickshell.iconPath(value, true) : ""
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  // Window class -> desktop entry. Chromium web apps report a class like
  // chrome-<host>__<path>-Default that no entry declares, so those are matched
  // on the host appearing in the entry's command line.
  property var classEntryCache: ({})
  function entryForClass(cls) {
    var key = String(cls || "")
    if (!key) return null
    if (root.classEntryCache[key] !== undefined) return root.classEntryCache[key]

    var found = DesktopEntries.heuristicLookup(key)
    var webapp = /^(?:chrome|chromium|brave|msedge)-(.+?)__/.exec(key)
    if (!found && webapp) {
      var host = webapp[1].toLowerCase()
      var values = DesktopEntries.applications.values || []
      for (var i = 0; i < values.length && !found; i++) {
        var exec = String(values[i].execString || "").toLowerCase()
        if (exec.indexOf("//" + host) >= 0 || exec.indexOf("." + host) >= 0) found = values[i]
      }
    }
    root.classEntryCache[key] = found || null
    return found || null
  }

  function iconForClass(cls) {
    var entry = root.entryForClass(cls)
    return root.iconSource(entry ? entry.icon : cls)
  }

  function activateDockItem(dockItem, forceNew) {
    var windows = dockItem.windows || []
    if (windows.length === 0 || forceNew) {
      if (!dockItem.appId) return
      root.close()
      root.launchApp(dockItem.appId, dockItem.name)
      return
    }
    var sorted = windows.slice().sort(function(a, b) { return a.focusOrder - b.focusOrder })
    // Already on the app's most recent window: step to the next one.
    var target = sorted[0].focused && sorted.length > 1 ? sorted[1] : sorted[0]
    root.focusWindow(target.address)
  }

  // ------------------------------------------------------------------ view

  readonly property int edge: Style.space(14)
  readonly property int peek: Style.space(22)
  readonly property int stackGap: Style.space(10)
  // Non-scrolling layouts: height of the focused workspace's thumbnail, and
  // how much smaller the others are.
  readonly property int stripH: Style.space(200)
  readonly property real stripShrink: 0.8
  readonly property int cellW: Style.space(116)
  readonly property int cellH: Style.space(108)
  readonly property int iconSize: Style.space(56)
  readonly property int dockIcon: Style.space(44)
  readonly property int radius: Math.max(Style.cornerRadius, Style.space(6))

  PanelWindow {
    id: panel
    visible: root.opened && root.nativeReady && root.stateLoaded
    onVisibleChanged: if (visible) keyCatcher.forceActiveFocus()
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-omaview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore

    readonly property real topH: root.scrollingMode ? Math.round(height * 0.40) : stripFocusedH
    readonly property real mainH: topH - 2 * (root.peek + root.stackGap)
    readonly property real mainScale: mainH / Math.max(1, root.monitor.h)

    // Strip thumbnails shrink together when the workspaces would not fit.
    readonly property real stripGap: Style.space(14)
    readonly property real stripFocusedH: {
      var n = Math.max(1, root.workspaces.length)
      var aspect = root.monitor.w / Math.max(1, root.monitor.h)
      var units = aspect * (1 + (n - 1) * root.stripShrink)
      var fit = (width - root.edge * 2 - (n - 1) * stripGap) / units
      return Math.round(Math.max(Style.space(60), Math.min(root.stripH, fit)))
    }

    // Backdrop: the wallpaper under a heavy tint, so the live desktop never
    // shows through behind the zoomed-out workspaces.
    Rectangle {
      anchors.fill: parent
      color: Color.menu.background
    }

    Image {
      anchors.fill: parent
      source: root.wallpaper
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize.width: 480
      smooth: true
      opacity: 0.35
    }

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.menu.background, 0.62)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        if (event.key === Qt.Key_Escape) {
          if (root.filterText) root.setFilter("")
          else if (!root.goBack()) root.close()
        } else if (ctrl && event.key === Qt.Key_Up) {
          root.stepWorkspace(-1)
        } else if (ctrl && event.key === Qt.Key_Down) {
          root.stepWorkspace(1)
        } else if (ctrl && event.key === Qt.Key_Left) {
          root.focusDirection("l")
        } else if (ctrl && event.key === Qt.Key_Right) {
          root.focusDirection("r")
        } else if (Util.editsFilter(event, root.filterText)) {
          root.setFilter(Util.editedFilter(event, root.filterText))
        } else if (event.key === Qt.Key_Backspace && !root.filterText) {
          root.goBack()
        } else if (event.key === Qt.Key_Left) {
          grid.moveCurrentIndexLeft()
        } else if (event.key === Qt.Key_Right) {
          grid.moveCurrentIndexRight()
        } else if (event.key === Qt.Key_Up) {
          grid.moveCurrentIndexUp()
        } else if (event.key === Qt.Key_Down) {
          grid.moveCurrentIndexDown()
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.activateIndex(grid.currentIndex)
        } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
                   && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
          root.setFilter(root.filterText + event.text)
        } else {
          return
        }
        event.accepted = true
      }

      // ------------------------------------------------ workspaces (top)
      Item {
        id: topArea
        x: 0
        y: root.edge
        width: parent.width
        height: panel.topH
        clip: true

        // Non-scrolling layouts: every workspace side by side, the focused
        // one slightly larger.
        Row {
          id: strip
          visible: !root.scrollingMode
          anchors.horizontalCenter: parent.horizontalCenter
          height: panel.stripFocusedH
          spacing: panel.stripGap

          Repeater {
            model: root.scrollingMode ? [] : root.workspaces
            delegate: WorkspaceView {
              required property var modelData
              readonly property real thumbH: panel.stripFocusedH * (isActive ? 1 : root.stripShrink)
              anchors.verticalCenter: parent.verticalCenter
              wsId: modelData.id
              wsName: modelData.name
              clients: root.clientsFor(modelData.id)
              monW: root.monitor.w
              monH: root.monitor.h
              s: thumbH / Math.max(1, root.monitor.h)
              width: wallW
              wallpaper: root.wallpaper
              clipToMonitor: true
              isActive: modelData.id === root.activeWsId
              radius: Style.space(6)
              toplevelFor: root.toplevelFor
              live: panel.visible
              iconFor: root.iconForClass
              onWorkspaceActivated: function(id) { root.focusWorkspace(id, true) }
              onWindowActivated: function(address) { root.focusWindow(address, true) }
              onWindowAccepted: function(address) { root.focusWindow(address, false) }
              onWindowCloseRequested: function(address) { root.closeWindow(address) }
            }
          }
        }

        // Scrolling layout: a sliver of the workspace above...
        WorkspaceView {
          visible: root.scrollingMode && root.prevWs !== null
          width: parent.width
          y: root.peek - height
          wsId: root.prevWs ? root.prevWs.id : 0
          wsName: root.prevWs ? root.prevWs.name : ""
          clients: root.prevWs && root.scrollingMode ? root.clientsFor(root.prevWs.id) : []
          monW: root.monitor.w
          monH: root.monitor.h
          s: panel.mainScale
          wallpaper: root.wallpaper
          showBadges: false
          radius: root.radius
          toplevelFor: root.toplevelFor
          live: panel.visible
          onWorkspaceActivated: function(id) { root.focusWorkspace(id, true) }
          onWindowActivated: function(address) { root.focusWindow(address, true) }
          onWindowAccepted: function(address) { root.focusWindow(address, false) }
          onWindowCloseRequested: function(address) { root.closeWindow(address) }
        }

        // ...the current workspace, wallpaper centered, off-view windows as
        // a filmstrip on either side...
        WorkspaceView {
          id: mainView
          visible: root.scrollingMode
          width: parent.width
          y: root.peek + root.stackGap
          wsId: root.activeWsId
          wsName: String(root.activeWsId)
          clients: root.scrollingMode ? root.clientsFor(root.activeWsId) : []
          monW: root.monitor.w
          monH: root.monitor.h
          s: panel.mainScale
          wallpaper: root.wallpaper
          isActive: true
          radius: root.radius
          toplevelFor: root.toplevelFor
          live: panel.visible
          iconFor: root.iconForClass
          onWorkspaceActivated: function(id) { root.focusWorkspace(id, true) }
          onWindowActivated: function(address) { root.focusWindow(address, true) }
          onWindowAccepted: function(address) { root.focusWindow(address, false) }
          onWindowCloseRequested: function(address) { root.closeWindow(address) }
        }

        // ...and a sliver of the one below.
        WorkspaceView {
          visible: root.scrollingMode && root.nextWs !== null
          width: parent.width
          y: mainView.y + mainView.height + root.stackGap
          wsId: root.nextWs ? root.nextWs.id : 0
          wsName: root.nextWs ? root.nextWs.name : ""
          clients: root.scrollingMode && root.nextWs ? root.clientsFor(root.nextWs.id) : []
          monW: root.monitor.w
          monH: root.monitor.h
          s: panel.mainScale
          wallpaper: root.wallpaper
          showBadges: false
          radius: root.radius
          toplevelFor: root.toplevelFor
          live: panel.visible
          onWorkspaceActivated: function(id) { root.focusWorkspace(id, true) }
          onWindowActivated: function(address) { root.focusWindow(address, true) }
          onWindowAccepted: function(address) { root.focusWindow(address, false) }
          onWindowCloseRequested: function(address) { root.closeWindow(address) }
        }
      }

      // ---------------------------------------------------- search / path
      Item {
        id: header
        anchors.top: topArea.bottom
        anchors.topMargin: Style.space(12)
        anchors.horizontalCenter: parent.horizontalCenter
        width: grid.width
        height: Style.space(36)

        Rectangle {
          id: backButton
          visible: root.activeMenu !== "root" && !root.filterText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: backLabel.implicitWidth + Style.space(20)
          height: parent.height - Style.space(6)
          radius: height / 2
          color: backMouse.containsMouse ? Color.menu.selectedBackground : Style.normalFill

          Text {
            id: backLabel
            anchors.centerIn: parent
            text: "‹  " + MenuModel.pathFor(root.items, root.activeMenu)
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          MouseArea {
            id: backMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.goBack()
          }
        }

        Rectangle {
          anchors.centerIn: parent
          width: Math.min(parent.width, Style.space(340))
          height: parent.height
          radius: height / 2
          color: Style.normalFill
          border.width: root.filterText ? 1 : 0
          border.color: Util.alpha(Color.accent, 0.6)

          Text {
            anchors.fill: parent
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(14)
            verticalAlignment: Text.AlignVCenter
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideLeft
            text: root.filterText ? root.filterText : "Type to search"
            color: root.filterText ? Color.menu.text : Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          MouseArea { anchors.fill: parent; onClicked: {} }
        }
      }

      // -------------------------------------------------- apps and menus
      GridView {
        id: grid
        anchors.top: header.bottom
        anchors.topMargin: Style.space(10)
        anchors.bottom: dock.top
        anchors.bottomMargin: Style.space(12)
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(1, Math.floor(Math.min(parent.width - root.edge * 4, Style.space(1180)) / root.cellW)) * root.cellW
        cellWidth: root.cellW
        cellHeight: root.cellH
        clip: true
        model: root.rows
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationEnabled: false
        highlightFollowsCurrentItem: true

        delegate: Item {
          id: tile
          required property var modelData
          required property int index
          readonly property bool current: GridView.isCurrentItem
          readonly property bool isApp: modelData.kind === "app"
          readonly property bool isMenu: modelData.kind === "menu" || modelData.kind === "link"
          width: root.cellW
          height: root.cellH

          Rectangle {
            anchors.fill: parent
            anchors.margins: Style.space(3)
            radius: root.radius
            color: tile.current ? Color.menu.selectedBackground : "transparent"
            border.width: tile.current ? Border.left(Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)) : 0
            border.color: Color.menu.selectedBorder
          }

          Item {
            id: iconBox
            width: root.iconSize
            height: root.iconSize
            anchors.horizontalCenter: parent.horizontalCenter
            y: Style.space(10)

            Image {
              visible: tile.isApp
              anchors.fill: parent
              source: tile.isApp ? root.iconSource(tile.modelData.appIcon) : ""
              sourceSize.width: 128
              sourceSize.height: 128
              asynchronous: true
            }

            // Omarchy menu entries have Nerd Font glyphs rather than icons;
            // give them an app-icon-sized plate so they sit in the same grid.
            Rectangle {
              visible: !tile.isApp
              anchors.fill: parent
              radius: width * 0.26
              color: tile.isMenu ? Util.alpha(Color.accent, 0.16) : Style.normalFill
              border.width: 1
              border.color: Util.alpha(tile.isMenu ? Color.accent : Color.foreground, 0.28)

              Text {
                anchors.centerIn: parent
                text: tile.modelData.icon || (tile.isMenu ? "" : "")
                color: tile.isMenu ? Color.accent : Color.menu.text
                font.family: tile.modelData.iconFont || Style.font.menuFamily
                font.pixelSize: Math.round(root.iconSize * 0.46)
              }
            }

            // Pinned marker
            Rectangle {
              visible: tile.isApp && root.isPinned(tile.modelData.appId)
              width: Style.space(8)
              height: width
              radius: width / 2
              color: Color.accent
              anchors.right: parent.right
              anchors.top: parent.top
            }
          }

          Text {
            anchors.top: iconBox.bottom
            anchors.topMargin: Style.space(6)
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - Style.space(10)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: tile.modelData.detail ? 1 : 2
            elide: Text.ElideRight
            text: tile.modelData.label
            color: tile.current ? Color.menu.selectedText : Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: !!tile.modelData.detail
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(6)
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - Style.space(10)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideLeft
            text: tile.modelData.detail
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Math.max(8, Style.font.caption - 2)
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onPositionChanged: grid.currentIndex = tile.index
            onClicked: function(mouse) {
              if (mouse.button === Qt.RightButton) {
                if (tile.isApp) root.togglePin(tile.modelData.appId)
              } else {
                root.activateIndex(tile.index)
              }
            }
          }
        }

        Text {
          visible: root.rows.length === 0
          anchors.horizontalCenter: parent.horizontalCenter
          y: Style.space(30)
          text: root.filterText ? "No matches" : "Nothing here"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      // ------------------------------------------------------------ dock
      Rectangle {
        id: dock
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.edge
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - root.edge * 2, dockRow.implicitWidth + Style.space(20))
        height: root.dockIcon + Style.space(22)
        radius: Math.max(root.radius, Style.space(12))
        color: Util.alpha(Color.bar.background, 0.85)
        border.width: 1
        border.color: Util.alpha(Color.foreground, 0.18)
        visible: root.dockItems.length > 0

        MouseArea { anchors.fill: parent; onClicked: {} }

        Row {
          id: dockRow
          anchors.centerIn: parent
          spacing: Style.space(6)

          Repeater {
            model: root.dockItems

            delegate: Row {
              id: dockSlot
              required property var modelData
              spacing: Style.space(6)

              Rectangle {
                visible: dockSlot.modelData.sepBefore
                width: 1
                height: root.dockIcon * 0.7
                anchors.verticalCenter: parent.verticalCenter
                color: Util.alpha(Color.foreground, 0.25)
              }

              Item {
                id: dockItem
                width: root.dockIcon + Style.space(8)
                height: root.dockIcon + Style.space(10)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(10)
                  color: dockMouse.containsMouse ? Color.menu.selectedBackground : "transparent"
                }

                Image {
                  id: dockImage
                  width: root.dockIcon
                  height: root.dockIcon
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: dockMouse.containsMouse ? 0 : Style.space(2)
                  scale: dockMouse.containsMouse ? 1.12 : 1.0
                  source: root.iconSource(dockSlot.modelData.icon)
                  sourceSize.width: 128
                  sourceSize.height: 128
                  asynchronous: true
                  Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                  Behavior on y { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                }

                Row {
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  spacing: Style.space(3)
                  Repeater {
                    model: Math.min(3, dockSlot.modelData.windows.length)
                    delegate: Rectangle {
                      required property int index
                      width: index === 0 ? Style.space(10) : Style.space(4)
                      height: Style.space(4)
                      radius: height / 2
                      color: Color.accent
                    }
                  }
                }

                Rectangle {
                  visible: dockMouse.containsMouse
                  anchors.bottom: parent.top
                  anchors.bottomMargin: Style.space(12)
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: tipText.implicitWidth + Style.space(14)
                  height: tipText.implicitHeight + Style.space(8)
                  radius: height / 2
                  color: Color.tooltip.background
                  border.width: 1
                  border.color: Util.alpha(Color.tooltip.border, 0.4)

                  Text {
                    id: tipText
                    anchors.centerIn: parent
                    text: dockSlot.modelData.name
                    color: Color.tooltip.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  id: dockMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                  onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) root.togglePin(dockSlot.modelData.appId)
                    else root.activateDockItem(dockSlot.modelData, mouse.button === Qt.MiddleButton)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
