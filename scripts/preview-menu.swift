import AppKit

// Render the actual menu model and its icon images for visual review. This is a
// rendered preview, not a screenshot of an enabled Finder extension.
final class PreviewTarget: NSObject {
    @objc func action(_ item: NSMenuItem) {}
}
let target = PreviewTarget()
let menu = AdvancedActionMenu.make(urls: [URL(fileURLWithPath: "/tmp/Holiday.heic")],
    enabled: Set(ActionDefinition.all.map(\.id)), favorites: ["png", "resize", "upload", "ocr"],
    busy: false, target: target, selector: #selector(PreviewTarget.action(_:)))
let missing = ActionDefinition.all.filter { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) == nil }
guard missing.isEmpty else {
    fputs("Unavailable action symbols: \(missing.map { $0.id + ": " + $0.symbol }.joined(separator: ", "))\n", stderr)
    exit(1)
}
let images = menu.items.first { $0.title == "Images" }!.submenu!
let width = 850, height = 600
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
bitmap.size = NSSize(width: width, height: height)
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    func text(_ text: String, x: CGFloat, top: CGFloat, font: NSFont, color: NSColor = .labelColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: x, y: CGFloat(height) - top - size.height), withAttributes: attributes)
    }
    text("Advanced Right Click", x: 36, top: 25, font: .systemFont(ofSize: 24, weight: .semibold))
    text("Action icons, format badges, and a menu that follows your selection.", x: 36, top: 60, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    func drawMenu(_ menu: NSMenu, x: CGFloat, top: CGFloat, width: CGFloat, highlighted: String?) {
        let totalHeight = menu.items.reduce(CGFloat(12)) { $0 + ($1.isSeparatorItem ? 10 : 27) }
        let rect = NSRect(x: x, y: CGFloat(height) - top - totalHeight, width: width, height: totalHeight)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.12); shadow.shadowBlurRadius = 16; shadow.shadowOffset = NSSize(width: 0, height: -4); shadow.set()
        NSColor.white.setFill(); NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.08).setStroke(); NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).stroke()
        var rowTop = top + 6
        for item in menu.items {
            if item.isSeparatorItem {
                NSColor.black.withAlphaComponent(0.08).setFill()
                NSRect(x: x + 12, y: CGFloat(height) - rowTop - 5, width: width - 24, height: 0.5).fill()
                rowTop += 10; continue
            }
            if item.title == highlighted {
                NSColor.systemIndigo.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: NSRect(x: x + 5, y: CGFloat(height) - rowTop - 27, width: width - 10, height: 27), xRadius: 5, yRadius: 5).fill()
            }
            item.image?.draw(in: NSRect(x: x + 12, y: CGFloat(height) - rowTop - 22, width: 20, height: 18))
            let enabled = item.action != nil || item.submenu != nil
            text(item.title, x: x + 42, top: rowTop + 5, font: .systemFont(ofSize: enabled ? 12 : 11, weight: enabled ? .regular : .medium), color: enabled ? .labelColor : .secondaryLabelColor)
            if item.submenu != nil { text("›", x: x + width - 24, top: rowTop + 1, font: .systemFont(ofSize: 19), color: .tertiaryLabelColor) }
            rowTop += 27
        }
    }
    drawMenu(menu, x: 36, top: 103, width: 320, highlighted: "Images")
    drawMenu(images, x: 368, top: 268, width: 330, highlighted: nil)
    text("Rendered menu preview · native icons and menu content · not a live Finder screenshot", x: 36, top: 567, font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
}
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print("All \(ActionDefinition.all.count) action symbols available; menu preview: \(output.path)")
