import AppKit

/// One icon vocabulary for Finder, the Services fallback and configuration.
/// Non-template images retain their category colors in native menus.
enum ActionIcon {
    struct CategoryStyle {
        let symbol: String
        let color: NSColor
    }
    static func style(for category: String) -> CategoryStyle {
        switch category {
        case "Images": return .init(symbol: "photo.on.rectangle.angled", color: .systemTeal)
        case "Documents": return .init(symbol: "doc.richtext", color: .systemRed)
        case "Media": return .init(symbol: "play.rectangle", color: .systemPurple)
        case "Organize": return .init(symbol: "tray.2", color: .systemOrange)
        case "Copy & share": return .init(symbol: "square.on.square", color: .systemBlue)
        case "Folders": return .init(symbol: "folder", color: .systemGreen)
        default: return .init(symbol: "cursorarrow.click.2", color: .systemIndigo)
        }
    }
    static func symbol(_ name: String, color: NSColor = .secondaryLabelColor, description: String? = nil) -> NSImage {
        let base = NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: description)!
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base.withSymbolConfiguration(configuration) ?? base
        image.size = NSSize(width: 20, height: 18)
        image.isTemplate = false
        return image
    }
    static func category(_ category: String) -> NSImage {
        let style = style(for: category)
        return symbol(style.symbol, color: style.color, description: category)
    }
    static func action(_ action: ActionDefinition) -> NSImage {
        let badges: [String: (String, NSColor)] = [
            "png": ("PNG", .systemTeal), "jpeg": ("JPG", .systemBlue),
            "heic": ("HEIC", .systemIndigo), "mp4": ("MP4", .systemPurple),
            "audio": ("M4A", .systemPink), "gif": ("GIF", .systemPink),
            "markdown": ("MD", .systemBlue)
        ]
        if let (label, color) = badges[action.id] { return badge(label, color: color, description: action.title) }
        return symbol(action.symbol, color: style(for: action.category).color, description: action.title)
    }
    static func badge(_ label: String, color: NSColor, description: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            let background = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 1), xRadius: 3, yRadius: 3)
            color.withAlphaComponent(0.12).setFill(); background.fill()
            color.withAlphaComponent(0.75).setStroke(); background.lineWidth = 0.8; background.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: label.count > 3 ? 6 : 7, weight: .heavy),
                .foregroundColor: color
            ]
            let size = (label as NSString).size(withAttributes: attributes)
            (label as NSString).draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false; image.accessibilityDescription = description
        return image
    }
    static func utility(_ id: String) -> NSImage {
        switch id {
        case "undo": return symbol("arrow.uturn.backward", color: .systemOrange, description: "Undo")
        case "history": return symbol("clock.arrow.circlepath", color: .systemIndigo, description: "History")
        case "cancel": return symbol("xmark.circle", color: .systemRed, description: "Cancel")
        default: return symbol("gearshape", color: .secondaryLabelColor, description: "Settings")
        }
    }
}

/// Native menu rows keep keyboard navigation, VoiceOver, hover and submenus.
/// The exact same menu is used by Finder Sync and the Services entry point.
enum AdvancedActionMenu {
    static func make(urls: [URL], enabled: Set<String>, favorites: Set<String>, busy: Bool,
                     target: AnyObject, selector: Selector) -> NSMenu {
        let menu = NSMenu(title: "Advanced Right Click")
        let selection = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items selected"
        heading(String(selection.prefix(60)), in: menu)
        menu.addItem(.separator())
        let selectionContext = SelectionContext(urls)
        let applicable = busy ? [] : ActionDefinition.all.filter { enabled.contains($0.id) && $0.accepts(selectionContext) }
        let quick = applicable.filter { favorites.contains($0.id) }.prefix(4)
        if !quick.isEmpty {
            heading("Quick actions", in: menu)
            for action in quick { menu.addItem(item(action, urls: urls, target: target, selector: selector)) }
            menu.addItem(.separator())
        }
        for category in ActionDefinition.categories {
            let actions = applicable.filter { $0.category == category }
            guard !actions.isEmpty else { continue }
            let group = NSMenuItem(title: category, action: nil, keyEquivalent: "")
            group.image = ActionIcon.category(category)
            group.toolTip = "\(actions.count) available actions"
            let submenu = NSMenu(title: category)
            for action in actions { submenu.addItem(item(action, urls: urls, target: target, selector: selector)) }
            group.submenu = submenu; menu.addItem(group)
        }
        if applicable.isEmpty { heading(busy ? "An action is running…" : "No enabled actions for this selection", in: menu) }
        menu.addItem(.separator())
        if busy { utility("Cancel running action", id: "cancel", in: menu, target: target, selector: selector) }
        utility("Undo last action", id: "undo", in: menu, target: target, selector: selector)
        utility("History…", id: "history", in: menu, target: target, selector: selector)
        utility("Settings…", id: "settings", in: menu, target: target, selector: selector)
        return menu
    }
    private static func heading(_ title: String, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }
    private static func item(_ action: ActionDefinition, urls: [URL], target: AnyObject, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: action.title(for: urls), action: selector, keyEquivalent: "")
        item.target = target; item.representedObject = ActionRequest(action: action.id, urls: urls)
        item.image = ActionIcon.action(action); item.toolTip = action.subtitle
        return item
    }
    private static func utility(_ title: String, id: String, in menu: NSMenu, target: AnyObject, selector: Selector) {
        let item = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        item.target = target; item.representedObject = ActionRequest(action: id, urls: [])
        item.image = ActionIcon.utility(id)
    }
}

/// Finder copies menu items across a process boundary and drops representedObject.
/// Keep each menu's selection snapshot in the extension and send only an integer tag.
final class MenuRequestRouter {
    private var nextTag = 1
    private var requests: [Int: ActionRequest] = [:]
    func register(_ menu: NSMenu) {
        for item in menu.items {
            if let request = item.representedObject as? ActionRequest {
                if nextTag == Int.max { requests.removeAll(); nextTag = 1 }
                item.tag = nextTag; requests[nextTag] = request; nextTag += 1
            }
            if let submenu = item.submenu { register(submenu) }
        }
        // Preserve recent menus from other Finder windows without unbounded growth.
        if requests.count > 4096 {
            let threshold = nextTag - 2048
            requests = requests.filter { $0.key >= threshold }
        }
    }
    func request(for item: NSMenuItem) -> ActionRequest? { requests[item.tag] }
}
