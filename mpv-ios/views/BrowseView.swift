//
//  BrowseView.swift
//  mpv-ios
//
//  Created by GitHub Copilot on 1/3/2026.
//

import SwiftUI
import UIKit
import AVFoundation
import CoreMedia
import QuickLookThumbnailing

struct BrowseView: View {
    private struct PlayerItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    @State private var files: [URL] = []
    @State private var playerURL: PlayerItem?
    @State private var orientationBeforePlayer: UIInterfaceOrientationMask = .portrait
    @StateObject private var wifiServer = WiFiTransferServer()
    @State private var resumeRefreshTrigger: Int = 0
    @AppStorage("BrowseIsGrid") private var isGrid: Bool = false

    var body: some View {
        NavigationView {
            Group {
                if files.isEmpty {
                    emptyState
                } else if isGrid {
                    gridView
                } else {
                    listView
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Section(wifiServer.isRunning ? wifiServer.localURL : "WiFi Transfer") {
                            if wifiServer.isRunning {
                                Button {
                                    UIPasteboard.general.string = wifiServer.localURL
                                } label: {
                                    Label("Copy Address", systemImage: "doc.on.doc")
                                }
                            }
                            Button {
                                if wifiServer.isRunning {
                                    wifiServer.stop()
                                } else {
                                    wifiServer.start()
                                    UIPasteboard.general.string = wifiServer.localURL
                                }
                            } label: {
                                Label(
                                    wifiServer.isRunning ? "Stop WiFi Transfer" : "WiFi Transfer",
                                    systemImage: wifiServer.isRunning ? "wifi.slash" : "wifi"
                                )
                            }
                        }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: wifiServer.isRunning ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .foregroundStyle(wifiServer.isRunning ? Color.accentColor : .primary)
                            if wifiServer.isRunning {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 3, y: 3)
                            }
                        }
                    }
                    .accessibilityLabel("WiFi Transfer")

                    Menu {
                        Button { refresh() } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        Divider()
                        Picker("View", selection: $isGrid) {
                            Label("List", systemImage: "list.bullet").tag(false)
                            Label("Grid", systemImage: "square.grid.2x2").tag(true)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Options")
                }
            }
            .onChange(of: wifiServer.importedCount) { _ in refresh() }
            .onAppear(perform: refresh)
        }
        .fullScreenCover(item: $playerURL, onDismiss: {
            playerURL = nil
            restoreOrientation()
            resumeRefreshTrigger += 1
        }) { item in
            iOSPlayerScreen(url: item.url)
        }
    }


    private var listView: some View {
        List {
            if !wifiServer.activeTransfers.isEmpty {
                Section("Transfers") {
                    ForEach(wifiServer.activeTransfers) { transfer in
                        TransferRow(transfer: transfer)
                    }
                }
            }
            Section("Documents") {
                ForEach(files, id: \.self) { url in
                    FileRow(url: url, refreshTrigger: resumeRefreshTrigger)
                        .contentShape(Rectangle())
                        .onTapGesture { open(url) }
                        .contextMenu {
                            Button(role: .destructive) { delete(url) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { share(url) } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                }
                .onDelete { indices in
                    for index in indices { delete(files[index]) }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var gridView: some View {
        let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 10, alignment: .top)]
        return ScrollView {
            if !wifiServer.activeTransfers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Transfers")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(wifiServer.activeTransfers) { transfer in
                            TransferTile(transfer: transfer)
                        }
                    }
                    .padding(.horizontal, 16)
                    Divider().padding(.top, 4)
                }
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(files, id: \.self) { url in
                    GridTile(url: url, refreshTrigger: resumeRefreshTrigger)
                        .onTapGesture { open(url) }
                        .contextMenu {
                            Button(role: .destructive) { delete(url) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { share(url) } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
        .background(Color(white: 0.06).ignoresSafeArea())
    }

    private struct TransferRow: View {
        let transfer: ActiveTransfer
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    MediaThumb(url: transfer.savedURL, filename: transfer.displayName)
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transfer.displayName)
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(sizeDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(transfer.progress < 1 ? "\(Int(transfer.progress * 100))%" : "Done")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: transfer.progress)
                    .tint(Color.accentColor)
            }
            .padding(.vertical, 2)
        }
        private var sizeDetail: String {
            guard transfer.totalBytes > 0 else { return "" }
            let total = ByteCountFormatter.string(fromByteCount: Int64(transfer.totalBytes), countStyle: .file)
            if transfer.progress < 1 {
                let received = Int64(Double(transfer.totalBytes) * transfer.progress)
                let recv = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                return "\(recv) of \(total)"
            }
            return total
        }
    }

    private struct TransferTile: View {
        let transfer: ActiveTransfer
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    MediaThumb(url: transfer.savedURL, filename: transfer.displayName, cornerRadius: 10)
                        .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100)
                    ProgressView(value: transfer.progress)
                        .tint(Color.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(URL(fileURLWithPath: transfer.displayName).deletingPathExtension().lastPathComponent)
                        .font(.footnote)
                        .lineLimit(2)
                    Text(sizeDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        private var sizeDetail: String {
            guard transfer.totalBytes > 0 else { return "" }
            let total = ByteCountFormatter.string(fromByteCount: Int64(transfer.totalBytes), countStyle: .file)
            if transfer.progress < 1 {
                let received = Int64(Double(transfer.totalBytes) * transfer.progress)
                let recv = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
                return "\(recv) / \(total)"
            }
            return total
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No files found")
                .foregroundStyle(.secondary)
            Text("Import files via Home → Open Local File")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06).ignoresSafeArea())
    }

    private func refresh() {
        var all: [URL] = []
        let fm = FileManager.default
        if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            if let docFiles = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                all.append(contentsOf: docFiles)
            }
            let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
            if let inboxFiles = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                all.append(contentsOf: inboxFiles)
            }
            let mpvFolder = docs.appendingPathComponent("MPV", isDirectory: true)
            if let mpvFiles = try? fm.contentsOfDirectory(at: mpvFolder, includingPropertiesForKeys: [.creationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                all.append(contentsOf: mpvFiles)
            }
        }
        all = all.filter { isPlayableMedia($0) }
        files = all.sorted(by: { (a, b) -> Bool in
            let ad = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let bd = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return ad ?? .distantPast > bd ?? .distantPast
        })
    }

    private func open(_ url: URL) {
        snapshotOrientation()
        playerURL = PlayerItem(url: url)
    }

    private func delete(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            refresh()
        } catch {
            print("[Browse] Failed to delete: \(error)")
        }
    }

    private func share(_ url: URL) {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let root = keyWindow?.rootViewController else { return }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        root.present(vc, animated: true)
    }

    private func snapshotOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        switch scene.interfaceOrientation {
        case .landscapeLeft:      orientationBeforePlayer = .landscapeLeft
        case .landscapeRight:     orientationBeforePlayer = .landscapeRight
        case .portraitUpsideDown: orientationBeforePlayer = .portraitUpsideDown
        default:                  orientationBeforePlayer = .portrait
        }
    }

    private func restoreOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationBeforePlayer)) { _ in }
    }
}

