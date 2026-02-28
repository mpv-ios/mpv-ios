import SwiftUI
import UIKit
import AVFoundation
import AVKit
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
            VStack {
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

    private let speedIndicatorLabel: UILabel = {
        let lbl = UILabel()
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.textColor = .white
        lbl.font = .systemFont(ofSize: 16, weight: .bold)
        lbl.textAlignment = .center
        lbl.backgroundColor = UIColor(white: 0.2, alpha: 0.8)
        lbl.layer.cornerRadius = 20
        lbl.clipsToBounds = true
        lbl.alpha = 0
        return lbl
    }()

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
        b.setImage(UIImage(systemName: "speaker.wave.2", withConfiguration: cfg), for: .normal)
        b.showsMenuAsPrimaryAction = true
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
    private var cachedPosition: Double = 0
    private var cachedDuration: Double = 0
    private var originalSpeed: Double = 1.0
    private var controlsVisible = true
    private var controlsHideWork: DispatchWorkItem?

    // MARK: Init

    init(url: URL, controls: PlayerControlsModel) {
        self.initialURL = url
        self.controls = controls
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        modalPresentationCapturesStatusBarAppearance = true

        setupLayout()
        setupGradient()
        setupActions()
        setupHoldGesture()

        do {
            try renderer.start()
            // Push subtitles above the progress bar (44pt bar + 8pt padding + safe area ≈ 80pt)
            renderer.setSubtitleMarginY(80)
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
        showControlsTemporarily()
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
    }

    deinit {
        pipController?.delegate = nil
        if pipController?.isPictureInPictureActive == true { pipController?.stopPictureInPicture() }
        pipController?.invalidate()
        renderer.stop()
        displayLayer.removeFromSuperlayer()
        NotificationCenter.default.removeObserver(self)
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
        videoContainer.addSubview(speedIndicatorLabel)
        videoContainer.addSubview(progressContainer)
        videoContainer.addSubview(mediaOptionsContainer)

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
        mediaOptionsContainer.addSubview(subtitleButton)
        mediaOptionsContainer.addSubview(audioButton)

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

            speedIndicatorLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            speedIndicatorLabel.centerXAnchor.constraint(equalTo: videoContainer.centerXAnchor),
            speedIndicatorLabel.widthAnchor.constraint(equalToConstant: 100),
            speedIndicatorLabel.heightAnchor.constraint(equalToConstant: 40),

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

            durationLabel.trailingAnchor.constraint(equalTo: progressContainer.trailingAnchor, constant: -14),
            durationLabel.centerYAnchor.constraint(equalTo: progressContainer.centerYAnchor),

            scrubber.leadingAnchor.constraint(equalTo: positionLabel.trailingAnchor, constant: 8),
            scrubber.trailingAnchor.constraint(equalTo: durationLabel.leadingAnchor, constant: -8),
            scrubber.centerYAnchor.constraint(equalTo: progressContainer.centerYAnchor),

            // Media options pill — trailing-aligned, sits just above the progress bar
            mediaOptionsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            mediaOptionsContainer.bottomAnchor.constraint(equalTo: progressContainer.topAnchor, constant: -8),
            mediaOptionsContainer.heightAnchor.constraint(equalToConstant: 44),
            mediaOptionsContainer.widthAnchor.constraint(equalToConstant: 96),

            mediaGlassView.topAnchor.constraint(equalTo: mediaOptionsContainer.topAnchor),
            mediaGlassView.leadingAnchor.constraint(equalTo: mediaOptionsContainer.leadingAnchor),
            mediaGlassView.trailingAnchor.constraint(equalTo: mediaOptionsContainer.trailingAnchor),
            mediaGlassView.bottomAnchor.constraint(equalTo: mediaOptionsContainer.bottomAnchor),

            subtitleButton.leadingAnchor.constraint(equalTo: mediaOptionsContainer.leadingAnchor, constant: 4),
            subtitleButton.centerYAnchor.constraint(equalTo: mediaOptionsContainer.centerYAnchor),
            subtitleButton.widthAnchor.constraint(equalToConstant: 44),
            subtitleButton.heightAnchor.constraint(equalToConstant: 44),

            audioButton.trailingAnchor.constraint(equalTo: mediaOptionsContainer.trailingAnchor, constant: -4),
            audioButton.centerYAnchor.constraint(equalTo: mediaOptionsContainer.centerYAnchor),
            audioButton.widthAnchor.constraint(equalToConstant: 44),
            audioButton.heightAnchor.constraint(equalToConstant: 44),
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(containerTapped))
        tap.delegate = self
        videoContainer.addGestureRecognizer(tap)
    }

    private func setupHoldGesture() {
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
        hold.minimumPressDuration = 0.5
        videoContainer.addGestureRecognizer(hold)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        videoContainer.addGestureRecognizer(pinch)
    }

    // MARK: Media Options Menus

    private func setupMediaOptionsButtons() {
        subtitleButton.menu = makeDeferredSubtitleMenu()
        audioButton.menu = makeDeferredAudioMenu()
    }

    private func makeDeferredSubtitleMenu() -> UIMenu {
        UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                var actions: [UIAction] = []
                let currentSub = self.renderer.getCurrentSubtitleTrack()
                let offAction = UIAction(
                    title: "Off",
                    image: currentSub == 0 ? UIImage(systemName: "checkmark") : nil
                ) { [weak self] _ in
                    self?.renderer.disableSubtitles()
                    UserDefaults.standard.set("off", forKey: "lastSubtitleLang")
                }
                actions.append(offAction)
                let tracks = self.renderer.getSubtitleTracks()
                for track in tracks {
                    let trackId = track["id"] as? Int ?? 0
                    let langCode = track["lang"] as? String
                    let displayLang = langCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                    let label = track["title"] as? String
                        ?? displayLang
                        ?? langCode
                        ?? "Track \(trackId)"
                    let isSelected = currentSub == trackId
                    let action = UIAction(
                        title: label,
                        image: isSelected ? UIImage(systemName: "checkmark") : nil
                    ) { [weak self] _ in
                        self?.renderer.setSubtitleTrack(trackId)
                        // Remember the lang code (or title as fallback) for future sessions
                        let key = langCode ?? label
                        UserDefaults.standard.set(key, forKey: "lastSubtitleLang")
                    }
                    actions.append(action)
                }
                completion(actions)
            }
        ])
    }

    private func makeDeferredAudioMenu() -> UIMenu {
        UIMenu(title: "Audio", image: UIImage(systemName: "speaker.wave.2"), children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                guard let self else { completion([]); return }
                var actions: [UIAction] = []
                let currentAudio = self.renderer.getCurrentAudioTrack()
                let tracks = self.renderer.getAudioTracks()
                for track in tracks {
                    let trackId = track["id"] as? Int ?? 0
                    let langCode = track["lang"] as? String
                    let displayLang = langCode.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
                    let label = track["title"] as? String
                        ?? displayLang
                        ?? langCode
                        ?? "Track \(trackId)"
                    let isSelected = currentAudio == trackId
                    let action = UIAction(
                        title: label,
                        image: isSelected ? UIImage(systemName: "checkmark") : nil
                    ) { [weak self] _ in self?.renderer.setAudioTrack(trackId) }
                    actions.append(action)
                }
                if actions.isEmpty {
                    actions.append(UIAction(title: "No audio tracks", attributes: .disabled) { _ in })
                }
                completion(actions)
            }
        ])
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
        showControlsTemporarily()
    }

    @objc private func skipForwardTapped() {
        renderer.seek(by: Double(controls.skipForward))
        showControlsTemporarily()
    }

    // MARK: - Stored settings

    private func applyStoredSettings() {
        let ud = UserDefaults.standard
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

    /// Converts an x position inside progressContainer to a playback time.
    private func scrubValue(forTouchX x: CGFloat) -> Float {
        let track = scrubber.convert(scrubber.trackRect(forBounds: scrubber.bounds), to: progressContainer)
        guard track.width > 0 else { return scrubber.value }
        let ratio = Float(max(0, min(1, (x - track.minX) / track.width)))
        return scrubber.minimumValue + ratio * (scrubber.maximumValue - scrubber.minimumValue)
    }

    @objc private func scrubberPanned(_ g: UIPanGestureRecognizer) {
        let x = g.location(in: progressContainer).x
        switch g.state {
        case .began:
            isSeeking = true
            controls.isScrubbing = true
            controlsHideWork?.cancel()
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
            isSeeking = false
            controls.isScrubbing = false
            renderer.seek(to: Double(v))  // precise seek on release
            showControlsTemporarily()
        default:
            break
        }
    }

    @objc private func scrubberTapped(_ g: UITapGestureRecognizer) {
        let v = scrubValue(forTouchX: g.location(in: progressContainer).x)
        scrubber.value = v
        positionLabel.text = formatTime(Double(v))
        renderer.seek(to: Double(v))
        showControlsTemporarily()
    }

    @objc private func containerTapped() {
        if controlsVisible { hideControls() } else { showControlsTemporarily() }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard g.state == .ended || g.state == .changed else { return }
        let wantsZoom = g.scale > 1.0
        guard wantsZoom != isZoomFill else { return }
        isZoomFill = wantsZoom
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        displayLayer.videoGravity = isZoomFill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()
        showControlsTemporarily()
    }

    // MARK: Hold-to-speed gesture

    @objc private func handleHold(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            originalSpeed = renderer.getSpeed()
            let stored = Double(UserDefaults.standard.float(forKey: "holdSpeedPlayer"))
            let target = stored > 0 ? stored : 2.0
            renderer.setSpeed(target)
            speedIndicatorLabel.text = String(format: "%.1fx", target)
            UIView.animate(withDuration: 0.2) { self.speedIndicatorLabel.alpha = 1 }
        case .ended, .cancelled:
            renderer.setSpeed(originalSpeed)
            UIView.animate(withDuration: 0.2) { self.speedIndicatorLabel.alpha = 0 }
        default: break
        }
    }

    // MARK: Controls visibility

    private func showControlsTemporarily() {
        controlsHideWork?.cancel()
        controlsVisible = true

        controls.isVisible = true
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
            self.controlsOverlayView.alpha = 1
            self.progressContainer.alpha = 1
            self.mediaOptionsContainer.alpha = 1
        }

        let work = DispatchWorkItem { [weak self] in self?.hideControls() }
        controlsHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func hideControls() {
        controlsHideWork?.cancel()
        controlsVisible = false

        controls.isVisible = false
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            self.controlsOverlayView.alpha = 0
            self.progressContainer.alpha = 0
            self.mediaOptionsContainer.alpha = 0
        }
    }

    // MARK: Helpers

    private func updatePlayPauseButton(isPaused: Bool) {
        DispatchQueue.main.async {
            self.controls.isPaused = isPaused
            self.showControlsTemporarily()
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
        }
    }

    func renderer(_ renderer: MPVLayerRenderer, didChangePause isPaused: Bool) {
        updatePlayPauseButton(isPaused: isPaused)
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
        guard UserDefaults.standard.bool(forKey: "rememberLastSubtitle") else { return }
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
    func renderer(_ renderer: MPVLayerRenderer, didSelectAudioOutput audioOutput: String) {}
}

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
