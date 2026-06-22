import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let maxAttachments = 10

private enum ChatRow: Identifiable {
    case day(Date)
    case message(ChatMessage)
    var id: String {
        switch self {
        case .day(let d): return "day-\(Int(d.timeIntervalSince1970))"
        case .message(let m): return m.id
        }
    }
}

struct ChatView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let peerID: String

    @State private var draft = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var mediaContext: MediaViewerContext?
    @State private var fileShareURL: URL?
    @State private var showGroupInfo = false

    // Message actions
    @State private var replyingTo: ChatMessage?
    @State private var editing: ChatMessage?
    @State private var selectionMode = false
    @State private var selected: Set<String> = []
    @State private var forwarding: [ChatMessage]?

    // Voice / video note recording
    enum RecState { case idle, active, locked }
    @StateObject private var audioRecorder = AudioRecorder()
    @StateObject private var videoRecorder = VideoNoteRecorder()
    @State private var recState: RecState = .idle
    @State private var dragTranslation: CGSize = .zero
    @State private var pressStart: Date?
    @State private var holdWork: DispatchWorkItem?
    @State private var videoPickerItem: PhotosPickerItem?
    @State private var showVideoPicker = false

    private var messages: [ChatMessage] { app.chatStore.messages(for: peerID) }
    private var isGroup: Bool { app.chatStore.isGroup(peerID) }
    private var rows: [ChatRow] { Self.buildRows(messages) }
    private var selectedMessages: [ChatMessage] { messages.filter { selected.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { row in
                            switch row {
                            case .day(let d): DayHeader(date: d)
                            case .message(let m): messageRow(m).id(m.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if selectionMode { selectionBar } else { inputArea }
        }
        .overlay(alignment: .bottomTrailing) {
            if recState == .active {
                LockHint(willLock: willLock)
                    .offset(x: -22, y: -68 + max(dragTranslation.height, -36))
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: recState)
        .simultaneousGesture(backSwipe)
        .navigationTitle(app.chatStore.nickname(for: peerID))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.chatStore.clearUnread(peerID: peerID) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: maxAttachments, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items; photoItems = []
            Task { await sendPickedMedia(picked) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await sendPickedFiles(urls) } }
        }
        .photosPicker(isPresented: $showVideoPicker, selection: $videoPickerItem, matching: .videos)
        .onChange(of: videoPickerItem) { _, item in
            guard let item else { return }
            videoPickerItem = nil
            Task { await sendPickedVideoNote(item) }
        }
        .fullScreenCover(item: $mediaContext) { MediaViewer(context: $0) }
        .sheet(item: $fileShareURL) { url in ShareSheet(items: [url]) }
        .sheet(isPresented: $showGroupInfo) { GroupInfoView(groupID: peerID, onLeave: { dismiss() }) }
        .sheet(isPresented: Binding(get: { forwarding != nil }, set: { if !$0 { forwarding = nil } })) {
            ForwardPickerView { target in
                let msgs = forwarding ?? []
                Task { await app.forwardMessages(msgs, to: target) }
                exitSelection()
            }
        }
        .toolbar { toolbarContent }
    }

    // MARK: - Rows

    private func messageRow(_ m: ChatMessage) -> some View {
        HStack(spacing: 8) {
            if selectionMode {
                Image(systemName: selected.contains(m.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected.contains(m.id) ? Color.accentColor : .secondary)
            }
            SwipeToReply(enabled: !selectionMode && !m.deleted, onReply: { startReply(m) }) {
                bubble(m)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if selectionMode { toggle(m) } }
    }

    /// Left-edge swipe to the right pops back to the chat list (a more generous
    /// version of the default back gesture). Only checked on release so it never
    /// interferes with scrolling or the per-message reply swipe.
    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { g in
                if g.startLocation.x < 40, g.translation.width > 90, abs(g.translation.height) < 60 {
                    dismiss()
                }
            }
    }

    @ViewBuilder private func bubble(_ m: ChatMessage) -> some View {
        let view = MessageBubble(message: m, showSender: isGroup, menuEnabled: !selectionMode,
                                 onRetry: { Task { await app.resend(message: m) } },
                                 onOpenMedia: { openMedia($0) },
                                 onOpenFile: { att in Task { fileShareURL = await app.attachmentFileURL(att) } },
                                 menu: { menu(for: m) })
        if selectionMode { view.allowsHitTesting(false) } else { view }
    }

    @ViewBuilder private func menu(for m: ChatMessage) -> some View {
        if !m.deleted {
            Button { startReply(m) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            if m.isMine && m.attachments.isEmpty {
                Button { startEdit(m) } label: { Label("Edit", systemImage: "pencil") }
            }
            Button { forwarding = [m] } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
            Button { selectionMode = true; selected = [m.id] } label: { Label("Select", systemImage: "checkmark.circle") }
        }
        Button(role: .destructive) { Task { await app.deleteMessages([m]) } } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: - Toolbar / bars

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if selectionMode {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { exitSelection() } }
            ToolbarItem(placement: .principal) { Text("\(selected.count) selected").font(.headline) }
        } else if isGroup {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showGroupInfo = true } label: { Image(systemName: "info.circle") }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 40) {
            Button { forwarding = selectedMessages } label: {
                Label("Forward", systemImage: "arrowshape.turn.up.right")
            }
            Button(role: .destructive) {
                Task { await app.deleteMessages(selectedMessages); exitSelection() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .disabled(selected.isEmpty)
        .padding()
    }

    private var inputArea: some View {
        VStack(spacing: 6) {
            if let editing { banner(icon: "pencil", title: "Editing message", subtitle: editing.text) { cancelEdit() } }
            if let replyingTo { banner(icon: "arrowshape.turn.up.left", title: "Reply to \(replyingTo.senderName ?? (replyingTo.isMine ? "yourself" : app.chatStore.nickname(for: peerID)))", subtitle: replyingTo.previewText) { self.replyingTo = nil } }
            inputBar
        }
    }

    private func banner(icon: String, title: String, subtitle: String, onClose: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.bold())
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
        }
        .padding(.horizontal).padding(.top, 6)
    }

    private var showSendButton: Bool {
        editing != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            // Leading: attachments when idle, trash when a recording is locked.
            if recState == .idle, editing == nil {
                Menu {
                    Button { showPhotoPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                    Button { showFileImporter = true } label: { Label("File", systemImage: "doc") }
                } label: {
                    Image(systemName: "paperclip").font(.title3).foregroundStyle(.secondary)
                }
            } else if recState == .locked {
                Button { cancelRecording() } label: {
                    Image(systemName: "trash").font(.title3).foregroundStyle(.red)
                }
            }

            // Center: the text field, or the recording indicator (inline).
            if recState == .idle {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            } else {
                recordingIndicator
            }

            // Trailing: send when there's text / locked recording, else the
            // press-and-hold recorder button (stays mounted so its gesture lives).
            if recState == .locked || showSendButton {
                Button { recState == .locked ? finishRecording() : commit() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
            } else {
                recorderButton
            }
        }
        .padding([.horizontal, .bottom])
        .padding(.top, 4)
        .animation(.easeInOut(duration: 0.18), value: recState)
    }

    private var recordingIndicator: some View {
        HStack(spacing: 10) {
            PulsingDot()
            Text(timeString(app.recorderMode == .voice ? audioRecorder.elapsed : videoRecorder.elapsed))
                .font(.callout.monospacedDigit())
            if app.recorderMode == .voice {
                LiveLevel(level: audioRecorder.level).frame(height: 22)
            } else if VideoNoteRecorder.isAvailable {
                CameraPreview(session: videoRecorder.session).frame(width: 30, height: 30).clipShape(Circle())
            }
            Spacer(minLength: 0)
            if recState == .active {
                Text(willCancel ? "release to cancel" : (willLock ? "release to lock" : "‹ slide to cancel"))
                    .font(.footnote).foregroundStyle(willCancel ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
    }

    // Tap toggles voice/video mode; press-and-hold records.
    private var recorderButton: some View {
        ZStack {
            Circle().fill(Color.accentColor).frame(width: 40, height: 40)
            Image(systemName: app.recorderMode == .voice ? "mic.fill" : "video.fill")
                .foregroundStyle(.white)
        }
        .scaleEffect(recState == .active ? 1.5 : 1)
        .offset(recorderButtonOffset)
        .animation(.interactiveSpring(response: 0.25), value: dragTranslation)
        .animation(.spring(response: 0.3), value: recState)
        .gesture(pressGesture)
    }

    /// While recording, the button follows the finger (clamped) toward the lock
    /// above and the cancel zone to the left.
    private var recorderButtonOffset: CGSize {
        guard recState == .active else { return .zero }
        return CGSize(width: max(-140, min(0, dragTranslation.width)),
                      height: max(-80, min(0, dragTranslation.height)))
    }

    /// One gesture handles everything: a quick tap toggles the mode, a hold
    /// (>0.3s) starts recording, and the release decides send / lock / cancel.
    private var pressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if pressStart == nil {
                    pressStart = Date()
                    let work = DispatchWorkItem {
                        if pressStart != nil, recState == .idle { beginRecording() }
                    }
                    holdWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                }
                if recState == .active { dragTranslation = v.translation }
            }
            .onEnded { v in
                holdWork?.cancel(); holdWork = nil
                let held = Date().timeIntervalSince(pressStart ?? Date())
                pressStart = nil
                if recState == .active {
                    if v.translation.height < -80 { recState = .locked }
                    else if v.translation.width < -100 { cancelRecording() }
                    else { finishRecording() }
                } else if held < 0.3 {
                    app.toggleRecorderMode()
                }
                dragTranslation = .zero
            }
    }

    private var willCancel: Bool { recState == .active && dragTranslation.width < -100 }
    private var willLock: Bool { recState == .active && dragTranslation.height < -80 }

    // MARK: - Recording handlers

    private func beginRecording() {
        switch app.recorderMode {
        case .voice:
            recState = .active
            Task {
                guard await AudioRecorder.requestPermission() else { recState = .idle; return }
                do { try audioRecorder.start() } catch { recState = .idle }
            }
        case .video:
            guard VideoNoteRecorder.isAvailable else { showVideoPicker = true; return }
            recState = .active
            Task {
                guard await VideoNoteRecorder.requestPermission() else { recState = .idle; return }
                videoRecorder.configure(); videoRecorder.startSession(); videoRecorder.startRecording()
            }
        }
    }

    private func finishRecording() {
        let mode = app.recorderMode
        recState = .idle
        switch mode {
        case .voice:
            guard let res = audioRecorder.stop(), res.durationMs > 600 else { return } // ignore < 0.6s
            let pm = AppState.PendingMedia(data: res.data, mime: "audio/m4a", name: "voice.m4a",
                                           durationMs: res.durationMs, waveform: res.waveform)
            Task { await app.sendAttachments([pm], to: peerID) }
        case .video:
            Task {
                let url = await videoRecorder.stopRecording()
                videoRecorder.stopSession()
                guard let url, let data = try? Data(contentsOf: url) else { return }
                let ms = Int(CMTimeGetSeconds(AVURLAsset(url: url).duration) * 1000)
                try? FileManager.default.removeItem(at: url)
                let pm = AppState.PendingMedia(data: data, mime: "video/mp4", name: "note.mp4",
                                               durationMs: ms, round: true)
                await app.sendAttachments([pm], to: peerID)
            }
        }
    }

    private func cancelRecording() {
        if app.recorderMode == .voice { audioRecorder.cancel() }
        else { videoRecorder.cancel(); videoRecorder.stopSession() }
        recState = .idle
    }

    private func sendPickedVideoNote(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pick-\(UUID().uuidString).mp4")
        try? data.write(to: tmp)
        let ms = Int(CMTimeGetSeconds(AVURLAsset(url: tmp).duration) * 1000)
        try? FileManager.default.removeItem(at: tmp)
        let pm = AppState.PendingMedia(data: data, mime: "video/mp4", name: "note.mp4",
                                       durationMs: ms, round: true)
        await app.sendAttachments([pm], to: peerID)
    }

    private func timeString(_ s: TimeInterval) -> String {
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Actions

    private func commit() {
        let text = draft
        draft = ""
        if let m = editing {
            editing = nil
            Task { await app.editMessage(m, newText: text) }
        } else {
            let reply = replyingTo
            replyingTo = nil
            Task { await app.send(text: text, to: peerID, replyingTo: reply) }
        }
    }

    private func startReply(_ m: ChatMessage) { editing = nil; replyingTo = m }
    private func startEdit(_ m: ChatMessage) { replyingTo = nil; editing = m; draft = m.text }
    private func cancelEdit() { editing = nil; draft = "" }

    private func toggle(_ m: ChatMessage) {
        if selected.contains(m.id) { selected.remove(m.id) } else { selected.insert(m.id) }
    }
    private func exitSelection() { selectionMode = false; selected = []; forwarding = nil }

    private func openMedia(_ attachment: Attachment) {
        let media = messages.flatMap { $0.attachments }.filter { $0.isMedia }
        guard let idx = media.firstIndex(of: attachment) else { return }
        mediaContext = MediaViewerContext(items: media, startIndex: idx)
    }

    private func sendPickedMedia(_ items: [PhotosPickerItem]) async {
        var pending: [AppState.PendingMedia] = []
        for item in items.prefix(maxAttachments) {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if isVideo {
                let t = item.supportedContentTypes.first { $0.conforms(to: .movie) }
                pending.append(.init(data: data, mime: t?.preferredMIMEType ?? "video/quicktime",
                                     name: "video.\(t?.preferredFilenameExtension ?? "mov")"))
            } else if let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) {
                pending.append(.init(data: jpeg, mime: "image/jpeg", name: "photo.jpg",
                                     width: Int(image.size.width), height: Int(image.size.height)))
            }
        }
        await app.sendAttachments(pending, to: peerID)
    }

    private func sendPickedFiles(_ urls: [URL]) async {
        var pending: [AppState.PendingMedia] = []
        for url in urls.prefix(maxAttachments) {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            pending.append(.init(data: data, mime: mime, name: url.lastPathComponent))
        }
        await app.sendAttachments(pending, to: peerID)
    }

    // MARK: - Row building / formatting

    private static func buildRows(_ msgs: [ChatMessage]) -> [ChatRow] {
        var rows: [ChatRow] = []
        let cal = Calendar.current
        var lastDay: Date?
        for m in msgs {
            let day = cal.startOfDay(for: m.timestamp)
            if lastDay == nil || day != lastDay! {
                rows.append(.day(day)); lastDay = day
            }
            rows.append(.message(m))
        }
        return rows
    }
}

/// Wraps a message bubble; swiping it left past a threshold triggers a reply,
/// revealing a reply icon as you drag.
private struct SwipeToReply<Content: View>: View {
    var enabled: Bool
    var onReply: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var dx: CGFloat = 0

    private var drag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { g in if g.translation.width < 0 { dx = max(g.translation.width, -80) } }
            .onEnded { g in
                if g.translation.width < -55 { onReply() }
                withAnimation(.spring(response: 0.3)) { dx = 0 }
            }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.secondary)
                .opacity(Double(min(-dx, 60) / 60))
                .padding(.trailing, 4)
            Group {
                if enabled {
                    content().offset(x: dx).gesture(drag)
                } else {
                    content()
                }
            }
        }
    }
}

/// Floating lock affordance shown above the recorder button while holding to
/// record. The button rises toward it; crossing the threshold snaps to locked.
private struct LockHint: View {
    let willLock: Bool
    @State private var bob = false

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: willLock ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(willLock ? .white : Color.accentColor)
                .frame(width: 36, height: 36)
                .background(willLock ? Color.accentColor : Color(.systemGray5), in: Circle())
                .scaleEffect(willLock ? 1.15 : 1)
            if !willLock {
                Image(systemName: "chevron.up")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
                    .offset(y: bob ? -3 : 1)
            }
        }
        .animation(.spring(response: 0.3), value: willLock)
        .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { bob = true } }
    }
}

