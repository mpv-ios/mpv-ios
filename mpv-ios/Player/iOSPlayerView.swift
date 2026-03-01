import SwiftUI
import UIKit
import AVFoundation
import AVKit
import MediaPlayer
import CoreMedia
import Combine

// MARK: - Player Controls Model

final class PlayerControlsModel: ObservableObject {
    @Published var isPaused: Bool = true
    @Published var isVisible: Bool = false
    @Published var isLoading: Bool = true
    /// True only until the renderer has become ready for the first time.
    /// Mid-playback buffering and seeks do NOT set this flag.
    @Published var isInitialLoading: Bool = true
    @Published var isScrubbing: Bool = false
    @Published var isVolumeHUDVisible: Bool = false

    @AppStorage("skipBackwardSeconds") var skipBack: Int = 10
    @AppStorage("skipForwardSeconds") var skipForward: Int = 10

    var onPlayPause: (() -> Void)?
    var onClose: (() -> Void)?
    var onPip: (() -> Void)?
    var onSkipBack: (() -> Void)?
    var onSkipForward: (() -> Void)?
}

// MARK: - Glass Circle Button Component

/// A reusable circular liquid-glass button.
/// Uses `.glassEffect(.clear.interactive())` — clear, untinted glass with no accent colour.
/// Falls back to `.ultraThinMaterial` on older OS.
struct GlassCircleButton: View {
    let symbol: String
    var size: CGFloat = 44
    var pointSize: CGFloat = 17
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: pointSize, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .glassEffect(.regular.interactive())
            .clipShape(Circle())
        } else {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: pointSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
            }
            .background(.ultraThinMaterial, in: Circle())
            .contentShape(Circle())
        }
    }
}

/// A plain circular button showing a spinning activity indicator (no glass background).
/// Tapping it triggers the given action (e.g. play/pause while buffering).
private struct BufferingCircleButton: View {
    var size: CGFloat = 90
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .scaleEffect(1.4)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

private struct ControlsOverlay: View {
    @ObservedObject var model: PlayerControlsModel

    var body: some View {
        ZStack {
            // Top bar — close + PiP
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    GlassCircleButton(symbol: "xmark") { model.onClose?() }
                    GlassCircleButton(symbol: "pip.enter") { model.onPip?() }
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                Spacer()
            }

            // Centre row — skip back / play-pause (or buffering spinner) / skip forward
            // Hidden only during the very first load; mid-playback buffering shows the spinner.
            if !model.isInitialLoading && !model.isScrubbing {
                HStack(spacing: 56) {
                    GlassCircleButton(symbol: "gobackward.\(model.skipBack)", size: 60, pointSize: 24) { model.onSkipBack?() }
                    if model.isLoading {
                        // Buffering: show a tappable spinner — tap still toggles play/pause
                        BufferingCircleButton(size: 90) { model.onPlayPause?() }
                    } else {
                        GlassCircleButton(
                            symbol: model.isPaused ? "play.fill" : "pause.fill",
                            size: 90,
                            pointSize: 38
                        ) { model.onPlayPause?() }
                    }
                    GlassCircleButton(symbol: "goforward.\(model.skipForward)", size: 60, pointSize: 24) { model.onSkipForward?() }
                }
            }
        }
        .opacity(model.isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: model.isVisible)
    }
}

// MARK: - Native Volume Slider (MPVolumeView)

private struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.semanticContentAttribute = .forceLeftToRight
        v.showsRouteButton = false
        v.showsVolumeSlider = true
        v.translatesAutoresizingMaskIntoConstraints = false
        // Style inner UISlider to match progress scrubber
        if let slider = v.subviews.compactMap({ $0 as? UISlider }).first {
            slider.semanticContentAttribute = .forceLeftToRight
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
            slider.setThumbImage(UIImage(), for: .normal)
            slider.setThumbImage(UIImage(), for: .highlighted)
        }
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.semanticContentAttribute = .forceLeftToRight
        // Re-apply styling in case subviews were recreated
        if let slider = uiView.subviews.compactMap({ $0 as? UISlider }).first {
            slider.semanticContentAttribute = .forceLeftToRight
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
            slider.setThumbImage(UIImage(), for: .normal)
            slider.setThumbImage(UIImage(), for: .highlighted)
        }
    }
}

// MARK: - Liquid Glass Pill Wrapper

private struct GlassPill<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26.0, *) {
            content()
                .frame(minWidth: 140)
                .background {
                    Capsule().glassEffect(.clear.interactive())
                }
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1 / UIScreen.main.scale)
                )
        } else {
            content()
                .frame(minWidth: 140)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1 / UIScreen.main.scale)
                )
        }
    }
}

// MARK: - SwiftUI Screen

struct iOSPlayerScreen: View {
    let url: URL
    @StateObject private var controls = PlayerControlsModel()

    var body: some View {
        ZStack {
            _PlayerViewControllerRepresentable(url: url, controls: controls)
                .ignoresSafeArea()
            ControlsOverlay(model: controls)
        }
    }
}

// MARK: - UIViewControllerRepresentable bridge

private struct _PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let url: URL
    let controls: PlayerControlsModel
    func makeUIViewController(context: Context) -> PlayerViewController {
        PlayerViewController(url: url, controls: controls)
    }
    func updateUIViewController(_ uiViewController: PlayerViewController, context: Context) {}
}

// MARK: - PlayerViewController

final class PlayerViewController: UIViewController {

    // MARK: Subviews

