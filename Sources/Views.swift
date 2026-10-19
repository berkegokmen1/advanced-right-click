import SwiftUI
import AppKit

private let accent = Color(red: 0.40, green: 0.32, blue: 0.88)

struct RootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "cursorarrow.click.2").font(.system(size: 25)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 3) { Text("Advanced").font(.system(size: 15, weight: .bold)); Text("Right Click").font(.system(size: 13)).foregroundStyle(.secondary) }
                }.padding(.vertical, 24).padding(.bottom, 20)
                ForEach([("General", "gearshape"), ("Menu", "line.3.horizontal"), ("History", "clock.arrow.circlepath")], id: \.0) { name, symbol in
                    Button { model.page = name } label: {
                        HStack(spacing: 10) { Image(systemName: symbol).frame(width: 20); Text(name); Spacer(); if name == "History", model.history.contains(where: \.requiresRecovery) { Circle().fill(.orange).frame(width: 6, height: 6) } }.font(.system(size: 13, weight: model.page == name ? .semibold : .regular)).padding(12).background(model.page == name ? accent.opacity(0.1) : .clear).foregroundStyle(model.page == name ? accent : .primary.opacity(0.7)).cornerRadius(9)
                    }.buttonStyle(.plain)
                }
                Spacer()
                Label("Quietly, on your Mac", systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 22)
            }.padding(.horizontal, 18).frame(width: 165).background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            Divider()
            VStack(spacing: 0) {
                HStack { Text(model.page).font(.system(size: 13, weight: .semibold)); Spacer(); Text("SETTINGS").font(.system(size: 9, weight: .medium)).tracking(1.5).foregroundStyle(.tertiary) }.padding(.horizontal, 28).frame(height: 54)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch model.page { case "Menu": menuSettings; case "History": history; default: general }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.mini); Text(model.status).font(.caption); Button("Cancel") { model.control?.cancel() } }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary); Text("Ready in your right-click menu").font(.system(size: 11)).foregroundStyle(.secondary) }
                    Spacer()
                    if let record = model.latest { Button(record.requiresRecovery ? "Recover action" : "Undo last action") { model.undo(record) }.disabled(model.busy).controlSize(.small) }
                }.padding(.horizontal, 28).frame(height: 42)
            }
        }.tint(accent).frame(minWidth: 790, minHeight: 600)
        .alert("Advanced Right Click", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    var general: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) { Text("More right click.\nLess everything else.").font(.system(size: 28, weight: .semibold)).tracking(-0.6); Text("No workspace to manage. Just your files, with more possibilities.").font(.system(size: 12)).foregroundStyle(.secondary) }
            block("FINDER MENU", symbol: "cursorarrow.click.2") {
                Text("Enable Advanced Right Click in System Settings → General → Login Items & Extensions → Finder. Then right-click a file or folder.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Button("Open extension settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!) }
                Text("If Finder hasn’t discovered the extension yet, install the app in Applications and open it once. A Services fallback is also included.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            block("BACKGROUND BEHAVIOR", symbol: "moon") {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                Toggle("Show menu bar icon", isOn: Binding(get: { model.showMenuBar }, set: { model.setMenuBar($0) }))
                Toggle("Show a brief message when an action finishes", isOn: Binding(get: { model.showCompletion }, set: { model.setCompletion($0) }))
                Text("No Dock icon. Closing Settings leaves the Finder menu running. Open Settings again from the right-click menu.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }
            block("UNDO", symbol: "arrow.uturn.backward") {
                Toggle("Allow immediate ⌘Z in Finder", isOn: Binding(get: { model.finderUndo }, set: { model.setFinderUndo($0) }))
                Text("Requires Accessibility permission. For 30 seconds after an action, ⌘Z can restore it while Finder stays active. Another click, key, scroll or app switch ends this shortcut. It is separate from Finder’s native undo history.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                if model.finderUndo {
                    HStack { Image(systemName: model.finderUndoAvailable ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(model.finderUndoAvailable ? .green : .orange); Text(model.finderUndoAvailable ? "Shortcut available" : "Permission or event access is needed").font(.caption); Spacer(); Button("Retry") { model.setFinderUndo(true) } }
                }
                Text("Undo is always available in the Advanced Right Click menu and History.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            block("RECOVERY & PRIVACY", symbol: "lock.shield") {
                Text("Files are processed locally. Originals are backed up before replacement and kept until you restore the action and remove its history record. Later edits are checked before undo.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Button("Show recovery storage") { NSWorkspace.shared.open(model.historyRoot) }
            }
            HStack { Text("Advanced Right Click 0.1.4").font(.system(size: 11)).foregroundStyle(.tertiary); Spacer(); Button("Quit Advanced Right Click") { NSApp.terminate(nil) }.buttonStyle(.link).font(.system(size: 11)).disabled(model.busy) }
        }
    }
    var menuSettings: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) { Text("Your menu. Your way.").font(.system(size: 28, weight: .semibold)).tracking(-0.6); Text("Choose what appears. Star up to four favorites to put them first.").font(.system(size: 12)).foregroundStyle(.secondary) }
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Find an action", text: $model.search).textFieldStyle(.plain) }.padding(10).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(8)
            ForEach(ActionDefinition.categories, id: \.self) { category in
                let actions = ActionDefinition.all.filter { $0.category == category && (model.search.isEmpty || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(model.search)) }
                if !actions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 7) { Image(nsImage: ActionIcon.category(category)); Text(category.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.2) }.foregroundStyle(Color(nsColor: ActionIcon.style(for: category).color)).padding(.bottom, 12)
                        ForEach(actions) { action in
                            HStack(spacing: 12) {
                                Image(nsImage: ActionIcon.action(action)).resizable().scaledToFit().frame(width: 24, height: 22).frame(width: 28)
                                Toggle(isOn: Binding(get: { model.enabledActions.contains(action.id) }, set: { model.setEnabled(action, $0) })) { VStack(alignment: .leading, spacing: 4) { Text(action.title).font(.system(size: 12, weight: .medium)); Text(action.subtitle).font(.system(size: 10)).foregroundStyle(.secondary) } }.toggleStyle(.checkbox)
                                Spacer()
                                Button { model.toggleFavorite(action) } label: { Image(systemName: model.favorites.contains(action.id) ? "star.fill" : "star").foregroundStyle(model.favorites.contains(action.id) ? accent : .secondary.opacity(0.4)) }.buttonStyle(.plain).help("Put this action at the top of the Finder menu")
                            }.padding(.vertical, 11)
                            if action.id != actions.last?.id { Divider().opacity(0.4) }
                        }
                    }.padding(18).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
                }
            }
        }
    }
    var history: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) { Text("A way back.").font(.system(size: 28, weight: .semibold)).tracking(-0.6); Text("Restore originals, even after reopening the app.").font(.system(size: 12)).foregroundStyle(.secondary) }
            if model.history.isEmpty { VStack(spacing: 12) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(accent); Text("Your file changes will appear here").font(.system(size: 13)); Text("Try an action from Finder’s right-click menu.").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 80) }
            ForEach(model.history) { record in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) { Image(systemName: record.requiresRecovery ? "exclamationmark.circle" : record.state == .undone ? "arrow.uturn.backward.circle" : "checkmark.circle").font(.title2).foregroundStyle(record.requiresRecovery ? .orange : accent); VStack(alignment: .leading, spacing: 4) { Text(record.title).font(.system(size: 13, weight: .semibold)); Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(stateLabel(record)).font(.system(size: 10)).foregroundStyle(.secondary) }
                    ForEach(Array(record.mutations.prefix(3).enumerated()), id: \.offset) { _, mutation in Text(URL(fileURLWithPath: mutation.destination).lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                    if record.mutations.count > 3 { Text("+\(record.mutations.count - 3) more items").font(.caption).foregroundStyle(.tertiary) }
                    if let detail = record.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    HStack { Button("Show recovery files") { NSWorkspace.shared.open(model.historyRoot.appendingPathComponent(record.id.uuidString)) }.buttonStyle(.link).font(.caption); Spacer(); if record.state == .complete || record.requiresRecovery { Button(record.requiresRecovery ? "Restore interrupted action" : "Undo action") { model.undo(record) }.disabled(model.busy) } else { Button("Remove record") { model.forget(record) }.disabled(model.busy) } }
                }.padding(18).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
            }
        }
    }
    func stateLabel(_ record: HistoryRecord) -> String { switch record.state { case .complete: return "Saved"; case .undone: return "Restored"; case .failed: return "No changes"; case .preparing: return "Preparation stopped"; case .applying, .undoing: return "Needs recovery" } }
    func block<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Label(title, systemImage: symbol).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(accent); content() }.font(.system(size: 12)).padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(12)
    }
}

