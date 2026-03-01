//
//  AccentProgressBar.swift
//  mpv-ios
//
//  A thin, reusable accent-coloured progress bar.
//

import SwiftUI

struct AccentProgressBar: View {
    let progress: Double // 0.0 ... 1.0
    var height: CGFloat = 3
    var cornerRadius: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.12))
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color("AccentColor"))
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((max(0, min(1, progress))) * 100)) percent")
    }
}

#Preview {
    VStack(spacing: 8) {
        AccentProgressBar(progress: 0.25)
        AccentProgressBar(progress: 0.6)
        AccentProgressBar(progress: 0.9)
    }
    .padding()
    .background(Color.black)
    .previewLayout(.sizeThatFits)
}
