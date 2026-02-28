import UIKit

/// Presented as a native `UIPopoverPresentationController` anchored to the gear button.
/// Sections: Playback (speed) and Subtitle (scale slider).
final class PlayerSettingsViewController: UIViewController, UIPopoverPresentationControllerDelegate, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning {

    // MARK: - Callbacks

    var onSpeedChanged: ((Double) -> Void)?
    var onSubtitleScaleChanged: ((Double) -> Void)?
    var onSubtitleDelayChanged: ((Double) -> Void)?

    // MARK: - Speed

    private static let minSpeed: Double = 0.25
    private static let maxSpeed: Double = 2.0
    private var currentSpeed: Double = 1.0

    private let speedLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        l.textAlignment = .center
        l.text = "1.00×"
        return l
    }()

    // MARK: - Subtitle

    private let subtitleSlider: UISlider = {
        let s = UISlider()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.minimumValue = 0.5
        s.maximumValue = 3.0
        s.value = 1.0
        return s
    }()

    private let subtitleValueLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        l.textColor = .secondaryLabel
        l.textAlignment = .right
        l.text = "1.0×"
        return l
    }()

    // Subtitle delay
    private var currentSubtitleDelay: Double = 0.0
    private let subtitleDelayLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        l.textAlignment = .center
        l.text = "0.00s"
        return l
    }()

    // MARK: - Positioning

    /// Anchor rect in window coordinates; used to position the glass panel under the gear.
    var anchorRectInWindow: CGRect?
    private var didPositionPanel = false
    private var anchorInSelfCache: CGRect?
    private var isPresentingAnimation = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .clear
        setupContent()
    }

    // MARK: - Setup

    private func setupContent() {
        // Glass panel container (not full-screen) to ensure blur samples the video behind.
        let panel: UIVisualEffectView
        if #available(iOS 26.0, *) {
            panel = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.layer.cornerRadius = 22
        panel.clipsToBounds = true
        view.addSubview(panel)

        subtitleSlider.addTarget(self, action: #selector(subtitleSliderChanged(_:)), for: .valueChanged)

        let stack = UIStackView(arrangedSubviews: [
            makeSectionHeader("PLAYBACK"),
            makeSpeedRow(),
            makeSectionHeader("SUBTITLE"),
            makeSubtitleRow(),
            makeSubtitleDelayRow(),
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        stack.isLayoutMarginsRelativeArrangement = true
        let topInset: CGFloat = 12
        let bottomInset: CGFloat = 12
        let sideInset: CGFloat = 18
        stack.layoutMargins = UIEdgeInsets(top: topInset, left: sideInset, bottom: bottomInset, right: sideInset)
        panel.contentView.addSubview(stack)

        // Insets + headers + rows (44pt rows): speed + subtitle size + subtitle delay
        let totalHeight: CGFloat = topInset + 28 + 44 + 28 + 44 + 44 + bottomInset
        preferredContentSize = CGSize(width: 320, height: totalHeight)

        // Size constraints
        let widthC = panel.widthAnchor.constraint(equalToConstant: 320)
        let heightC = panel.heightAnchor.constraint(equalToConstant: totalHeight)
        // Position constraints (centerX relative to leading allows adjustable constant)
        let centerXC = panel.centerXAnchor.constraint(equalTo: view.leadingAnchor, constant: view.bounds.midX)
        let topC = panel.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
        NSLayoutConstraint.activate([widthC, heightC, centerXC, topC,
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor),
        ])

        self.panelCenterXConstraint = centerXC
        self.panelTopConstraint = topC

        // Dismiss on outside tap
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // Position later in viewDidLayoutSubviews when window/bounds are valid
        self._panel = panel
    }


    // MARK: - Section builders

    private func makeSectionHeader(_ title: String) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabel

        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = .separator

        container.addSubview(label)
        container.addSubview(line)

        let hairline = 1.0 / UIScreen.main.scale
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            line.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            line.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: hairline),
        ])
        return container
    }

    private func makeSpeedRow() -> UIView {
        let row = GlassStepperRow(iconSystemName: "clock", title: "Speed", valueLabel: speedLabel, valueWidth: 60)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.minusButton.addTarget(self, action: #selector(minusTapped), for: .touchUpInside)
        row.plusButton.addTarget(self, action: #selector(plusTapped), for: .touchUpInside)
        return row
    }

    private func makeSubtitleDelayRow() -> UIView {
        let row = GlassStepperRow(iconSystemName: "timer", title: "Delay", valueLabel: subtitleDelayLabel, valueWidth: 60)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.minusButton.addTarget(self, action: #selector(subDelayMinusTapped), for: .touchUpInside)
        row.plusButton.addTarget(self, action: #selector(subDelayPlusTapped), for: .touchUpInside)
        return row
    }

    private func makeSubtitleRow() -> UIView {
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let icon = UIImageView(image: UIImage(systemName: "textformat.size"))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Size"
        title.font = .systemFont(ofSize: 15, weight: .regular)
        title.textColor = .label

        row.addSubview(icon)
        row.addSubview(title)
        row.addSubview(subtitleSlider)
        row.addSubview(subtitleValueLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            subtitleValueLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            subtitleValueLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            subtitleValueLabel.widthAnchor.constraint(equalToConstant: 38),

            subtitleSlider.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            subtitleSlider.trailingAnchor.constraint(equalTo: subtitleValueLabel.leadingAnchor, constant: -8),
            subtitleSlider.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func makeGlassButton(systemName: String, action: Selector) -> UIVisualEffectView {
        let v: UIVisualEffectView
        if #available(iOS 26.0, *) {
            v = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            v = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 18 // match 36x36 circular button
        v.clipsToBounds = true
        let hairline = 1.0 / UIScreen.main.scale
        v.layer.borderWidth = hairline
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        b.setImage(UIImage(systemName: systemName, withConfiguration: cfg), for: .normal)
        b.tintColor = .label
        b.addTarget(self, action: action, for: .touchUpInside)
        v.contentView.addSubview(b)

        NSLayoutConstraint.activate([
            b.centerXAnchor.constraint(equalTo: v.contentView.centerXAnchor),
            b.centerYAnchor.constraint(equalTo: v.contentView.centerYAnchor),
        ])
        return v
    }

    // Keep references for positioning
    private weak var _panel: UIVisualEffectView?
    private var panelCenterXConstraint: NSLayoutConstraint?
    private var panelTopConstraint: NSLayoutConstraint?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionPanelIfNeeded(force: false)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Reposition to respect updated safe area (e.g., rotation, PiP changes)
        positionPanelIfNeeded(force: true)
    }

    private func positionPanelIfNeeded(force: Bool) {
        guard let panel = _panel else { return }
        if didPositionPanel && !force { return }
        let margin: CGFloat = 12
        let panelSize = panel.bounds.size

        var targetX = view.bounds.midX
        var targetY: CGFloat = margin
        var anchorInSelf: CGRect?
        if let anchor = anchorRectInWindow, let win = view.window {
            let inSelf = view.convert(anchor, from: win)
            anchorInSelf = inSelf
            targetX = inSelf.midX
            // Place above the gear: top of panel sits 8pt above the gear frame
            targetY = inSelf.minY - 8 - panelSize.height
        }

        // Constrain within safe bounds
        let safe = view.safeAreaInsets
        let minX = (safe.left + margin) + panelSize.width / 2
        let maxX = (view.bounds.width - safe.right - margin) - panelSize.width / 2
        let centerX = max(minX, min(maxX, targetX))

        let topMin = safe.top + margin
        let maxY = view.bounds.height - safe.bottom - margin - panelSize.height
        let originY = min(maxY, max(topMin, targetY))

        // Update constraints instead of fiddling with anchorPoint/center directly
        panelCenterXConstraint?.constant = centerX
        panelTopConstraint?.constant = originY
        view.layoutIfNeeded()

        anchorInSelfCache = anchorInSelf

        didPositionPanel = true
    }

    @objc private func backgroundTapped(_ gr: UITapGestureRecognizer) {
        guard let panel = _panel else { return }
        let pt = gr.location(in: view)
        if !panel.frame.contains(pt) { dismiss(animated: true) }
    }

    // MARK: - UIViewControllerTransitioningDelegate

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        isPresentingAnimation = true
        return self
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        isPresentingAnimation = false
        return self
    }

    // MARK: - UIViewControllerAnimatedTransitioning

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return isPresentingAnimation ? 0.22 : 0.18
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        if isPresentingAnimation {
            guard let toVC = transitionContext.viewController(forKey: .to) as? PlayerSettingsViewController else { return }
            let toView = toVC.view!
            toView.frame = container.bounds
            toView.backgroundColor = .clear
            container.addSubview(toView)
            toView.layoutIfNeeded()
            // Ensure panel is positioned before animating
            toVC.positionPanelIfNeeded(force: true)
            guard let panel = toVC._panel else { return }
            // Mimic UIMenu pop-in: subtle upward expansion with spring
            panel.alpha = 0
            panel.transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.94, y: 0.94)

            let animator = UIViewPropertyAnimator(duration: 0.22, dampingRatio: 0.85) {
                panel.alpha = 1
                panel.transform = .identity
            }
            animator.addCompletion { position in
                transitionContext.completeTransition(position == .end)
            }
            animator.startAnimation()
        } else {
            guard let fromVC = transitionContext.viewController(forKey: .from) as? PlayerSettingsViewController else { return }
            guard let panel = fromVC._panel else { return }
            // Dismiss: slight down-and-shrink with ease-in
            let animator = UIViewPropertyAnimator(duration: 0.16, curve: .easeIn) {
                panel.alpha = 0
                panel.transform = CGAffineTransform(translationX: 0, y: 6).scaledBy(x: 0.96, y: 0.96)
            }
            animator.addCompletion { position in
                transitionContext.completeTransition(position == .end)
            }
            animator.startAnimation()
        }
    }

    // MARK: - Public API

    func applyStoredSubtitleScale() {
        let scale = (UserDefaults.standard.object(forKey: "subtitleScale") as? Double) ?? 1.0
        subtitleSlider.value = Float(scale)
        updateSubtitleLabel(scale)
    }

    func applyStoredSubtitleDelay() {
        let delay = (UserDefaults.standard.object(forKey: "subtitleDelaySeconds") as? Double) ?? 0.0
        currentSubtitleDelay = clampSubtitleDelay(delay)
        updateSubtitleDelayLabel()
    }

    // Gestures settings are managed in the app Settings screen (SwiftUI), not here.

    func applyStoredSpeed() {
        let stored = (UserDefaults.standard.object(forKey: "playbackSpeed") as? Double) ?? 1.0
        currentSpeed = clampSpeed(stored)
        updateSpeedLabel()
    }

    // MARK: - Actions

    @objc private func minusTapped() {
        stepSpeed(by: -0.25)
    }

    @objc private func plusTapped() {
        stepSpeed(by: 0.25)
    }

    @objc private func subtitleSliderChanged(_ s: UISlider) {
        let rounded = (Double(s.value) * 10).rounded() / 10
        s.value = Float(rounded)
        updateSubtitleLabel(rounded)
        UserDefaults.standard.set(rounded, forKey: "subtitleScale")
        onSubtitleScaleChanged?(rounded)
    }

    private func updateSubtitleLabel(_ scale: Double) {
        subtitleValueLabel.text = String(format: "%.1f×", scale)
    }

    @objc private func subDelayMinusTapped() { stepSubtitleDelay(by: -0.25) }
    @objc private func subDelayPlusTapped() { stepSubtitleDelay(by: 0.25) }

    private func updateSubtitleDelayLabel() {
        let rounded = (currentSubtitleDelay * 100).rounded() / 100
        subtitleDelayLabel.text = String(format: "%.2fs", rounded)
    }

    private func stepSubtitleDelay(by delta: Double) {
        let stepped = ((currentSubtitleDelay + delta) * 4).rounded() / 4
        currentSubtitleDelay = clampSubtitleDelay(stepped)
        updateSubtitleDelayLabel()
        UserDefaults.standard.set(currentSubtitleDelay, forKey: "subtitleDelaySeconds")
        onSubtitleDelayChanged?(currentSubtitleDelay)
    }

    private func clampSubtitleDelay(_ value: Double) -> Double {
        return min(max(value, -20.0), 20.0)
    }

    private func updateSpeedLabel() {
        let rounded = (currentSpeed * 100).rounded() / 100
        speedLabel.text = String(format: "%.2f×", rounded)
    }

    private func stepSpeed(by delta: Double) {
        let stepped = ((currentSpeed + delta) * 4).rounded() / 4
        currentSpeed = clampSpeed(stepped)
        updateSpeedLabel()
        UserDefaults.standard.set(currentSpeed, forKey: "playbackSpeed")
        onSpeedChanged?(currentSpeed)
    }

    private func clampSpeed(_ value: Double) -> Double {
        return min(max(value, Self.minSpeed), Self.maxSpeed)
    }

    

    // MARK: - UIPopoverPresentationControllerDelegate

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        return .none
    }
}

    // MARK: - Reusable Glass Stepper Row

    final class GlassStepperRow: UIView {
        let iconView = UIImageView()
        let titleLabel = UILabel()
        let valueLabel: UILabel
        let minusButton = UIButton(type: .system)
        let plusButton = UIButton(type: .system)
        private let minusContainer = UIVisualEffectView()
        private let plusContainer = UIVisualEffectView()

        init(iconSystemName: String, title: String, valueLabel: UILabel, valueWidth: CGFloat) {
            self.valueLabel = valueLabel
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false

            // Left: icon + title
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.image = UIImage(systemName: iconSystemName)
            iconView.tintColor = .secondaryLabel
            iconView.contentMode = .scaleAspectFit

            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.text = title
            titleLabel.font = .systemFont(ofSize: 15, weight: .regular)
            titleLabel.textColor = .label

            // Right: - [value] + in glass
            configureGlassContainer(minusContainer)
            configureGlassContainer(plusContainer)

            let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            minusButton.translatesAutoresizingMaskIntoConstraints = false
            minusButton.setImage(UIImage(systemName: "minus", withConfiguration: cfg), for: .normal)
            minusButton.tintColor = .label
            plusButton.translatesAutoresizingMaskIntoConstraints = false
            plusButton.setImage(UIImage(systemName: "plus", withConfiguration: cfg), for: .normal)
            plusButton.tintColor = .label
            minusContainer.contentView.addSubview(minusButton)
            plusContainer.contentView.addSubview(plusButton)

            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            valueLabel.setContentHuggingPriority(.required, for: .horizontal)
            valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            addSubview(iconView)
            addSubview(titleLabel)
            let controlStack = UIStackView(arrangedSubviews: [minusContainer, valueLabel, plusContainer])
            controlStack.translatesAutoresizingMaskIntoConstraints = false
            controlStack.axis = .horizontal
            controlStack.alignment = .center
            controlStack.distribution = .fill
            controlStack.spacing = 4
            addSubview(controlStack)

            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 20),
                iconView.heightAnchor.constraint(equalToConstant: 20),

                titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

                minusContainer.widthAnchor.constraint(equalToConstant: 36),
                minusContainer.heightAnchor.constraint(equalToConstant: 36),
                plusContainer.widthAnchor.constraint(equalToConstant: 36),
                plusContainer.heightAnchor.constraint(equalToConstant: 36),

                valueLabel.widthAnchor.constraint(equalToConstant: valueWidth),

                controlStack.trailingAnchor.constraint(equalTo: trailingAnchor),
                controlStack.centerYAnchor.constraint(equalTo: centerYAnchor),
                controlStack.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

                minusButton.centerXAnchor.constraint(equalTo: minusContainer.contentView.centerXAnchor),
                minusButton.centerYAnchor.constraint(equalTo: minusContainer.contentView.centerYAnchor),
                plusButton.centerXAnchor.constraint(equalTo: plusContainer.contentView.centerXAnchor),
                plusButton.centerYAnchor.constraint(equalTo: plusContainer.contentView.centerYAnchor),
            ])
        }

        required init?(coder: NSCoder) { fatalError() }

        private func configureGlassContainer(_ v: UIVisualEffectView) {
            if #available(iOS 26.0, *) {
                v.effect = UIGlassEffect()
            } else {
                v.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
            }
            v.translatesAutoresizingMaskIntoConstraints = false
            v.layer.cornerRadius = 18
            v.clipsToBounds = true
            let hairline = 1.0 / UIScreen.main.scale
            v.layer.borderWidth = hairline
            v.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        }
    }