struct ActionPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct OptionsView: View {
    @ObservedObject var model: AppModel
    let action: ActionDefinition
    @State private var previewReady = false
    private var usesPreview: Bool { ["trim", "gif", "extract", "pdf", "split", "pdfrotate", "pdfcompress", "searchable"].contains(action.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch action.id {
            case "resize":
                field("Maximum edge (px)", value: $model.options.dimension)
            case "compress":
                field("Maximum size (MB)", value: $model.options.targetMB)
                Text("Saves as JPEG; transparency becomes white.").font(.caption).foregroundStyle(.secondary)
            case "rename":
                HStack { TextField("Find", text: $model.options.search); TextField("Replace", text: $model.options.replacement) }
                TextField("Prefix", text: $model.options.prefix)
                HStack { Toggle("Number files", isOn: $model.options.numberFiles); Toggle("Lowercase", isOn: $model.options.lowercase) }.font(.system(size: 11))
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(model.selection.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(4).enumerated()), id: \.offset) { index, url in
                        Text((try? model.options.renamed(url, index: index)) ?? "Invalid filename").font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color(nsColor: .controlBackgroundColor)).cornerRadius(7)
            case "extract", "pdf", "split", "pdfrotate", "pdfcompress", "searchable":
                PDFOptionsPreview(urls: model.selection, action: action.id, options: $model.options, ready: $previewReady)
            case "trim", "gif":
                MediaOptionsPreview(urls: model.selection, gif: action.id == "gif", options: $model.options, ready: $previewReady)
            case "newfile", "pastefile":
                TextField("Filename", text: $model.options.filename)
                if action.id == "newfile" { Picker("Template", selection: $model.options.template) { Text("Markdown").tag("Markdown"); Text("Plain text").tag("Plain text"); Text("Checklist").tag("Checklist") } }
                else { Text("Clipboard images save as PNG.").font(.caption).foregroundStyle(.secondary) }
            default: EmptyView()
            }
            HStack {
                Spacer()
                Button("Cancel") { model.optionsAction = nil; model.dismissOptions?() }.keyboardShortcut(.cancelAction)
                Button("Apply") { model.optionsAction = nil; model.dismissOptions?(); model.execute(action, configured: true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(usesPreview && !previewReady)
            }.padding(.top, 4)
        }.textFieldStyle(.roundedBorder).padding(18).frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in Color.clear.preference(key: ActionPanelHeightKey.self, value: geometry.size.height) })
    }
    func field<T: BinaryInteger>(_ title: String, value: Binding<T>) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, value: value, formatter: NumberFormatter()) } }
    func field(_ title: String, value: Binding<Double>) -> some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title, value: value, format: .number) } }
}

struct CompareView: View {
    let urls: [URL]
    let done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) { ForEach(urls, id: \.path) { url in
                VStack(alignment: .leading, spacing: 10) {
                    Text(url.lastPathComponent).font(.headline).lineLimit(1)
                    Text(properties(url)).font(.caption).foregroundStyle(.secondary)
                    if ActionDefinition.imageExtensions.contains(url.pathExtension.lowercased()), let image = NSImage(contentsOf: url) { Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 240) }
                    else if let text = smallText(url) { ScrollView([.horizontal, .vertical]) { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 240).padding(12).background(Color(nsColor: .textBackgroundColor)).cornerRadius(8) }
                    else { Text("No inline text preview").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 180) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } }
            HStack { Spacer(); Button("Done", action: done).keyboardShortcut(.defaultAction) }
        }.padding(16).frame(width: 680, height: 380)
    }
    func properties(_ url: URL) -> String { let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]); return ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file) + " · " + (values?.contentModificationDate?.formatted(date: .abbreviated, time: .shortened) ?? "") }
    func smallText(_ url: URL) -> String? { guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 < 2_097_152 else { return nil }; return try? String(contentsOf: url, encoding: .utf8) }
}