    private let videoContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .black
        v.clipsToBounds = true
        return v
    }()

    private let displayLayer = AVSampleBufferDisplayLayer()

    private let controlsOverlayView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        v.isUserInteractionEnabled = false
        return v
    }()

    private let loadingIndicator: UIActivityIndicatorView = {
        let v = UIActivityIndicatorView(style: .large)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.hidesWhenStopped = true
        v.color = .white
        v.alpha = 0
        return v
    }()

    private var isZoomFill = false

    private let speedIndicatorContainer: UIVisualEffectView = {
        let v: UIVisualEffectView
        if #available(iOS 26.0, *) {
            v = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            v = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 22
        v.clipsToBounds = true
        let hairline = 1.0 / UIScreen.main.scale
        v.layer.borderWidth = hairline
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        v.alpha = 0
        return v
    }()
    private let speedIndicatorLabel: UILabel = {
        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.textColor = .white
        lbl.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        lbl.textAlignment = .center
        return lbl
    }()

    private var speedIndicatorHideWorkItem: DispatchWorkItem?

    private let progressContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = .clear
        v.alpha = 0
        return v
    }()

    private let positionLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textColor = UIColor.white.withAlphaComponent(0.8)
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        l.text = "0:00"
        return l
    }()

    private let fileTitleLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textColor = .white
        l.font = .systemFont(ofSize: 20, weight: .semibold)
        l.numberOfLines = 1
        l.lineBreakMode = .byTruncatingTail
        l.alpha = 0
        return l
    }()

    private var showFileTitleEnabled: Bool {
        let ud = UserDefaults.standard
        return (ud.object(forKey: "showFileTitle") as? Bool) ?? true
    }

    private let durationLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.textColor = UIColor.white.withAlphaComponent(0.8)
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        l.textAlignment = .right
        l.text = "0:00"
        return l
    }()

    private let scrubber: UISlider = {
        let s = UISlider()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.minimumTrackTintColor = .white
        s.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
        s.setThumbImage(UIImage(), for: .normal)
        s.setThumbImage(UIImage(), for: .highlighted)
        s.contentVerticalAlignment = .center
        s.transform = CGAffineTransform(scaleX: 1.0, y: 0.9)
        s.isUserInteractionEnabled = false   // driven by pan/tap gesture below
        s.value = 0
        return s
    }()

    private let mediaOptionsContainer: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        return v
    }()
    private let volumePill = VolumePillView()

    // Removed: bottom mini progress (now a shared SwiftUI component used in Browse)

    private lazy var subtitleButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.tintColor = .white
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        b.setImage(UIImage(systemName: "captions.bubble", withConfiguration: cfg), for: .normal)
        b.showsMenuAsPrimaryAction = true
        return b
    }()

    private lazy var audioButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.tintColor = .white
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        b.setImage(UIImage(systemName: "waveform", withConfiguration: cfg), for: .normal)
        b.showsMenuAsPrimaryAction = true
        return b
    }()

    private lazy var gearButton: UIButton = {
        let b = UIButton(type: .system)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.tintColor = .white
        let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        b.setImage(UIImage(systemName: "gearshape", withConfiguration: cfg), for: .normal)
        b.addTarget(self, action: #selector(gearTapped), for: .touchUpInside)
        return b
    }()

    // MARK: Controls model

    private let controls: PlayerControlsModel

    // MARK: State

    private lazy var renderer: MPVLayerRenderer = {
        let r = MPVLayerRenderer(displayLayer: displayLayer)
        r.delegate = self
        return r
    }()

    private var pipController: PiPController?
    private let initialURL: URL
    private var isSeeking = false
    private var endSeekDelayWorkItem: DispatchWorkItem?
    private var wasPlayingBeforeScrub = false
    private var cachedPosition: Double = 0
    private var cachedDuration: Double = 0
    private var originalSpeed: Double = 1.0
    private var controlsVisible = true
    private var baseSubtitleScale: Double = 1.0
    private var baseSubtitleMarginY: Int = 80
    private var panStartY: CGFloat = 0
    private var startBrightness: CGFloat = 0
    private var startVolume: Float = 0
    private enum VerticalControlMode { case none, brightness, volume }
    private var controlPanMode: VerticalControlMode = .none
    private var brightnessIndicatorHideWorkItem: DispatchWorkItem?
    private let brightnessIndicator: UIVisualEffectView = {
        let v: UIVisualEffectView
        if #available(iOS 26.0, *) {
            v = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            v = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        v.layer.cornerRadius = 22
        v.clipsToBounds = true
        let hairline = 1.0 / UIScreen.main.scale
        v.layer.borderWidth = hairline
        v.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        v.alpha = 0
        return v
    }()
    private let brightnessIndicatorLabel: UILabel = {
        let l = UILabel()
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        l.textColor = .white
        l.textAlignment = .center
        l.text = "100%"
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }()
    private let brightnessIconView: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "sun.max.fill"))
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        return iv
    }()
    private let hiddenVolumeView: MPVolumeView = {
        let v = MPVolumeView(frame: .zero)
        v.alpha = 0.01 // keep in hierarchy to suppress system HUD
        v.isUserInteractionEnabled = false
        v.showsRouteButton = false
        v.showsVolumeSlider = true
        v.semanticContentAttribute = .forceLeftToRight
        return v
    }()

    // MARK: Init

    init(url: URL, controls: PlayerControlsModel) {
        self.initialURL = url
        self.controls = controls
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Volume-only HUD shown when controls are hidden and volume changes
    private var volumeHUDHideWorkItem: DispatchWorkItem?
    private var volumeObservation: NSKeyValueObservation?
    private var controlsAutoHideWorkItem: DispatchWorkItem?
    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        modalPresentationCapturesStatusBarAppearance = true

        setupLayout()
        setupGradient()
        setupActions()
        setupHoldGesture()
        setupSwipeGestures()

        do {
            try renderer.start()
            // Push subtitles above the progress bar (44pt bar + 8pt padding + safe area ≈ 80pt)
            baseSubtitleMarginY = 80
            renderer.setSubtitleMarginY(baseSubtitleMarginY)
            applyStoredSettings()
        } catch {
            print("[PlayerViewController] Failed to start renderer: \(error)")
        }

        pipController = PiPController(sampleBufferDisplayLayer: displayLayer)
        pipController?.delegate = self

        let preset = PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: [])
        renderer.load(url: initialURL, with: preset)

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)

        setupAudioSession()
        // Observe system volume so we can show the HUD when it changes
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.handleSystemVolumeChanged()
            }
        }
        showControls()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { PlayerOrientation.supported }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { PlayerOrientation.preferredPresentation }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PlayerOrientation.applyToScene(view.window?.windowScene)
        setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Save position for resume-where-left-off
        let shouldResume = (UserDefaults.standard.object(forKey: "resumePlayback") as? Bool) ?? true
        if shouldResume && cachedDuration > 0 {
            let resumeKey = "resume_\(initialURL.absoluteString)"
            // Clear if within 5s of the end (treat as finished)
            if cachedPosition < cachedDuration - 5 {
                UserDefaults.standard.set(cachedPosition, forKey: resumeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: resumeKey)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = videoContainer.bounds
        if let grad = controlsOverlayView.layer.sublayers?.first(where: { $0.name == "gradient" }) {
            grad.frame = controlsOverlayView.bounds
        }
        CATransaction.commit()
        updateSubtitleZoomAdaption()
    }

    deinit {
        pipController?.delegate = nil
        if pipController?.isPictureInPictureActive == true { pipController?.stopPictureInPicture() }
        pipController?.invalidate()
        renderer.stop()
        displayLayer.removeFromSuperlayer()
        volumeObservation?.invalidate()
        controlsAutoHideWorkItem?.cancel()
        volumeHUDHideWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        MPVNowPlayingManager.shared.cleanupRemoteCommands()
        MPVNowPlayingManager.shared.clear()
        MPVNowPlayingManager.shared.deactivateAudioSession()
    }

    // MARK: Layout

    private func setupLayout() {
        view.addSubview(videoContainer)
        displayLayer.frame = videoContainer.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        videoContainer.layer.addSublayer(displayLayer)

        videoContainer.addSubview(controlsOverlayView)
        videoContainer.addSubview(loadingIndicator)
        videoContainer.addSubview(speedIndicatorContainer)
        speedIndicatorContainer.contentView.addSubview(speedIndicatorLabel)
        videoContainer.addSubview(progressContainer)
        videoContainer.addSubview(mediaOptionsContainer)
        videoContainer.addSubview(brightnessIndicator)
        videoContainer.addSubview(fileTitleLabel)
        videoContainer.addSubview(volumePill)
        let brightStack = UIStackView(arrangedSubviews: [brightnessIconView, brightnessIndicatorLabel])
        brightStack.translatesAutoresizingMaskIntoConstraints = false
        brightStack.axis = .horizontal
        brightStack.alignment = .center
        brightStack.spacing = 4
        brightnessIndicator.contentView.addSubview(brightStack)

        // Button stack inside the media options pill
        let buttonStack = UIStackView(arrangedSubviews: [subtitleButton, audioButton, gearButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 0

        // Liquid glass background for the media options pill
        let mediaGlassView: UIVisualEffectView
        if #available(iOS 26.0, *) {
            mediaGlassView = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            mediaGlassView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        mediaGlassView.translatesAutoresizingMaskIntoConstraints = false
        mediaGlassView.layer.cornerRadius = 22
        mediaGlassView.clipsToBounds = true
        mediaOptionsContainer.insertSubview(mediaGlassView, at: 0)
        mediaOptionsContainer.addSubview(buttonStack)

        // Liquid glass background for the progress pill
        let progressGlassView: UIVisualEffectView
        if #available(iOS 26.0, *) {
            progressGlassView = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            progressGlassView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        }
        progressGlassView.translatesAutoresizingMaskIntoConstraints = false
        progressGlassView.layer.cornerRadius = 22
        progressGlassView.clipsToBounds = true
        progressContainer.insertSubview(progressGlassView, at: 0)
        progressContainer.addSubview(scrubber)
        progressContainer.addSubview(positionLabel)
        progressContainer.addSubview(durationLabel)

        NSLayoutConstraint.activate([
            videoContainer.topAnchor.constraint(equalTo: view.topAnchor),
            videoContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            controlsOverlayView.topAnchor.constraint(equalTo: videoContainer.topAnchor),
            controlsOverlayView.leadingAnchor.constraint(equalTo: videoContainer.leadingAnchor),
            controlsOverlayView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            controlsOverlayView.bottomAnchor.constraint(equalTo: videoContainer.bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor),

            speedIndicatorContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            speedIndicatorContainer.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            speedIndicatorContainer.heightAnchor.constraint(equalToConstant: 44),
            speedIndicatorContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            speedIndicatorLabel.leadingAnchor.constraint(equalTo: speedIndicatorContainer.contentView.leadingAnchor, constant: 14),
            speedIndicatorLabel.trailingAnchor.constraint(equalTo: speedIndicatorContainer.contentView.trailingAnchor, constant: -14),
            speedIndicatorLabel.centerYAnchor.constraint(equalTo: speedIndicatorContainer.contentView.centerYAnchor),

            progressContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            progressContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            progressContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            progressContainer.heightAnchor.constraint(equalToConstant: 44),

            progressGlassView.topAnchor.constraint(equalTo: progressContainer.topAnchor),
            progressGlassView.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor),
            progressGlassView.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor),
            progressGlassView.bottomAnchor.constraint(equalTo: progressContainer.bottomAnchor),

            positionLabel.leadingAnchor.constraint(equalTo: progressContainer.leadingAnchor, constant: 14),
            positionLabel.centerYAnchor.constraint(equalTo: progressContainer.centerYAnchor),

            // File title — above progress bar, left-aligned
            fileTitleLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            fileTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            fileTitleLabel.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -6),

            durationLabel.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: -14),
            durationLabel.centerYAnchor.constraint(equalTo: progressContainer.centerYAnchor),

            scrubber.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 8),
            scrubber.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            scrubber.centerYAnchor.constraint(equalTo: progressContainer.centerYAnchor),
            scrubber.heightAnchor.constraint(equalToConstant: 20),

            // Media options pill — trailing-aligned, sits just above the progress bar
            mediaOptionsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            mediaOptionsContainer.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -8),
            mediaOptionsContainer.heightAnchor.constraint(equalToConstant: 44),
            mediaOptionsContainer.widthAnchor.constraint(equalToConstant: 140),

            mediaGlassView.topAnchor.constraint(equalTo: mediaOptionsContainer.topAnchor),
            mediaGlassView.leadingAnchor.constraint(equalTo: mediaOptionsContainer.leadingAnchor),
            mediaGlassView.trailingAnchor.constraint(equalTo: mediaOptionsContainer.trailingAnchor),
            mediaGlassView.bottomAnchor.constraint(equalTo: mediaOptionsContainer.bottomAnchor),

            buttonStack.topAnchor.constraint(equalTo: mediaOptionsContainer.topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: mediaOptionsContainer.bottomAnchor),
            buttonStack.leadingAnchor.constraint(equalTo: mediaOptionsContainer.leadingAnchor, constant: 4),
            buttonStack.trailingAnchor.constraint(equalTo: mediaOptionsContainer.trailingAnchor, constant: -4),

            // Brightness indicator — centered horizontally, above play button
            brightnessIndicator.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            brightnessIndicator.centerYAnchor.constraint(equalTo: videoContainer.centerYAnchor, constant: -90),
            brightnessIndicator.heightAnchor.constraint(equalToConstant: 44),
            brightnessIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            brightStack.leadingAnchor.constraint(equalTo: brightnessIndicator.contentView.leadingAnchor, constant: 10),
            brightStack.trailingAnchor.constraint(equalTo: brightnessIndicator.contentView.trailingAnchor, constant: -10),
            brightStack.centerYAnchor.constraint(equalTo: brightnessIndicator.contentView.centerYAnchor),
            brightnessIconView.widthAnchor.constraint(equalToConstant: 16),
            brightnessIconView.heightAnchor.constraint(equalToConstant: 16),
            brightnessIndicatorLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),

            // Volume pill — top-right, align trailing with media options pill (-12) to form a clean vertical stack
            volumePill.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            volumePill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            volumePill.heightAnchor.constraint(equalToConstant: 44),
            volumePill.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    private func setupGradient() {
        let grad = CAGradientLayer()
        grad.name = "gradient"
        grad.frame = view.bounds
        grad.colors = [
            UIColor.black.withAlphaComponent(0.55).cgColor,
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.65).cgColor,
        ]
        grad.locations = [0, 0.25, 0.65, 1]
        controlsOverlayView.layer.insertSublayer(grad, at: 0)
        controlsOverlayView.isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    // MARK: Actions

    private func setupActions() {
        controls.onPlayPause = { [weak self] in self?.playPauseTapped() }
        controls.onClose = { [weak self] in self?.closeTapped() }
        controls.onPip = { [weak self] in self?.pipTapped() }
        controls.onSkipBack = { [weak self] in self?.skipBackwardTapped() }
        controls.onSkipForward = { [weak self] in self?.skipForwardTapped() }

        let scrubPan = UIPanGestureRecognizer(target: self, action: #selector(scrubberPanned(_:)))
        scrubPan.maximumNumberOfTouches = 1
        let scrubTap = UITapGestureRecognizer(target: self, action: #selector(scrubberTapped(_:)))
        progressContainer.addGestureRecognizer(scrubPan)
        progressContainer.addGestureRecognizer(scrubTap)

        setupMediaOptionsButtons()

        // Volume gestures handled internally by VolumePillView

        let tap = UITapGestureRecognizer(target: self, action: #selector(containerTapped))
        tap.delegate = self
        videoContainer.addGestureRecognizer(tap)

        // Set file title from current URL and initial visibility
        fileTitleLabel.text = displayName(for: initialURL)
        fileTitleLabel.alpha = showFileTitleEnabled ? 1 : 0

        // Wire up Now Playing remote commands
        MPVNowPlayingManager.shared.setupRemoteCommands(
            playHandler:   { [weak self] in self?.renderer.play() },
            pauseHandler:  { [weak self] in self?.renderer.pausePlayback() },
            toggleHandler: { [weak self] in self?.playPauseTapped() },
            seekHandler:   { [weak self] time in self?.renderer.seek(to: time) },
            skipForward:   { [weak self] interval in
                guard let self else { return }
                self.renderer.seek(to: self.cachedPosition + interval)
            },
            skipBackward: { [weak self] interval in
                guard let self else { return }
                self.renderer.seek(to: max(0, self.cachedPosition - interval))
            }
        )
        MPVNowPlayingManager.shared.setMetadata(
            title: displayName(for: initialURL),
            artist: nil, albumTitle: nil, artworkUrl: nil
        )
    }

    // Volume gestures are encapsulated in VolumePillView

    private func setupHoldGesture() {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.5
        hold.delegate = self
        videoContainer.addGestureRecognizer(hold)

        let pinchEnabled = (UserDefaults.standard.object(forKey: "enablePinchZoom") as? Bool) ?? true
        if pinchEnabled {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            videoContainer.addGestureRecognizer(pinch)
        }
    }

    private func setupSwipeGestures() {
        // Hidden volume view for programmatic volume changes
        view.addSubview(hiddenVolumeView)
        hiddenVolumeView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hiddenVolumeView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 0),
            hiddenVolumeView.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            hiddenVolumeView.widthAnchor.constraint(equalToConstant: 1),
            hiddenVolumeView.heightAnchor.constraint(equalToConstant: 1),
        ])

        let controlPan = UIPanGestureRecognizer(target: self, action: #selector(handleControlPan(_:)))
        controlPan.maximumNumberOfTouches = 1
        controlPan.delegate = self
        videoContainer.addGestureRecognizer(controlPan)
    }

    // MARK: Media Options Menus

    private func setupMediaOptionsButtons() {
        subtitleButton.menu = MediaOptionsMenuBuilder.makeSubtitleMenu(renderer: renderer)
        audioButton.menu = MediaOptionsMenuBuilder.makeAudioMenu(renderer: renderer)
    }

    // MARK: Settings Panel
    @objc private func gearTapped() {
        let vc = PlayerSettingsViewController()
        vc.onSpeedChanged = { [weak self] speed in
            self?.renderer.setSpeed(speed)
        }
        vc.onSubtitleScaleChanged = { [weak self] scale in
            guard let self else { return }
            // Treat the gear's scale as the user-selected base; adapt on top when zoomed
            self.baseSubtitleScale = scale
            self.updateSubtitleZoomAdaption()
        }
        vc.onSubtitleDelayChanged = { [weak self] delay in
            self?.renderer.setSubtitleDelay(delay)
        }
        vc.onSubtitlePositionChanged = { [weak self] uiPos in
            // UI: 0=bottom..100=top -> mpv: 0=top..100=bottom
            let mpvPos = max(0, min(100, 100 - uiPos))
            self?.renderer.setSubtitlePosition(mpvPos)
        }
        definesPresentationContext = true
        vc.modalPresentationStyle = .custom
        vc.transitioningDelegate = vc
        vc.loadViewIfNeeded()
        vc.applyStoredSpeed()
        vc.applyStoredSubtitleScale()
        vc.applyStoredSubtitlePosition()
        vc.applyStoredSubtitleDelay()
        // Anchor under the gear
        if let windowRect = gearButton.superview?.convert(gearButton.frame, to: nil) {
            vc.anchorRectInWindow = windowRect
        }
        present(vc, animated: true)
    }

    // MARK: Button handlers

    @objc private func playPauseTapped() {
        if renderer.isPausedState {
            renderer.play()
            updatePlayPauseButton(isPaused: false)
        } else {
            renderer.pausePlayback()
            updatePlayPauseButton(isPaused: true)
        }
    }

    @objc private func skipBackwardTapped() {
        renderer.seek(by: -Double(controls.skipBack))
    }

    @objc private func skipForwardTapped() {
        renderer.seek(by: Double(controls.skipForward))
    }

    // MARK: - Stored settings

    private func applyStoredSettings() {
        let ud = UserDefaults.standard
        // Subtitle scale
        let rawScale = (UserDefaults.standard.object(forKey: "subtitleScale") as? Double) ?? 1.0
        let clampedScale = min(max(rawScale, 0.5), 2.5)
        baseSubtitleScale = clampedScale
        renderer.setSubtitleScale(clampedScale)
        // Subtitle position UI: 0=bottom..100=top (slider)
        let uiPos = (ud.object(forKey: "subtitlePosition") as? Int) ?? 0
        let mpvPos = max(0, min(100, 100 - uiPos))
        renderer.setSubtitlePosition(mpvPos)
        // Keep horizontal centered by default
        renderer.setSubtitleAlignX("center")
        // Hardware decoding (default on)
        let hwDecoding = (ud.object(forKey: "hardwareDecoding") as? Bool) ?? true
        #if !targetEnvironment(simulator)
        renderer.setHardwareDecoding(hwDecoding)
        #endif
        // Deinterlace (default off)
        if ud.bool(forKey: "deinterlace") {
            renderer.setDeinterlace(true)
        }
        // Cache size (default 150 MB)
        let cacheRaw = ud.integer(forKey: "networkCacheSize")
        let cache = cacheRaw > 0 ? cacheRaw : 150
        renderer.setCacheSize(megabytes: cache)
        // User-Agent
        if let agent = ud.string(forKey: "networkUserAgent"), !agent.isEmpty {
            renderer.setUserAgent(agent)
        }
    }

    @objc private func closeTapped() {
        pipController?.delegate = nil
        if pipController?.isPictureInPictureActive == true { pipController?.stopPictureInPicture() }
        renderer.stop()
        if presentingViewController != nil {
            dismiss(animated: true)
        } else {
            view.window?.rootViewController?.dismiss(animated: true)
        }
    }

    @objc private func pipTapped() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // PiP requires an exclusive playback session — do NOT use .mixWithOthers
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            print("[PlayerViewController] AVAudioSession setup failed: \(error)")
        }
    }

    private var lastLiveScrubTime: TimeInterval = 0
    private let liveScrubInterval: TimeInterval = 1.0 / 15  // ~15fps

    /// Generic slider mapping: map a touch X in a container to a UISlider value.
    private func computeSliderValue(_ slider: UISlider, in container: UIView, touchX x: CGFloat) -> Float {
        let trackInSlider = slider.trackRect(forBounds: slider.bounds)
        let track = slider.convert(trackInSlider, to: container)
        guard track.width > 0 else { return slider.value }
        let ratio = Float(max(0, min(1, (x - track.minX) / track.width)))
        return slider.minimumValue + ratio * (slider.maximumValue - slider.minimumValue)
    }

    /// Converts an x position inside progressContainer to a playback time.
    private func scrubValue(forTouchX x: CGFloat) -> Float {
        return computeSliderValue(scrubber, in: progressContainer, touchX: x)
    }

    @objc private func scrubberPanned(_ g: UIPanGestureRecognizer) {
        let x = g.location(in: progressContainer).x
        switch g.state {
        case .began:
            endSeekDelayWorkItem?.cancel()
            isSeeking = true
            controls.isScrubbing = true
            // Pause playback while scrubbing to avoid UI fighting with advancing playback
            wasPlayingBeforeScrub = !renderer.isPausedState
            if wasPlayingBeforeScrub { renderer.pausePlayback() }
            fallthrough
        case .changed:
            let v = scrubValue(forTouchX: x)
            scrubber.value = v
            positionLabel.text = formatTime(Double(v))
            // Throttle live seeks to ~15fps to avoid flooding mpv
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastLiveScrubTime >= liveScrubInterval {
                lastLiveScrubTime = now
                renderer.seekFast(to: Double(v))
            }
        case .ended, .cancelled:
            let v = scrubValue(forTouchX: x)
            scrubber.value = v
            controls.isScrubbing = false
            renderer.seek(to: Double(v))  // precise seek on release
            // Delay clearing isSeeking briefly to avoid jitter from in-flight updates
            endSeekDelayWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.isSeeking = false }
            endSeekDelayWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            // Resume playback if it was playing before scrubbing
            if wasPlayingBeforeScrub { renderer.play() }
        default:
            break
        }
    }

    @objc private func scrubberTapped(_ g: UITapGestureRecognizer) {
        let v = scrubValue(forTouchX: g.location(in: progressContainer).x)
        scrubber.value = v
        positionLabel.text = formatTime(Double(v))
        renderer.seek(to: Double(v))
    }

    @objc private func containerTapped() {
        if controlsVisible { hideControls() } else { showControls() }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let pinchEnabled = (UserDefaults.standard.object(forKey: "enablePinchZoom") as? Bool) ?? true
        guard pinchEnabled else { return }
        guard g.state == .ended || g.state == .changed else { return }
        let wantsZoom = g.scale > 1.0
        guard wantsZoom != isZoomFill else { return }
        isZoomFill = wantsZoom
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        displayLayer.videoGravity = isZoomFill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()
        updateSubtitleZoomAdaption()
    }

    // MARK: Hold-to-speed gesture

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        let enabled = (UserDefaults.standard.object(forKey: "enableHoldSpeed") as? Bool) ?? true
        guard enabled else { return }
        switch g.state {
        case .began:
            originalSpeed = renderer.getSpeed()
            let stored = Double(UserDefaults.standard.float(forKey: "holdSpeedPlayer"))
            let target = stored > 0 ? stored : 2.0
            renderer.setSpeed(target)
            showSpeedIndicator(text: String(format: "%.1fx", target), autoHideAfter: 1.0)
        case .ended, .cancelled:
            renderer.setSpeed(originalSpeed)
            speedIndicatorHideWorkItem?.cancel()
            speedIndicatorHideWorkItem = nil
            UIView.animate(withDuration: 0.2) { self.speedIndicatorContainer.alpha = 0 }
        default: break
        }
    }

    @objc private func handleControlPan(_ g: UIPanGestureRecognizer) {
        let loc = g.location(in: videoContainer)
        let leftThird = loc.x <= videoContainer.bounds.width * 0.33
        let rightThird = loc.x >= videoContainer.bounds.width * 0.67
        switch g.state {
        case .began:
            panStartY = loc.y
            let brightEnabled = (UserDefaults.standard.object(forKey: "enableSwipeBrightness") as? Bool) ?? true
            let volEnabled = (UserDefaults.standard.object(forKey: "enableSwipeVolume") as? Bool) ?? true
            if brightEnabled && leftThird {
                controlPanMode = .brightness
                startBrightness = UIScreen.main.brightness
                showBrightnessIndicator(percent: Int(round(startBrightness * 100)))
            } else if volEnabled && rightThird {
                controlPanMode = .volume
                if let slider = hiddenVolumeView.subviews.compactMap({ $0 as? UISlider }).first {
                    startVolume = slider.value
                } else {
                    controlPanMode = .none
                }
            } else {
                controlPanMode = .none
            }
        case .changed:
            let dy = panStartY - loc.y
            // Map roughly one full upward swipe (full view height) to a full-range change
            let sensitivity = max(100, videoContainer.bounds.height)
            switch controlPanMode {
            case .brightness:
                var newVal = startBrightness + (dy / sensitivity)
                newVal = max(0.0, min(1.0, newVal))
                UIScreen.main.brightness = newVal
                showBrightnessIndicator(percent: Int(round(newVal * 100)))
            case .volume:
                guard let slider = hiddenVolumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
                var newVal = startVolume + Float(dy / sensitivity)
                newVal = max(0.0, min(1.0, newVal))
                slider.value = newVal
                slider.sendActions(for: .valueChanged)
                if !controlsVisible { showVolumeHUD(autoHideAfter: 0.8) }
            case .none:
                break
            }
        default:
            if controlPanMode == .brightness {
                showBrightnessIndicator(percent: Int(round(UIScreen.main.brightness * 100)), autoHideAfter: 0.6)
            }
            controlPanMode = .none
        }
    }

    private func showBrightnessIndicator(percent: Int, autoHideAfter seconds: TimeInterval? = nil) {
        brightnessIndicatorLabel.text = "\(percent)%"
        UIView.animate(withDuration: 0.15) { self.brightnessIndicator.alpha = 1 }
        brightnessIndicatorHideWorkItem?.cancel()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                UIView.animate(withDuration: 0.2) { self.brightnessIndicator.alpha = 0 }
            }
            brightnessIndicatorHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func handleSystemVolumeChanged() {
        if !controlsVisible { showVolumeHUD(autoHideAfter: 1.2) }
        volumePill.syncToSystemVolume()
    }

    private func showVolumeHUD(autoHideAfter seconds: TimeInterval) {
        UIView.animate(withDuration: 0.15) { self.volumePill.alpha = 1 }
        volumeHUDHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.controlsVisible else { return }
            UIView.animate(withDuration: 0.2) { self.volumePill.alpha = 0 }
        }
        volumeHUDHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func showSpeedIndicator(text: String, autoHideAfter seconds: TimeInterval) {
        speedIndicatorLabel.text = text
        UIView.animate(withDuration: 0.2) { self.speedIndicatorContainer.alpha = 1 }
        speedIndicatorHideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 0.2) { self.speedIndicatorContainer.alpha = 0 }
        }
        speedIndicatorHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: Controls visibility

    private func showControls() {
        controlsVisible = true
        controls.isVisible = true
        volumeHUDHideWorkItem?.cancel()
        volumeHUDHideWorkItem = nil
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            self.controlsOverlayView.alpha = 1
            self.progressContainer.alpha = 1
            self.mediaOptionsContainer.alpha = 1
            self.volumePill.alpha = 1
            self.fileTitleLabel.alpha = self.showFileTitleEnabled ? 1 : 0
        }
    }

    private func hideControls() {
        controlsVisible = false

        controls.isVisible = false
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            self.controlsOverlayView.alpha = 0
            self.progressContainer.alpha = 0
            self.mediaOptionsContainer.alpha = 0
            self.volumePill.alpha = 0
            self.fileTitleLabel.alpha = 0
        }
    }

    // MARK: Helpers

    private func updatePlayPauseButton(isPaused: Bool) {
        DispatchQueue.main.async {
            self.controls.isPaused = isPaused
        }
    }

    private func animateTap(_ button: UIButton) {
        UIView.animate(withDuration: 0.1, delay: 0, options: .curveEaseOut) {
            button.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        } completion: { _ in
            UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseIn) {
                button.transform = .identity
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let t = Int(round(seconds))
        let s = t % 60; let m = (t / 60) % 60; let h = t / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Apply base subtitle scale and margin; no auto adjustments.
    private func updateSubtitleZoomAdaption() {
        renderer.setSubtitleScale(baseSubtitleScale)
        renderer.setSubtitleMarginY(baseSubtitleMarginY)
    }

    private func displayName(for url: URL) -> String {
        if url.isFileURL, let name = (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName, !name.isEmpty {
            return name
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let last = comps?.url?.lastPathComponent ?? url.lastPathComponent
        let base = (last as NSString).deletingPathExtension
        return (base.removingPercentEncoding ?? base).isEmpty ? url.absoluteString : (base.removingPercentEncoding ?? base)
    }

    @objc private func userDefaultsChanged() {
        DispatchQueue.main.async {
            self.fileTitleLabel.alpha = (self.controlsVisible && self.showFileTitleEnabled) ? 1 : 0
            // Update base subtitle scale if changed in Settings and re-apply adaption
            if let newBase = UserDefaults.standard.object(forKey: "subtitleScale") as? Double {
                self.baseSubtitleScale = min(max(newBase, 0.5), 2.5)
                self.updateSubtitleZoomAdaption()
            }
            // Ignoring sub-use-margins by request
        }
    }

    // MARK: Background / Foreground

    @objc private func appDidEnterBackground() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let pip = self.pipController else { return }
            if pip.isPictureInPicturePossible, !pip.isPictureInPictureActive {
                pip.startPictureInPicture()
            }
        }
    }

    @objc private func appWillEnterForeground() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let pip = self.pipController, pip.isPictureInPictureActive {
                pip.stopPictureInPicture()
            }
            PlayerOrientation.applyToScene(self.view.window?.windowScene)
            self.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension PlayerViewController: UIGestureRecognizerDelegate {
    /// Prevent the container tap from swallowing touches destined for buttons/controls.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Allow pinch + tap/hold to coexist
        return gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }

    /// Never require system gestures (home bar, edge swipes) to fail before our gestures
    /// can begin — this prevents the "System gesture gate timed out" log warning.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return touch.view is UIControl == false
    }
}