private struct FileRow: View {
    let url: URL
    let refreshTrigger: Int
    @State private var resume: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                MediaThumb(url: url, filename: url.lastPathComponent)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.subheadline)
                        .lineLimit(2)
                    Text(detail(for: url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let p = resume, p > 0.02, p < 0.98 {
                AccentProgressBar(progress: p)
            }
        }
        .onAppear { loadResumePercent() }
        .onChange(of: refreshTrigger) { _ in loadResumePercent() }
    }

    private func iconName(for url: URL) -> String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? nil
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { return "film" }
        return "doc"
    }

    private func detail(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil
        let sizeStr = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let dateStr = date.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? ""
        return [sizeStr, dateStr].filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

// MARK: - Grid Tile

private struct GridTile: View {
    let url: URL
    let refreshTrigger: Int
    @State private var resume: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                MediaThumb(url: url, filename: url.lastPathComponent, cornerRadius: 10)
                    .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 100)
                if let p = resume, p > 0.02, p < 0.98 {
                    AccentProgressBar(progress: p, height: 3)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.footnote)
                    .lineLimit(2)
                Text(fileSizeString(url))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .clipped()
        .onAppear { loadResumePercent() }
        .onChange(of: refreshTrigger) { _ in loadResumePercent() }
    }
}

// MARK: - Shared Thumbnail Box

private struct MediaThumb: View {
    let url: URL?           // nil = file not yet on disk (active transfer)
    let filename: String    // used for the placeholder icon
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(white: 0.15))
            if let url {
                ThumbnailView(url: url)
                    .scaledToFit()
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                Image(systemName: iconForFilename(filename))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func iconForFilename(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        if ["mp3","m4a","aac","flac","wav","opus","ogg","oga","alac","aiff"].contains(ext) { return "waveform" }
        if ["mp4","m4v","mov","mkv","webm","avi","flv","wmv","ts","m2ts","3gp","3g2","ogv"].contains(ext) { return "film" }
        return "doc"
    }
}

// MARK: - Thumbnail Loader/View

private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, UIImage>()
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}

private struct ThumbnailView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: placeholderIcon())
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear { loadIfNeeded() }
    }

    private func placeholderIcon() -> String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? nil
        if type?.conforms(to: .audio) == true { return "waveform" }
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { return "film" }
        return "doc"
    }

    private func loadIfNeeded() {
        if let cached = ThumbnailCache.shared.image(for: url) {
            image = cached
            return
        }
        Task.detached(priority: .utility) {
            guard let thumbnail = generateThumbnail(for: url) else { return }
            ThumbnailCache.shared.set(thumbnail, for: url)
            await MainActor.run { self.image = thumbnail }
        }
    }
}

