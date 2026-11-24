import SwiftUI
import AppKit
import MydroidCore

struct PhotosView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var gridFocus: Bool

    var body: some View {
        let p = model.photos
        ZStack {
            VStack(spacing: 0) {
                PhotosBar()
                if !p.items.isEmpty { DisconnectedBar() }
                content
            }
            .blur(radius: p.previewID == nil ? 0 : 8)
            .allowsHitTesting(p.previewID == nil)

            if let id = p.previewID, let item = p.item(id) {
                PhotoPreviewOverlay(item: item).transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .background(.background)
        .animation(.spring(duration: 0.35, bounce: 0.1), value: p.previewID)
        .task(id: model.state.link) { p.activate() }
        .onAppear { gridFocus = true }
        .focusable()
        .focused($gridFocus)
        .focusEffectDisabled()
        .onKeyPress(.space) { p.previewOrSelected(); return .handled }
        .onKeyPress(.escape) { if p.previewID != nil { p.closePreview(); return .handled }; return .ignored }
        .onKeyPress(.leftArrow) { if p.previewID != nil { p.stepPreview(-1); return .handled }; return .ignored }
        .onKeyPress(.rightArrow) { if p.previewID != nil { p.stepPreview(1); return .handled }; return .ignored }
        .background(Button("") { p.selectAll() }.keyboardShortcut("a", modifiers: .command).opacity(0).allowsHitTesting(false))
    }

    @ViewBuilder private var content: some View {
        let p = model.photos
        let s = model.state
        let state = p.current
        if !s.settings.photos {
            StateView(icon: "photo.on.rectangle.angled", title: "Photos from your phone",
                      message: "Browse your library and save photos here.",
                      tint: Brand.accent) {
                Button("Turn On Photos") { model.updateSettings { $0.photos = true } }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        } else if s.link == .connected && (s.features.photos == .needsPermission || p.permissionDenied) {
            StateView(icon: "lock.shield", title: "Allow photo access on your phone",
                      message: "One tap on your phone, then your library appears here.",
                      tint: .orange) { AskOnPhoneButton(kind: .photos) }
        } else if state.items.isEmpty {
            if s.link != .connected { DisconnectedState(what: "Your photos") }
            else if state.loading || !state.loaded && state.error == nil {
                StateView(icon: "photo", title: "Loading photos", message: "From your phone\u{2026}", busy: true)
            } else if let err = state.error {
                StateView(icon: "exclamationmark.triangle", title: "Couldn't load photos", message: err, tint: .orange) {
                    Button("Try Again") { p.refresh() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
            } else {
                StateView(icon: "photo.on.rectangle", title: p.album == .all ? "No photos" : "No \(p.album.title.lowercased()) here",
                          message: "Pictures on your phone show up here.")
            }
        } else {
            PhotoGrid()
        }
    }
}

struct PhotosBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var p = model.photos
        let n = p.selection.count
        HStack(spacing: 12) {
            Picker("Album", selection: Binding(get: { p.album }, set: { p.setAlbum($0) })) {
                ForEach(PhotoAlbum.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 250)

            if n > 0 {
                HStack(spacing: 8) {
                    Text("\(n) selected").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                    Button { p.save(p.selectedItems) } label: { Label("Save to Pictures", systemImage: "square.and.arrow.down") }
                        .controlSize(.regular)
                        .disabled(p.saving != nil)
                    Button("Clear") { p.selection = [] }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            if let saving = p.saving {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(saving).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
                Slider(value: $p.thumbSize, in: 84...240).frame(width: 110).controlSize(.small)
                Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .help("Thumbnail size")
            Button { p.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
                .disabled(model.state.link != .connected || p.current.loading)
        }
        .animation(.spring(duration: 0.3), value: n)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .barBackground()
    }
}

struct PhotoGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.photos
        let months = p.months(of: p.items)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: p.thumbSize, maximum: p.thumbSize * 1.6), spacing: 3)], spacing: 3, pinnedViews: [.sectionHeaders]) {
                ForEach(months) { month in
                    Section {
                        ForEach(month.items) { item in PhotoCell(item: item) }
                    } header: {
                        Text(month.title).font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.thinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                    }
                }
            }
            .padding(.horizontal, 3).padding(.bottom, 8)
            if p.current.more {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.padding(16)
            } else {
                Text("\(p.items.count) photos").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(16)
            }
        }
        .background(.background)
        .onTapGesture { p.selection = [] }
    }
}

struct PhotoCell: View {
    @Environment(AppModel.self) private var model
    var item: PhotoItem
    @State private var slot: ThumbSlot?
    @State private var hover = false