// MARK: - MPVLayerRendererDelegate

extension PlayerViewController: MPVLayerRendererDelegate {
    func renderer(_ renderer: MPVLayerRenderer, didUpdatePosition position: Double, duration: Double, cacheSeconds: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isSeeking else { return }
            self.cachedPosition = position
            self.cachedDuration = duration
            self.scrubber.minimumValue = 0
            self.scrubber.maximumValue = Float(max(duration, 1))
            self.scrubber.value = Float(position)
            self.positionLabel.text = self.formatTime(position)
            self.durationLabel.text = self.formatTime(duration)
            self.pipController?.setCurrentTimeFromSeconds(position, duration: duration)
            // Mini progress is handled in Browse via a SwiftUI component.
            MPVNowPlayingManager.shared.updatePlayback(
                position: position, duration: duration, isPlaying: !renderer.isPausedState)
        }
    }

    func renderer(_ renderer: MPVLayerRenderer, didChangePause isPaused: Bool) {
        updatePlayPauseButton(isPaused: isPaused)
        MPVNowPlayingManager.shared.updatePlayback(
            position: cachedPosition, duration: cachedDuration, isPlaying: !isPaused)
        DispatchQueue.main.async { [weak self] in
            self?.pipController?.setPlaybackRate(isPaused ? 0 : 1)
            self?.pipController?.updatePlaybackState()
        }
    }

    func renderer(_ renderer: MPVLayerRenderer, didChangeLoading isLoading: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controls.isLoading = isLoading
            // The UIKit spinner only covers the very first load; mid-playback
            // buffering is represented by BufferingCircleButton in the SwiftUI overlay.
            if self.controls.isInitialLoading {
                if isLoading {
                    self.loadingIndicator.alpha = 1
                    self.loadingIndicator.startAnimating()
                } else {
                    self.loadingIndicator.stopAnimating()
                    self.loadingIndicator.alpha = 0
                }
            }
            if !isLoading {
                self.updatePlayPauseButton(isPaused: self.renderer.isPausedState)
            }
        }
    }

    func renderer(_ renderer: MPVLayerRenderer, didBecomeReadyToSeek: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Stop the UIKit spinner immediately — from here on the SwiftUI
            // overlay handles any buffering indicator.
            self.loadingIndicator.stopAnimating()
            self.loadingIndicator.alpha = 0
            self.controls.isInitialLoading = false
        }
        let ud = UserDefaults.standard
        // Apply default playback speed
        let speed = (ud.object(forKey: "defaultSpeed") as? Double) ?? 1.0
        if speed != 1.0 { renderer.setSpeed(speed) }
        // Resume where left off
        let shouldResume = (ud.object(forKey: "resumePlayback") as? Bool) ?? true
        if shouldResume {
            let resumeKey = "resume_\(initialURL.absoluteString)"
            let saved = ud.double(forKey: resumeKey)
            if saved > 5 { renderer.seek(to: saved) }
        }
    }
    func renderer(_ renderer: MPVLayerRenderer, didBecomeTracksReady: Bool) {
        let saved = UserDefaults.standard.string(forKey: "lastSubtitleLang")
        guard let saved else { return }
        if saved == "off" {
            renderer.disableSubtitles()
            return
        }
        // Find a track whose lang code or title matches the saved value
        let tracks = renderer.getSubtitleTracks()
        if let match = tracks.first(where: { ($0["lang"] as? String) == saved }) {
            let trackId = match["id"] as? Int ?? 0
            renderer.setSubtitleTrack(trackId)
        } else if let match = tracks.first(where: { ($0["title"] as? String) == saved }) {
            let trackId = match["id"] as? Int ?? 0
            renderer.setSubtitleTrack(trackId)
        }
    }

    func renderer(_ renderer: MPVLayerRenderer, didSelectAudioOutput audioOutput: String) {
        // MPV's AudioUnit init can displace our audio session registration.
        // Re-activate here so iOS re-associates this app as the Now Playing source,
        // then force an immediate Now Playing write regardless of the throttle.
        MPVNowPlayingManager.shared.activateAudioSession()
        MPVNowPlayingManager.shared.forceRefresh()
    }}

