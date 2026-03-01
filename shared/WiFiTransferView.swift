//
//  WiFiTransferView.swift
//  shared
//

import SwiftUI

struct WiFiTransferView: View {
    @ObservedObject var server: WiFiTransferServer
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false
    @State private var showCopiedBanner = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {

                // Copied banner
                if showCopiedBanner {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Address copied to clipboard")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                Spacer()

                // Status icon
                ZStack {
                    Circle()
                        .fill(server.isRunning ? Color.accentColor.opacity(0.15) : Color(white: 0.12))
                        .frame(width: 88, height: 88)
                    Image(systemName: server.isRunning ? "wifi" : "wifi.slash")
                        .font(.system(size: 34, weight: .medium))
                        .foregroundStyle(server.isRunning ? Color.accentColor : .secondary)
                        .symbolEffect(.bounce, value: server.isRunning)
                }
                .padding(.bottom, 20)

                Text(server.isRunning ? "WiFi Transfer Active" : "WiFi Transfer")
                    .font(.title2.bold())

                Text(server.isRunning
                     ? "Open the address below in any browser on the same network"
                     : "Start the server to transfer files from another device")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 6)

                // URL card
                if server.isRunning {
                    VStack(spacing: 10) {
                        Text(server.localURL)
                            .font(.system(.title3, design: .monospaced).bold())
                            .foregroundStyle(.primary)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)

#if os(iOS)
                        Button {
                            copyURL()
                        } label: {
                            Label(copied ? "Copied!" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(copied ? .green : .accentColor)
                        }
                        .buttonStyle(.plain)
#endif
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 28)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                }

                Spacer()

                // Start / Stop button
                Button {
                    if server.isRunning { server.stop() } else { server.start() }
                } label: {
                    Text(server.isRunning ? "Stop Server" : "Start Server")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(server.isRunning ? Color(white: 0.18) : Color.accentColor,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(server.isRunning ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                Text("Files are saved to Documents/MPV")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
            }
            .animation(.easeInOut(duration: 0.25), value: showCopiedBanner)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(white: 0.06).ignoresSafeArea())
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        server.stop()
                        dismiss()
                    }
                }
            }
            .onAppear {
                server.start()
            }
            .onChange(of: server.isRunning) { running in
                if running { copyURL() }
            }
        }
    }

#if os(iOS)
    private func copyURL() {
        UIPasteboard.general.string = server.localURL
        copied = true
        withAnimation { showCopiedBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
            withAnimation { showCopiedBanner = false }
        }
    }
#endif
}
