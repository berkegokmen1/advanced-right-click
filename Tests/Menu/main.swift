import AppKit

final class Target: NSObject { @objc func action(_ item: NSMenuItem) {} }
let target = Target()
let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("menu-fixtures-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
func file(_ name: String) throws -> URL { let url = directory.appendingPathComponent(name); try Data([1, 2, 3]).write(to: url); return url }
let png = try file("one.png"), jpg = try file("two.jpg"), pdf = try file("three.pdf"), otherPDF = try file("four.pdf"), text = try file("five.txt"), binary = try file("six.bin")
let folder = directory.appendingPathComponent("folder.jpg", isDirectory: true), folder2 = directory.appendingPathComponent("folder2", isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)
func ids(_ urls: [URL]) -> Set<String> { Set(ActionDefinition.all.filter { $0.accepts(urls) }.map(\.id)) }
var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) { guard condition() else { fputs("FAIL \(message)\n", stderr); exit(1) }; passed += 1 }
let single = ids([png])
check(!single.contains("png"), "No conversion to an already matching format")
check(single.contains("jpeg"), "PNG offers JPEG conversion")
check(!single.contains("contact") && !single.contains("zipEach") && !single.contains("compare"), "Single selection hides actions requiring multiple items")
check(!single.contains("contents"), "Images do not offer UTF-8 contents")
check(!ids([pdf]).contains("pdf"), "A single PDF does not offer merge with itself")
check(ids([pdf, otherPDF]).contains("pdf") && ids([pdf, otherPDF]).contains("compare"), "Two PDFs offer merge and compare")
check(ids([png, jpg]).contains("contact") && ids([png, jpg]).contains("zipEach"), "Two images offer contact sheet and individual ZIPs")
check(ids([pdf, png]).contains("pdf") && ids([pdf, png]).contains("ocr"), "Mixed document selection supports merge and text extraction")
check(!ids([png, text]).contains("pdf") && !ids([png, text]).contains("resize"), "Mixed unsupported types hide conversion actions")
check(ids([text]).contains("contents") && !ids([binary]).contains("contents"), "Only text files offer copy contents")
check(ids([folder]).contains("newfile") && ids([folder]).contains("terminal"), "One folder offers folder actions")
check(!ids([folder]).contains("jpeg"), "A folder with an image extension is never an image")
check(!ids([folder, folder2]).contains("terminal") && !ids([folder, folder2]).contains("compare"), "Two folders hide single-folder and file comparison actions")
check(ActionDefinition.find("rename")!.title(for: [png]) == "Rename…", "Single-file rename label")
check(ActionDefinition.find("rename")!.title(for: [png, jpg]) == "Rename 2 items…", "Batch rename count")
check(ActionDefinition.find("png")!.title(for: [png, jpg]) == "Convert 1 image to PNG", "Only files needing conversion are counted")
check(ActionDefinition.find("pdf")!.title(for: [png]) == "Create PDF", "Single image creates a PDF")
check(ActionDefinition.find("pdf")!.title(for: [pdf, png]) == "Combine 2 items into PDF", "Mixed merge count")
check(FinderSelection.urls(selected: [png], targeted: folder, background: true) == [folder], "Folder background ignores stale file selection")
check(FinderSelection.urls(selected: [png, jpg], targeted: png, background: false) == [png, jpg], "Item menu preserves full multiselection")
check(ids([]).isEmpty, "Empty selection has no file actions")
let enabled = Set(ActionDefinition.all.map(\.id))
func menu(_ urls: [URL]) -> NSMenu { AdvancedActionMenu.make(urls: urls, enabled: enabled, favorites: ["png", "rename"], busy: false, target: target, selector: #selector(Target.action(_:))) }
func actionable(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { item -> [NSMenuItem] in (item.action != nil && item.submenu == nil ? [item] : []) + (item.submenu.map(actionable) ?? []) } }
let router = MenuRequestRouter(), first = menu([png]), second = menu([png, jpg])
router.register(first); router.register(second)
for original in actionable(first) + actionable(second) {
    let copied = NSMenuItem(title: original.title, action: original.action, keyEquivalent: "")
    copied.tag = original.tag // Finder preserves tag but discards representedObject and target.
    check(copied.representedObject == nil, "Lossy Finder copy has no represented object")
    let request = router.request(for: copied)
    check(request != nil, "Copied menu action is routable")
    check(request?.urls == (original.representedObject as? ActionRequest)?.urls, "Copied menu keeps the original selection snapshot")
    check(request?.action == (original.representedObject as? ActionRequest)?.action, "Copied menu keeps its action")
}
let busy = AdvancedActionMenu.make(urls: [png], enabled: enabled, favorites: [], busy: true, target: target, selector: #selector(Target.action(_:)))
check(!actionable(busy).contains { ($0.representedObject as? ActionRequest)?.action == "jpeg" }, "Busy menu hides new file actions")
check(actionable(busy).contains { ($0.representedObject as? ActionRequest)?.action == "cancel" }, "Busy menu offers cancellation")
// Visual range edits must stay exportable, including short media and GIF limits.
let gifRange = PreviewRange(duration: 60, maximumLength: 15)
check(gifRange.end(40, start: 5) == 20, "GIF handle cannot select more than 15 seconds")
check(gifRange.start(0, end: 30) == 15, "GIF start handle maintains maximum length")
check(gifRange.end(2, start: 5) > 5, "End cannot cross start")
check(gifRange.start(20, end: 10) < 10, "Start cannot cross end")
let shortRange = PreviewRange(duration: 0.02, maximumLength: 15)
check(shortRange.end(15, start: 0) == 0.02, "Sub-frame media range stays within duration")
check(PreviewRange.seconds("01:02.50") == 62.5, "Editable minutes/seconds round trip")
check(PreviewRange.seconds("01:00:61") == nil && PreviewRange.seconds("NaN") == nil && PreviewRange.seconds("-1") == nil, "Invalid timecodes rejected")
check(PreviewRange.timestamp(62.5) == "01:02.50", "Timestamp display is precise")
print("\(passed) menu and Finder-handoff checks passed")