private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(.red).frame(width: 12, height: 12)
            .opacity(on ? 1 : 0.25)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct LiveLevel: View {
    let level: Float
    private let variation: [CGFloat] = [0.5, 0.8, 1, 0.7, 0.9, 1, 0.6, 0.85, 1, 0.7, 0.55, 0.9]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<variation.count, id: \.self) { i in
                Capsule().fill(Color.accentColor.opacity(0.85))
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.1), value: level)
    }
    private func barHeight(_ i: Int) -> CGFloat {
        let l = CGFloat(max(0.06, min(1, CGFloat(level))))
        return max(3, 22 * l * variation[i])
    }
}

private struct DayHeader: View {
    let date: Date
    var body: some View {
        Text(Self.label(date))
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(Color(.systemGray5), in: Capsule())
            .padding(.vertical, 4)
    }

    static func label(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMMM d" : "MMMM d, yyyy"
        return f.string(from: date)
    }
}

private let timeFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
}()

private struct MessageBubble<Menu: View>: View {
    let message: ChatMessage
    var showSender: Bool = false
    var menuEnabled: Bool = true
    var onRetry: () -> Void
    var onOpenMedia: (Attachment) -> Void
    var onOpenFile: (Attachment) -> Void
    @ViewBuilder var menu: () -> Menu

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                if showSender, !message.isMine, let sender = message.senderName {
                    Text(sender).font(.caption2.bold()).foregroundStyle(.secondary)
                }
                // Only the message body gets the context-menu highlight — not the
                // full-width row, sender label, or timestamp footer.
                bodyWithMenu
                footer
            }
            if !message.isMine { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder private var bodyWithMenu: some View {
        if menuEnabled {
            messageBody.contextMenu { menu() }
        } else {
            messageBody
        }
    }

    private var messageBody: some View {
        VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
            if message.forwarded {
                Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                    .font(.caption2).italic().foregroundStyle(.secondary)
            }
            if let reply = message.replyTo { ReplyQuote(reply: reply) }
            if message.deleted {
                Text("Message deleted").italic().foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color(.systemGray6)).clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        if message.attachments.count == 1, message.attachments[0].isVoice {
            VoiceBubble(attachment: message.attachments[0], isMine: message.isMine)
        } else if message.attachments.count == 1, message.attachments[0].isVideoNote {
            VideoNoteBubble(attachment: message.attachments[0])
        } else if !message.attachments.isEmpty {
            AlbumView(attachments: message.attachments, isMine: message.isMine,
                      onOpenMedia: onOpenMedia, onOpenFile: onOpenFile)
        }
        if !message.text.isEmpty {
            Text(message.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(message.isMine ? Color.accentColor : Color(.systemGray5))
                .foregroundStyle(message.isMine ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(timeFormatter.string(from: message.timestamp)).font(.caption2).foregroundStyle(.secondary)
            if message.editedAt != nil { Text("· edited").font(.caption2).foregroundStyle(.secondary) }
            if message.isMine, !message.deleted {
                if message.delivery == .failed {
                    Button(action: onRetry) { Text("· failed, retry").font(.caption2).foregroundStyle(.red) }
                } else {
                    Text("· \(statusText)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String {
        switch message.delivery {
        case .sending: return "sending…"
        case .sent: return "sent"
        case .delivered: return "delivered"
        case .failed: return "failed"
        }
    }
}

/// The quoted reference shown above a reply.
private struct ReplyQuote: View {
    let reply: ReplyPreview
    var body: some View {
        HStack(spacing: 6) {
            Rectangle().fill(Color.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(reply.sender).font(.caption2.bold()).foregroundStyle(Color.accentColor)
                Text(reply.text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AlbumView: View {
    let attachments: [Attachment]
    let isMine: Bool
    var onOpenMedia: (Attachment) -> Void
    var onOpenFile: (Attachment) -> Void

    private var media: [Attachment] { attachments.filter { $0.isMedia } }
    private var fileItems: [Attachment] { attachments.filter { !$0.isMedia } }
    private let columns = [GridItem(.flexible(), spacing: 3), GridItem(.flexible(), spacing: 3)]

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            if media.count == 1 {
                MediaThumb(attachment: media[0], size: 220).onTapGesture { onOpenMedia(media[0]) }
            } else if media.count > 1 {
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(media) { att in
                        MediaThumb(attachment: att, size: 108).onTapGesture { onOpenMedia(att) }
                    }
                }
                .frame(width: 219)
            }
            ForEach(fileItems) { att in
                FileChip(attachment: att, isMine: isMine).onTapGesture { onOpenFile(att) }
            }
        }
    }
}

private struct MediaThumb: View {
    @EnvironmentObject var app: AppState
    let attachment: Attachment
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(.systemGray5))
                    .overlay { if !attachment.isVideo { ProgressView() } }
            }
            if attachment.isVideo {
                Image(systemName: "play.circle.fill").font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.9)).shadow(radius: 3)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 150 ? 16 : 8))
        .task(id: attachment.key) {
            if attachment.isImage {
                if let data = await app.attachmentData(attachment) { image = UIImage(data: data) }
            } else if attachment.isVideo {
                image = await app.videoThumbnail(attachment)
            }
        }
    }
}

private struct FileChip: View {
    let attachment: Attachment
    let isMine: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isMine ? Color.accentColor.opacity(0.15) : Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
