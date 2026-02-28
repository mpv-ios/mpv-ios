import UIKit
import MediaPlayer
import AVFoundation

final class VolumePillView: UIView {
    private let effectView: UIVisualEffectView
    private let volumeView: MPVolumeView = {
        let v = MPVolumeView(frame: .zero)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.showsRouteButton = false
        v.showsVolumeSlider = true
        v.semanticContentAttribute = .forceLeftToRight
        return v
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
        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.layer.cornerRadius = 22
        effectView.clipsToBounds = true
        let hairline = 1.0 / UIScreen.main.scale
        effectView.layer.borderWidth = hairline
        effectView.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        addSubview(effectView)
        let hstack = UIStackView(arrangedSubviews: [volumeView, iconView])
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
            hstack.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor, constant: 2),

            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
            iconView.centerYAnchor.constraint(equalTo: volumeView.centerYAnchor, constant: -3),
            volumeView.heightAnchor.constraint(equalToConstant: 24),
        ])

        if let s = volumeSlider {
            s.semanticContentAttribute = .forceLeftToRight
            s.minimumTrackTintColor = .white
            s.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
            s.setThumbImage(UIImage(), for: .normal)
            s.setThumbImage(UIImage(), for: .highlighted)
            s.contentVerticalAlignment = .center
            s.isUserInteractionEnabled = false // we handle gestures on self
            s.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
        // Initialize icon to current system volume
        syncToSystemVolume()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.layer.cornerRadius = bounds.height / 2
    }

    private var volumeSlider: UISlider? {
        return volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    private func valueForTouchX(_ x: CGFloat) -> Float {
        guard let s = volumeSlider else { return 0 }
        let trackRect = s.trackRect(forBounds: s.bounds)
        let inSelf = s.convert(trackRect, to: self)
        guard inSelf.width > 0 else { return s.value }
        let ratio = max(0, min(1, Float((x - inSelf.minX) / inSelf.width)))
        return s.minimumValue + ratio * (s.maximumValue - s.minimumValue)
    }

    private func iconName(for volume: Float) -> String {
        if volume <= 0.001 { return "speaker.slash.fill" }
        if volume <= 0.33 { return "speaker.wave.1.fill" }
        if volume <= 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func updateIcon(for volume: Float, animated: Bool) {
        let name = iconName(for: volume)
        let cfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let img = UIImage(systemName: name, withConfiguration: cfg)
        if animated {
            UIView.transition(with: iconView, duration: 0.18, options: .transitionCrossDissolve, animations: {
                self.iconView.image = img
            }, completion: nil)
        } else {
            iconView.image = img
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let s = volumeSlider else { return }
        let x = g.location(in: self).x
        switch g.state {
        case .began:
            adjustEndWorkItem?.cancel()
            isAdjusting = true
            fallthrough
        case .changed:
            let v = valueForTouchX(x)
            s.value = v
            s.sendActions(for: .valueChanged)
            updateIcon(for: v, animated: true)
        case .ended, .cancelled:
            let v = valueForTouchX(x)
            s.value = v
            s.sendActions(for: .valueChanged)
            updateIcon(for: v, animated: true)
            adjustEndWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.isAdjusting = false }
            adjustEndWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let s = volumeSlider else { return }
        let x = g.location(in: self).x
        let v = valueForTouchX(x)
        s.value = v
        s.sendActions(for: .valueChanged)
        updateIcon(for: v, animated: true)
        // brief cooldown to ignore external syncs after tap
        isAdjusting = true
        adjustEndWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.isAdjusting = false }
        adjustEndWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        updateIcon(for: sender.value, animated: true)
    }

    func syncToSystemVolume() {
        guard !isAdjusting, let s = volumeSlider else { return }
        let v = AVAudioSession.sharedInstance().outputVolume
        s.value = v
        updateIcon(for: v, animated: true)
    }
}
