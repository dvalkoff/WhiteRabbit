import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let maxAttachments = 10

struct ChatView: View {
    @EnvironmentObject var app: AppState
    let peerID: String

    @State private var draft = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var mediaContext: MediaViewerContext?
    @State private var fileShareURL: URL?

    private var messages: [ChatMessage] { app.chatStore.messages(for: peerID) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg,
                                          onRetry: { Task { await app.resend(message: msg) } },
                                          onOpenMedia: { openMedia($0) },
                                          onOpenFile: { att in Task { fileShareURL = await app.attachmentFileURL(att) } })
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            inputBar
        }
        .navigationTitle(app.chatStore.nickname(for: peerID))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { app.chatStore.clearUnread(peerID: peerID) }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: maxAttachments, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            photoItems = []
            Task { await sendPickedMedia(picked) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await sendPickedFiles(urls) } }
        }
        .fullScreenCover(item: $mediaContext) { MediaViewer(context: $0) }
        .sheet(item: $fileShareURL) { url in ShareSheet(items: [url]) }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button { showPhotoPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                Button { showFileImporter = true } label: { Label("File", systemImage: "doc") }
            } label: {
                Image(systemName: "paperclip").font(.title3)
            }
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button {
                let text = draft
                draft = ""
                Task { await app.send(text: text, to: peerID) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
    }

    /// Open the swipeable viewer at the tapped media item, paging across all
    /// media in the conversation.
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
                let type = item.supportedContentTypes.first { $0.conforms(to: .movie) }
                pending.append(.init(data: data,
                                     mime: type?.preferredMIMEType ?? "video/quicktime",
                                     name: "video.\(type?.preferredFilenameExtension ?? "mov")"))
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
}

private struct MessageBubble: View {
    let message: ChatMessage
    var onRetry: () -> Void
    var onOpenMedia: (Attachment) -> Void
    var onOpenFile: (Attachment) -> Void

    var body: some View {
        HStack {
            if message.isMine { Spacer(minLength: 40) }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 4) {
                if !message.attachments.isEmpty {
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
                if message.isMine {
                    if message.delivery == .failed {
                        Button(action: onRetry) {
                            Label("Failed — tap to retry", systemImage: "exclamationmark.circle")
                                .font(.caption2).foregroundStyle(.red)
                        }
                    } else {
                        Text(statusText).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !message.isMine { Spacer(minLength: 40) }
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

/// Renders a message's attachments: a media grid plus any file chips.
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
                Image(systemName: "play.circle.fill")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.9))
                    .shadow(radius: 3)
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