private func generateThumbnail(for url: URL) -> UIImage? {
    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? nil
    let asset = AVAsset(url: url)
    let ext = url.pathExtension.lowercased()
    let isVideo = (type?.conforms(to: .movie) == true) || (type?.conforms(to: .video) == true) ||
        ["mp4","m4v","mov","mkv","webm","avi","flv","wmv","ts","m2ts","3gp","3g2","ogv"].contains(ext)
    let isAudio = (type?.conforms(to: .audio) == true) ||
        ["mp3","m4a","aac","flac","wav","opus","ogg","oga","alac","aiff"].contains(ext)

    // Video: capture a representative frame (robust selection)
    if isVideo {
        let imgGen = AVAssetImageGenerator(asset: asset)
        imgGen.appliesPreferredTrackTransform = true
        imgGen.maximumSize = CGSize(width: 800, height: 800)
        imgGen.requestedTimeToleranceBefore = .zero
        imgGen.requestedTimeToleranceAfter = .zero

        let durationSec = max(0.0, CMTimeGetSeconds(asset.duration))
        // Try early, then ~1s, then zero as a last resort
        let candidates: [CMTime] = [
            CMTime(seconds: min(max(durationSec * 0.1, 0.1), max(0.0, durationSec - 0.05)), preferredTimescale: 600),
            CMTime(seconds: min(1.0, max(0.0, durationSec - 0.05)), preferredTimescale: 600),
            .zero
        ]
        for t in candidates {
            do {
                let cg = try imgGen.copyCGImage(at: t, actualTime: nil)
                return UIImage(cgImage: cg)
            } catch {
                // try next candidate
            }
        }
        // Fallback: Quick Look thumbnail generation
        if let ql = quickLookThumbnail(for: url, size: CGSize(width: 800, height: 800)) {
            return ql
        }
    }

    // Audio: extract embedded artwork (ID3 / iTunes)
    if isAudio {
        if let art = extractArtworkImage(from: asset) {
            return art
        }
    }

    return nil
}

private func extractArtworkImage(from asset: AVAsset) -> UIImage? {
    // Try common metadata first
    if let commonItem = asset.commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork }) {
        if let data = commonItem.dataValue, let img = UIImage(data: data) { return img }
        if let obj = commonItem.value as? Data, let img = UIImage(data: obj) { return img }
    }

    // Fallback: explicit formats (ID3, iTunes)
    for format in asset.availableMetadataFormats {
        for item in asset.metadata(forFormat: format) {
            // Prefer modern identifiers
            if let id = item.identifier {
                if id == .id3MetadataAttachedPicture || id == .iTunesMetadataCoverArt {
                    if let data = item.dataValue, let img = UIImage(data: data) { return img }
                }
            }
        }
    }
    return nil
}

// MARK: - Quick Look fallback

private func quickLookThumbnail(for url: URL, size: CGSize) -> UIImage? {
    let scale: CGFloat = 2.0
    let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
    var image: UIImage?
    let sema = DispatchSemaphore(value: 0)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
        if let rep = rep { image = rep.uiImage }
        sema.signal()
    }
    _ = sema.wait(timeout: .now() + 1.0)
    return image
}

// MARK: - Media type helpers

private func isPlayableMedia(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if ["mp4","m4v","mov","mkv","webm","avi","flv","wmv","ts","m2ts","3gp","3g2","ogv"].contains(ext) { return true }
    if ["mp3","m4a","aac","flac","wav","opus","ogg","oga","alac","aiff"].contains(ext) { return true }
    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
        if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audio) { return true }
    }
    return false
}

// MARK: - Resume helpers

private func resumeKey(for url: URL) -> String { "resume_\(url.absoluteString)" }

private func resumePercent(for url: URL) async -> Double? {
    let pos = UserDefaults.standard.double(forKey: resumeKey(for: url))
    guard pos > 0 else { return nil }
    let asset = AVURLAsset(url: url)
    let duration: CMTime
    do {
        duration = try await asset.load(.duration)
    } catch {
        return nil
    }
    let seconds = duration.seconds
    guard seconds.isFinite && seconds > 0 else { return nil }
    return max(0, min(1, pos / seconds))
}

private extension FileRow {
    func loadResumePercent() {
        Task.detached(priority: .utility) {
            let p = await resumePercent(for: url)
            await MainActor.run { self.resume = p }
        }
    }
}

// MARK: - Formatting helpers

private func fileSizeString(_ url: URL) -> String {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
    return size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
}

private extension GridTile {
    func loadResumePercent() {
        Task.detached(priority: .utility) {
            let p = await resumePercent(for: url)
            await MainActor.run { self.resume = p }
        }
    }
}
