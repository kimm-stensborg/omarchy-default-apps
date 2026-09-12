import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Default-application picker. Left pane lists filetype groups with the app
// each one currently opens in; right pane lists the apps that can take it.
// Everything it writes goes through `xdg-mime default`, so the result is the
// same mimeapps.list any other tool would produce.
Item {
  id: root

  // Injected by omarchy-shell when this plugin is summoned.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null
  // The registry hands every plugin its own source directory, so the helper
  // script is found wherever the plugin was installed rather than at a path
  // hardcoded from the id.
  readonly property string pluginDir: root.manifest && root.manifest.__sourceDir
    ? String(root.manifest.__sourceDir)
    : Quickshell.env("HOME") + "/.config/omarchy/plugins/" + root.pluginId
  readonly property string pluginId: "io.github.kimm-stensborg.default-apps"
  readonly property string customPath: Quickshell.env("HOME") + "/.config/omarchy/default-apps.json"

  property bool opened: false
  // 0 = filetype list, 1 = app list. Each pane keeps its own filter: sharing
  // one meant that clearing it on the way into the app pane re-expanded the
  // filetype list under a positional selection, silently retargeting the
  // assignment at whatever now sat in that row.
  property int pane: 0
  property string categoryFilter: ""
  property string appFilter: ""
  readonly property string filterText: root.pane === 0 ? root.categoryFilter : root.appFilter
  // The selected filetype is held by key, so a list that regroups underneath
  // (a filter edit, a rescan, a custom row added or removed) cannot move the
  // selection to a different group.
  property string selectedKey: ""
  property int appIndex: 0
  property bool showAllApps: false
  property bool addPromptOpen: false
  // The prompt renders its own typed line rather than embedding a focused
  // TextField: the key catcher below owns keyboard input for the whole panel,
  // and two focus owners in one layer surface race each other.
  property string addInput: ""
  property string addError: ""
  // Removing a custom row is destructive (the filetype leaves the list), so it
  // goes through the same confirm the menu uses for uninstalling an app.
  property bool deleteConfirmOpen: false
  property var deleteTarget: null
  property string statusMessage: ""
  property bool busy: false

  // Whole-system snapshot from scan.py: apps, current defaults, declared
  // handlers, and the MIME subclass map.
  property var scan: ({ apps: ({}), defaults: ({}), handlers: ({}), parents: ({}) })
  property bool scanned: false
  property var customRows: []

  readonly property var categoryRows: root.scanned
    ? Model.categoryRows(root.customRows, root.scan, root.categoryFilter)
    : []
  // ADD_KEY is the trailing "Add a filetype…" row, which has no category behind it.
  readonly property string addKey: "__add"
  readonly property int categoryIndex: {
    if (root.selectedKey === root.addKey) return root.categoryRows.length
    for (var i = 0; i < root.categoryRows.length; i++) {
      if (root.categoryRows[i].key === root.selectedKey) return i
    }
    return 0
  }
  readonly property var selectedCategory: {
    for (var i = 0; i < root.categoryRows.length; i++) {
      if (root.categoryRows[i].key === root.selectedKey) return root.categoryRows[i]
    }
    return null
  }
  readonly property var appList: root.selectedCategory
    ? Model.appRows(root.selectedCategory, root.scan, root.appFilter, root.showAllApps)
    : []
  readonly property bool moreAppsAvailable: !root.showAllApps && root.selectedCategory
    ? Model.hasHiddenApps(root.selectedCategory, root.scan, root.appFilter)
    : false

  // Theme: shares the [menu] surface tokens, so a theme that styles the
  // Omarchy menu styles this panel too.
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))
  readonly property color scrim: Color.menu.scrim
  readonly property color selectedBackground: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property color accent: Color.accent
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily
  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int contentSpacing: Style.spacing.md
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  readonly property int footerHeight: Math.max(Style.space(20), Style.font.caption + Style.space(6))
  readonly property int rowHeight: Math.max(Style.space(46), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  readonly property int cardWidth: Math.min(Style.space(940), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(620), panel.height - Style.gapsOut * 2)

  // ------------------------------------------------------------- lifecycle

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }

    root.opened = true
    root.pane = 0
    root.categoryFilter = ""
    root.appFilter = ""
    root.selectedKey = ""
    root.appIndex = 0
    root.showAllApps = false
    root.addPromptOpen = false
    root.addError = ""
    root.closeDeleteConfirm()
    root.statusMessage = ""
    root.refresh()
    if (root.appLibrary) root.appLibrary.refreshIcons()

    // `summon <id> '{"filter":"pdf"}'` lands straight on a group.
    if (payload.filter) root.categoryFilter = String(payload.filter)

    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.addPromptOpen = false
    root.closeDeleteConfirm()
    root.opened = false
  }

  function refresh() {
    if (!scanProc.running) scanProc.running = true
    return "ok"
  }

  function ping() { return "ok" }

  // keepLoaded mounts the plugin when the shell starts, so this is the first
  // start after enabling: the moment to put it under Setup → Defaults, once.
  // Deferred a tick so the host has injected `manifest` and pluginDir points
  // at the real install.
  Component.onCompleted: Qt.callLater(function() { menuProc.running = true })

  // Seed and heal the selection: on open there is no key yet, and a filter
  // edit can exclude the selected group. Never re-seed from the app pane —
  // the whole point of the key is that the target cannot move once chosen.
  onCategoryRowsChanged: {
    if (root.pane !== 0) return
    if (root.selectedKey === root.addKey) return
    if (root.selectedCategory) return
    if (root.categoryRows.length > 0) root.selectedKey = root.categoryRows[0].key
  }

  // ------------------------------------------------------------- navigation

  function activeCount() {
    return root.pane === 0 ? root.categoryRows.length + 1 : root.appList.length + (root.moreAppsAvailable ? 1 : 0)
  }

  function activeIndex() {
    return root.pane === 0 ? root.categoryIndex : root.appIndex
  }

  function selectCategoryRow(index) {
    root.selectedKey = index >= root.categoryRows.length || index < 0
      ? root.addKey
      : root.categoryRows[index].key
  }

  function setActiveIndex(value) {
    var count = root.activeCount()
    if (count <= 0) return
    var next = Math.max(0, Math.min(value, count - 1))
    if (root.pane === 0) root.selectCategoryRow(next)
    else root.appIndex = next
    Qt.callLater(function() {
      var view = root.pane === 0 ? categoryList : appListView
      view.positionViewAtIndex(next, ListView.Contain)
    })
  }

  function move(delta) {
    var count = root.activeCount()
    if (count <= 0) return
    pointerGate.reset()
    root.setActiveIndex((root.activeIndex() + delta + count) % count)
  }

  function enterAppPane() {
    if (!root.selectedCategory) return
    root.pane = 1
    root.appFilter = ""
    root.showAllApps = false
    // Start on the app that is already set, so Enter is a no-op rather than a
    // surprise reassignment.
    var index = 0
    for (var i = 0; i < root.appList.length; i++) {
      if (root.appList[i].isCurrent) { index = i; break }
    }
    root.appIndex = index
    pointerGate.reset()
    Qt.callLater(function() { appListView.positionViewAtIndex(root.appIndex, ListView.Contain) })
  }

  function leaveAppPane() {
    root.pane = 0
    root.appFilter = ""
    root.showAllApps = false
    pointerGate.reset()
  }

  function setFilter(next) {
    if (root.pane === 0) {
      root.categoryFilter = next
      // Keep the current group selected while it still matches; only fall to
      // the top row when the filter has excluded it.
      if (!root.selectedCategory && root.selectedKey !== root.addKey) root.selectCategoryRow(0)
    } else {
      root.appFilter = next
      root.appIndex = 0
    }
    pointerGate.reset()
  }

  // ---------------------------------------------------------------- actions

  function activate() {
    if (root.pane === 0) {
      if (!root.selectedCategory) { root.openAddPrompt(); return }
      root.enterAppPane()
      return
    }

    if (root.appIndex >= root.appList.length) {
      // The "show every application" row.
      root.showAllApps = true
      root.appIndex = 0
      return
    }
    root.assign(root.appList[root.appIndex])
  }

  function assign(appRow) {
    if (!appRow || !root.selectedCategory) return
    if (root.busy) return
    root.busy = true
    root.statusMessage = "Setting " + root.selectedCategory.label + " → " + appRow.name + "…"
    applyProc.command = ["python3", root.pluginDir + "/scan.py", "set", appRow.appId]
      .concat(root.selectedCategory.mimes)
    applyProc.pendingLabel = root.selectedCategory.label + " → " + appRow.name
    applyProc.running = true
  }

  function openAddPrompt() {
    root.addError = ""
    root.addInput = ""
    root.addPromptOpen = true
  }

  function closeAddPrompt() {
    root.addPromptOpen = false
    root.addInput = ""
    root.addError = ""
  }

  function submitAddPrompt() {
    var raw = root.addInput.trim()
    if (raw.length === 0) { root.closeAddPrompt(); return }
    root.addError = ""
    resolveProc.command = ["python3", root.pluginDir + "/scan.py", "resolve", raw]
    resolveProc.running = true
  }

  function handleResolved(payload) {
    if (!payload || payload.ok !== true) {
      root.addError = (payload && payload.error) ? String(payload.error) : "Could not resolve that filetype"
      return
    }
    var mime = String(payload.mime)
    var builtin = Model.builtinFor(mime)
    if (builtin) {
      // Two rows writing the same registration would disagree on screen, so
      // send them to the group that already owns it.
      root.addError = mime + " is already covered by “" + builtin.label + "”"
      return
    }
    root.customRows = Model.addCustom(root.customRows, Model.prettyLabel(mime, payload.ext), [mime])
    customFile.setText(Model.serializeCustom(root.customRows))
    root.closeAddPrompt()
    root.pane = 0
    root.categoryFilter = ""
    root.selectedKey = "custom:" + mime
    root.statusMessage = "Added " + mime
    statusTimer.restart()
    Qt.callLater(function() { categoryList.positionViewAtIndex(root.categoryIndex, ListView.Contain) })
  }

  function requestRemoveSelectedCustom() {
    var row = root.selectedCategory
    if (!row || !row.custom) return
    // Held by key rather than by row object: the list regroups on removal, and
    // the confirm has to name the filetype the user was actually looking at.
    root.deleteTarget = { key: row.key, label: row.label }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function closeDeleteConfirm() {
    root.deleteConfirmOpen = false
    root.deleteTarget = null
    deleteConfirm.selectedIndex = 1
  }

  function cancelRemoveCustom() {
    root.closeDeleteConfirm()
    pointerGate.reset()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmRemoveCustom() {
    var target = root.deleteTarget
    root.closeDeleteConfirm()
    if (!target) return
    var wasAt = root.categoryIndex
    root.customRows = Model.removeCustom(root.customRows, target.key)
    customFile.setText(Model.serializeCustom(root.customRows))
    root.statusMessage = "Removed " + target.label
    statusTimer.restart()
    root.selectCategoryRow(Math.min(wasAt, root.categoryRows.length - 1))
    pointerGate.reset()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // ------------------------------------------------------------- subprocess

  Process {
    id: scanProc
    command: ["python3", root.pluginDir + "/scan.py", "scan"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.scan = {
            apps: parsed.apps || ({}),
            defaults: parsed.defaults || ({}),
            handlers: parsed.handlers || ({}),
            parents: parsed.parents || ({})
          }
          root.scanned = true
        } catch (e) {
          console.warn(root.pluginId + ": could not parse scan output:", e)
          root.statusMessage = "Could not read the system MIME database"
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim().length > 0) console.warn(root.pluginId + " scan:", text.trim())
    }
  }

  Process {
    id: applyProc
    property string pendingLabel: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        if (payload && payload.ok === true) {
          root.statusMessage = applyProc.pendingLabel
          root.refresh()
          root.leaveAppPane()
        } else {
          root.statusMessage = payload && payload.error
            ? "Failed: " + payload.error
            : "Failed to set the default application"
        }
        root.busy = false
        statusTimer.restart()
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim().length > 0) console.warn(root.pluginId + " set:", text.trim())
    }
    onExited: function(code) {
      // A crash before any stdout arrives would otherwise leave the panel
      // wedged on "Setting …".
      if (root.busy) {
        root.busy = false
        root.statusMessage = "Failed to set the default application"
        statusTimer.restart()
      }
    }
  }

  Process {
    id: resolveProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        root.handleResolved(payload)
      }
    }
  }

  // scan.py decides whether adding the menu row is wanted and safe; this only
  // runs it and says so when a row went in.
  Process {
    id: menuProc
    command: ["python3", root.pluginDir + "/scan.py", "menu"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        if (payload && payload.status === "added") {
          Quickshell.execDetached(["notify-send", "-a", "Default Applications", "Default Applications",
                                   "Added to the Omarchy menu under Setup → Defaults → Filetypes"])
        } else if (!payload || payload.ok !== true) {
          console.warn(root.pluginId + " menu:", payload && payload.error ? payload.error : text.trim())
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim().length > 0) console.warn(root.pluginId + " menu:", text.trim())
    }
  }

  Timer {
    id: statusTimer
    interval: 3000
    onTriggered: root.statusMessage = ""
  }

  FileView {
    id: customFile
    path: root.customPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.customRows = Model.parseCustom(text())
    onLoadFailed: root.customRows = []
    onFileChanged: reload()
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  // ------------------------------------------------------------------- view

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-default-apps"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        // Above the list rows while the confirm is up, so a stray click lands
        // on the dialog's scrim instead of retargeting the selection under it.
        z: root.deleteConfirmOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.deleteConfirmOpen) {
            if (deleteConfirm.handleKey(event)) event.accepted = true
            return
          }

          if (root.addPromptOpen) {
            if (event.key === Qt.Key_Escape) {
              root.closeAddPrompt()
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.submitAddPrompt()
            } else if (Util.editsFilter(event, root.addInput)) {
              root.addInput = Util.editedFilter(event, root.addInput)
              root.addError = ""
            } else if (event.text && event.text.length === 1
                       && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
              root.addInput += event.text
              root.addError = ""
            }
            event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else if (root.pane === 1) root.leaveAppPane()
            else root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_Tab && root.pane === 1) {
            // Tab out of the app pane too, so the key is a symmetric toggle.
            root.leaveAppPane()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.move(-1); event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.move(1); event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.setActiveIndex(root.activeIndex() - 6); event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.setActiveIndex(root.activeIndex() + 6); event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.setActiveIndex(0); event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.setActiveIndex(root.activeCount() - 1); event.accepted = true
          } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab) {
            if (root.pane === 0 && root.categoryIndex < root.categoryRows.length) root.enterAppPane()
            event.accepted = true
          } else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab) {
            if (root.pane === 1) root.leaveAppPane()
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (root.pane === 0) root.requestRemoveSelectedCustom()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.activate(); event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: deleteConfirm

          anchors.fill: parent
          opened: root.deleteConfirmOpen
          z: 10
          message: "Do you want to remove " + ((root.deleteTarget && root.deleteTarget.label) || "") + "?"
          confirmText: "Remove"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelRemoveCustom()
          onConfirmed: root.confirmRemoveCustom()
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: searchLine
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: statusLine.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || (root.pane === 0 ? "Search filetypes…" : "Search applications…")
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: statusLine
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width * 0.5)
            horizontalAlignment: Text.AlignRight
            text: root.statusMessage
            color: root.selectedText
            opacity: root.statusMessage ? 0.95 : 0
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
          }
        }

        // -------------------------------------------------------------- body
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.footerHeight - root.contentSpacing * 2

          Row {
            anchors.fill: parent
            spacing: 0

            // ---- filetype groups
            Item {
              width: Math.round(parent.width * 0.46)
              height: parent.height
              clip: true

              ListView {
                id: categoryList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: root.categoryRows.length + 1
                clip: true
                spacing: Style.space(2)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: catRow
                  required property int index
                  readonly property bool isAddRow: index >= root.categoryRows.length
                  readonly property var entry: isAddRow ? null : root.categoryRows[index]
                  readonly property bool hasCursor: index === root.categoryIndex
                  readonly property bool active: hasCursor && root.pane === 0

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: active ? root.selectedBackground
                    : (hasCursor ? Util.alpha(root.selectedBackground, 0.5) : "transparent")

                  Text {
                    id: catIcon
                    textFormat: Text.PlainText
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(28)
                    horizontalAlignment: Text.AlignHCenter
                    text: catRow.isAddRow ? "󰐕" : catRow.entry.icon
                    color: catRow.active ? root.selectedText : root.foreground
                    opacity: catRow.isAddRow ? 0.75 : 1
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.iconLarge
                  }

                  Column {
                    anchors.left: catIcon.right
                    anchors.leftMargin: Style.space(10)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: catRow.isAddRow ? "Add a filetype…" : catRow.entry.label
                      color: catRow.active ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      visible: text.length > 0
                      text: catRow.isAddRow
                        ? "Type an extension or MIME type"
                        : catRow.entry.currentLabel
                      color: !catRow.isAddRow
                        && (catRow.entry.currentState === "mixed"
                            || catRow.entry.currentState === "partial")
                        ? root.accent : root.foreground
                      opacity: catRow.isAddRow || catRow.entry.currentState === "unset" ? 0.5 : 0.75
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: function(mouse) {
                      if (!pointerGate.moved(catRow, mouse)) return
                      root.pane = 0
                      root.selectCategoryRow(catRow.index)
                    }
                    onClicked: {
                      root.pane = 0
                      root.selectCategoryRow(catRow.index)
                      root.activate()
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                visible: !root.scanned
                text: "Reading installed applications…"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }

            // ---- applications for the selected group
            Item {
              width: parent.width - Math.round(parent.width * 0.46)
              height: parent.height
              clip: true

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.borderColor, 0.28)
              }

              Column {
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                spacing: Style.space(6)

                Text {
                  id: appPaneHeader
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.selectedCategory
                    ? "Open " + root.selectedCategory.label.toLowerCase() + " with"
                    : (root.selectedKey === root.addKey ? "New filetype" : "")
                  color: root.foreground
                  opacity: 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                ListView {
                  id: appListView
                  width: parent.width
                  height: parent.height - parent.spacing - appPaneHeader.height
                  model: root.appList.length + (root.moreAppsAvailable ? 1 : 0)
                  clip: true
                  spacing: Style.space(2)
                  boundsBehavior: Flickable.StopAtBounds

                  delegate: Rectangle {
                    id: appRow
                    required property int index
                    readonly property bool isMoreRow: index >= root.appList.length
                    readonly property var entry: isMoreRow ? null : root.appList[index]
                    readonly property bool hasCursor: index === root.appIndex && root.pane === 1

                    width: ListView.view.width
                    height: root.rowHeight
                    radius: root.cornerRadius
                    color: hasCursor ? root.selectedBackground : "transparent"

                    Text {
                      id: mark
                      textFormat: Text.PlainText
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(8)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(20)
                      horizontalAlignment: Text.AlignHCenter
                      text: appRow.isMoreRow ? "" : (appRow.entry.isCurrent ? "󰐾" : "󰐽")
                      color: appRow.hasCursor ? root.selectedText : root.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Image {
                      id: appIcon
                      visible: !appRow.isMoreRow
                      width: visible ? Style.font.iconLarge : 0
                      height: Style.font.iconLarge
                      anchors.left: mark.right
                      anchors.leftMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      fillMode: Image.PreserveAspectFit
                      sourceSize.width: width * Screen.devicePixelRatio
                      sourceSize.height: height * Screen.devicePixelRatio
                      asynchronous: true
                      source: !appRow.isMoreRow && root.appLibrary
                        ? root.appLibrary.iconSource(appRow.entry.icon) : ""
                    }

                    Column {
                      anchors.left: appIcon.right
                      anchors.leftMargin: Style.space(10)
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(1)

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        text: appRow.isMoreRow ? "Show every application…" : appRow.entry.name
                        color: appRow.hasCursor ? root.selectedText : root.foreground
                        opacity: appRow.isMoreRow ? 0.75 : 1
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        elide: Text.ElideRight
                      }

                      Text {
                        textFormat: Text.PlainText
                        width: parent.width
                        visible: text.length > 0
                        text: appRow.isMoreRow
                          ? "Apps that do not advertise this filetype"
                          : (appRow.entry.declared ? appRow.entry.subtext
                                                  : appRow.entry.subtext + " · not advertised")
                        color: root.foreground
                        opacity: 0.5
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: function(mouse) {
                        if (!pointerGate.moved(appRow, mouse)) return
                        root.pane = 1
                        root.appIndex = appRow.index
                      }
                      onClicked: {
                        root.pane = 1
                        root.appIndex = appRow.index
                        root.activate()
                      }
                    }
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                visible: root.scanned && root.selectedCategory && root.appList.length === 0
                  && !root.moreAppsAvailable
                text: "No application matches"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }
            }
          }
        }

        // ------------------------------------------------------------ footer
        Text {
          textFormat: Text.PlainText
          width: parent.width
          height: root.footerHeight
          text: root.pane === 0
            ? "↑↓ filetype   → apps   ⏎ choose   del remove added   esc close"
            : "↑↓ app   ⏎ set default   ← back   esc back"
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          verticalAlignment: Text.AlignVCenter
        }
      }

      // ------------------------------------------------------------- add flow
      Rectangle {
        anchors.fill: parent
        visible: root.addPromptOpen
        color: root.scrim
        z: 20

        MouseArea { anchors.fill: parent; onClicked: root.closeAddPrompt() }

        BorderSurface {
          width: Math.min(Style.space(460), parent.width - Style.space(40))
          height: promptColumn.implicitHeight + root.contentMargin * 2
          anchors.centerIn: parent
          radius: root.cornerRadius
          color: root.background
          borderSpec: root.borderSpec
          padding: root.contentMargin

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: promptColumn
            anchors.centerIn: parent
            width: parent.width - root.contentMargin * 2
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Add a filetype"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "An extension like .kra, or a MIME type like application/x-krita."
              color: root.foreground
              opacity: 0.6
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            BorderSurface {
              width: parent.width
              height: Math.max(Style.space(30), Style.font.title + Style.spacing.inputPaddingY * 2)
              radius: root.cornerRadius
              color: Util.alpha(root.foreground, 0.06)
              borderSpec: Border.controlSpec("focus", root.foreground, root.accent)
              padding: Style.spacing.controlPaddingX

              Text {
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: parent.contentLeftInset
                anchors.rightMargin: parent.contentRightInset
                anchors.verticalCenter: parent.verticalCenter
                text: root.addInput || ".kra"
                color: root.foreground
                opacity: root.addInput ? 1 : 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                elide: Text.ElideLeft
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.addError.length > 0
              text: root.addError
              color: Color.urgent
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "⏎ add   esc cancel"
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
