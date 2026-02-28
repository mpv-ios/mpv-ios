//
//  SettingsView.swift
//  mpv-ios
//
//  Created by Alex Kim on 27/2/2026.
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(destination: PlaybackSettingsView()) {
                        Label("Playback", systemImage: "slider.horizontal.3")
                    }
                    NavigationLink(destination: DecoderSettingsView()) {
                        Label("Decoder", systemImage: "film.stack")
                    }
                    NavigationLink(destination: GesturesSettingsView()) {
                        Label("Gestures", systemImage: "hand.tap")
                    }
                } header: {
                    Text("Player")
                } footer: {
                    Text("Configure playback behaviour and hardware decoding preferences.")
                }

                Section {
                    NavigationLink(destination: NetworkSettingsView()) {
                        Label("Network", systemImage: "network")
                    }
                } header: {
                    Text("Connectivity")
                } footer: {
                    Text("HTTP headers, proxy, and stream buffering options.")
                }

                Section {
                    NavigationLink(destination: AboutView()) {
                        Label("About", systemImage: "info.circle")
                    }
                } header: {
                    Text("Info")
                }

                Section(footer: Text("mpv-ios \(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")) {}
            }
            .navigationTitle("Settings")
        }
    }
}

struct GesturesSettingsView: View {
    @AppStorage("enableHoldSpeed") private var enableHoldSpeed: Bool = true
    @AppStorage("holdSpeedPlayer") private var holdSpeed: Double = 2.0
    @AppStorage("enableSwipeBrightness") private var enableSwipeBrightness: Bool = true
    @AppStorage("enableSwipeVolume") private var enableSwipeVolume: Bool = true
    @AppStorage("enablePinchZoom") private var enablePinchZoom: Bool = true

    var body: some View {
        List {
            Section {
                Toggle("Pinch to Zoom (fill)", isOn: $enablePinchZoom)
            } header: {
                Text("Zoom")
            } footer: {
                Text("Pinch to switch between fit and fill (crop) video modes.")
            }

            Section {
                Toggle("Hold to Speed", isOn: $enableHoldSpeed)
                HStack {
                    Text("Hold Speed")
                    Spacer()
                    Picker("", selection: $holdSpeed) {
                        Text("1.50×").tag(1.5)
                        Text("2.00×").tag(2.0)
                        Text("2.50×").tag(2.5)
                        Text("3.00×").tag(3.0)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Hold Gesture")
            } footer: {
                Text("Long‑press on the video to temporarily change playback speed. The indicator auto‑hides after a few seconds.")
            }

            Section {
                Toggle("Swipe Brightness (left)", isOn: $enableSwipeBrightness)
                Toggle("Swipe Volume (right)", isOn: $enableSwipeVolume)
            } header: {
                Text("Vertical Swipes")
            } footer: {
                Text("Swipe up/down on the left half to change screen brightness, and on the right half to change system volume.")
            }
        }
        .navigationTitle("Gestures")
    }
}

// MARK: - Sub-pages

struct PlaybackSettingsView: View {
    @AppStorage("defaultSpeed") private var defaultSpeed: Double = 1.0
    @AppStorage("resumePlayback") private var resumePlayback: Bool = true
    @AppStorage("rememberLastSubtitle") private var rememberLastSubtitle: Bool = true
    @AppStorage("lockLandscape") private var lockLandscape: Bool = true
    @AppStorage("skipForwardSeconds") private var skipForward: Int = 10
    @AppStorage("skipBackwardSeconds") private var skipBackward: Int = 10

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Default Speed")
                    Spacer()
                    Picker("", selection: $defaultSpeed) {
                        Text("0.5×").tag(0.5)
                        Text("0.75×").tag(0.75)
                        Text("1×").tag(1.0)
                        Text("1.25×").tag(1.25)
                        Text("1.5×").tag(1.5)
                        Text("2×").tag(2.0)
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Resume Where Left Off", isOn: $resumePlayback)
                Toggle("Remember Last Subtitle", isOn: $rememberLastSubtitle)
                Toggle("Lock to Landscape", isOn: $lockLandscape)
            } header: {
                Text("General")
            } footer: {
                Text("Lock to Landscape forces the player to stay in landscape orientation.")
            }

            Section {
                HStack {
                    Text("Skip Forward")
                    Spacer()
                    Picker("", selection: $skipForward) {
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                        Text("15s").tag(15)
                        Text("30s").tag(30)
                    }
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("Skip Backward")
                    Spacer()
                    Picker("", selection: $skipBackward) {
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                        Text("15s").tag(15)
                        Text("30s").tag(30)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Skip Intervals")
            }
        }
        .navigationTitle("Playback")
    }
}

struct DecoderSettingsView: View {
    @AppStorage("hardwareDecoding") private var hwDecoding: Bool = true
    @AppStorage("deinterlace") private var deinterlace: Bool = false

    var body: some View {
        List {
            Section {
                Toggle("Hardware Decoding", isOn: $hwDecoding)
                Toggle("Deinterlace", isOn: $deinterlace)
            } header: {
                Text("Video")
            } footer: {
                Text("Hardware decoding offloads video decode to the GPU. Disable if you see artefacts.")
            }
        }
        .navigationTitle("Decoder")
    }
}

struct NetworkSettingsView: View {
    @AppStorage("networkUserAgent") private var userAgent: String = ""
    @AppStorage("networkCacheSize") private var cacheSize: Int = 150

    var body: some View {
        List {
            Section {
                HStack {
                    Text("User-Agent")
                    Spacer()
                    TextField("Default", text: $userAgent)
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("HTTP")
            }

            Section {
                HStack {
                    Text("Cache Size")
                    Spacer()
                    Picker("", selection: $cacheSize) {
                        Text("50 MB").tag(50)
                        Text("150 MB").tag(150)
                        Text("300 MB").tag(300)
                        Text("500 MB").tag(500)
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Buffering")
            } footer: {
                Text("Larger caches improve streaming stability but use more memory.")
            }
        }
        .navigationTitle("Network")
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Player Engine")
                    Spacer()
                    Text("mpv")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("About")
    }
}

// MARK: - Bundle helpers

private extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

#Preview {
    SettingsView()
}
