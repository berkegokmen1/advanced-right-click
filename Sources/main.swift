import AppKit
import SwiftUI

final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    var statusItem: NSStatusItem?
    var window: NSWindow?
    var actionPanel: NSPanel?
    var previousApplication: NSRunningApplication?
    var toast: NSPanel?
    var toastTimer: Timer?
    var pending: [ActionRequest] = []
    var launched = false
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NSApp.servicesProvider = self
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.showWindow = { [weak self] in self?.showSettings() }
        model.showToast = { [weak self] text in self?.showToast(text) }
        model.presentOptions = { [weak self] action in self?.presentOptions(action) }
        model.dismissOptions = { [weak self] in self?.dismissActionPanel() }
        model.presentReport = { [weak self] text in self?.presentReport(text) }
        model.presentComparison = { [weak self] urls in self?.presentComparison(urls) }
        model.presentError = { [weak self] text in self?.presentError(text) }
        model.onChange = { [weak self] in self?.refreshMenu() }
        model.start(); buildMainMenu(); refreshMenu(); launched = true
        NSUpdateDynamicServices()
        if !pending.isEmpty { let requests = pending; pending = []; for request in requests { model.receive(request) } }
        else if !UserDefaults.standard.bool(forKey: "hasSeenConfiguration"), ProcessInfo.processInfo.environment["ARC_BACKGROUND"] != "1" {
            showSettings(); UserDefaults.standard.set(true, forKey: "hasSeenConfiguration")
        }
        if model.history.contains(where: \.requiresRecovery) { model.page = "History"; showSettings() }
        if model.error != nil { showSettings() }
    }
    func buildMainMenu() {
        let root = NSMenu(), appMenu = NSMenu(), edit = NSMenu()
        let app = root.addItem(withTitle: "Advanced Right Click", action: nil, keyEquivalent: ""); app.submenu = appMenu
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit Advanced Right Click", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = root.addItem(withTitle: "Edit", action: nil, keyEquivalent: ""); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: #selector(ActionWindow.undo(_:)), keyEquivalent: "z")
        edit.addItem(.separator())
        for (name, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: name, action: Selector(selector), keyEquivalent: key) }
        NSApp.mainMenu = root
    }
    func refreshMenu() {
        model.publishMenu()
        guard model.showMenuBar else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: "Advanced Right Click")
            statusItem?.button?.toolTip = "Advanced Right Click"
        }
        let menu = NSMenu()
        let title = menu.addItem(withTitle: "Advanced Right Click", action: nil, keyEquivalent: ""); title.isEnabled = false
        if model.busy {
            menu.addItem(withTitle: "Working…", action: nil, keyEquivalent: "")
            let cancel = menu.addItem(withTitle: "Cancel action", action: #selector(cancelAction), keyEquivalent: ""); cancel.target = self; cancel.image = ActionIcon.utility("cancel")
        }
        if let record = model.latest {
            let undo = menu.addItem(withTitle: record.requiresRecovery ? "Recover interrupted action…" : "Undo \(record.title)", action: #selector(undoAction), keyEquivalent: ""); undo.target = self; undo.image = ActionIcon.utility("undo"); undo.isEnabled = !model.busy
        }
        for (title, selector) in [("History…", #selector(openHistory)), ("Settings…", #selector(openSettings)), ("Quit", #selector(quit))] {
            let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: ""); item.target = self; item.image = selector == #selector(quit) ? ActionIcon.symbol("power") : ActionIcon.utility(selector == #selector(openHistory) ? "history" : "settings"); item.isEnabled = selector == #selector(quit) ? !model.busy : true
        }
        statusItem?.menu = menu
    }
    @objc func openHistory() { model.page = "History"; showSettings() }
    @objc func openSettings() { model.page = "General"; showSettings() }
    @objc func undoAction() { model.undo() }
    @objc func cancelAction() { model.control?.cancel() }
    @objc func quit() { NSApp.terminate(nil) }
    func showSettings() {
        if window == nil {
            let w = ActionWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.model = model; w.title = "Advanced Right Click Settings"; w.titlebarAppearsTransparent = true
            w.contentView = NSHostingView(rootView: RootView(model: model)); w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("AdvancedRightClickSettings"); w.minSize = NSSize(width: 790, height: 630); w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func panel<V: View>(_ title: String, size: NSSize, content: V) {
        actionPanel?.close()
        previousApplication = NSWorkspace.shared.frontmostApplication
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = title; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.contentView = NSHostingView(rootView: content); panel.center(); panel.makeKeyAndOrderFront(nil)
        actionPanel = panel; NSApp.activate(ignoringOtherApps: true)
    }
    func presentOptions(_ action: ActionDefinition) {
        let content = OptionsView(model: model, action: action).onPreferenceChange(ActionPanelHeightKey.self) { [weak self] height in
            DispatchQueue.main.async {
                guard let self, self.model.optionsAction?.id == action.id, height > 0 else { return }
                self.actionPanel?.setContentSize(NSSize(width: 380, height: ceil(height)))
            }
        }
        panel(action.title(for: model.selection), size: NSSize(width: 380, height: 170), content: content)
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSPanel, closing === actionPanel { model.optionsAction = nil; actionPanel = nil }
    }
    func dismissActionPanel() {
        actionPanel?.close(); actionPanel = nil
        if previousApplication?.bundleIdentifier == "com.apple.finder" { previousApplication?.activate(options: []) }
        previousApplication = nil
    }
    func presentReport(_ text: String) {
        panel("Folder report", size: NSSize(width: 620, height: 360), content:
            VStack(alignment: .leading, spacing: 12) {
                ScrollView { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }.background(Color(nsColor: .textBackgroundColor)).cornerRadius(10)
                HStack { Spacer(); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }; Button("Done") { [weak self] in self?.dismissActionPanel() }.keyboardShortcut(.defaultAction) }
            }.padding(16).frame(width: 620, height: 360))
    }
    func presentComparison(_ urls: [URL]) {
        panel("Compare files", size: NSSize(width: 680, height: 380), content: CompareView(urls: urls) { [weak self] in self?.dismissActionPanel() })
    }
    func presentError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "Advanced Right Click"; alert.informativeText = message; alert.runModal()
    }
    func showToast(_ message: String) {
        toastTimer?.invalidate(); toast?.close()
        guard let screen = NSScreen.main else { return }
        let panel = NSPanel(contentRect: NSRect(x: screen.visibleFrame.maxX - 340, y: screen.visibleFrame.maxY - 72, width: 320, height: 52), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: HStack(spacing: 12) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green); Text(message).font(.system(size: 11)).lineLimit(2); Spacer(minLength: 0) }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial).cornerRadius(13))
        panel.orderFrontRegardless(); toast = panel
        toastTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in self?.toast?.close(); self?.toast = nil }
    }
    @objc func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: string), let request = ActionRequest(url: url) else { return }
        if launched { model.receive(request) } else { pending.append(request) }
    }
    @objc func advancedRightClick(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard !model.busy else { error.pointee = "An action is already running."; return }
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] { urls = paths.map { URL(fileURLWithPath: $0) } }
        guard !urls.isEmpty else { error.pointee = "Choose files in Finder first."; return }
        let menu = AdvancedActionMenu.make(urls: urls, enabled: model.enabledActions,
            favorites: model.favorites, busy: model.busy, target: self, selector: #selector(serviceAction(_:)))
        // Return to Finder before tracking the popup, so a synchronous Services
        // request cannot block waiting for the user to choose a menu item.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
    @objc func serviceAction(_ sender: NSMenuItem) { if let request = sender.representedObject as? ActionRequest { model.receive(request) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        presentError("Wait for the current action to finish, or cancel it, before quitting."); return .terminateCancel
    }
}

final class ActionWindow: NSWindow {
    weak var model: AppModel?
    @objc func undo(_ sender: Any?) { model?.undo() }
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return model?.latest != nil && model?.busy == false }
        return super.validateUserInterfaceItem(item)
    }
}

let app = NSApplication.shared
let delegate = ApplicationDelegate()
app.delegate = delegate
app.run()
