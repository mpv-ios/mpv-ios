//
//  HomeView.swift
//  mpv-ios
//
//  Created by Alex Kim on 27/2/2026.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct HomeView: View {
    // Tiny Identifiable wrapper so we can drive fullScreenCover(item:) with a URL
    private struct PlayerItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    @State private var isURLEntryPresented = false
    @State private var isFilePickerPresented = false
    @State private var urlInput = ""
    @State private var playerURL: PlayerItem?
    @State private var orientationBeforePlayer: UIInterfaceOrientationMask = .portrait

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color.black, Color(white: 0.06)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo / title
                VStack(spacing: 8) {
                    Image("mpv_logo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text("mpv")
                        .font(.system(size: 42, weight: .thin, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }

                Spacer()

                // Action buttons
                VStack(spacing: 14) {
                    HomeActionButton(
                        symbol: "folder.fill",
                        label: "Open Local File"
                    ) {
                        isFilePickerPresented = true
                    }

                    HomeActionButton(
                        symbol: "link",
                        label: "Play URL"
                    ) {
                        urlInput = ""
                        isURLEntryPresented = true
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        // URL entry sheet
        .sheet(isPresented: $isURLEntryPresented) {
            URLEntrySheet(url: $urlInput) { url in
                isURLEntryPresented = false
                // Small delay lets the sheet fully dismiss before cover presents
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    snapshotOrientation()
                    playerURL = PlayerItem(url: url)
                }
            }
            .presentationDetents([.height(180)])
            .presentationDragIndicator(.visible)
        }
        // File picker
        .fileImporter(
            isPresented: $isFilePickerPresented,
            allowedContentTypes: [.movie, .video, .audio, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                let saved = persistImportedFile(at: url)
                snapshotOrientation()
                playerURL = PlayerItem(url: saved ?? url)
            }
        }
        // Player
        .fullScreenCover(item: $playerURL, onDismiss: {
            playerURL = nil
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationBeforePlayer)) { _ in }
        }) { item in
            iOSPlayerScreen(url: item.url)
        }
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
}

// MARK: - File persistence

private func persistImportedFile(at externalURL: URL) -> URL? {
    let fm = FileManager.default
    guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

    // If it's already inside our Documents, just return it
    if externalURL.path.hasPrefix(docs.path) {
        return externalURL
    }

    let started = externalURL.startAccessingSecurityScopedResource()
    defer {
        if started { externalURL.stopAccessingSecurityScopedResource() }
    }

    var dest = docs.appendingPathComponent(externalURL.lastPathComponent, isDirectory: false)
    // Ensure unique name if a file exists
    if fm.fileExists(atPath: dest.path) {
        let base = dest.deletingPathExtension().lastPathComponent
        let ext = dest.pathExtension
        var counter = 2
        while fm.fileExists(atPath: dest.path) && counter < 10_000 {
            let name = "\(base) \(counter)"
            dest = docs.appendingPathComponent(name).appendingPathExtension(ext)
            counter += 1
        }
    }

    do {
        try fm.copyItem(at: externalURL, to: dest)
        // Make sure it's not excluded from backups unintentionally; default is ok
        return dest
    } catch {
        print("[Home] Copy failed: \(error)")
        return nil
    }
}

// MARK: - Action Button

private struct HomeActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background {
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular)
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
        }
        .tint(Color("AccentColor"))
    }
}

// MARK: - URL Entry Sheet

private struct URLEntrySheet: View {
    @Binding var url: String
    let onConfirm: (URL) -> Void
    @State private var canPaste: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Enter URL")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(Color("AccentColor"))
                TextField("https://…", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .foregroundStyle(.white)
                    .submitLabel(.go)
                    .onSubmit { tryConfirm() }
                if canPaste {
                    Button {
                        // User-initiated: safe to read pasteboard
                        if let u = UIPasteboard.general.url {
                            url = u.absoluteString
                        } else if let clip = UIPasteboard.general.string, !clip.isEmpty {
                            url = clip
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 15))
                            .foregroundStyle(Color("AccentColor"))
                    }
                    .accessibilityLabel("Paste from Clipboard")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                if #available(iOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.regular)
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.ultraThinMaterial)
                }
            }
            .padding(.horizontal, 20)
            .onAppear {
                // Check capability without triggering paste permission
                canPaste = UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings
            }
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                canPaste = UIPasteboard.general.hasURLs || UIPasteboard.general.hasStrings
            }

            Button(action: tryConfirm) {
                Text("Play")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color("AccentColor"), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .background {
            if #available(iOS 26.0, *) {
                Color.clear.ignoresSafeArea()
            } else {
                Color(white: 0.08).ignoresSafeArea()
            }
        }
    }

    private func tryConfirm() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed) else { return }
        onConfirm(parsed)
    }
}

#Preview {
    HomeView()
}