    var body: some View {
        let p = model.photos
        let selected = p.selection.contains(item.id.text)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let img = slot?.image {
                        Image(nsImage: img).resizable().scaledToFill().transition(.opacity)
                    } else if slot?.failed == true {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "photo").font(.system(size: 18)).foregroundStyle(.quaternary)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: slot?.image != nil)
            }
            .clipped()
            .overlay { if hover && !selected { Rectangle().fill(.white.opacity(0.08)) } }
            .overlay(alignment: .bottomLeading) {
                if item.isVideo { Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white).padding(6).shadow(radius: 2) }
            }
            .overlay { if selected { Rectangle().strokeBorder(Brand.accent, lineWidth: 3) } }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Brand.accent).padding(5).transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.25, bounce: 0.3), value: selected)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(count: 2) { p.openPreview(item) }
            .onTapGesture {
                let f = NSEvent.modifierFlags
                p.click(item, command: f.contains(.command), shift: f.contains(.shift))
            }
            .onDrag { p.dragProvider(for: item) }
            .contextMenu {
                Button("Open") { p.openPreview(item) }
                Divider()
                Button("Save to Pictures") { p.save(selected && p.selection.count > 1 ? p.selectedItems : [item]) }
                Button("Copy") { p.copy(item) }
            }
            .onAppear {
                slot = p.slot(for: item)
                p.loadMoreIfNeeded(after: item)
            }
            .onDisappear { p.unwant(item); slot = nil }
            .accessibilityLabel("\(item.name), \(item.taken.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Preview

struct PhotoPreviewOverlay: View {
    @Environment(AppModel.self) private var model
    var item: PhotoItem
    @State private var full: NSImage?
    @State private var shareAnchor: NSView?

    var body: some View {
        let p = model.photos
        let dl = p.downloads[item.id.text]
        let idx = p.items.firstIndex { $0.id == item.id }
        ZStack {
            Rectangle().fill(.black.opacity(0.8)).background(.ultraThinMaterial).ignoresSafeArea()
                .onTapGesture { p.closePreview() }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { p.closePreview() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28) }
                        .buttonStyle(.plain).background(.white.opacity(0.14), in: Circle()).foregroundStyle(.white)
                        .help("Close (Esc)")
                    Spacer()
                    VStack(spacing: 1) {
                        Text(item.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(item.taken.formatted(date: .long, time: .shortened)).font(.system(size: 11.5)).opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 28, height: 28)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                ZStack {
                    if let img = full ?? p.cachedThumb(item.id.text) {
                        Image(nsImage: img).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(color: .black.opacity(0.4), radius: 20, y: 6)
                            .onDrag { p.dragProvider(for: item) }
                            .opacity(full == nil ? 0.85 : 1)
                            .animation(.easeOut(duration: 0.25), value: full != nil)
                    }
                    if full == nil {
                        switch dl {
                        case .failed(let why):
                            VStack(spacing: 8) {
                                Text("Couldn't download the original").font(.system(size: 13, weight: .semibold))
                                Text(why).font(.system(size: 12)).opacity(0.8)
                                Button("Try Again") { p.downloads[item.id.text] = nil; p.ensureDownload(item) }.controlSize(.regular)
                            }
                            .foregroundStyle(.white).padding(16).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                        case .downloading(let f):
                            ProgressRing(fraction: f).frame(width: 44, height: 44)
                        default: ProgressView().controlSize(.regular).colorScheme(.dark)
                        }
                    }
                }
                .padding(.horizontal, 64)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) { stepButton("chevron.left", enabled: (idx ?? 0) > 0) { p.stepPreview(-1) } }
                .overlay(alignment: .trailing) { stepButton("chevron.right", enabled: idx.map { $0 + 1 < p.items.count } ?? false) { p.stepPreview(1) } }

                HStack(spacing: 10) {
                    Button { p.save([item]) } label: { Label("Save to Pictures", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.borderedProminent).controlSize(.regular)
                    Button { p.copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }.controlSize(.regular)
                    Button { share() } label: { Label("Share", systemImage: "square.and.arrow.up") }.controlSize(.regular)
                        .background(ShareAnchor(view: $shareAnchor))
                    Spacer()
                    Text(details).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
        .task(id: item.id) {
            full = nil
            p.ensureDownload(item)
            if let url = try? await p.download(item) {
                full = await Task.detached { decodeImage(url: url, maxPixel: 2600) }.value
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if item.width > 0 { parts.append("\(item.width)\u{00D7}\(item.height)") }
        if item.size > 0 { parts.append(ByteSize.text(item.size)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).frame(width: 34, height: 34)
                .background(.white.opacity(0.14), in: Circle()).foregroundStyle(.white)
        }
        .buttonStyle(.plain).opacity(enabled ? 1 : 0).disabled(!enabled).padding(.horizontal, 14)
    }

    private func share() {
        let p = model.photos
        Task {
            guard let url = try? await p.download(item), let anchor = shareAnchor else { return }
            NSSharingServicePicker(items: [url]).show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
        }
    }
}

struct ProgressRing: View {
    var fraction: Double
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.04, fraction)).stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            Text("\(Int(fraction * 100))").font(.system(size: 11, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
        }
        .animation(.easeOut(duration: 0.2), value: fraction)
    }
}

/// Gives SwiftUI a handle on a view so `NSSharingServicePicker` has something to anchor to.
struct ShareAnchor: NSViewRepresentable {
    @Binding var view: NSView?
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