// MARK: - Subtitle horizontal shift helper

// Horizontal subtitle shifting disabled: using centered alignment only.

// MARK: - PiPControllerDelegate

extension PlayerViewController: PiPControllerDelegate {
    func pipController(_ controller: PiPController, willStartPictureInPicture: Bool) {}
    func pipController(_ controller: PiPController, didStartPictureInPicture: Bool) {
        pipController?.updatePlaybackState()
    }
    func pipController(_ controller: PiPController, willStopPictureInPicture: Bool) {}
    func pipController(_ controller: PiPController, didStopPictureInPicture: Bool) {}
    func pipController(_ controller: PiPController, restoreUserInterfaceForPictureInPictureStop completionHandler: @escaping (Bool) -> Void) {
        if presentedViewController != nil {
            dismiss(animated: true) { completionHandler(true) }
        } else {
            completionHandler(true)
        }
    }
    func pipControllerPlay(_ controller: PiPController) { renderer.play() }
    func pipControllerPause(_ controller: PiPController) { renderer.pausePlayback() }
    func pipController(_ controller: PiPController, skipByInterval interval: CMTime) {
        let seconds = CMTimeGetSeconds(interval)
        renderer.seek(to: max(0, cachedPosition + seconds))
        pipController?.updatePlaybackState()
    }
    func pipControllerIsPlaying(_ controller: PiPController) -> Bool { !renderer.isPausedState }
    func pipControllerDuration(_ controller: PiPController) -> Double { cachedDuration }
    func pipControllerCurrentPosition(_ controller: PiPController) -> Double { cachedPosition }
}
