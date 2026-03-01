//
//  ContentView.swift
//  mpv-ios
//
//  Created by Alex Kim on 27/2/2026.
//

import SwiftUI
import UIKit

struct ContentView: View {
    private struct PlayerItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    @State private var externalPlayerURL: PlayerItem?
    @State private var securityScopedURL: URL?
    @State private var orientationBeforePlayer: UIInterfaceOrientationMask = .portrait

    var body: some View {
        Group {
#if compiler(>=6.0)
            if #available(iOS 26.0, *) {
                TabView {
                    Tab("Home", systemImage: "house.fill") {
                        HomeView()
                    }
                    Tab("Browse", systemImage: "folder") {
                        BrowseView()
                    }
                    Tab("Settings", systemImage: "gear") {
                        SettingsView()
                    }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
                .accentColor(Color("AccentColor"))
            } else {
                olderTabView
            }
#else
            olderTabView
#endif
        }
        .onOpenURL { url in
            _ = url.startAccessingSecurityScopedResource()
            securityScopedURL = url
            snapshotOrientation()
            externalPlayerURL = PlayerItem(url: url)
        }
        .fullScreenCover(item: $externalPlayerURL, onDismiss: {
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
            externalPlayerURL = nil
            restoreOrientation()
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

    private func restoreOrientation() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientationBeforePlayer)) { _ in }
    }

    private var olderTabView: some View {
        TabView {
            HomeView()
                .tabItem {
                    Image(systemName: "house.fill")
                    Text("Home")
                }
            BrowseView()
                .tabItem {
                    Image(systemName: "folder")
                    Text("Browse")
                }
            SettingsView()
                .tabItem {
                    Image(systemName: "gear")
                    Text("Settings")
                }
        }
        .accentColor(Color("AccentColor"))
    }
}

#Preview {
    ContentView()
}
