import AppKit
import SwiftUI
import ServiceManagement

final class AppModel: ObservableObject {
    @Published var selection: [URL] = []
    @Published var page = "General"
    @Published var search = ""
    @Published var busy = false
    @Published var progress = 0.0
    @Published var status = "Ready when you are"
    @Published var history: [HistoryRecord] = []
    @Published var error: String?
    @Published var optionsAction: ActionDefinition?
    @Published var options = ActionOptions()
    @Published var favorites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? ["png", "resize", "upload", "ocr", "rename", "pdf"])
    @Published var finderUndo = UserDefaults.standard.bool(forKey: "finderUndo")
    @Published var finderUndoAvailable = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var showMenuBar = UserDefaults.standard.bool(forKey: "showMenuBar")
    @Published var showCompletion = UserDefaults.standard.object(forKey: "showCompletion") as? Bool ?? true
    @Published var enabledActions: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "enabledActions") ?? ActionDefinition.all.map(\.id))
    let undoBridge = FinderUndoBridge()
    var engine: ActionEngine?
    var control: OperationControl?
    var onChange: (() -> Void)?
    var showWindow: (() -> Void)?
    var showToast: ((String) -> Void)?
    var presentOptions: ((ActionDefinition) -> Void)?
    var dismissOptions: (() -> Void)?
    var presentReport: ((String) -> Void)?
    var presentComparison: (([URL]) -> Void)?
    var presentError: ((String) -> Void)?
    let work = DispatchQueue(label: "com.berkegokmen.advancedrightclick.operations", qos: .userInitiated)
    var historyRoot: URL {
        if let override = ProcessInfo.processInfo.environment["ARC_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Advanced Right Click/History")
    }
    func start() {
        do { engine = ActionEngine(store: try HistoryStore(root: historyRoot)); refreshHistory() }
        catch { self.error = error.localizedDescription }
        if finderUndo { finderUndoAvailable = undoBridge.enable(prompt: false) }
        publishMenu()
    }
    var latest: HistoryRecord? { history.first { $0.state == .complete || $0.requiresRecovery } }
    func refreshHistory() {
        guard let engine else { return }
        do { history = try engine.store.records() } catch { self.error = error.localizedDescription }
        onChange?()
    }
    func toggleFavorite(_ action: ActionDefinition) {
        if favorites.contains(action.id) { favorites.remove(action.id) } else { favorites.insert(action.id) }
        UserDefaults.standard.set(Array(favorites), forKey: "favorites")
        publishMenu()
    }
    func receive(_ request: ActionRequest) {
        if request.action == "cancel" { control?.cancel(); return }
        if ["show", "settings", "history"].contains(request.action) { page = request.action == "history" ? "History" : "General"; showWindow?(); return }
        guard !busy else { presentError?("An action is already running. Cancel it from the right-click menu or wait for it to finish."); return }
        if request.action == "undo" { if latest != nil { undo() } else { showToast?("No Advanced Right Click actions to undo.") }; return }
        guard optionsAction == nil else { presentError?("Finish or close the current action options before choosing another action."); return }
        selection = request.urls
        guard let action = ActionDefinition.find(request.action) else { return }
        execute(action)
    }
    func execute(_ action: ActionDefinition, configured: Bool = false) {
        guard !busy else { return }
        guard let engine else { presentError?(error ?? "Recovery storage is unavailable. Open Settings to review it before trying again."); return }
        guard action.accepts(selection) else { presentError?("This action does not support the selected items."); return }
        if action.needsOptions && !configured {
            options = ActionOptions()
            if action.id == "rename" { options.prefix = "" }
            if action.id == "pastefile" { options.filename = "Clipboard.txt" }
            optionsAction = action; presentOptions?(action); return
        }
        if history.contains(where: \.requiresRecovery) { error = "Restore the interrupted operation in History before making more changes."; page = "History"; showWindow?(); return }
        let urls = selection; let settings = options; let token = OperationControl(); control = token
        undoBridge.disarm(); busy = true; status = action.title(for: urls).replacingOccurrences(of: "…", with: "") + "…"; progress = 0; onChange?()
        if showCompletion { showToast?(status) }
        work.async { [weak self] in
            do {
                let result = try engine.perform(action, urls: urls, options: settings, control: token) { message, fraction in
                    DispatchQueue.main.async { self?.status = message; self?.progress = fraction }
                }
                DispatchQueue.main.async { self?.finished(action, result: result) }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }; self.busy = false; self.control = nil
                    self.status = error is CancellationError ? "Cancelled · changes restored" : "Action stopped"
                    if !(error is CancellationError) { self.presentError?(error.localizedDescription) }
                    self.refreshHistory()
                }
            }
        }
    }
    func finished(_ action: ActionDefinition, result: ActionResult) {
        busy = false; control = nil; progress = 1
        if let text = result.text {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            status = "Copied to clipboard"
        } else if let report = result.report { presentReport?(report); status = "Scan complete" }
        else if action.id == "compare" { presentComparison?(result.outputs); status = "Ready to compare" }
        else if action.id == "terminal", let folder = result.outputs.first {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            status = "Opened Terminal"
        } else {
            status = "\(action.title.replacingOccurrences(of: "…", with: "")) · done"
            // Keep the user's selection aligned with files that may have changed extensions.
            if !result.outputs.isEmpty { selection = result.outputs }
        }
        refreshHistory()
        if let record = result.record {
            if finderUndo && finderUndoAvailable {
                undoBridge.arm { [weak self] in self?.undo(record) }
            }
            if showCompletion { showToast?("\(record.title) · Done") }
        } else if result.text != nil && showCompletion { showToast?(status) }
    }
    func undo(_ record: HistoryRecord? = nil) {
        guard !busy, let engine, let record = record ?? latest else { return }
        undoBridge.disarm(); busy = true; status = "Restoring originals…"; onChange?()
        work.async { [weak self] in
            do {
                _ = try engine.store.undo(record)
                DispatchQueue.main.async { self?.busy = false; self?.status = "Originals restored"; self?.selection = record.mutations.compactMap(\.source).map { URL(fileURLWithPath: $0) }; self?.refreshHistory(); self?.showToast?("Originals restored") }
            } catch {
                DispatchQueue.main.async { self?.busy = false; self?.presentError?(error.localizedDescription); self?.refreshHistory() }
            }
        }
    }
    func forget(_ record: HistoryRecord) {
        guard !busy, let engine else { return }
        do { try engine.store.forget(record); refreshHistory() } catch { self.error = error.localizedDescription }
    }
    func setFinderUndo(_ enabled: Bool) {
        finderUndo = enabled; UserDefaults.standard.set(enabled, forKey: "finderUndo")
        if enabled { finderUndoAvailable = undoBridge.enable(prompt: true) }
        else { undoBridge.disable(); finderUndoAvailable = false }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = SMAppService.mainApp.status == .enabled }
        catch { self.error = error.localizedDescription }
    }
    func publishMenu() { MenuPreferences.publish(enabled: enabledActions, favorites: favorites, busy: busy) }
    func setEnabled(_ action: ActionDefinition, _ enabled: Bool) {
        if enabled { enabledActions.insert(action.id) } else { enabledActions.remove(action.id) }
        UserDefaults.standard.set(Array(enabledActions), forKey: "enabledActions"); publishMenu()
    }
    func setMenuBar(_ enabled: Bool) { showMenuBar = enabled; UserDefaults.standard.set(enabled, forKey: "showMenuBar"); onChange?() }
    func setCompletion(_ enabled: Bool) { showCompletion = enabled; UserDefaults.standard.set(enabled, forKey: "showCompletion") }
}
