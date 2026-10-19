import AppKit
import FinderSync

@objc(AdvancedFinderSync)
final class AdvancedFinderSync: FIFinderSync {
    private let requests = MenuRequestRouter()
    override init() {
        super.init()
        // Finder controls observation; no recursive directory scans or badges.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        let urls = FinderSelection.urls(selected: selected, targeted: controller.targetedURL(), background: menuKind == .contextualMenuForContainer)
        guard !urls.isEmpty, urls.count <= 500 else { return nil }
        let menu = NSMenu()
        let parent = NSMenuItem(title: "Advanced Right Click", action: nil, keyEquivalent: "")
        parent.image = ActionIcon.symbol("cursorarrow.click.2", color: .systemIndigo, description: "Advanced Right Click")
        let preferences = MenuPreferences.read()
        parent.submenu = AdvancedActionMenu.make(urls: urls, enabled: preferences.enabled,
            favorites: preferences.favorites, busy: preferences.busy, target: self, selector: #selector(run(_:)))
        menu.addItem(parent)
        requests.register(menu)
        return menu
    }
    @objc func run(_ sender: NSMenuItem) {
        guard let request = requests.request(for: sender), let url = request.url else { return }
        // Open the containing application explicitly, including when another build is registered.
        let host = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let config = NSWorkspace.OpenConfiguration(); config.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: host, configuration: config) { _, error in
            if let error { NSLog("Advanced Right Click could not open its host: %@", error.localizedDescription) }
        }
    }
}
