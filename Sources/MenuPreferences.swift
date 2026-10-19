import Foundation
import Darwin

/// notifyd state bridges small preference masks to the sandboxed Finder extension.
/// The host remains running; defaults are used if notification access is unavailable.
enum MenuPreferences {
    private static let prefix = "com.berkegokmen.advancedrightclick.menu."
    private static let initialized: UInt64 = 1 << 63
    private static func token(_ name: String) -> Int32? {
        var token: Int32 = 0
        guard notify_register_check(prefix + name, &token) == NOTIFY_STATUS_OK else { return nil }
        return token
    }
    // Keep registrations alive so state survives between individual menu requests.
    private static let enabledToken = token("enabled")
    private static let favoriteToken = token("favorites")
    private static let busyToken = token("busy")
    static func publish(enabled: Set<String>, favorites: Set<String>, busy: Bool) {
        for (token, values) in [(enabledToken, enabled), (favoriteToken, favorites)] {
            guard let token else { continue }
            var mask = initialized
            for (index, action) in ActionDefinition.all.enumerated() where values.contains(action.id) { mask |= 1 << index }
            _ = notify_set_state(token, mask)
        }
        if let token = busyToken { _ = notify_set_state(token, busy ? 1 : 0) }
    }
    static func read() -> (enabled: Set<String>, favorites: Set<String>, busy: Bool) {
        func read(_ token: Int32?, fallback: Set<String>) -> Set<String> {
            guard let token else { return fallback }
            var state: UInt64 = 0
            guard notify_get_state(token, &state) == NOTIFY_STATUS_OK, state & initialized != 0 else { return fallback }
            return Set(ActionDefinition.all.enumerated().filter { state & (1 << $0.offset) != 0 }.map { $0.element.id })
        }
        var busy: UInt64 = 0
        if let token = busyToken { _ = notify_get_state(token, &busy) }
        return (read(enabledToken, fallback: Set(ActionDefinition.all.map(\.id))), read(favoriteToken, fallback: ["png", "resize", "ocr", "rename"]), busy == 1)
    }
}
