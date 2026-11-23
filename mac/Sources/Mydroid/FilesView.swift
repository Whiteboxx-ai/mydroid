import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MydroidCore

struct FilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var f = model.files
        let rows = f.entries
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $f.filter) {
                    ForEach(FilesModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 270)
                Spacer()
                Button { model.chooseFilesToSend() } label: { Label("Send File\u{2026}", systemImage: "paperplane") }
                    .disabled(model.state.link != .connected)
            }
            .padding(.horizontal, 14).padding(.vertical, 8).barBackground()
            if !rows.isEmpty { DisconnectedBar() }

            if rows.isEmpty {
                empty
            } else {
                List {
                    ForEach(rows) { e in
                        FileRow(entry: e)
                            .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                    }
                }
                .listStyle(.inset)
            }
        }
        .background(.background)
        .overlay { if f.dropTargeted { DropZone() } }
        .onDrop(of: [.fileURL], isTargeted: $f.dropTargeted) { providers in
            guard model.isPaired else { return false }
            let group = DispatchGroup()
            var urls: [URL] = []
            let lock = NSLock()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { f.send(urls) }
            return true
        }
        .task { f.activate() }
        .animation(.easeOut(duration: 0.2), value: rows.map(\.id))
    }

    @ViewBuilder private var empty: some View {
        let f = model.files
        switch f.filter {
        case .photos:
            StateView(icon: "photo.on.rectangle", title: "No photos yet", message: "New photos are saved to \(model.photosFolderLabel).")
        case .sent:
            StateView(icon: "paperplane", title: "Nothing sent yet", message: "Drag files here to send them.") {
                Button("Send File\u{2026}") { model.chooseFilesToSend() }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.state.link != .connected)
            }
        default:
            StateView(icon: "tray.and.arrow.down", title: "No transfers yet",
                      message: "Drag a file here to send it.") {
                Button("Send File\u{2026}") { model.chooseFilesToSend() }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.state.link != .connected)
            }
        }
    }
}

struct DropZone: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill").font(.system(size: 34)).foregroundStyle(Color.accentColor)
                Text("Drop to send to \(model.phoneName)").font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(12).transition(.opacity).allowsHitTesting(false)
    }
}

struct FileRow: View {
    @Environment(AppModel.self) private var model
    var entry: FileEntry
    @State private var thumb: NSImage?
    @State private var hover = false

    var body: some View {
        let exists = entry.exists
        HStack(spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                icon.frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Image(systemName: entry.direction == .received ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                    .symbolRenderingMode(.palette).foregroundStyle(.white, entry.direction == .received ? Color.green : Color.accentColor)
                    .font(.system(size: 15)).offset(x: 4, y: 4)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                switch entry.phase {
                case let .active(f):
                    HStack(spacing: 8) {
                        ProgressView(value: f).progressViewStyle(.linear).frame(maxWidth: 220)
                        Text("\(Int(f * 100))%").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                case let .failed(why):
                    Text("Couldn't send").font(.system(size: 11.5)).foregroundStyle(.red).lineLimit(1)
                case .done:
                    Text(subtitle(exists)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if case .done = entry.phase, exists {
                HStack(spacing: 4) {
                    Button { if let u = entry.url { NSWorkspace.shared.open(u) } } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Open")
                    Button { if let u = entry.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } } label: { Image(systemName: "magnifyingglass") }
                        .help("Reveal in Finder")
                }
                .buttonStyle(.borderless).font(.system(size: 14)).opacity(hover ? 1 : 0)
            }
            if case .failed = entry.phase, let u = entry.url, exists {
                Button("Send Again") { model.files.send([u]) }.controlSize(.small).disabled(model.state.link != .connected)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .opacity(exists || entry.phase != .done ? 1 : 0.6)
        .onDrag { entry.url.flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider() }
        .onTapGesture(count: 2) { if let u = entry.url, exists { NSWorkspace.shared.open(u) } }
        .contextMenu {
            if let u = entry.url, exists {
                Button("Open") { NSWorkspace.shared.open(u) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([u as NSURL]) }
                if entry.direction == .received { Button("Send Back to Phone") { model.files.send([u]) }.disabled(model.state.link != .connected) }
                else { Button("Send Again") { model.files.send([u]) }.disabled(model.state.link != .connected) }
            }
        }
        .task(id: entry.url) {
            guard entry.isPhoto, let u = entry.url else { thumb = nil; return }
            thumb = await Task.detached { decodeImage(url: u, maxPixel: 120) }.value
        }
    }

    @ViewBuilder private var icon: some View {
        if let thumb {
            Image(nsImage: thumb).resizable().scaledToFill()
        } else if let u = entry.url, entry.exists {
            Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().scaledToFit().padding(2)
        } else {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: entry.isPhoto ? "photo" : "doc").foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(_ exists: Bool) -> String {
        var parts: [String] = [entry.direction == .received ? (entry.isPhoto ? "Photo from \(model.phoneName)" : "From \(model.phoneName)") : "Sent to \(model.phoneName)"]
        let s = ByteSize.text(entry.size)
        if !s.isEmpty { parts.append(s) }
        parts.append(Fmt.relative(entry.date, style: .wide))
        if !exists { parts.append("No longer on this Mac") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
