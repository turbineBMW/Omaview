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

  property bool iconsRefreshed: false

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.layoutOverride = String(payload.layout || "")
    root.filterText = ""
    root.navStack = []
    root.activeMenu = "root"
    root.iconPickAppId = ""
    root.setDockHints(false)
    root.clearDockDrag()
    root.closeAppMenu()
    workspaceAnimation.stop()
    root.stateLoaded = false
    root.nativeError = ""
    root.nativeRecovered = false
    root.modePending = true
    Style.refresh()
    // The app library rescans icons itself whenever desktop entries change;
    // one explicit refresh per shell session covers icons placed after start.
    if (root.appLibrary && !root.iconsRefreshed) { root.iconsRefreshed = true; root.appLibrary.refreshIcons() }
    root.evaluateGuards()
    root.mergeAppRows()
    if (payload.menu) root.setActiveMenu(MenuModel.resolveRoute(root.items, root.itemOrder, payload.menu), false)
    root.rebuildDisplay(true)
    root.opened = true
    // The companion stays loaded between opens; the loader only runs when
    // it has not been verified in this session or Hyprland reported it gone.
    if (root.nativeReady) root.refreshState()
    else nativeLoader.running = true
  }

  // Hyprland already owns the selected window and layout. Closing only
  // removes the layer; Hyprland returns keyboard input to its active window.
  function close() {
    root.opened = false
    root.setDockHints(false)
    root.clearDockDrag()
    root.closeAppMenu()
    workspaceAnimation.stop()
    refreshDebounce.stop()
  }

  property bool nativeReady: false
  property bool nativeRecovered: false
  property string nativeError: ""
  function nativeBootstrapEnvironment() {
    var allowed = ({})
    var cacheHome = Quickshell.env("XDG_CACHE_HOME")
    var runtimeDirectory = Quickshell.env("XDG_RUNTIME_DIR")
    var instance = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    if (cacheHome) allowed.XDG_CACHE_HOME = cacheHome
    if (runtimeDirectory) allowed.XDG_RUNTIME_DIR = runtimeDirectory
    if (instance) allowed.HYPRLAND_INSTANCE_SIGNATURE = instance
    return allowed
  }
  Process {
    id: nativeLoader
    clearEnvironment: true
    environment: root.nativeBootstrapEnvironment()
    command: ["/usr/bin/python3", "-I", "-S",
      decodeURIComponent(Qt.resolvedUrl("native/ensure-native.py").toString().replace(/^file:\/\//, ""))]
    stderr: StdioCollector { onStreamFinished: root.nativeError = text.trim() }
    onExited: function(code) {
      if (!root.opened) return
      if (code !== 0) {
        console.warn("Omaview native companion:", root.nativeError)
        root.close()
        Quickshell.execDetached(["/usr/bin/notify-send", "Omaview could not open", root.nativeError || "Native Hyprland companion failed to load."])
        return
      }
      root.nativeReady = true
      root.refreshState()
    }
  }

  // A state query that fails while the companion was assumed loaded means
  // the shell missed its unload; verify and reload it once, then give up.
  function recoverNative() {
    if (!root.opened || root.stateLoaded) return
    if (root.nativeRecovered) {
      root.close()
      Quickshell.execDetached(["/usr/bin/notify-send", "Omaview could not open", "The native Hyprland companion is not answering."])
      return
    }
    root.nativeRecovered = true
    root.nativeReady = false
    nativeLoader.running = true
  }

  function status(arg) {
    return JSON.stringify({ opened: root.opened, nativeReady: root.nativeReady, panelVisible: panel.visible,
      workspace: root.activeWsId, focusedAddress: root.focusedAddress, rounding: root.previewRounding,
      filter: root.filterText, clients: root.clientsByWs, previews: root.previewStatus(), error: root.nativeError,
      dockHintsVisible: root.dockHintsVisible, dockShortcutKeys: root.dockShortcutKeys, dock: root.dockItems,
      activeMenu: root.activeMenu, rows: root.rows, gridSlots: root.gridSlotGeometry(), hiddenApps: root.hiddenApps,
      appMenu: { appId: root.contextAppId, actions: root.contextActions,
        x: appMenu.card.x, y: appMenu.card.y, w: appMenu.card.width, rowHeight: root.contextRowHeight },
      dockSlots: overviewDock.slotGeometry(), dockDragging: overviewDock.dragging, dockDropValid: overviewDock.dropValid,
      dockScale: overviewDock.scale, desktopDock: root.desktopDockEnabled, desktopDocks: root.desktopDockStatus(),
      settings: root.effectiveSettings(), theme: root.themeDockStatus(),
      iconPick: root.iconPickAppId, iconOverrides: root.iconOverrides,
      workspaceMotion: { running: workspaceAnimation.running, position: root.workspacePosition,
        duration: root.previewDuration, views: root.workspaceStackStatus() }, wallpapers: root.wallpaperStatus() })
  }

  function previewStatus() {
    var result = []
    var previews = root.scrollingMode ? scrollingPreviews : workspacePreviews
    for (var i = 0; i < previews.count; i++) {
      var workspace = previews.itemAt(i)
      if (workspace) result = result.concat(workspace.previewStatus())
    }
    return result
  }

  function wallpaperStatus() {
    var result = []
    var previews = root.scrollingMode ? scrollingPreviews : workspacePreviews
    for (var i = 0; i < previews.count; i++) {
      var workspace = previews.itemAt(i)
      if (workspace) result.push(workspace.wallpaperStatus())
    }
    return result
  }

  function refresh() {
    defaultMenuFile.reload()
    userMenuFile.reload()
    return "ok"
  }

  function ping() { return "ok" }

  // ------------------------------------------------------------- settings

  // ~/.config/omarchy/omaview.json, all keys optional:
  //   desktopDock          bool    show the dock on the desktop (false)
  //   desktopDockMargin    number  gap below the desktop dock, in style units (14)
  //   desktopDockIconSize  number  desktop dock icon size, in style units (35)
  //   desktopDockBorder    bool    outline around the desktop dock (true)
  //   dockBackground       "theme" | "bar" | "app"  color behind both docks ("theme":
  //                        the theme's [omaview] dock-background, else the bar's)
  //   dockOpacity          0..1    opacity of that color (0.85)
  property var settings: ({})
  readonly property var settingLimits: ({
    desktopDockMargin: { fallback: 14, min: 0, max: 200 },
    desktopDockIconSize: { fallback: 35, min: 16, max: 96 },
    dockOpacity: { fallback: 0.85, min: 0, max: 1 }
  })
  readonly property bool desktopDockEnabled: root.settings.desktopDock === true
  readonly property real desktopDockMargin: Style.space(root.settingNumber("desktopDockMargin"))
  readonly property real desktopDockIconSize: Style.space(root.settingNumber("desktopDockIconSize"))
  readonly property bool desktopDockBorder: root.settings.desktopDockBorder !== false
  readonly property var dockBackgroundModes: ["theme", "bar", "app"]
  readonly property string dockBackground: root.dockBackgroundModes.indexOf(root.settings.dockBackground) >= 0 ? root.settings.dockBackground : "theme"
  readonly property real dockOpacity: root.settingNumber("dockOpacity")

  // Themes override the dock's colors through an [omaview] section of the
  // shell's theme values: a theme ships themes/<name>/shell.omaview.toml and
  // omarchy-theme-set folds it into the staged shell.toml, or the user puts
  // the section in ~/.config/omarchy/shell.toml. Keys, each with an -alpha
  // companion: dock-background, dock-border, desktop-dock-background,
  // desktop-dock-border (the desktop keys fall back to the dock ones).
  // Values are hex colors, palette roles (background, foreground, accent,
  // muted, urgent) or another shell.toml key. The background keys apply while
  // omaview.json's dockBackground is "theme" (its default); the border keys
  // always apply.
  function themeColor(keys, fallback) {
    var values = Color.shellValues
    for (var i = 0; i < keys.length; i++) {
      var raw = values["omaview." + keys[i]]
      if (typeof raw === "string" && raw.length > 0) return Color.flatColor(raw, fallback)
    }
    return null
  }

  function themeAlpha(keys, fallback) {
    var values = Color.shellValues
    for (var i = 0; i < keys.length; i++) {
      var number = Number(values["omaview." + keys[i] + "-alpha"])
      if (typeof values["omaview." + keys[i] + "-alpha"] === "string" && isFinite(number)) return Util.clampAlpha(number)
    }
    return fallback
  }

  readonly property color settingBackgroundColor: root.dockBackground === "app" ? Color.background : Color.bar.background
  readonly property bool themeBackground: root.dockBackground === "theme"
  readonly property color dockBackgroundColor: {
    var themed = root.themeBackground ? root.themeColor(["dock-background"], Color.background) : null
    return themed !== null ? themed : (root.themeBackground ? Color.bar.background : root.settingBackgroundColor)
  }
  readonly property real dockBackgroundAlpha: root.themeBackground ? root.themeAlpha(["dock-background"], root.dockOpacity) : root.dockOpacity
  readonly property color dockBorderColor: {
    var themed = root.themeColor(["dock-border"], Color.foreground)
    return Util.alpha(themed !== null ? themed : Color.foreground, root.themeAlpha(["dock-border"], 0.18))
  }
  readonly property color desktopDockBackgroundColor: {
    var themed = root.themeBackground ? root.themeColor(["desktop-dock-background", "dock-background"], Color.background) : null
    return themed !== null ? themed : (root.themeBackground ? Color.bar.background : root.settingBackgroundColor)
  }
  readonly property real desktopDockBackgroundAlpha: root.themeBackground
    ? root.themeAlpha(["desktop-dock-background", "dock-background"], root.dockOpacity) : root.dockOpacity
  readonly property color desktopDockBorderColor: {
    var themed = root.themeColor(["desktop-dock-border", "dock-border"], Color.foreground)
    return Util.alpha(themed !== null ? themed : Color.foreground, root.themeAlpha(["desktop-dock-border", "dock-border"], 0.18))
  }

  function themeDockStatus() {
    var out = ({})
    var values = Color.shellValues
    for (var key in values) if (key.indexOf("omaview.") === 0) out[key] = values[key]
    return { keys: out, dockBackground: String(root.dockBackgroundColor), dockBackgroundAlpha: root.dockBackgroundAlpha,
      dockBorder: String(root.dockBorderColor), desktopDockBackground: String(root.desktopDockBackgroundColor),
      desktopDockBackgroundAlpha: root.desktopDockBackgroundAlpha, desktopDockBorder: String(root.desktopDockBorderColor) }
  }

  function settingNumber(key) {
    var limit = root.settingLimits[key]
    var value = Number(root.settings[key])
    if (!isFinite(value)) return limit.fallback
    return Math.max(limit.min, Math.min(limit.max, value))
  }

  function applySettings(raw) {
    var parsed = ({})
    try { parsed = JSON.parse(raw) } catch (e) { parsed = ({}) }
    root.settings = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : ({})
  }

  function updateSettings(patch) {
    var next = ({})
    for (var key in root.settings) next[key] = root.settings[key]
    for (var changed in patch) next[changed] = patch[changed]
    root.settings = next
    // Writes are atomic and asynchronous; a second one while the first is in
    // flight would be dropped, so a burst of changes lands as one write.
    settingsWrite.restart()
  }

  Timer {
    id: settingsWrite
    interval: 50
    onTriggered: {
      settingsFile.setText(JSON.stringify(root.settings, null, 2) + "\n")
    }
  }

  function setDesktopDock(enabled) {
    root.updateSettings({ desktopDock: enabled === true })
  }

  // omarchy-shell shell call turbinebmw.omaview setting 'desktopDockMargin=20'
  // Returns the key's effective value; a bare key only reads it.
  function setting(arg) {
    var text = String(arg || "").trim()
    var at = text.indexOf("=")
    var key = (at >= 0 ? text.substring(0, at) : text).trim()
    var known = ["desktopDock", "desktopDockMargin", "desktopDockIconSize", "desktopDockBorder", "dockBackground", "dockOpacity"]
    if (known.indexOf(key) < 0) return "unknown setting: " + key
    if (at >= 0) {
      var raw = text.substring(at + 1).trim()
      var value
      if (key === "dockBackground") value = root.dockBackgroundModes.indexOf(raw) >= 0 ? raw : "theme"
      else if (key === "desktopDock" || key === "desktopDockBorder") value = ["on", "true", "1", "yes"].indexOf(raw.toLowerCase()) >= 0
      else {
        value = Number(raw)
        if (!isFinite(value)) return "not a number: " + raw
        var limit = root.settingLimits[key]
        value = Math.max(limit.min, Math.min(limit.max, value))
      }
      var patch = ({})
      patch[key] = value
      root.updateSettings(patch)
    }
    return JSON.stringify(root.effectiveSettings()[key])
  }

  function effectiveSettings() {
    return { desktopDock: root.desktopDockEnabled, desktopDockMargin: root.settingNumber("desktopDockMargin"),
      desktopDockIconSize: root.settingNumber("desktopDockIconSize"), desktopDockBorder: root.desktopDockBorder,
      dockBackground: root.dockBackground, dockOpacity: root.dockOpacity }
  }

  // omarchy-shell shell call turbinebmw.omaview desktopDock on|off|toggle
  function desktopDock(arg) {
    var value = String(arg || "").trim().toLowerCase()
    if (value === "on" || value === "true" || value === "1") root.setDesktopDock(true)
    else if (value === "off" || value === "false" || value === "0") root.setDesktopDock(false)
    else if (value === "toggle") root.setDesktopDock(!root.desktopDockEnabled)
    return root.desktopDockEnabled ? "on" : "off"
  }

  FileView {
    id: settingsFile
    path: root.configHome + "/omarchy/omaview.json"
    watchChanges: true
    printErrors: false
    atomicWrites: true
    onLoaded: root.applySettings(text())
    onLoadFailed: root.settings = ({})
    // A change on disk while a write is pending is ours; keep the newer state.
    onFileChanged: if (!settingsWrite.running) reload()
    onSaveFailed: console.warn("Omaview could not save omaview.json")
  }

  // ------------------------------------------------------- compositor state

  property var monitor: ({ name: "", x: 0, y: 0, w: 1920, h: 1080 })
  property int activeWsId: 1
  property bool scrollingMode: true
  property string activeLayout: "scrolling"   // tiledLayout of the active workspace
  property var workspaces: []        // [{id, name}] on the focused monitor, by id
  property var clientsByWs: ({})     // wsId -> [client] in monitor-local coords

  readonly property int activeWsIndex: {
    for (var i = 0; i < workspaces.length; i++) if (workspaces[i].id === activeWsId) return i
    return -1
  }
  // niri always keeps an empty workspace at the bottom; mirror that.
  property int nextFreeWsId: 2
  readonly property var nextWs: activeWsIndex >= 0 && activeWsIndex < workspaces.length - 1
    ? workspaces[activeWsIndex + 1]
    : root.clientsFor(root.activeWsId).length > 0 ? ({ id: nextFreeWsId, name: String(nextFreeWsId) }) : null

  // These are observations of the compositor, never an editable selection.
  property string focusedAddress: ""
  property string lastState: ""
  property bool modePending: false

  // Animation changes only the presentation. Workspace selection and window
  // contents always come from the latest compositor observation.
  readonly property int previewDuration: 220
  readonly property int previewEasing: Easing.OutCubic
  property real workspacePosition: 0
  property int workspaceTargetId: 0
  property string workspaceMonitor: ""
  ListModel { id: scrollingWorkspaces }
  NumberAnimation {
    id: workspaceAnimation
    target: root
    property: "workspacePosition"
    duration: root.previewDuration
    easing.type: root.previewEasing
    onFinished: root.syncWorkspaceStack(false)
  }

  function workspaceStackStatus() {
    var result = []
    for (var i = 0; i < scrollingPreviews.count; i++) {
      var view = scrollingPreviews.itemAt(i)
      if (view) result.push({ id: view.wsId, y: view.y, h: view.height, active: view.isActive })
    }
    return result
  }

  function syncWorkspaceStack(animate) {
    if (!root.scrollingMode) {
      workspaceAnimation.stop()
      scrollingWorkspaces.clear()
      root.workspaceTargetId = 0
      return
    }

    var rows = root.workspaces.slice()
    if (root.nextWs && !rows.some(function(ws) { return ws.id === root.nextWs.id })) rows.push(root.nextWs)
    var oldIds = []
    var canAnimate = animate && root.workspaceMonitor === root.monitor.name && root.workspaceTargetId !== 0
    var selectionChanged = root.workspaceTargetId !== root.activeWsId
    for (var i = 0; i < scrollingWorkspaces.count; i++) {
      var old = scrollingWorkspaces.get(i)
      oldIds.push(old.workspaceId)
      // Hyprland may remove an empty workspace as soon as we leave it. Keep
      // its preview until it has slid out, then prune it on animation finish.
      if (canAnimate && (selectionChanged || workspaceAnimation.running)
          && !rows.some(function(ws) { return ws.id === old.workspaceId }))
        rows.push({ id: old.workspaceId, name: old.workspaceName })
    }
    rows.sort(function(a, b) { return a.id - b.id })
    var ids = rows.map(function(ws) { return ws.id })
    var target = ids.indexOf(root.activeWsId)
    if (target < 0) return
    var structureChanged = JSON.stringify(ids) !== JSON.stringify(oldIds)
    var oldPosition = root.workspacePosition
    var anchor = oldIds.indexOf(root.workspaceTargetId)
    var newAnchor = ids.indexOf(root.workspaceTargetId)
    var reposition = !canAnimate || selectionChanged || structureChanged
    if (reposition) workspaceAnimation.stop()

    // Preserve delegates by workspace ID, just as WorkspaceView preserves
    // window captures by address. A focus change must not rebuild either.
    for (var row = 0; row < rows.length; row++) {
      var at = -1
      for (var j = row; j < scrollingWorkspaces.count; j++)
        if (scrollingWorkspaces.get(j).workspaceId === rows[row].id) { at = j; break }
      if (at < 0) scrollingWorkspaces.insert(row, { workspaceId: rows[row].id, workspaceName: rows[row].name })
      else {
        if (at !== row) scrollingWorkspaces.move(at, row, 1)
        scrollingWorkspaces.setProperty(row, "workspaceName", rows[row].name)
      }
    }
    if (scrollingWorkspaces.count > rows.length)
      scrollingWorkspaces.remove(rows.length, scrollingWorkspaces.count - rows.length)

    root.workspaceTargetId = root.activeWsId
    root.workspaceMonitor = root.monitor.name
    if (!reposition) return // Geometry updates must not restart the transition.
    root.workspacePosition = canAnimate && anchor >= 0 && newAnchor >= 0
      ? oldPosition + newAnchor - anchor : target
    if (root.workspacePosition !== target) {
      workspaceAnimation.from = root.workspacePosition
      workspaceAnimation.to = target
      workspaceAnimation.start()
    } else if (canAnimate) root.syncWorkspaceStack(false)
  }

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
    // Skip identical observations so captures stay alive.
    if (raw === root.lastState && root.stateLoaded && !root.modePending) return
    var data
    try { data = JSON.parse(raw) } catch (e) { root.recoverNative(); return }
    if (!data || typeof data !== "object" || !data.monitors) { root.recoverNative(); return }

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
    var history = []
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
      history.push(client)
      if (client.wsId <= 0 || c.monitor !== mon.id) continue
      if (!byWs[client.wsId]) byWs[client.wsId] = []
      byWs[client.wsId].push(client)
    }
    root.clientsByWs = byWs
    // Hyprland's focus history is authoritative while the overview is open;
    // the dock keeps following activewindowv2 events after it closes.
    history.sort(function(a, b) { return a.focusOrder - b.focusOrder })
    var ordered = history.map(function(entry) { return root.normalizeAddress(entry.address) })
    if (JSON.stringify(ordered) !== JSON.stringify(root.focusHistory)) root.focusHistory = ordered

    var screens = Quickshell.screens
    for (var s = 0; s < screens.length; s++) {
      if (screens[s].name === mon.name) { panel.screen = screens[s]; break }
    }
    root.syncWorkspaceStack(root.stateLoaded && panel.visible)
    root.stateLoaded = true
  }

  Process {
    id: stateProc
    property bool rerun: false
    command: ["/usr/bin/hyprctl", "omaview-state"]
    stdout: StdioCollector {
      onStreamFinished: root.applyState(text)
    }
    onExited: function(code) {
      if (code !== 0) root.recoverNative()
      if (rerun) { rerun = false; Qt.callLater(root.refreshState) }
    }
  }

  Timer {
    id: refreshDebounce
    interval: 16
    onTriggered: root.refreshState()
  }

  // Window focus order, most recent first, as normalized addresses. It is
  // kept while the overview is closed so the desktop dock cycles windows the
  // same way the overview does.
  property var focusHistory: []

  function noteFocus(address) {
    var key = root.normalizeAddress(address)
    if (!key) return
    var next = root.focusHistory.filter(function(entry) { return entry !== key })
    next.unshift(key)
    if (next.length > 64) next.length = 64
    root.focusHistory = next
  }

  function forgetWindow(address) {
    var key = root.normalizeAddress(address)
    if (root.focusHistory.indexOf(key) < 0) return
    root.focusHistory = root.focusHistory.filter(function(entry) { return entry !== key })
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var n = event.name
      if (n === "omaview" && event.data === "unloaded") {
        root.nativeReady = false
        root.close()
        return
      }
      if (n === "activewindowv2") root.noteFocus(event.data)
      else if (n === "closewindow") root.forgetWindow(event.data)
      if (!root.opened) return
      if (n === "configreloaded") Style.refresh()
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
    command: ["/usr/bin/readlink", "-f", (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/current/background"]
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
  property string rowsJson: "[]"
  property var providersLoaded: ({})
  property var providerQueue: []
  property int providerRevision: 0
  property var whenResults: ({})
  property var checkedResults: ({})
  property bool guardsPending: false
  // SplitParser emits strings, so this caps retained UTF-16 code units. The
  // process is killed before an oversized stream can be merged into the model.
  readonly property int collectorCharacterLimit: 262144

  function appendBoundedOutput(target, data, description) {
    if (target.outputOverflow) return
    var chunk = String(data)
    if (chunk.length > root.collectorCharacterLimit - target.collected.length) {
      target.outputOverflow = true
      target.collected = ""
      console.warn("Omaview " + description + " exceeded the output limit")
      target.signal(9)
      return
    }
    target.collected += chunk
  }

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
    if (entry && entry.kind === "app" && root.isHidden(entry.appId)) return false
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

  // Navigation always resets the grid. Refreshes from guards, providers or
  // app changes pass no force and are dropped when nothing changed: assigning
  // an equal array would still rebuild every delegate and reload its icon.
  function rebuildDisplay(force) {
    var out = []
    var query = root.filterText.trim()
    var i, entry

    if (root.iconPickAppId) {
      out = root.iconRows(query)
    } else if (root.activeMenu === root.hiddenMenuId) {
      for (i = 0; i < root.itemOrder.length; i++) {
        entry = root.item(root.itemOrder[i])
        if (!entry || entry.kind !== "app" || !root.isHidden(entry.appId)) continue
        if (query && !MenuModel.matchesQuery(entry, query, true)) continue
        out.push(MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, "", 0, "app"))
      }
      out.sort(function(a, b) { return a.label.localeCompare(b.label) })
    } else if (query) {
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
      out.push({ itemId: root.hiddenMenuId, kind: "menu", icon: "󰈉", iconFont: "",
        appIcon: "", appId: "", label: "Hidden", target: root.hiddenMenuId, detail: "", action: "" })
    } else {
      for (i = 0; i < root.itemOrder.length; i++) {
        entry = root.item(root.itemOrder[i])
        if (!entry || entry.parent !== root.activeMenu || !root.isVisible(entry)) continue
        out.push(MenuModel.displayRow(root.items, root.itemOrder, root.checkedResults, entry, "", 0, ""))
      }
    }

    var json = JSON.stringify(out)
    if (!force && json === root.rowsJson) return
    root.rowsJson = json
    root.rows = out
    grid.currentIndex = out.length > 0 ? 0 : -1
    grid.positionViewAtBeginning()
  }

  function setFilter(next) {
    if (next === root.filterText) return
    root.closeAppMenu()
    root.filterText = next
    if (next.trim() && !root.iconPickAppId) root.loadProvidersForSearch()
    root.rebuildDisplay(true)
  }

  function setActiveMenu(id, pushHistory) {
    var entry = root.item(id)
    root.closeAppMenu()
    if ((!entry && id !== root.hiddenMenuId) || id === "apps") id = "root"
    if (pushHistory && id !== root.activeMenu) root.navStack = root.navStack.concat([root.activeMenu])
    root.activeMenu = id
    root.filterText = ""
    if (id !== "root") {
      root.invalidateVolatileProvider(id)
      root.loadProviderForMenu(id)
    }
    root.rebuildDisplay(true)
  }

  function goBack() {
    if (root.iconPickAppId) { root.endIconPick(); return true }
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

    if (row.kind === "icon") {
      root.applyIcon(root.iconPickAppId, row.iconValue)
    } else if (row.kind === "app") {
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
    providerProc.outputOverflow = false
    providerProc.command = ["/usr/bin/bash", "-lc", spec.script]
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
    property bool outputOverflow: false
    stdout: SplitParser {
      // Raw chunks prevent SplitParser from retaining an unlimited partial line.
      splitMarker: ""
      onRead: function(data) { root.appendBoundedOutput(providerProc, data, "provider") }
    }
    onExited: {
      if (!providerProc.outputOverflow && providerProc.revision === root.providerRevision)
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
    guardProc.outputOverflow = false
    guardProc.command = ["/usr/bin/bash", "-lc", script]
    guardProc.running = true
  }

  Process {
    id: guardProc
    property string collected: ""
    property bool outputOverflow: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.appendBoundedOutput(guardProc, data, "guard") }
    }
    onExited: function(exitCode, exitStatus) {
      if (!guardProc.outputOverflow && exitCode === 0 && exitStatus === 0) {
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
      if (guardProc.outputOverflow) root.guardsPending = false
      else if (root.guardsPending) Qt.callLater(function() { root.evaluateGuards() })
    }
  }

  Connections {
    target: root.appLibrary
    function onAppsChanged() { root.mergeAppRows() }
  }

  // Apps that arrive after a failed pin load (DesktopEntries fills in async),
  // and class lookups that must follow installed or edited entries.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      root.classEntryCache = ({})
      if (!root.appLibrary) root.mergeAppRows()
      if (root.pinnedLoaded && root.pinned.length === 0 && !pinnedFile.loaded) root.pinned = root.defaultPins()
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

  // ------------------------------------------ app visibility / context menu

  readonly property string hiddenMenuId: "__omaview_hidden"
  property var hiddenApps: []
  onHiddenAppsChanged: root.rebuildDisplay()

  function isHidden(appId) { return root.hiddenApps.indexOf(appId) >= 0 }

  function setAppHidden(appId, hidden) {
    if (!appId || root.isHidden(appId) === hidden) return
    var next = root.hiddenApps.slice()
    if (hidden) next.push(appId)
    else next.splice(next.indexOf(appId), 1)
    root.hiddenApps = next
    hiddenFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  FileView {
    id: hiddenFile
    path: root.configHome + "/omarchy/omaview-hidden.json"
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        if (Array.isArray(parsed)) root.hiddenApps = parsed.map(String)
      } catch (e) { }
    }
    onLoadFailed: root.hiddenApps = []
  }

  property string contextAppId: ""
  property var contextActions: []
  property int contextIndex: 0
  property point contextPoint: Qt.point(0, 0)
  readonly property int contextRowHeight: Style.space(38)

  // Sources: "launcher" and "hidden" tiles, "dock" icons in the overview,
  // "desktop" icons on the desktop dock, and "background" for the dock's
  // padding. The same actions run from either dock.
  function contextActionsFor(appId, source) {
    var actions = []
    if (source === "hidden") {
      actions.push({ label: "Unhide app", action: "unhide" })
    } else if (appId && source !== "background") {
      actions.push({ label: root.isPinned(appId) ? "Unpin from dock" : "Pin to dock", action: "pin" })
      if (source === "launcher") actions.push({ label: "Hide app", action: "hide" })
      actions.push({ label: "Change icon…", action: "icon" })
      if (root.iconOverrides.indexOf(appId) >= 0) actions.push({ label: "Reset icon", action: "resetIcon" })
    }
    if (source === "background" || source === "desktopBackground")
      actions.push({ label: root.desktopDockEnabled ? "Hide dock from desktop" : "Show dock on desktop", action: "desktopDock" })
    if (source === "desktopBackground") {
      actions.push({ label: root.desktopDockBorder ? "Hide border" : "Show border", action: "border" })
      actions.push({ label: "Background: " + root.dockBackground, action: "background" })
      actions.push({ label: "Larger icons", action: "larger" })
      actions.push({ label: "Smaller icons", action: "smaller" })
    }
    return actions
  }

  function runContextAction(appId, action) {
    if (action === "pin") root.togglePin(appId)
    else if (action === "hide" || action === "unhide") root.setAppHidden(appId, action === "hide")
    else if (action === "icon") root.beginIconPick(appId)
    else if (action === "resetIcon") root.applyIcon(appId, "")
    else if (action === "desktopDock") root.setDesktopDock(!root.desktopDockEnabled)
    else if (action === "border") root.updateSettings({ desktopDockBorder: !root.desktopDockBorder })
    else if (action === "background") {
      var modes = root.dockBackgroundModes
      root.updateSettings({ dockBackground: modes[(modes.indexOf(root.dockBackground) + 1) % modes.length] })
    }
    else if (action === "larger" || action === "smaller") {
      var limit = root.settingLimits.desktopDockIconSize
      var size = root.settingNumber("desktopDockIconSize") + (action === "larger" ? 4 : -4)
      root.updateSettings({ desktopDockIconSize: Math.max(limit.min, Math.min(limit.max, size)) })
    }
  }

  function closeAppMenu() {
    root.contextAppId = ""
    root.contextActions = []
  }

  function openAppMenu(appId, source, point) {
    var actions = root.contextActionsFor(appId, source)
    if (actions.length === 0) return
    root.contextPoint = point
    root.contextIndex = 0
    root.contextActions = actions
    root.contextAppId = appId || "__background"
    keyCatcher.forceActiveFocus()
  }

  function activateAppMenu(index) {
    if (index < 0 || index >= root.contextActions.length) return
    var appId = root.contextAppId === "__background" ? "" : root.contextAppId
    var action = root.contextActions[index].action
    root.closeAppMenu()
    root.runContextAction(appId, action)
  }

  function gridSlotGeometry() {
    var result = []
    for (var i = 0; i < grid.count; i++) {
      var tile = grid.itemAtIndex(i)
      if (!tile) continue
      var point = tile.mapToItem(keyCatcher, 0, 0)
      if (point.y < grid.y || point.y + tile.height > grid.y + grid.height) continue
      result.push({ itemId: tile.modelData.itemId, appId: tile.modelData.appId,
        x: point.x, y: point.y, w: tile.width, h: tile.height })
    }
    return result
  }

  // ------------------------------------------------------------ icon picker

  // "Change icon…" turns the grid into a picker: theme icon names matching
  // the search, or an image path typed or pasted in. The choice is written
  // by scripts/set-icon.py into a user-local desktop entry.
  property string iconPickAppId: ""
  property string iconPickName: ""
  property string iconPickCurrent: ""
  property var iconNames: []
  property bool iconNamesLoaded: false
  property var iconOverrides: []

  function iconToolEnvironment() {
    var allowed = ({})
    var keys = ["HOME", "XDG_DATA_HOME", "XDG_DATA_DIRS"]
    for (var i = 0; i < keys.length; i++) {
      var value = Quickshell.env(keys[i])
      if (value) allowed[keys[i]] = value
    }
    return allowed
  }

  readonly property string iconToolPath: decodeURIComponent(Qt.resolvedUrl("scripts/set-icon.py").toString().replace(/^file:\/\//, ""))

  function beginIconPick(appId) {
    if (!appId) return
    if (!root.opened) root.open("{}")
    root.closeAppMenu()
    var entry = DesktopEntries.byId(appId)
    root.iconPickName = entry ? String(entry.name || appId) : appId
    root.iconPickCurrent = entry ? String(entry.icon || "") : ""
    root.iconPickAppId = appId
    root.filterText = ""
    root.loadIconNames()
    root.rebuildDisplay(true)
  }

  function endIconPick() {
    root.iconPickAppId = ""
    root.filterText = ""
    root.rebuildDisplay(true)
  }

  function iconRow(value, label) {
    return { itemId: "icon:" + value, kind: "icon", icon: "", iconFont: "", appIcon: value, appId: "",
             label: label, target: "", detail: "", action: "", iconValue: value }
  }

  function iconResolves(name) {
    return root.iconSource(name) !== root.iconSource("")
  }

  function iconRows(query) {
    var out = []
    var seen = ({})
    var expanded = query.replace(/^~(?=\/)/, Quickshell.env("HOME"))
    if (expanded.charAt(0) === "/" && /\.(png|svg|svgz|jpe?g|webp|xpm|ico|bmp)$/i.test(expanded)) {
      seen[expanded] = true
      out.push(root.iconRow(expanded, expanded.split("/").pop()))
    }
    var lower = query.toLowerCase()
    if (!lower) {
      // Without a query, offer the icons of installed apps: borrowing one of
      // those is the common case for a web app or a terminal program.
      var entries = root.appEntries()
      for (var e = 0; e < entries.length; e++) {
        var icon = String(entries[e].icon || "")
        if (!icon || seen[icon] || icon.charAt(0) === "/") continue
        seen[icon] = true
        out.push(root.iconRow(icon, icon))
      }
      out.sort(function(a, b) { return a.label.localeCompare(b.label) })
      return out
    }
    var prefix = [], contains = []
    for (var i = 0; i < root.iconNames.length && prefix.length + contains.length < 400; i++) {
      var name = root.iconNames[i]
      var at = name.toLowerCase().indexOf(lower)
      if (at < 0) continue
      if (at === 0) prefix.push(name)
      else contains.push(name)
    }
    var ordered = prefix.concat(contains)
    for (var k = 0; k < ordered.length && out.length < 150; k++) {
      if (seen[ordered[k]] || !root.iconResolves(ordered[k])) continue
      seen[ordered[k]] = true
      out.push(root.iconRow(ordered[k], ordered[k]))
    }
    return out
  }

  function iconDirectories() {
    var home = Quickshell.env("HOME")
    var dirs = [(Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")) + "/icons", home + "/.icons",
                home + "/.local/share/flatpak/exports/share/icons", "/var/lib/flatpak/exports/share/icons"]
    var dataDirs = (Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share").split(":")
    for (var i = 0; i < dataDirs.length; i++) {
      if (!dataDirs[i]) continue
      dirs.push(dataDirs[i] + "/icons")
      dirs.push(dataDirs[i] + "/pixmaps")
    }
    return dirs
  }

  function loadIconNames() {
    if (root.iconNamesLoaded || iconNamesProc.running) return
    var dirs = root.iconDirectories().map(Util.shellQuote).join(" ")
    iconNamesProc.collected = ""
    iconNamesProc.outputOverflow = false
    iconNamesProc.command = ["/usr/bin/bash", "-c",
      "find " + dirs + " -type f \\( -iname '*.svg' -o -iname '*.svgz' -o -iname '*.png' -o -iname '*.xpm' \\) -printf '%f\\n' 2>/dev/null"
      + " | sed -E 's/\\.(svgz?|png|xpm)$//I' | sort -u"]
    iconNamesProc.running = true
  }

  Process {
    id: iconNamesProc
    property string collected: ""
    property bool outputOverflow: false
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(data) { root.appendBoundedOutput(iconNamesProc, data, "icon list") }
    }
    onExited: {
      if (iconNamesProc.outputOverflow) return
      root.iconNames = iconNamesProc.collected.split("\n").filter(function(name) { return name.length > 0 })
      root.iconNamesLoaded = true
      if (root.opened && root.iconPickAppId) root.rebuildDisplay()
    }
  }

  function applyIcon(appId, value) {
    if (!appId || iconProc.running) return
    iconProc.appId = appId
    iconProc.error = ""
    iconProc.command = value
      ? ["/usr/bin/python3", "-I", "-S", root.iconToolPath, "set", appId, value]
      : ["/usr/bin/python3", "-I", "-S", root.iconToolPath, "reset", appId]
    iconProc.running = true
    if (root.iconPickAppId === appId) root.endIconPick()
  }

  Process {
    id: iconProc
    property string appId: ""
    property string error: ""
    clearEnvironment: true
    environment: root.iconToolEnvironment()
    stderr: StdioCollector { onStreamFinished: iconProc.error = text.trim() }
    onExited: function(code) {
      if (code !== 0) {
        console.warn("Omaview icon change:", iconProc.error)
        Quickshell.execDetached(["/usr/bin/notify-send", "Omaview could not change the icon", iconProc.error || "The desktop entry could not be updated."])
      }
      root.listIconOverrides()
    }
  }

  function listIconOverrides() {
    if (iconListProc.running) { iconListProc.rerun = true; return }
    iconListProc.running = true
  }

  Process {
    id: iconListProc
    property bool rerun: false
    clearEnvironment: true
    environment: root.iconToolEnvironment()
    command: ["/usr/bin/python3", "-I", "-S", root.iconToolPath, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        var ids = text.split("\n").filter(function(id) { return id.length > 0 })
        if (JSON.stringify(ids) !== JSON.stringify(root.iconOverrides)) root.iconOverrides = ids
      }
    }
    onExited: {
      if (rerun) { rerun = false; Qt.callLater(root.listIconOverrides) }
    }
  }

  Component.onCompleted: root.listIconOverrides()

  // ------------------------------------------------------------------ dock

  property string pinnedPath: root.configHome + "/omarchy/omaview-pinned.json"
  property var pinned: []
  property bool pinnedLoaded: false
  property bool dockHintsVisible: false
  property var dockShortcutKeys: []

  function clearDockDrag() {
    overviewDock.clearDrag()
  }

  function setDockHints(held) {
    held = held && root.opened
    if (held === root.dockHintsVisible) return
    // Keep letters attached to app identities if windows change while Ctrl
    // is held. A fresh press assigns a-z in the current dock order.
    root.dockShortcutKeys = held ? overviewDock.displayItems.slice(0, 26).map(function(item) { return item.key }) : []
    root.dockHintsVisible = held
  }

  function activateDockShortcut(index) {
    if (!root.opened || !root.dockHintsVisible || index < 0 || index >= root.dockShortcutKeys.length) return false
    var key = root.dockShortcutKeys[index]
    for (var i = 0; i < root.dockItems.length; i++) {
      if (root.dockItems[i].key !== key) continue
      root.activateDockItem(root.dockItems[i], false)
      return true
    }
    // The app disappeared after its badge was shown. Do not reinterpret its
    // letter as a different app or as a search-editing command.
    return true
  }
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

  function savePins(next) {
    if (JSON.stringify(next) === JSON.stringify(root.pinned)) return
    root.pinned = next
    pinnedFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function togglePin(appId) {
    if (!appId) return
    var next = root.pinned.slice()
    var at = next.indexOf(appId)
    if (at >= 0) next.splice(at, 1)
    else next.push(appId)
    root.savePins(next)
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

  // Pinned apps, then running apps grouped by desktop entry. Running windows
  // come from Hyprland's toplevel list, which Quickshell keeps current without
  // any process, so the desktop dock stays live while the overview is closed.
  readonly property var dockItems: {
    var _apps = DesktopEntries.applications.values
    var out = []
    if (!root.opened && !root.desktopDockEnabled) return out
    var seen = ({})
    var i

    for (i = 0; i < root.pinned.length; i++) {
      var pinnedEntry = DesktopEntries.byId(root.pinned[i])
      if (!pinnedEntry || seen[pinnedEntry.id] !== undefined) continue
      seen[pinnedEntry.id] = out.length
      out.push({ key: pinnedEntry.id, appId: pinnedEntry.id, name: pinnedEntry.name, icon: pinnedEntry.icon, pinned: true, windows: [], sepBefore: false })
    }

    var firstRunning = true
    var toplevels = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i].wayland
      if (!toplevel || !toplevel.appId || toplevel.parent) continue
      var cls = String(toplevel.appId)
      var entry = root.entryForClass(cls)
      var key = entry ? entry.id : "class:" + cls
      if (seen[key] === undefined) {
        seen[key] = out.length
        out.push({
          key: key, appId: entry ? entry.id : "", name: entry ? entry.name : cls,
          icon: entry ? entry.icon : cls, pinned: false, windows: [],
          sepBefore: firstRunning && out.length > 0
        })
        firstRunning = false
      }
      var normalized = root.normalizeAddress(toplevels[i].address)
      var order = root.focusHistory.indexOf(normalized)
      out[seen[key]].windows.push({ address: "0x" + normalized, cls: cls,
        focused: toplevel.activated === true, focusOrder: order >= 0 ? order : 1e9 })
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

  function scrollWorkspaces(steps) {
    // Scrolling down moves to the next workspace, matching the bar button.
    root.dispatch(Navigation.stepWorkspace(steps < 0 ? 1 : -1))
  }

  // ---------------------------------------------------------- desktop dock

  // The desktop dock is the overview's dock drawn smaller on a Top layer at
  // the bottom of every screen, reserving its own height. Opening the
  // overview draws its dock over it and scales up from the same size.
  readonly property real desktopDockScale: root.desktopDockIconSize / Math.max(1, root.dockIcon)
  readonly property int desktopPopupRoom: root.contextRowHeight * 5 + Style.space(28)

  function desktopDockStatus() {
    var result = []
    for (var i = 0; i < desktopDocks.instances.length; i++) {
      var window = desktopDocks.instances[i]
      result.push({ screen: window.screen ? window.screen.name : "", visible: window.visible,
        exclusiveZone: window.exclusiveZone, slots: window.dock.slotGeometry(),
        menu: { appId: window.menuAppId, actions: window.menuActions } })
    }
    return result
  }

  Variants {
    id: desktopDocks
    model: root.desktopDockEnabled ? Quickshell.screens : []

    delegate: PanelWindow {
      id: desktopPanel
      required property var modelData
      property alias dock: desktopDock
      screen: modelData
      visible: root.desktopDockEnabled && root.dockItems.length > 0
      color: "transparent"
      WlrLayershell.namespace: "omarchy-omaview-dock"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Normal
      exclusiveZone: Math.round(dockBody.height + root.desktopDockMargin)
      anchors { left: true; right: true; bottom: true }
      implicitHeight: Math.round(dockBody.height + root.desktopDockMargin + root.desktopPopupRoom)

      property string menuAppId: ""
      property var menuActions: []
      property point menuPoint: Qt.point(0, 0)

      function openMenu(appId, source, at) {
        var actions = root.contextActionsFor(appId, source)
        if (actions.length === 0) return
        desktopPanel.menuAppId = appId
        desktopPanel.menuPoint = Qt.point(at.x, dockBody.y)
        desktopPanel.menuActions = actions
        desktopMenu.currentIndex = 0
      }

      function closeMenu() {
        desktopPanel.menuAppId = ""
        desktopPanel.menuActions = []
      }

      // Only the dock and an open menu take input; the room kept above them
      // for tooltips and menus lets clicks through to the windows below.
      mask: Region {
        item: dockBody
        Region { item: desktopMenu.visible ? desktopMenu.card : null }
      }

      HyprlandFocusGrab {
        active: desktopMenu.visible
        windows: [desktopPanel]
        onCleared: desktopPanel.closeMenu()
      }

      Item {
        id: dockBody
        width: desktopDock.width * desktopDock.scale
        height: desktopDock.height * desktopDock.scale
        x: Math.round((parent.width - width) / 2)
        y: parent.height - height - root.desktopDockMargin

        Dock {
          id: desktopDock
          transformOrigin: Item.TopLeft
          scale: root.desktopDockScale
          items: root.dockItems
          pinnedOrder: root.pinned
          maxWidth: (desktopPanel.width - root.edge * 2) / root.desktopDockScale
          iconSize: root.dockIcon
          iconSource: root.iconSource
          backgroundColor: root.desktopDockBackgroundColor
          backgroundOpacity: root.desktopDockBackgroundAlpha
          borderVisible: root.desktopDockBorder
          borderColor: root.desktopDockBorderColor
          onActivated: function(item, forceNew) { root.activateDockItem(item, forceNew) }
          onContextRequested: function(item, at) { desktopPanel.openMenu(item.appId, item.appId ? "desktop" : "desktopBackground", at) }
          onBackgroundContextRequested: function(at) { desktopPanel.openMenu("", "desktopBackground", at) }
          onReordered: function(appIds) { root.savePins(appIds) }
          onScrolled: function(steps) { root.scrollWorkspaces(steps) }
        }
      }

      AppMenu {
        id: desktopMenu
        actions: desktopPanel.menuActions
        at: desktopPanel.menuPoint
        above: true
        rowHeight: root.contextRowHeight
        radius: root.radius
        onHovered: function(index) { desktopMenu.currentIndex = index }
        onActivated: function(index) {
          var action = desktopPanel.menuActions[index].action
          var appId = desktopPanel.menuAppId
          desktopPanel.closeMenu()
          root.runContextAction(appId, action)
        }
        onDismissed: desktopPanel.closeMenu()
      }
    }
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
  readonly property real previewRounding: Math.max(0, Style.cornerRadius)

  PanelWindow {
    id: panel
    visible: root.opened && root.nativeReady && root.stateLoaded
    onVisibleChanged: {
      if (visible) {
        keyCatcher.forceActiveFocus()
        // Grow out of the desktop dock when there is one to grow from.
        if (root.desktopDockEnabled) dockEntry.restart()
      } else {
        root.setDockHints(false)
        dockEntry.stop()
        overviewDock.scale = 1
      }
    }
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

      function pasteFilter() {
        var clip = String(Quickshell.clipboardText || "").split("\n")[0].trim()
        if (clip) root.setFilter(root.filterText + clip)
      }

      Keys.onPressed: function(event) {
        var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
        root.setDockHints(ctrl || event.key === Qt.Key_Control)
        if (root.contextAppId) {
          if (event.key === Qt.Key_Escape) root.closeAppMenu()
          else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
            var delta = event.key === Qt.Key_Up ? -1 : 1
            root.contextIndex = (root.contextIndex + delta + root.contextActions.length) % root.contextActions.length
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.activateAppMenu(root.contextIndex)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape && overviewDock.pressedItem) {
          overviewDock.cancelDrag()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Control) {
          event.accepted = true
          return
        }
        // Shift+Insert pastes anywhere; Ctrl+V does too while picking an
        // icon, where a pasted image path is the likely intent.
        if ((event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier))
            || (root.iconPickAppId && ctrl && event.key === Qt.Key_V && !(event.modifiers & (Qt.AltModifier | Qt.MetaModifier)))) {
          keyCatcher.pasteFilter()
          event.accepted = true
          return
        }
        if (ctrl && !(event.modifiers & (Qt.AltModifier | Qt.MetaModifier))
            && event.key >= Qt.Key_A && event.key <= Qt.Key_Z) {
          if (event.isAutoRepeat || root.activateDockShortcut(event.key - Qt.Key_A)) {
            event.accepted = true
            return
          }
        }
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

      Keys.onReleased: function(event) {
        if (event.isAutoRepeat) return
        root.setDockHints(event.key !== Qt.Key_Control && (event.modifiers & Qt.ControlModifier) !== 0)
        if (event.key === Qt.Key_Control) event.accepted = true
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
            id: workspacePreviews
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
              radius: root.previewRounding * s
              toplevelFor: root.toplevelFor
              live: panel.visible
              animationDuration: root.previewDuration
              animationEasing: root.previewEasing
              iconFor: root.iconForClass
              onWorkspaceActivated: function(id) { root.focusWorkspace(id, true) }
              onWindowAccepted: function(address) { root.focusWindow(address, false) }
              onWindowCloseRequested: function(address) { root.closeWindow(address) }
            }
          }
        }

        // Stable workspace previews slide through the viewport together.
        // The adjacent workspaces naturally remain visible as narrow peeks.
        Repeater {
          id: scrollingPreviews
          model: scrollingWorkspaces
          delegate: WorkspaceView {
            required property int index
            required property int workspaceId
            required property string workspaceName
            visible: root.scrollingMode
            width: parent.width
            y: root.peek + root.stackGap + (index - root.workspacePosition) * (height + root.stackGap)
            wsId: workspaceId
            wsName: workspaceName
            clients: root.clientsFor(workspaceId)
            monW: root.monitor.w
            monH: root.monitor.h
            s: panel.mainScale
            wallpaper: root.wallpaper
            isActive: workspaceId === root.activeWsId
            showBadges: isActive
            radius: root.previewRounding * s
            toplevelFor: root.toplevelFor
            live: panel.visible
            animationDuration: root.previewDuration
            animationEasing: root.previewEasing
            iconFor: root.iconForClass
            onWorkspaceActivated: function(id) { root.focusWorkspace(id, true) }
            onWindowActivated: function(address) { root.focusWindow(address, true) }
            onWindowAccepted: function(address) { root.focusWindow(address, false) }
            onWindowCloseRequested: function(address) { root.closeWindow(address) }
          }
        }

        // One-finger swipes. The handler grabs passively on press, so taps
        // still reach the previews; past the drag threshold it takes the
        // touch point and the tap is cancelled. The axis locks on the first
        // movement, and every swipeStep of travel dispatches one step, so a
        // longer swipe moves further. Content follows the finger: swiping up
        // or left reveals the next workspace or the column to the right.
        Item {
          anchors.fill: parent
          z: 10

          DragHandler {
            id: swipe
            target: null
            acceptedDevices: PointerDevice.TouchScreen
            property string axis: ""
            property real consumed: 0
            readonly property real swipeStep: Style.space(90)

            onActiveChanged: {
              axis = ""
              consumed = 0
            }
            onActiveTranslationChanged: {
              if (!active) return
              var t = activeTranslation
              if (!axis) axis = Math.abs(t.x) >= Math.abs(t.y) ? "x" : "y"
              var travel = axis === "x" ? -t.x : -t.y
              while (Math.abs(travel - consumed) >= swipeStep) {
                var direction = travel > consumed ? 1 : -1
                consumed += direction * swipeStep
                if (axis === "y" && root.scrollingMode) root.stepWorkspace(direction)
                else if (axis === "x" && root.scrollingMode) root.focusDirection(direction > 0 ? "r" : "l")
                else if (axis === "x") root.stepWorkspace(direction)
              }
            }
          }

          // Mouse wheels and touchpads. Deltas accumulate so one notch (120)
          // is one step and a touchpad needs a deliberate scroll; reversing
          // direction or pausing starts over, and touchpad momentum is
          // ignored so a flick stops where the fingers lift. Vertical
          // scrolling switches workspaces; horizontal scrolling moves through
          // columns in the scrolling layout and through workspaces in the
          // strip.
          MouseArea {
            id: wheelArea
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            property real accX: 0
            property real accY: 0
            readonly property real notch: 120

            Timer {
              id: wheelIdle
              interval: 300
              onTriggered: {
                wheelArea.accX = 0
                wheelArea.accY = 0
              }
            }

            onWheel: function(event) {
              event.accepted = true
              if (event.phase === Qt.ScrollMomentum) return
              wheelIdle.restart()
              var dx = event.angleDelta.x
              var dy = event.angleDelta.y
              if (Math.abs(dy) >= Math.abs(dx)) {
                if (dy * accY < 0) accY = 0
                accY += dy
                accX = 0
                while (Math.abs(accY) >= notch) {
                  var down = accY < 0
                  accY += down ? notch : -notch
                  root.stepWorkspace(down ? 1 : -1)
                }
              } else {
                if (dx * accX < 0) accX = 0
                accX += dx
                accY = 0
                while (Math.abs(accX) >= notch) {
                  var right = accX < 0
                  accX += right ? notch : -notch
                  if (root.scrollingMode) root.focusDirection(right ? "r" : "l")
                  else root.stepWorkspace(right ? 1 : -1)
                }
              }
            }
          }
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
          visible: (root.activeMenu !== "root" || root.iconPickAppId !== "") && !root.filterText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: backLabel.implicitWidth + Style.space(20)
          height: parent.height - Style.space(6)
          radius: height / 2
          color: backMouse.containsMouse ? Color.menu.selectedBackground : Style.normalFill

          Text {
            id: backLabel
            anchors.centerIn: parent
            text: "‹  " + (root.iconPickAppId ? "Icon for " + root.iconPickName
              : root.activeMenu === root.hiddenMenuId ? "Hidden" : MenuModel.pathFor(root.items, root.activeMenu))
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
            text: root.filterText ? root.filterText : (root.iconPickAppId ? "Icon name or image path" : "Type to search")
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
        anchors.bottom: overviewDock.top
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
          readonly property bool isIcon: modelData.kind === "icon"
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
              visible: tile.isApp || tile.isIcon
              anchors.fill: parent
              source: tile.isApp || tile.isIcon ? root.iconSource(tile.modelData.appIcon) : ""
              sourceSize.width: 128
              sourceSize.height: 128
              asynchronous: true
            }

            // Omarchy menu entries have Nerd Font glyphs rather than icons;
            // give them an app-icon-sized plate so they sit in the same grid.
            Rectangle {
              visible: !tile.isApp && !tile.isIcon
              anchors.fill: parent
              radius: width * 0.26
              color: tile.isMenu ? Util.alpha(Color.accent, 0.16) : Style.normalFill
              border.width: 1
              border.color: Util.alpha(tile.isMenu ? Color.accent : Color.foreground, 0.28)

              Text {
                anchors.centerIn: parent
                text: tile.modelData.icon || (tile.isMenu ? "" : "")
                color: tile.isMenu ? Color.accent : Color.menu.text
                font.family: tile.modelData.iconFont || Style.font.menuFamily
                font.pixelSize: Math.round(root.iconSize * 0.46)
              }
            }

            // Pinned marker, or the app's current icon while picking one.
            Rectangle {
              visible: (tile.isApp && root.isPinned(tile.modelData.appId))
                || (tile.isIcon && tile.modelData.iconValue === root.iconPickCurrent)
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
                if (tile.isApp) root.openAppMenu(tile.modelData.appId,
                  root.activeMenu === root.hiddenMenuId ? "hidden" : "launcher", mapToItem(keyCatcher, mouse.x, mouse.y))
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
          text: root.iconPickAppId ? (root.iconNamesLoaded ? "No matching icons" : "Looking for icons…")
            : root.filterText ? "No matches" : (root.activeMenu === root.hiddenMenuId ? "No hidden apps" : "Nothing here")
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      // ------------------------------------------------------------ dock
      Dock {
        id: overviewDock
        anchors.bottom: parent.bottom
        // Sit where the desktop dock sits, so the scale-up starts in place.
        anchors.bottomMargin: root.desktopDockEnabled ? root.desktopDockMargin : root.edge
        anchors.horizontalCenter: parent.horizontalCenter
        transformOrigin: Item.Bottom
        maxWidth: parent.width - root.edge * 2
        iconSize: root.dockIcon
        items: root.dockItems
        pinnedOrder: root.pinned
        hintsVisible: root.dockHintsVisible
        shortcutKeys: root.dockShortcutKeys
        iconSource: root.iconSource
        backgroundColor: root.dockBackgroundColor
        backgroundOpacity: root.dockBackgroundAlpha
        borderColor: root.dockBorderColor
        onActivated: function(item, forceNew) { root.activateDockItem(item, forceNew) }
        onContextRequested: function(item, at) { root.openAppMenu(item.appId, item.appId ? "dock" : "background", at) }
        onBackgroundContextRequested: function(at) { root.openAppMenu("", "background", at) }
        onReordered: function(appIds) { root.savePins(appIds) }
        onScrolled: function(steps) { root.scrollWorkspaces(steps) }
      }

      NumberAnimation {
        id: dockEntry
        target: overviewDock
        property: "scale"
        from: root.desktopDockScale
        to: 1
        duration: root.previewDuration
        easing.type: root.previewEasing
      }

      // Keep the menu in this layer so native keyboard routing and pointer
      // dismissal work without a separate Wayland popup or focus grab.
      AppMenu {
        id: appMenu
        actions: root.contextActions
        currentIndex: root.contextIndex
        at: root.contextPoint
        rowHeight: root.contextRowHeight
        radius: root.radius
        onHovered: function(index) { root.contextIndex = index }
        onActivated: function(index) { root.activateAppMenu(index) }
        onDismissed: root.closeAppMenu()
      }
    }
  }
}
