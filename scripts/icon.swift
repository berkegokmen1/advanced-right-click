import AppKit
let output = CommandLine.arguments[1]
var chunks = Data()
for (tag, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: scale, y: scale)
    let rect = NSRect(x: 64, y: 64, width: 896, height: 896)
    NSColor(calibratedRed: 0.38, green: 0.28, blue: 0.85, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 210, yRadius: 210).fill()
    NSColor(calibratedWhite: 1, alpha: 0.13).setFill()
    NSBezierPath(roundedRect: NSRect(x: 312, y: 258, width: 480, height: 430), xRadius: 60, yRadius: 60).fill()
    NSColor.white.withAlphaComponent(0.9).setFill()
    for y in [566, 470, 374] { NSBezierPath(roundedRect: NSRect(x: 455, y: y, width: 250, height: 28), xRadius: 14, yRadius: 14).fill() }
    let cursor = NSBezierPath(); cursor.move(to: NSPoint(x: 251, y: 780)); cursor.line(to: NSPoint(x: 251, y: 345)); cursor.line(to: NSPoint(x: 350, y: 438)); cursor.line(to: NSPoint(x: 423, y: 271)); cursor.line(to: NSPoint(x: 489, y: 301)); cursor.line(to: NSPoint(x: 412, y: 464)); cursor.line(to: NSPoint(x: 551, y: 464)); cursor.close(); NSColor.white.setFill(); cursor.fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    chunks.append(Data(tag.utf8)); var length = UInt32(png.count + 8).bigEndian; chunks.append(Data(bytes: &length, count: 4)); chunks.append(png)
}
var icon = Data("icns".utf8); var length = UInt32(chunks.count + 8).bigEndian; icon.append(Data(bytes: &length, count: 4)); icon.append(chunks)
try icon.write(to: URL(fileURLWithPath: output))
