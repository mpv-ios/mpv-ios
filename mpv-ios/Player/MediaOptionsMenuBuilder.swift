import UIKit

/// Builds the deferred UIMenu instances for subtitle-track and audio-track selection.
/// Both menus use `UIDeferredMenuElement.uncached` so the track list is always
/// re-fetched from the renderer each time the user opens the menu.
enum MediaOptionsMenuBuilder {

    // MARK: - Subtitle Menu

    static func makeSubtitleMenu(renderer: MPVLayerRenderer) -> UIMenu {
        UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: [
            UIDeferredMenuElement.uncached { [weak renderer] completion in
                guard let renderer else { completion([]); return }
                var actions: [UIAction] = []

                // Off
                let currentSub = renderer.getCurrentSubtitleTrack()
                let offAction = UIAction(
                    title: "Off",
                    image: currentSub == 0 ? UIImage(systemName: "checkmark") : nil
                ) { [weak renderer] _ in
                    renderer?.disableSubtitles()
                    UserDefaults.standard.set("off", forKey: "lastSubtitleLang")
                }
                actions.append(offAction)

                // Available tracks
                for track in renderer.getSubtitleTracks() {
                    let trackId  = track["id"]    as? Int    ?? 0
                    let langCode = track["lang"]  as? String
                    let displayLang = langCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                    let label = track["title"] as? String
                        ?? displayLang
                        ?? langCode
                        ?? "Track \(trackId)"
                    let isSelected = currentSub == trackId
                    let action = UIAction(
                        title: label,
                        image: isSelected ? UIImage(systemName: "checkmark") : nil
                    ) { [weak renderer] _ in
                        renderer?.setSubtitleTrack(trackId)
                        let key = langCode ?? label
                        UserDefaults.standard.set(key, forKey: "lastSubtitleLang")
                    }
                    actions.append(action)
                }
                completion(actions)
            }
        ])
    }

    // MARK: - Audio Menu

    static func makeAudioMenu(renderer: MPVLayerRenderer) -> UIMenu {
        UIMenu(title: "Audio", image: UIImage(systemName: "speaker.wave.2"), children: [
            UIDeferredMenuElement.uncached { [weak renderer] completion in
                guard let renderer else { completion([]); return }
                var actions: [UIAction] = []
                let currentAudio = renderer.getCurrentAudioTrack()

                for track in renderer.getAudioTracks() {
                    let trackId  = track["id"]    as? Int    ?? 0
                    let langCode = track["lang"]  as? String
                    let displayLang = langCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                    let label = track["title"] as? String
                        ?? displayLang
                        ?? langCode
                        ?? "Track \(trackId)"
                    let isSelected = currentAudio == trackId
                    let action = UIAction(
                        title: label,
                        image: isSelected ? UIImage(systemName: "checkmark") : nil
                    ) { [weak renderer] _ in renderer?.setAudioTrack(trackId) }
                    actions.append(action)
                }

                if actions.isEmpty {
                    actions.append(UIAction(title: "No audio tracks", attributes: .disabled) { _ in })
                }
                completion(actions)
            }
        ])
    }

    // MARK: - Settings / Playback Speed Menu

    static func makeSettingsMenu(renderer: MPVLayerRenderer) -> UIMenu {
        UIMenu(title: "Playback", image: UIImage(systemName: "gauge.medium"), children: [
            UIDeferredMenuElement.uncached { [weak renderer] completion in
                guard let renderer else { completion([]); return }

                let current = max(0.25, min(2.0, renderer.getSpeed()))
                let header = UIAction(title: String(format: "Speed • %.2g×", current), attributes: [.disabled]) { _ in }

                func step(_ delta: Double) -> UIAction {
                    let title = delta < 0 ? "Slower (−0.25×)" : "Faster (+0.25×)"
                    return UIAction(title: title, image: UIImage(systemName: delta < 0 ? "minus" : "plus")) { _ in
                        let stepped = ((current + delta) * 4).rounded() / 4
                        let clamped = max(0.25, min(2.0, stepped))
                        renderer.setSpeed(clamped)
                        UserDefaults.standard.set(clamped, forKey: "playbackSpeed")
                    }
                }

                let reset = UIAction(title: "Reset to 1.0×", image: UIImage(systemName: "arrow.uturn.left")) { _ in
                    renderer.setSpeed(1.0)
                    UserDefaults.standard.set(1.0, forKey: "playbackSpeed")
                }

                completion([header, step(-0.25), step(0.25), reset])
            }
        ])
    }
}
