import UIKit
import MediaPlayer
import AVFoundation

final class VolumePillView: UIView {
    private let effectView: UIVisualEffectView

    // MPVolumeView — kept solely so the system binds its internal slider to the
    // hardware volume buttons. Embedding it inside UIVisualEffectView.contentView
    // triggers "Tracking element window has a non-placeholder input view" spam,
    // so we add it directly to self with a frame that sits just outside our bounds.
    // self.clipsToBounds = true (set in setup()) clips it to nothing — no alpha
    // tricks needed, and the system binding remains active.
    private let hiddenVolumeView: MPVolumeView = {
        let v = MPVolumeView(frame: CGRect(x: -2, y: -2, width: 1, height: 1))
        v.showsRouteButton = false
        v.showsVolumeSlider = true
        v.isUserInteractionEnabled = false
        return v
    }()

    // Plain UISlider used purely for visual display inside the pill.
    private let displaySlider: UISlider = {
        let s = UISlider()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.minimumValue = 0
        s.maximumValue = 1
        s.semanticContentAttribute = .forceLeftToRight
        s.minimumTrackTintColor = .white
        s.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        s.setThumbImage(UIImage(), for: .normal)
        s.setThumbImage(UIImage(), for: .highlighted)
        s.isUserInteractionEnabled = false  // gestures handled on self
        return s
    }()

    private let iconView: UIImageView = {
        let iv = UIImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.contentMode = .scaleAspectFit
        iv.tintColor = .white
        iv.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        return iv
    }()

    private var isAdjusting: Bool = false
    private var adjustEndWorkItem: DispatchWorkItem?

    var isUserAdjusting: Bool { isAdjusting }

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            effectView = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    required init?(coder: NSCoder) {
        if #available(iOS 26.0, *) {
            effectView = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
    }

    private func setup() {
        // Clip self so the out-of-bounds MPVolumeView is invisible without any
        // alpha tricks. The effect view manages its own corner clipping.
        clipsToBounds = true

        // Park the hidden MPVolumeView directly on self — NOT inside the effect
        // view — to avoid triggering the input-tracking warning.
        addSubview(hiddenVolumeView)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.layer.cornerRadius = 22
        effectView.clipsToBounds = true
        let hairline = 1.0 / UIScreen.main.scale
        effectView.layer.borderWidth = hairline
        effectView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        addSubview(effectView)

        let hstack = UIStackView(arrangedSubviews: [displaySlider, iconView])
        hstack.translatesAutoresizingMaskIntoConstraints = false
        hstack.axis = .horizontal
        hstack.alignment = .center
        hstack.spacing = 8
        effectView.contentView.addSubview(hstack)

        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            hstack.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor, constant: 12),
            hstack.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor, constant: -12),
            hstack.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            displaySlider.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Forward system-volume changes from the hidden MPVolumeView's slider
        // to the display slider.
        if let s = systemVolumeSlider {
            s.addTarget(self, action: #selector(systemSliderChanged(_:)), for: .valueChanged)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        syncToSystemVolume()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.layer.cornerRadius = bounds.height / 2
    }

    // MARK: - Internal helpers

    private var systemVolumeSlider: UISlider? {
        hiddenVolumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    /// Maps a touch x-position (in self's coordinate space) to a 0…1 volume value
    /// using the display slider's track geometry.
    private func valueForTouchX(_ x: CGFloat) -> Float {
        let trackRect = displaySlider.trackRect(forBounds: displaySlider.bounds)
        let inSelf = displaySlider.convert(trackRect, to: self)
        guard inSelf.width > 0 else { return displaySlider.value }
        let ratio = max(0, min(1, Float((x - inSelf.minX) / inSelf.width)))
        return ratio
    }

    private func applyVolume(_ v: Float) {
        displaySlider.value = v
        systemVolumeSlider?.value = v
        systemVolumeSlider?.sendActions(for: .valueChanged)
        updateIcon(for: v, animated: true)
    }

    private func iconName(for volume: Float) -> String {
        if volume <= 0.001 { return "speaker.slash.fill" }
        if volume <= 0.33  { return "speaker.wave.1.fill" }
        if volume <= 0.66  { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func updateIcon(for volume: Float, animated: Bool) {
        let name = iconName(for: volume)
        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let img = UIImage(systemName: name, withConfiguration: cfg)
        if animated {
            UIView.transition(with: iconView, duration: 0.18, options: .transitionCrossDissolve) {
                self.iconView.image = img
            }
        } else {
            iconView.image = img
        }
    }

    // MARK: - Gesture handlers

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let x = g.location(in: self).x
        switch g.state {
        case .began:
            adjustEndWorkItem?.cancel()
            isAdjusting = true
            fallthrough
        case .changed:
            applyVolume(valueForTouchX(x))
        case .ended, .cancelled:
            applyVolume(valueForTouchX(x))
            scheduleAdjustEnd()
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        applyVolume(valueForTouchX(g.location(in: self).x))
        isAdjusting = true
        scheduleAdjustEnd()
    }

    private func scheduleAdjustEnd() {
        adjustEndWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isAdjusting = false }
        adjustEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    // Called when the hardware volume buttons change the system slider value.
    @objc private func systemSliderChanged(_ sender: UISlider) {
        guard !isAdjusting else { return }
        displaySlider.value = sender.value
        updateIcon(for: sender.value, animated: true)
    }

    func syncToSystemVolume() {
        guard !isAdjusting else { return }
        let v = AVAudioSession.sharedInstance().outputVolume
        displaySlider.value = v
        updateIcon(for: v, animated: false)
    }
}
