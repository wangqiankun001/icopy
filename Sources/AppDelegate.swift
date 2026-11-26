import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var store: ClipboardStore!
    private var watcher: ClipboardWatcher!
    private var panelController: HistoryPanelController!

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var appObserver: NSObjectProtocol?
    private var lastExternalApp: NSRunningApplication?

    private let hotKeySignature: OSType = 0x49434F50 // ICOP

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ClipboardStore()
        watcher = ClipboardWatcher(store: store)
        watcher.start()

        panelController = HistoryPanelController(store: store)
        panelController.onChoose = { [weak self] item in
            self?.handleSelection(item)
        }
        panelController.onCancel = { [weak self] in
            self?.restoreFocus()
        }

        lastExternalApp = externalFrontmostApp()
        observeFrontmostApp()
        setupStatusItem()
        setupMainMenu()
        registerHotKey()

        let snapshotPath = CommandLine.arguments
            .first(where: { $0.hasPrefix("--snapshot=") })?
            .replacingOccurrences(of: "--snapshot=", with: "")

        if CommandLine.arguments.contains("--show") || snapshotPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showHistory()
            }
        }

        if let snapshotPath {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.panelController.snapshot(to: URL(fileURLWithPath: snapshotPath))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
        }
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
        }
        store?.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showHistory()
        return true
    }

    // MARK: - Panel

    private func showHistory() {
        guard !panelController.isVisible else { return }
        if let app = externalFrontmostApp() {
            lastExternalApp = app
        }
        NSApp.activate(ignoringOtherApps: true)
        panelController.show()
    }

    private func toggleHistory() {
        if panelController.isVisible {
            panelController.hide()
            restoreFocus()
        } else {
            showHistory()
        }
    }

    private func handleSelection(_ item: ClipItem) {
        let target = lastExternalApp
        guard ClipboardWriter.write(item, store: store) else {
            Toast.show("复制失败 · 内容可能已失效")
            return
        }
        watcher.markOwnWrite()
        panelController.hide()
        store.touch(item.id)

        guard autoPasteEnabled else {
            restoreFocus()
            Toast.show("已复制 · 按 ⌘V 粘贴")
            return
        }

        guard AXIsProcessTrusted() else {
            restoreFocus()
            if !UserDefaults.standard.bool(forKey: "didExplainAccessibility") {
                UserDefaults.standard.set(true, forKey: "didExplainAccessibility")
                Toast.show("已复制 · 开启辅助功能后可自动粘贴")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.explainAccessibility()
                }
            } else {
                Toast.show("已复制 · 按 ⌘V 粘贴")
            }
            return
        }

        guard let target, !target.isTerminated,
              target.bundleIdentifier != Bundle.main.bundleIdentifier else {
            Toast.show("已复制到剪贴板 · 按 ⌘V 粘贴")
            return
        }

        activateAndPaste(target: target, attemptsLeft: 3)
    }

    private func activateAndPaste(target: NSRunningApplication, attemptsLeft: Int) {
        target.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                Self.postCommandV()
            } else if attemptsLeft > 1 {
                self.activateAndPaste(target: target, attemptsLeft: attemptsLeft - 1)
            } else {
                Toast.show("已复制 · 按 ⌘V 粘贴")
            }
        }
    }

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let key: CGKeyCode = 0x09 // V
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }
    }

    private func restoreFocus() {
        guard let app = lastExternalApp, !app.isTerminated else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    private func externalFrontmostApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        return app
    }

    // MARK: - Clipboard permission

    private var autoPasteEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "autoPaste") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "autoPaste")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "autoPaste")
        }
    }

    private func explainAccessibility() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "让 icopy 自动粘贴"
        alert.informativeText = """
        选中历史记录后，icopy 会自动把内容粘贴到刚才使用的应用。
        自动粘贴需要「辅助功能」权限。

        内容已经复制到剪贴板，也可以直接按 ⌘V 粘贴。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    private func openAccessibilitySettings() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "icopy")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "icopy · 剪贴板历史（⌘⇧V）"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
            return
        }
        toggleHistory()
    }

    private func showStatusMenu() {
        let menu = makeStatusMenu()
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = NSMenuItem(
            title: "打开剪贴板历史（⌘⇧V）",
            action: #selector(openHistoryFromMenu),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let autoPaste = NSMenuItem(
            title: "选中后自动粘贴",
            action: #selector(toggleAutoPaste),
            keyEquivalent: ""
        )
        autoPaste.target = self
        autoPaste.state = autoPasteEnabled ? .on : .off
        menu.addItem(autoPaste)

        let launchAtLogin = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        launchAtLogin.state = launchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLogin)

        let permission = NSMenuItem(
            title: "辅助功能权限设置…",
            action: #selector(accessibilitySettingsFromMenu),
            keyEquivalent: ""
        )
        permission.target = self
        menu.addItem(permission)

        menu.addItem(.separator())

        let clear = NSMenuItem(
            title: "清空未固定的记录…",
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = store.items.contains { !$0.pinned }
        menu.addItem(clear)

        let folder = NSMenuItem(
            title: "在 Finder 中显示数据文件夹",
            action: #selector(revealDataFolder),
            keyEquivalent: ""
        )
        folder.target = self
        menu.addItem(folder)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 icopy", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出 icopy", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openHistoryFromMenu() {
        showHistory()
    }

    @objc private func toggleAutoPaste() {
        autoPasteEnabled.toggle()
    }

    @objc private func accessibilitySettingsFromMenu() {
        openAccessibilitySettings()
    }

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "无法修改登录项"
            alert.informativeText = error.localizedDescription + "\n\n请把 icopy.app 放到「应用程序」文件夹后再试。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "清空未固定的记录？"
        alert.informativeText = "固定项会保留，此操作不可撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearUnpinned()
        }
    }

    @objc private func revealDataFolder() {
        NSWorkspace.shared.open(store.dataFolderURL)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "icopy",
            .applicationVersion: "1.0",
            .version: "1.0",
            .credits: NSAttributedString(string: "轻巧的剪贴板历史工具\n快捷键 ⌘⇧V")
        ])
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Global hotkey

    private func registerHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                delegate.hotKeyPressed()
                return noErr
            },
            1,
            &eventType,
            userData,
            &hotKeyHandler
        )
        if handlerStatus != noErr {
            NSLog("icopy: failed to install hotkey handler (\(handlerStatus))")
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = hotKeySignature
        hotKeyID.id = 1

        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("icopy: failed to register ⌘⇧V (\(status))")
        }
    }

    private func hotKeyPressed() {
        DispatchQueue.main.async { [weak self] in
            self?.toggleHistory()
        }
    }

    // MARK: - Workspace notifications

    private func observeFrontmostApp() {
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self.lastExternalApp = app
        }
    }

    // MARK: - Menus

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(title: "icopy", action: nil, keyEquivalent: "")
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "icopy")
        let aboutItem = appMenu.addItem(withTitle: "关于 icopy", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: "隐藏 icopy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(.separator())
        let quitItem = appMenu.addItem(withTitle: "退出 icopy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}
