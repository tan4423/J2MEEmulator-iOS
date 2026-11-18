//
//  GameViewController.swift
//  J2MEEmulator
//
//  Runs a single J2ME MIDlet. Presented modally with zoom transition.
//  Layout mode determines the arrangement of screen and controls.
//

import UIKit

// MARK: - Layout mode (extensible for future layouts)

enum GameLayoutMode {
    case portrait
    case ngage      // Landscape: D-pad left, screen center, numpad right
    // Future: .classic   — Portrait: screen top, keyboard bottom
    // Future: .fullscreen — Landscape: screen fills, overlay controls
}

// MARK: - GameViewController

class GameViewController: UIViewController {

    let jarPath: String
    let appName: String
    let appIcon: UIImage
    let canvasWidth: Int
    let canvasHeight: Int
    let render3dScale: Int
    let fpsLimit: Int
    let layoutMode: GameLayoutMode

    private let emulatorView = EmulatorView()
    private let glowContainer = UIView()
    private let glowContentView = UIView()
    private lazy var formView = FormView()
    private lazy var listView = J2MEListView()
    private let backButton = UIButton(type: .system)
    private let lskButton = UIButton(type: .system)
    private let rskButton = UIButton(type: .system)
    private let softKeyHaptic = UIImpactFeedbackGenerator(style: .light)
    private(set) var placeholderIconView: UIImageView?

    // Controls — created based on layoutMode
    private var joystickView: JoystickView?
    private var numpadView: NumpadView?
    private enum PadMode { case directions, numbers, hidden }
    private var padMode: PadMode = .directions
    private var directionalPad: UIStackView?
    private var portraitPanel: UIView?
    private var portraitControlsHeight: NSLayoutConstraint?
    private var portraitPadBottomPins: [NSLayoutConstraint] = []
    private let screenMenu = UIButton(type: .system)
    private var blackout: UIButton?
    private var blackoutScreen: UIScreen?
    private var previousBrightness: CGFloat?
    private var heldDirections: Set<Int32> = []
    private var directionTimers: [Int32: Timer] = [:]

    init(jarPath: String, appName: String, appIcon: UIImage,
         canvasWidth: Int = 240, canvasHeight: Int = 320,
         render3dScale: Int = 3, fpsLimit: Int = 0,
         layoutMode: GameLayoutMode = .portrait) {
        self.jarPath = jarPath
        self.appName = appName
        self.appIcon = appIcon
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.render3dScale = render3dScale
        self.fpsLimit = fpsLimit
        self.layoutMode = layoutMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // The render target is weak. An older controller must not clear the
        // render target that a newer game session has already registered.
        alertTimeoutWork?.cancel()
        startupWatchdog?.cancel()
        measurementDeadline?.cancel()
        afkMeasure?.cancel()
        jarAuditWork?.cancel()
    }

    private var alertTimeoutWork: DispatchWorkItem?
    private var didStartGame = false
    private var cpuProfileStartedAt: TimeInterval?
    private var powerRun: PowerRun?
    private var afkMeasure: DispatchWorkItem?
    private var afkMeasureID: UUID?
    private var afkComparisonDone = false
    private var guardedBlackout = false
    private var jarAuditID: UUID?
    private var jarAuditWork: DispatchWorkItem?
    private var jarAuditJIT: Int32 = 0
    private var afkOriginalJIT: Int32?
    private var lastAFKTrace = ""
    private var afkFrozenLayers: [CALayer] = []

    private func setAFKUICut(_ enabled: Bool) {
        treo_afk_ui_cut_set(enabled ? 1 : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if enabled {
            // The wake button keeps its own clock. Leave any custom layer clocks alone.
            for child in view.subviews where child !== blackout {
                let layer = child.layer
                guard layer.speed == 1, layer.timeOffset == 0, layer.beginTime == 0 else { continue }
                let local = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                layer.timeOffset = local
                afkFrozenLayers.append(layer)
            }
            emulatorView.clearPendingGameFrame()
        } else {
            for layer in afkFrozenLayers {
                let local = layer.timeOffset
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
                layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - local
            }
            afkFrozenLayers.removeAll()
        }
        CATransaction.commit()
    }
    private var measurementDeadline: DispatchWorkItem?
    private var measurementID: UUID?
    private var lastMeasurement: (title: String, message: String)?
    private var cpuMetalBaseline: (UInt64, UInt64, UInt64) = (0, 0, 0)
    private var startupWatchdog: DispatchWorkItem?

    override var prefersStatusBarHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch layoutMode {
        case .portrait: return .portrait
        case .ngage: return .landscape
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        emulatorView.canvasWidth = canvasWidth
        emulatorView.canvasHeight = canvasHeight

        switch layoutMode {
        case .portrait: setupNGageLayout(portrait: true)
        case .ngage: setupNGageLayout()
        }

        // Placeholder icon — visible until first game frame
        let iconIV = UIImageView(image: appIcon)
        iconIV.contentMode = .center
        iconIV.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconIV)
        NSLayoutConstraint.activate([
            iconIV.centerXAnchor.constraint(equalTo: emulatorView.centerXAnchor),
            iconIV.centerYAnchor.constraint(equalTo: emulatorView.centerYAnchor),
        ])
        placeholderIconView = iconIV
        view.bringSubviewToFront(backButton)

        // Fade out placeholder on first rendered frame
        emulatorView.onFirstFrame = { [weak self] in
            NSLog("[J2ME Treo] First game frame displayed")
            self?.finishStartupWatchdog()
            guard let icon = self?.placeholderIconView else { return }
            UIView.animate(withDuration: 0.2) {
                icon.alpha = 0
            } completion: { _ in
                icon.removeFromSuperview()
                self?.placeholderIconView = nil
            }
        }

        if layoutMode == .ngage {
            emulatorView.onFrame = { [weak self] cgImage in
                self?.glowContentView.layer.contents = cgImage
            }
        }

        // Register native callbacks
        setGlobalEmulatorView(emulatorView)
        j2me_render_set_afk_suspended(0)
        j2me_render_set_flush_callback(flushCallback)
        j2me_ui_set_callback(gameUICallback)
        activeGameViewController = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startGame()
    }

    // ============================================================
    // MARK: - N-Gage layout
    // ============================================================
    //
    //  ┌──────────────────────────────────────────────────────┐
    //  │ [X]                                                   │
    //  │  ┌─────────┐  ┌──────────────┐  ┌───────────────┐  │
    //  │  │         │  │              │  │ [LSK]   [RSK] │  │
    //  │  │  ╭───╮  │  │  J2ME Canvas │  │ [1] [2] [3]  │  │
    //  │  │  │ ○ │  │  │   240×320    │  │ [4] [5] [6]  │  │
    //  │  │  ╰───╯  │  │              │  │ [7] [8] [9]  │  │
    //  │  │joystick │  │              │  │ [*] [0] [#]  │  │
    //  │  └─────────┘  └──────────────┘  └───────────────┘  │
    //  └──────────────────────────────────────────────────────┘

    private func setupNGageLayout(portrait: Bool = false) {
        let joystick = JoystickView()
        let numpad = NumpadView()
        self.joystickView = joystick
        self.numpadView = numpad

        // Glow: container with game content mirror + NeutralBlurView on top
        glowContainer.isUserInteractionEnabled = false
        glowContainer.clipsToBounds = true

        glowContentView.layer.magnificationFilter = .trilinear
        glowContentView.layer.minificationFilter = .trilinear
        glowContentView.alpha = 0.6
        glowContainer.addSubview(glowContentView)

        // glowContentView fills glowContainer
        glowContentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glowContentView.topAnchor.constraint(equalTo: glowContainer.topAnchor),
            glowContentView.leadingAnchor.constraint(equalTo: glowContainer.leadingAnchor),
            glowContentView.trailingAnchor.constraint(equalTo: glowContainer.trailingAnchor),
            glowContentView.bottomAnchor.constraint(equalTo: glowContainer.bottomAnchor),
        ])

        // Full-screen blur over the glow (no hard edge)
        let glowBlur = NeutralBlurView(radius: 100)
        glowBlur.isUserInteractionEnabled = false

        for v: UIView in [glowContainer, glowBlur, joystick, emulatorView, numpad, lskButton, rskButton, formView, listView, backButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        formView.isHidden = true
        listView.isHidden = true

        // Soft keys — flanking the game screen at bottom
        for (btn, title) in [(lskButton, "L"), (rskButton, "R")] {
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
            btn.setTitleColor(.white, for: .normal)
            btn.backgroundColor = UIColor(white: 0.12, alpha: 1)
            btn.layer.cornerRadius = 10
            btn.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
            btn.layer.borderWidth = 1
            btn.addTarget(self, action: #selector(softKeyDown(_:)), for: .touchDown)
            btn.addTarget(self, action: #selector(softKeyUp(_:)),
                          for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        lskButton.tag = -6
        rskButton.tag = -7

        // Back button
        backButton.setTitle("  \u{2715}  ", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        backButton.backgroundColor = UIColor(white: 0.15, alpha: 0.85)
        backButton.setTitleColor(.white, for: .normal)
        backButton.layer.cornerRadius = 10
        backButton.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        backButton.layer.borderWidth = 1
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)

        let canvasRatio: CGFloat = CGFloat(emulatorView.canvasWidth) / CGFloat(emulatorView.canvasHeight)
        let pad: CGFloat = 8

        if portrait {
            let safe = view.safeAreaLayoutGuide
            let panel = UIView()
            portraitPanel = panel
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.backgroundColor = UIColor(white: 0.07, alpha: 1)
            view.addSubview(panel)
            let dpad = makeDirectionalPad()
            directionalPad = dpad
            for control in [numpad as UIView, dpad as UIView, lskButton, rskButton] {
                panel.addSubview(control)
                control.translatesAutoresizingMaskIntoConstraints = false
            }
            joystick.isHidden = true
            glowContainer.isHidden = true
            glowBlur.isHidden = true
            emulatorView.layer.contentsGravity = .resizeAspect
            emulatorView.clipsToBounds = true
            screenMenu.translatesAutoresizingMaskIntoConstraints = false
            screenMenu.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            screenMenu.tintColor = .white
            screenMenu.accessibilityLabel = "Tùy chọn game"
            screenMenu.showsMenuAsPrimaryAction = true
            view.addSubview(screenMenu)
            let height = panel.heightAnchor.constraint(equalToConstant: 198)
            height.priority = .defaultHigh
            portraitControlsHeight = height
            NSLayoutConstraint.activate([
                backButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
                backButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
                backButton.heightAnchor.constraint(equalToConstant: 36),
                screenMenu.topAnchor.constraint(equalTo: backButton.topAnchor),
                screenMenu.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
                screenMenu.widthAnchor.constraint(equalToConstant: 44),
                screenMenu.heightAnchor.constraint(equalToConstant: 36),
                emulatorView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 4),
                emulatorView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                emulatorView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                emulatorView.bottomAnchor.constraint(equalTo: panel.topAnchor),
                panel.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                height
            ])
            let left = lskButton
            let right = rskButton
            NSLayoutConstraint.activate([
                left.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
                right.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
                left.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
                right.topAnchor.constraint(equalTo: left.topAnchor),
                left.widthAnchor.constraint(equalToConstant: 54),
                right.widthAnchor.constraint(equalToConstant: 54),
                left.heightAnchor.constraint(equalToConstant: 30),
                right.heightAnchor.constraint(equalToConstant: 30)
            ])
            left.setTitle("L", for: .normal)
            right.setTitle("R", for: .normal)
            for padView in [numpad as UIView, dpad as UIView] {
                // Optional bottom pin lets the hidden panel collapse without conflicting constraints.
                let bottom = padView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6)
                portraitPadBottomPins.append(bottom)
                NSLayoutConstraint.activate([
                    padView.topAnchor.constraint(equalTo: left.bottomAnchor, constant: 4),
                    padView.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
                    padView.widthAnchor.constraint(equalTo: panel.widthAnchor, multiplier: 0.76)
                ])
            }
            for overlay in [formView as UIView, listView as UIView] {
                NSLayoutConstraint.activate([
                    overlay.topAnchor.constraint(equalTo: backButton.bottomAnchor),
                    overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
                view.bringSubviewToFront(overlay)
            }
            applyPadMode()
            return
        }

        // Layout guides for centering controls in the side panels
        let leftArea = UILayoutGuide()
        let rightArea = UILayoutGuide()
        view.addLayoutGuide(leftArea)
        view.addLayoutGuide(rightArea)

        NSLayoutConstraint.activate([
            leftArea.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            leftArea.trailingAnchor.constraint(equalTo: emulatorView.leadingAnchor),

            rightArea.leadingAnchor.constraint(equalTo: emulatorView.trailingAnchor),
            rightArea.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            // Glow content: slightly larger than emulator, sits behind it
            glowContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            glowContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            glowContainer.widthAnchor.constraint(equalTo: emulatorView.widthAnchor),
            glowContainer.heightAnchor.constraint(equalTo: emulatorView.heightAnchor),

            // Blur: full screen (no hard edge at glow boundary)
            glowBlur.topAnchor.constraint(equalTo: view.topAnchor),
            glowBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glowBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glowBlur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Emulator: centered, aspect ratio, full height with padding
            emulatorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emulatorView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: pad),
            emulatorView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),
            emulatorView.widthAnchor.constraint(equalTo: emulatorView.heightAnchor, multiplier: canvasRatio),

            // Joystick: centered horizontally between safe area left and emulator left
            joystick.centerXAnchor.constraint(equalTo: leftArea.centerXAnchor),
            joystick.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 80),
            joystick.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.42),
            joystick.heightAnchor.constraint(equalTo: joystick.widthAnchor),

            // Numpad: centered in right panel, same width as joystick, top 48pt
            numpad.centerXAnchor.constraint(equalTo: rightArea.centerXAnchor),
            numpad.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 80),
            numpad.widthAnchor.constraint(equalTo: joystick.widthAnchor),
            numpad.heightAnchor.constraint(equalTo: numpad.widthAnchor, multiplier: 1.33),

            // Soft keys: flanking game screen at bottom
            lskButton.trailingAnchor.constraint(equalTo: emulatorView.leadingAnchor, constant: -6),
            lskButton.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
            lskButton.widthAnchor.constraint(equalToConstant: 68),
            lskButton.heightAnchor.constraint(equalToConstant: 40),

            rskButton.leadingAnchor.constraint(equalTo: emulatorView.trailingAnchor, constant: 6),
            rskButton.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
            rskButton.widthAnchor.constraint(equalToConstant: 68),
            rskButton.heightAnchor.constraint(equalToConstant: 40),

            // Form / List: full screen (overlays everything when visible)
            formView.topAnchor.constraint(equalTo: view.topAnchor),
            formView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            listView.topAnchor.constraint(equalTo: view.topAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Back button: top-left
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4),
        ])

        // Game screen rounded corners + border
        emulatorView.layer.cornerRadius = 8
        emulatorView.clipsToBounds = true
        emulatorView.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        emulatorView.layer.borderWidth = 1

        view.bringSubviewToFront(formView)
        view.bringSubviewToFront(listView)
        view.bringSubviewToFront(backButton)
    }

    private func makeDirectionalPad() -> UIStackView {
        // Nokia/MIDP direction and FIRE codes, also used by upstream J2ME Loader.
        let rows: [[(String, Int)]] = [
            [("", 0), ("↑", -1), ("", 0)],
            [("←", -3), ("OK", -5), ("→", -4)],
            [("", 0), ("↓", -2), ("", 0)]
        ]
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 4
        for keys in rows {
            let row = UIStackView()
            row.distribution = .fillEqually
            row.spacing = 4
            for (title, code) in keys {
                if code == 0 {
                    row.addArrangedSubview(UIView())
                    continue
                }
                let button = UIButton(type: .system)
                button.tag = code
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
                button.setTitleColor(.white, for: .normal)
                button.backgroundColor = UIColor(white: 0.17, alpha: 1)
                button.layer.cornerRadius = 9
                button.addTarget(self, action: #selector(directionDown(_:)), for: .touchDown)
                button.addTarget(self, action: #selector(directionUp(_:)),
                                 for: [.touchUpInside, .touchUpOutside, .touchCancel])
                row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
        }
        return stack
    }

    @objc private func directionDown(_ sender: UIButton) {
        let code = Int32(sender.tag)
        guard heldDirections.insert(code).inserted else { return }
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
        if code != -5 {
            let timer = Timer(fireAt: Date(timeIntervalSinceNow: 0.36), interval: 0.085,
                              target: self, selector: #selector(repeatDirection(_:)),
                              userInfo: code, repeats: true)
            directionTimers[code] = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func repeatDirection(_ timer: Timer) {
        guard let code = timer.userInfo as? Int32, heldDirections.contains(code) else { return }
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_REPEATED), code)
    }

    @objc private func directionUp(_ sender: UIButton) {
        releaseDirection(Int32(sender.tag))
    }

    private func releaseDirection(_ code: Int32) {
        directionTimers.removeValue(forKey: code)?.invalidate()
        if heldDirections.remove(code) != nil {
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
        }
    }

    private func setPadMode(_ mode: PadMode) {
        for code in Array(heldDirections) { releaseDirection(code) }
        padMode = mode
        applyPadMode()
    }

    private func applyPadMode() {
        guard let panel = portraitPanel else { return }
        let canvasIsVisible = !emulatorView.isHidden
        let padIsVisible = canvasIsVisible && padMode != .hidden
        panel.isHidden = !padIsVisible
        screenMenu.isHidden = !canvasIsVisible
        directionalPad?.isHidden = padMode != .directions
        numpadView?.isHidden = padMode != .numbers
        portraitControlsHeight?.constant = padIsVisible ? 198 : 0
        for pin in portraitPadBottomPins { pin.isActive = padIsVisible }
        if jarAuditID != nil {
            screenMenu.menu = UIMenu(children: [
                UIAction(title: "Hủy chẩn đoán CPU JAR", attributes: .destructive) { [weak self] _ in self?.stopJarAudit() }
            ])
            return
        }
        screenMenu.menu = UIMenu(children: [
            UIAction(title: "Phím điều hướng", state: padMode == .directions ? .on : .off) { [weak self] _ in self?.setPadMode(.directions) },
            UIAction(title: "Phím số", state: padMode == .numbers ? .on : .off) { [weak self] _ in self?.setPadMode(.numbers) },
            UIAction(title: "Ẩn phím · màn hình lớn", state: padMode == .hidden ? .on : .off) { [weak self] _ in self?.setPadMode(.hidden) },
            UIAction(title: "Xem kết quả đo gần nhất",
                     attributes: lastMeasurement == nil ? .disabled : []) { [weak self] _ in
                self?.showLastMeasurement()
            },
            UIAction(title: powerRun == nil ? "Bắt đầu đo nhiệt và CPU tổng" : "Dừng đo nhiệt và CPU tổng",
                     attributes: cpuProfileStartedAt == nil ? [] : .disabled) { [weak self] _ in
                self?.togglePowerRun()
            },
            UIAction(title: "Chẩn đoán CPU JAR · 4 lượt") { [weak self] _ in self?.confirmJarAudit() },
            UIAction(title: "Treo tối đa · màn hình đen") { [weak self] _ in self?.showBlackout() },
            UIAction(title: "Treo · vẽ SIMD ngầm (thử nghiệm)") { [weak self] _ in self?.showBlackout(mode: 5) },
            UIAction(title: "So CPU treo · Canvas nhanh",
                     attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in self?.startGuardedComparison(fast: true) },
            UIAction(title: "So CPU treo · Canvas không dựng hình",
                     attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in self?.confirmGuardedComparison() },
            UIAction(title: "So CPU treo · paint 5 Hz / JIT") { [weak self] _ in self?.confirmAfkPaintTest() },
            UIAction(title: treo_game_jit_is_enabled() != 0 ? "Tắt JIT Java (thử nghiệm)" : "Bật JIT Java (thử nghiệm)", attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in
                guard let self else { return }
                if treo_game_jit_is_enabled() != 0 {
                    treo_game_jit_set_enabled(0)
                    self.applyPadMode()
                    return
                }
                let prompt = UIAlertController(title: "JIT Java thử nghiệm",
                    message: "Chỉ bật sau khi StikDebug đã attach vào tiến trình này. Phương thức game chạy nhiều sẽ được biên dịch; tính năng có thể gây lỗi hoặc thoát app.",
                    preferredStyle: .alert)
                prompt.addAction(UIAlertAction(title: "Hủy", style: .cancel))
                prompt.addAction(UIAlertAction(title: "Bật JIT Java", style: .default) { [weak self] _ in
                    let smoke = treo_jit_probe()
                    let result = smoke == 42 ? treo_game_jit_backend_probe() : smoke
                    if result == 42 {
                        treo_game_jit_set_enabled(1)
                        self?.applyPadMode()
                    } else {
                        let report = UIAlertController(title: "Không bật được JIT Java",
                            message: "Mã lỗi kiểm tra thực thi: \(result). Game vẫn chạy bằng trình thông dịch.",
                            preferredStyle: .alert)
                        report.addAction(UIAlertAction(title: "OK", style: .default))
                        self?.present(report, animated: true)
                    }
                })
                self.present(prompt, animated: true)
            },
            UIAction(title: "Bỏ sprite ngoài vùng vẽ (thử nghiệm)",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil ? [] : .disabled,
                     state: treo_render_region_cull_enabled() != 0 ? .on : .off) { [weak self] _ in
                let enabled = treo_render_region_cull_enabled() != 0
                treo_render_set_region_cull_enabled(enabled ? 0 : 1)
                self?.applyPadMode()
            },
            UIAction(title: cpuProfileStartedAt == nil ? "Bắt đầu đo CPU" : "Dừng và xem số liệu CPU",
                     attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in
                self?.toggleCPUProfile()
            },
            UIAction(title: "Vẽ sprite trực tiếp · CPU SIMD",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil ? [] : .disabled,
                     state: treo_software_enabled() != 0 ? .on : .off) { [weak self] _ in
                let enabling = treo_software_enabled() == 0
                if enabling {
                    treo_cpu_batch_set_enabled(0)
                    treo_metal_live_set_enabled(0)
                    treo_render_set_region_cull_enabled(0)
                }
                treo_software_set_enabled(enabling ? 1 : 0)
                self?.applyPadMode()
            },
            UIAction(title: "Đường vẽ trực tiếp · SIMD+",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil && treo_software_enabled() != 0 ? [] : .disabled,
                     state: treo_direct_graphics_enabled() != 0 && treo_software_enabled() != 0 ? .on : .off) { [weak self] _ in
                treo_direct_graphics_set_enabled(treo_direct_graphics_enabled() == 0 ? 1 : 0)
                self?.applyPadMode()
            },
            UIAction(title: "Dùng lại cụm sprite (CPU)",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil ? [] : .disabled,
                     state: treo_cpu_batch_enabled() != 0 ? .on : .off) { [weak self] _ in
                let enabling = treo_cpu_batch_enabled() == 0
                if enabling { treo_metal_live_set_enabled(0); treo_software_set_enabled(0) }
                treo_cpu_batch_set_enabled(enabling ? 1 : 0)
                self?.applyPadMode()
            },
            UIAction(title: "Metal toàn khung (thử nghiệm)",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil ? [] : .disabled,
                     state: treo_metal_live_enabled() != 0 ? .on : .off) { [weak self] _ in
                let enabling = treo_metal_live_enabled() == 0
                if enabling { treo_cpu_batch_set_enabled(0); treo_software_set_enabled(0) }
                treo_metal_live_set_enabled(enabling ? 1 : 0)
                self?.applyPadMode()
            },
            UIAction(title: "Đo thử Metal · drawRegion", attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in
                self?.showMetalReplay()
            },
            UIAction(title: "Thống kê JIT Java") { [weak self] _ in
                let compiled = treo_game_jit_compiled_count()
                let calls = treo_game_jit_call_count()
                let report = UIAlertController(title: "Thống kê JIT Java",
                    message: "Từ khi mở app: \(compiled) phương thức đã biên dịch · \(calls) lượt mã máy.\n\(treo_game_jit_fallback_count()) lần biên dịch không dùng được; tiếp tục thông dịch.\nBộ nhớ mã Java: \(treo_game_jit_code_kib()) KiB / 32 MiB.",
                    preferredStyle: .alert)
                report.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(report, animated: true)
            }
        ])
    }

    private func cancelMeasurementDeadline() {
        measurementDeadline?.cancel()
        measurementDeadline = nil
        measurementID = nil
    }

    private func scheduleMeasurementDeadline(power: Bool) {
        cancelMeasurementDeadline()
        let id = UUID()
        measurementID = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.measurementID == id else { return }
            if power {
                if self.powerRun != nil { self.togglePowerRun() }
            } else if self.cpuProfileStartedAt != nil {
                self.toggleCPUProfile()
            }
        }
        measurementDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60), execute: work)
    }

    private func publishMeasurement(title: String, message: String) {
        lastMeasurement = (title, message)
        applyPadMode()
        showLastMeasurement()
    }

    private func showLastMeasurement() {
        guard let report = lastMeasurement, viewIfLoaded?.window != nil,
              presentedViewController == nil, !isBeingDismissed,
              UIApplication.shared.applicationState == .active else { return }
        let alert = UIAlertController(title: report.title, message: report.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sao chép", style: .default) { _ in
            if report.title == "CPU luồng chính", !self.lastAFKTrace.isEmpty {
                UIPasteboard.general.string = report.message + "\n\n" + self.lastAFKTrace
            } else {
                UIPasteboard.general.string = report.message
            }
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        present(alert, animated: true)
    }

    private struct PowerRun {
        let time: TimeInterval
        let cpu: Double
        let thermal: ProcessInfo.ThermalState
        let metal: Int32
        let jit: Int32
        let cull: Int32
        let gpuFrames: UInt64
        let batch: Int32
        let queued: UInt64
        let reused: UInt64
        let software: Int32
        let softwareStats: TreoSoftwareStats
        let direct: Int32
    }

    private func togglePowerRun() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = treo_process_cpu_seconds()
        let thermal = ProcessInfo.processInfo.thermalState
        let metal = treo_metal_live_enabled()
        let jit = treo_game_jit_is_enabled()
        let cull = treo_render_region_cull_enabled()
        let gpuFrames = treo_metal_live_frames()
        guard let start = powerRun else {
            powerRun = PowerRun(time: now, cpu: cpu, thermal: thermal, metal: metal, jit: jit,
                                cull: cull, gpuFrames: gpuFrames, batch: treo_cpu_batch_enabled(),
                                queued: treo_cpu_batch_queued(), reused: treo_cpu_batch_reused(),
                                software: treo_software_enabled(), softwareStats: treo_software_stats(), direct: treo_direct_graphics_enabled())
            scheduleMeasurementDeadline(power: true)
            applyPadMode()
            return
        }
        cancelMeasurementDeadline()
        powerRun = nil
        let duration = now - start.time
        let valid = start.cpu >= 0 && cpu >= start.cpu && duration > 0
        let cpuText = valid ? String(format: "%.1f%% một lõi", 100.0 * (cpu - start.cpu) / duration) : "Không đọc được"
        func thermalLabel(_ value: ProcessInfo.ThermalState) -> String {
            switch value {
            case .nominal: return "Bình thường"
            case .fair: return "Tăng nhẹ"
            case .serious: return "Cao"
            case .critical: return "Rất cao"
            @unknown default: return "Không rõ"
            }
        }
        let sw = treo_software_stats()
        let fps = Double(sw.frames &- start.softwareStats.frames) / max(0.001, duration)
        let report = """
        SIMD: \(start.software != 0 ? "Bật" : "Tắt") · \(String(format: "%.1f", fps)) khung gửi/giây
        SIMD+: \(start.direct != 0 && start.software != 0 ? "Bật" : "Tắt") · \(sw.direct &- start.softwareStats.direct) lệnh API trực tiếp
        Vẽ nhanh: \(sw.fast &- start.softwareStats.fast)/\(sw.regions &- start.softwareStats.regions)
        Đối chiếu CG: \(sw.checked &- start.softwareStats.checked) · Lệch: \(sw.mismatch &- start.softwareStats.mismatch)
        Thời gian: \(String(format: "%.1f", duration)) s
        CPU toàn app: \(cpuText)
        Mức nhiệt iOS (đầu → cuối): \(thermalLabel(start.thermal)) → \(thermalLabel(thermal))
        Metal: \(metal != 0 ? "Bật" : "Tắt") · \(gpuFrames &- start.gpuFrames) khung GPU
        JIT: \(jit != 0 ? "Bật" : "Tắt") · Bỏ sprite: \(cull != 0 ? "Bật" : "Tắt")
        Cụm sprite CPU: \(start.batch != 0 ? "Bật" : "Tắt")
        Lệnh dùng lại: \(treo_cpu_batch_reused() &- start.reused)/\(treo_cpu_batch_queued() &- start.queued) lệnh gom đủ cụm
        Không đo công suất, độ C hoặc mức tải GPU.
        """
        publishMeasurement(title: "Nhiệt và CPU tổng", message: report)
    }

    private func showMetalReplay() {
        let raw = treo_metal_replay_copy_report()
        let report = raw.map { String(cString: $0) } ?? "Không đọc được báo cáo."
        if let raw { free(raw) }
        let alert = UIAlertController(title: "Replay Metal · drawRegion", message: report, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sao chép", style: .default) { _ in
            UIPasteboard.general.string = report
        })
        if cpuProfileStartedAt == nil && treo_render_region_cull_enabled() == 0 && treo_metal_live_enabled() == 0 && treo_cpu_batch_enabled() == 0 {
            alert.addAction(UIAlertAction(title: "Thu và đo", style: .default) { _ in
                _ = treo_metal_replay_start()
            })
        }
        present(alert, animated: true)
    }

    private func toggleCPUProfile() {
        guard let start = cpuProfileStartedAt else {
            cpuMetalBaseline = (treo_metal_live_frames(), treo_metal_live_sprites(), treo_metal_live_fallback_sprites())
            treo_render_profile_start()
            cpuProfileStartedAt = ProcessInfo.processInfo.systemUptime
            scheduleMeasurementDeadline(power: false)
            applyPadMode()
            return
        }
        cancelMeasurementDeadline()
        let result = treo_render_profile_stop()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        cpuProfileStartedAt = nil
        let paint = Double(result.paint_ns) / 1_000_000
        let snapshot = Double(result.snapshot_ns) / 1_000_000
        let region = Double(result.region_sample_ns) / 1_000_000
        let cullMode = treo_render_region_cull_enabled() != 0 ? "Bật" : "Tắt"
        let cullPercent = 100.0 * Double(result.region_culled) / max(1.0, Double(result.region_calls))
        let metalMode = treo_metal_live_enabled() != 0 ? "Bật" : "Tắt"
        let metalFrames = treo_metal_live_frames() &- cpuMetalBaseline.0
        let metalSprites = treo_metal_live_sprites() &- cpuMetalBaseline.1
        let metalFallback = treo_metal_live_fallback_sprites() &- cpuMetalBaseline.2
        let report = """
        Metal live: \(metalMode) · \(metalFrames) khung · \(metalSprites) lệnh GPU
        Lệnh đã xếp hàng nhưng vẽ lại bằng CG: \(metalFallback)
        Xử lý sprite cuối khung (ngoài paint): \(String(format: "%.1f", Double(result.live_boundary_ns) / 1_000_000)) ms CPU
        Bỏ sprite ngoài vùng vẽ: \(cullMode)
        Bỏ sớm: \(result.region_culled)/\(result.region_calls) · \(String(format: "%.1f", cullPercent))%
        Thời gian đo: \(String(format: "%.1f", seconds)) s
        paint(): \(result.paints) lần · \(String(format: "%.1f", paint)) ms CPU
        Flush: \(result.flushes) · Ảnh tạo: \(result.snapshots)
        Tạo ảnh: \(String(format: "%.1f", snapshot)) ms CPU
        Gửi lên layer: \(result.submitted) · Bị thay trong hàng đợi: \(result.replaced)
        drawRegion: \(result.region_calls) lượt · \(result.region_samples) mẫu, \(String(format: "%.1f", region)) ms CPU trong mẫu
        """
        NSLog("[TREO-CPU] %@", report)
        publishMeasurement(title: "CPU khi hiện game", message: report)
    }

    private func discardCPUProfile() {
        cancelMeasurementDeadline()
        let hadPowerRun = powerRun != nil
        powerRun = nil
        guard cpuProfileStartedAt != nil else {
            if hadPowerRun { applyPadMode() }
            return
        }
        _ = treo_render_profile_stop()
        cpuProfileStartedAt = nil
        applyPadMode()
    }

    fileprivate func keepBlackoutOnTop() {
        if let blackout { view.bringSubviewToFront(blackout) }
    }

    private func showBlackout(mode: Int32 = 1) {
        guard blackout == nil else { return }
        discardCPUProfile()
        for code in Array(heldDirections) { releaseDirection(code) }
        let cover = UIButton(type: .custom)
        cover.backgroundColor = .black
        cover.setTitle("Chạm để hiện game", for: .normal)
        cover.setTitleColor(UIColor(white: 0.36, alpha: 1), for: .normal)
        cover.titleLabel?.font = .systemFont(ofSize: 14)
        cover.accessibilityLabel = "Hiện lại game"
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.addTarget(self, action: #selector(hideBlackout), for: .touchUpInside)
        view.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: view.topAnchor),
            cover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        blackout = cover
        treo_render_set_afk_mode(mode)
        if let screen = view.window?.windowScene?.screen {
            blackoutScreen = screen
            previousBrightness = screen.brightness
            screen.brightness = 0
        }
        NotificationCenter.default.addObserver(self, selector: #selector(hideBlackout), name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func hideBlackout() {
        guard blackout != nil else { return }
        afkMeasure?.cancel()
        treo_afk_main_trace_cancel()
        if guardedBlackout {
            treo_afk_wakes_set(0)
            guardedBlackout = false
        }
        if !afkFrozenLayers.isEmpty || afkMeasureID != nil { setAFKUICut(false) }
        afkMeasure = nil
        afkMeasureID = nil
        restoreAfkJIT()
        let showComparison = afkComparisonDone
        afkComparisonDone = false
        j2me_render_set_afk_suspended(0)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        if let screen = blackoutScreen, let brightness = previousBrightness, screen.brightness == 0 {
            screen.brightness = brightness
        }
        blackoutScreen = nil
        previousBrightness = nil
        blackout?.removeFromSuperview()
        blackout = nil
        if showComparison { showLastMeasurement() }
    }

    private struct JarAuditSample {
        let base = AfkSample()
        let on = treo_jar_audit_ticks(1)
        let off = treo_jar_audit_ticks(0)
        let frames = treo_afk_layer_frames()
        let wakes = treo_afk_main_wakes()
    }

    private func confirmJarAudit() {
        guard jarAuditID == nil, blackout == nil, powerRun == nil, cpuProfileStartedAt == nil else { return }
        let alert = UIAlertController(title: "Chẩn đoán CPU JAR",
            message: "Dùng Farm-Clean-CPU.jar trong map 37, auto đang chạy, mục treo trong game đang TẮT. App tự đo 4 lượt × 60 giây. Chỉ cần bật treo trong game khi được nhắc. Không bật màn đen Treo. JIT tạm tắt trong bài đo.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Đo", style: .default) { [weak self] _ in self?.startJarAudit() })
        present(alert, animated: true)
    }

    private func startJarAudit() {
        guard jarAuditID == nil, blackout == nil else { return }
        let id = UUID()
        jarAuditID = id
        jarAuditJIT = treo_game_jit_is_enabled()
        treo_game_jit_set_enabled(0)
        treo_jar_audit_set(1)
        treo_afk_wakes_set(1)
        NotificationCenter.default.addObserver(self, selector: #selector(stopJarAudit),
            name: UIApplication.willResignActiveNotification, object: nil)
        applyPadMode()
        runJarAudit(id: id, leg: 0, rows: [])
    }

    @objc private func stopJarAudit() {
        guard jarAuditID != nil else { return }
        jarAuditID = nil
        jarAuditWork?.cancel()
        jarAuditWork = nil
        treo_jar_audit_set(0)
        treo_afk_wakes_set(0)
        treo_render_set_afk_mode(0)
        treo_game_jit_set_enabled(jarAuditJIT)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        applyPadMode()
    }

    private func scheduleJarAudit(id: UUID, after seconds: Double, _ action: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard self?.jarAuditID == id else { return }
            action()
        }
        jarAuditWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func runJarAudit(id: UUID, leg: Int, rows: [String]) {
        // Only change the native AFK switch. No overlay/brightness or pad changes.
        let blocked = leg == 1 || leg == 3
        treo_render_set_afk_mode(blocked ? 1 : 0)
        scheduleJarAudit(id: id, after: 2) { [weak self] in
            guard let self else { return }
            treo_afk_threads_begin()
            let start = JarAuditSample()
            self.scheduleJarAudit(id: id, after: 60) { [weak self] in
                guard let self else { return }
                let end = JarAuditSample()
                let dt = max(0.001, end.base.time - start.base.time)
                let on = end.on &- start.on, off = end.off &- start.off
                let names = ["JAR tắt · hiện", "JAR tắt · chặn khung", "JAR bật · hiện", "JAR bật · chặn khung"]
                let total = end.base.cpuPercent(since: start.base).map { String(format: "%.1f%%", $0) } ?? "?"
                let paint = Double(end.base.paintNS &- start.base.paintNS) / dt / 10_000_000
                let paints = Double(end.base.paints &- start.base.paints) / dt
                let main = start.base.mainCPU >= 0 && end.base.mainCPU >= start.base.mainCPU
                    ? String(format: "%.1f%%", 100 * (end.base.mainCPU - start.base.mainCPU) / dt) : "?"
                var row = "\(names[leg]): \(total) tổng · \(main) main"
                row += String(format: "\n%.1f s · %.1f%% paint · %.2f paint/s · %.1f wake/s",
                    dt, paint, paints, Double(end.wakes &- start.wakes) / dt)
                row += String(format: "\n%.2f vòng game/s", Double(on + off) / dt)
                row += " · \(off) tick tắt / \(on) tick bật · \(end.frames &- start.frames) khung lên layer"
                if (leg < 2 && (off == 0 || on != 0)) || (leg >= 2 && (on == 0 || off != 0)) {
                    row += "\nKhông hợp lệ: không thấy helper đúng trạng thái suốt lượt."
                }
                if let raw = treo_afk_threads_report(dt) {
                    row += "\n" + String(cString: raw)
                    free(raw)
                }
                let all = rows + [row]
                if leg == 1 && off != 0 && on == 0 {
                    treo_render_set_afk_mode(0)
                    let alert = UIAlertController(title: "Bật treo trong game",
                        message: "Bấm OK rồi vào menu trong game và bật Treo tối ưu CPU. App sẽ nhận biết và đo tiếp tự động. Không chạm game sau khi bật.",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { [weak self] _ in self?.stopJarAudit() })
                    alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                        self?.waitForJarAudit(id: id, previous: treo_jar_audit_ticks(1), tries: 240, rows: all)
                    })
                    self.present(alert, animated: true)
                } else if leg == 3 || (leg < 2 && (off == 0 || on != 0)) {
                    self.finishJarAudit(rows: all)
                } else {
                    self.runJarAudit(id: id, leg: leg + 1, rows: all)
                }
            }
        }
    }

    private func waitForJarAudit(id: UUID, previous: UInt64, tries: Int, rows: [String]) {
        guard jarAuditID == id else { return }
        if treo_jar_audit_ticks(1) != previous {
            runJarAudit(id: id, leg: 2, rows: rows)
        } else if tries == 0 {
            finishJarAudit(rows: rows + ["Không nhận được tick bật treo từ JAR."])
        } else {
            scheduleJarAudit(id: id, after: 0.25) { [weak self] in
                self?.waitForJarAudit(id: id, previous: previous, tries: tries - 1, rows: rows)
            }
        }
    }

    private func finishJarAudit(rows: [String]) {
        stopJarAudit()
        publishMeasurement(title: "Chẩn đoán CPU JAR", message:
            "Giới hạn FPS Treo: \(fpsLimit) · JIT tắt trong phép đo.\n\n" +
            rows.joined(separator: "\n\n") +
            "\n\nCPU quy về một lõi. Chặn khung dùng công tắc AFK native, không đổi độ sáng. paint* trong báo cáo luồng là luồng paint gần nhất, không phải thời gian callback. Không đo GPU.")
    }

    private struct GuardedSample {
        let cpu = AfkSample()
        let discarded = treo_afk_guarded_paints()
        let real = treo_afk_guarded_real()
        let late = treo_afk_guarded_late()
        let native = treo_afk_skipped_draws()
        let frames = treo_afk_layer_frames()
        let wakes = treo_afk_main_wakes()
        let software = treo_software_stats()
        let fast = treo_fast_canvas_stats()
    }

    private func confirmGuardedComparison() {
        guard blackout == nil, powerRun == nil else { return }
        let file = URL(fileURLWithPath: jarPath).lastPathComponent
        let alert = UIAlertController(title: "Thử treo không dựng hình",
            message: "JAR đang chạy: \(file)\nChỉ thử trên x1. App đo CPU từng luồng trong 3 lượt, rồi lấy mẫu chuỗi gọi main trong 2 lượt riêng. Mỗi lượt 60 giây. Có thể chạm màn đen để dừng và kiểm tra lại game. Màn đen thường không thay đổi.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Đo x1", style: .default) { [weak self] _ in
            self?.startGuardedComparison()
        })
        present(alert, animated: true)
    }

    private func startGuardedComparison(fast: Bool = false) {
        guard blackout == nil, powerRun == nil else { return }
        showBlackout()
        treo_afk_main_trace_cancel()
        let id = UUID()
        afkMeasureID = id
        guardedBlackout = true
        treo_afk_wakes_set(1)
        runGuardedLeg(id: id, index: 0, rows: [], fast: fast)
    }

    private func runGuardedLeg(id: UUID, index: Int, rows: [String], fast: Bool) {
        let tracing = index >= 3
        treo_render_set_afk_mode(index == 1 || index == 4 ? (fast ? 9 : 8) : 1)
        blackout?.setTitle("Đang đo \(index + 1)/\(fast ? 3 : 5) · Chạm để hủy", for: .normal)
        // CPU scoring and diagnostic stack sampling use disjoint windows.
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.afkMeasureID == id else { return }
            if tracing { treo_afk_main_stack_begin() }
            else { treo_afk_threads_begin() }
            let start = GuardedSample()
            let measure = DispatchWorkItem { [weak self] in
                guard let self, self.afkMeasureID == id else { return }
                let end = GuardedSample()
                if tracing {
                    let raw = treo_afk_main_trace_end()
                    let report = raw.map { String(cString: $0) } ?? "Không đọc được chuỗi gọi."
                    if let raw { free(raw) }
                    let name = index == 3 ? "Main · màn đen cũ" : "Main · không dựng hình"
                    let all = rows + [name + "\n" + report]
                    if index == 3 {
                        self.runGuardedLeg(id: id, index: 4, rows: all, fast: false)
                    } else {
                        // Restore ordinary blackout before presenting the report.
                        treo_render_set_afk_mode(1)
                        treo_afk_wakes_set(0)
                        self.afkMeasure = nil
                        self.afkMeasureID = nil
                        self.afkComparisonDone = true
                        self.lastMeasurement = ("Chẩn đoán CPU treo", all.joined(separator: "\n\n") +
                            "\n\nCPU quy về một lõi. Chuỗi FP lấy ở lượt riêng, có thể thiếu frame; số mẫu không phải CPU %. Không đo GPU %.")
                        self.blackout?.setTitle("Đo xong · Chạm xem kết quả", for: .normal)
                    }
                    return
                }
                let seconds = max(0.001, end.cpu.time - start.cpu.time)
                func percent(_ value: Double?) -> String {
                    value.map { String(format: "%.1f%%", $0) } ?? "?"
                }
                let main: Double? = start.cpu.mainCPU >= 0 && end.cpu.mainCPU >= start.cpu.mainCPU
                    ? 100 * (end.cpu.mainCPU - start.cpu.mainCPU) / seconds : nil
                let name = ["Cũ 1", fast ? "Canvas nhanh" : "Không dựng hình", "Cũ 2"][index]
                let paint = Double(end.cpu.paintNS &- start.cpu.paintNS) / seconds / 10_000_000
                let rate = Double(end.cpu.paints &- start.cpu.paints) / seconds
                let wakes = Double(end.wakes &- start.wakes) / seconds
                var row = "\(name): \(percent(end.cpu.cpuPercent(since: start.cpu))) tổng · \(percent(main)) main · \(percent(paint)) paint"
                row += String(format: "\n%.1f paint/s · %.1f wake/s · %llu khung lên layer", rate, wakes, end.frames &- start.frames)
                if index == 1 && fast {
                    row += "\nSIMD \(end.software.fast &- start.software.fast) · gọi tắt \(end.software.direct &- start.software.direct) · kiểm \(end.software.checked &- start.software.checked) · lệch \(end.software.mismatch &- start.software.mismatch)."
                    row += "\nTô nhanh \(end.fast.fills &- start.fast.fills) · kiểm \(end.fast.checks &- start.fast.checks) · lệch \(end.fast.mismatch &- start.fast.mismatch) · trạng thái trùng \(end.fast.state &- start.fast.state)."
                }
                if index == 1 && !fast {
                    row += "\nCanvas: \(end.discarded &- start.discarded) lượt bỏ raster · \(end.real &- start.real) lượt vẽ thật."
                    row += "\nNative bỏ \(end.native &- start.native) lệnh (không tính lệnh trả sớm ở Java)."
                    if end.late != start.late {
                        row += "\nCó truy cập pixel/handle phát hiện muộn: không xác nhận tương thích."
                    }
                }
                if let raw = treo_afk_threads_report(seconds) {
                    row += "\n" + String(cString: raw)
                    free(raw)
                }
                let all = rows + [row]
                if fast && index == 2 {
                    treo_afk_wakes_set(0)
                    self.afkMeasure = nil
                    self.afkMeasureID = nil
                    self.afkComparisonDone = true
                    self.lastMeasurement = ("So CPU · Canvas nhanh", all.joined(separator: "\n\n") +
                        "\n\nCùng màn đen, giữ nhịp paint và cấu hình JIT. CPU quy về một lõi. Không đo GPU %.")
                    self.blackout?.setTitle("Đo xong · Chạm xem kết quả", for: .normal)
                } else {
                    self.runGuardedLeg(id: id, index: index + 1, rows: all, fast: fast)
                }
            }
            self.afkMeasure = measure
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60), execute: measure)
        }
        afkMeasure = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: settle)
    }

    private struct AfkSample {
        let time = ProcessInfo.processInfo.systemUptime
        let cpu = treo_process_cpu_seconds()
        let paints = treo_afk_paint_count()
        let paintNS = treo_afk_paint_cpu_ns()
        let bypassed = treo_afk_bypassed_paints()
        let mainCPU = treo_afk_current_thread_cpu()
        let jitCalls = treo_game_jit_call_count()
        let jitCompiled = treo_game_jit_compiled_count()

        func cpuPercent(since start: AfkSample) -> Double? {
            let seconds = time - start.time
            guard seconds > 0, start.cpu >= 0, cpu >= start.cpu else { return nil }
            return 100 * (cpu - start.cpu) / seconds
        }
    }

    private func confirmAfkPaintTest() {
        let alert = UIAlertController(title: "Thử ở màn hình chờ",
            message: "Thử giới hạn callback paint tối đa 5 lần/giây khi màn đen. Có thể đổi hành vi nếu paint chứa logic; chỉ thử trước đăng nhập. Nếu đã bật JIT bằng StikDebug, app tự đo thêm lượt JIT ở nhịp paint gốc.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Bắt đầu", style: .default) { [weak self] _ in
            self?.startAfkComparison()
        })
        present(alert, animated: true)
    }

    fileprivate func stopAfkPaintTestForPrompt() {
        stopJarAudit()
        if afkMeasureID != nil || guardedBlackout { hideBlackout() }
    }

    private func startAfkComparison() {
        guard blackout == nil else { return }
        showBlackout()
        let id = UUID()
        afkMeasureID = id
        let original = treo_game_jit_is_enabled()
        afkOriginalJIT = original
        let modes: [Int32] = original != 0 ? [0, 1, 2, 0] : [0, 2, 0]
        runAfkLeg(id: id, index: 0, modes: modes, results: [])
    }

    private func restoreAfkJIT() {
        if let original = afkOriginalJIT {
            afkOriginalJIT = nil
            treo_game_jit_set_enabled(original)
        }
    }

    private struct AfkLeg {
        let label: String
        let cpu: Double?
        let mainCPU: Double?
        let paintCPU: Double
        let paintRate: Double
        let bypassed: UInt64
        let jitCalls: UInt64
        let jitCompiled: UInt64
    }

    private func runAfkLeg(id: UUID, index: Int, modes: [Int32], results: [AfkLeg]) {
        let mode = modes[index]
        treo_game_jit_set_enabled(mode == 1 ? 1 : 0)
        treo_render_set_afk_mode(mode == 2 ? 7 : 1)
        blackout?.setTitle("Đang đo \(index + 1)/\(modes.count) · Chạm để hủy", for: .normal)
        let start = AfkSample()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.afkMeasureID == id, self.blackout != nil else { return }
            let end = AfkSample()
            let seconds = max(0.001, end.time - start.time)
            let label = mode == 2 ? "Paint ≤5 Hz" : (mode == 1 ? "JIT · nhịp gốc" : (index == 0 ? "Cũ 1" : "Cũ 2"))
            let leg = AfkLeg(label: label, cpu: end.cpuPercent(since: start),
                             mainCPU: start.mainCPU >= 0 && end.mainCPU >= start.mainCPU
                                ? 100 * (end.mainCPU - start.mainCPU) / seconds : nil,
                             paintCPU: Double(end.paintNS &- start.paintNS) / seconds / 10_000_000,
                             paintRate: Double(end.paints &- start.paints) / seconds,
                             bypassed: end.bypassed &- start.bypassed,
                             jitCalls: UInt64(UInt32(bitPattern: end.jitCalls &- start.jitCalls)),
                             jitCompiled: UInt64(UInt32(bitPattern: end.jitCompiled &- start.jitCompiled)))
            let all = results + [leg]
            if index + 1 < modes.count {
                self.runAfkLeg(id: id, index: index + 1, modes: modes, results: all)
                return
            }
            self.restoreAfkJIT()
            func percent(_ value: Double?) -> String {
                value.map { String(format: "%.1f%%", $0) } ?? "?"
            }
            let rows = all.map { v in
                "\(v.label): \(percent(v.cpu)) tổng · main \(percent(v.mainCPU)) · \(String(format: "%.1f%%", v.paintCPU)) trong paint · \(String(format: "%.1f", v.paintRate)) paint/s"
            }.joined(separator: "\n")
            let paced = all.first { $0.label == "Paint ≤5 Hz" }
            let jit = all.first { $0.label == "JIT · nhịp gốc" }
            let jitText = jit.map { "JIT: \($0.jitCalls) lượt mã máy · \($0.jitCompiled) biên dịch mới." } ?? "Không đo JIT (chưa bật trước bài thử)."
            let report = """
            \(rows)
            Bỏ \(paced?.bypassed ?? 0) yêu cầu paint ở lượt 5 Hz.
            \(jitText)
            Cùng màn đen; CPU quy về một lõi. Không lấy mẫu hàm hay đo GPU %.
            """
            self.afkMeasure = nil
            self.afkMeasureID = nil
            self.afkComparisonDone = true
            self.lastMeasurement = ("So CPU treo", report)
            self.applyPadMode()
            self.blackout?.setTitle("Đo xong · Chạm xem kết quả", for: .normal)
        }
        afkMeasure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60), execute: work)
    }

    // MARK: - Soft keys

    @objc private func softKeyDown(_ sender: UIButton) {
        softKeyHaptic.impactOccurred(intensity: 0.6)
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), Int32(sender.tag))
        sender.backgroundColor = UIColor(white: 0.30, alpha: 1)
    }

    @objc private func softKeyUp(_ sender: UIButton) {
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), Int32(sender.tag))
        sender.backgroundColor = UIColor(white: 0.12, alpha: 1)
    }

    // ============================================================
    // MARK: - Game lifecycle
    // ============================================================

    private func startGame() {
        guard !didStartGame else { return }
        didStartGame = true
        NSLog("[J2ME Treo] Game view appeared; scheduling JVM startup")

        guard let resRoot = Bundle.main.resourcePath,
              ["minijvm_rt.jar", "j2me_api.jar"].allSatisfy({
                  FileManager.default.isReadableFile(atPath: resRoot + "/" + $0)
              }),
              FileManager.default.isReadableFile(atPath: jarPath) else {
            showLaunchFailure("The game JAR or a bundled Java runtime file is missing.")
            return
        }

        // Copy plain values on the main actor; the VM worker never reads the view controller.
        let gamePath = jarPath
        let width = Int32(canvasWidth)
        let height = Int32(canvasHeight)
        let scale = Int32(render3dScale)
        let fps = Int32(fpsLimit)
        let worker = DispatchWorkItem { [weak self] in
            let failure = GameViewController.runMIDlet(
                resRoot: resRoot, jarPath: gamePath, width: width,
                height: height, scale: scale, fps: fps
            )
            DispatchQueue.main.async { [weak self] in
                if let self {
                    self.finishStartupWatchdog()
                    self.discardCPUProfile()
                    self.hideBlackout()
                    for code in Array(self.heldDirections) { self.releaseDirection(code) }
                }
                if let failure {
                    self?.showLaunchFailure(failure)
                } else {
                    self?.dismiss(animated: true)
                }
            }
        }
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, let icon = self.placeholderIconView, !icon.isHidden else { return }
            NSLog("[J2ME Treo] Startup: no game frame or native screen after 15 seconds")
        }
        startupWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: watchdog)
        DispatchQueue.global(qos: .userInitiated).async(execute: worker)
    }

    private func finishStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    private func showLaunchFailure(_ message: String) {
        NSLog("[J2ME Treo] Launch failed: %@", message)
        let alert = UIAlertController(title: "Game could not start", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Back", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    nonisolated private static func runMIDlet(resRoot: String, jarPath: String,
                                              width: Int32, height: Int32,
                                              scale: Int32, fps: Int32) -> String? {
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let jarFileName = URL(fileURLWithPath: jarPath).deletingPathExtension().lastPathComponent
        let gameId = jarFileName.replacingOccurrences(of: "[^a-zA-Z0-9._-]",
                                                       with: "_", options: .regularExpression)
        let saveRoot = docs + "/Games Data/" + gameId
        do {
            try FileManager.default.createDirectory(atPath: saveRoot, withIntermediateDirectories: true)
        } catch {
            return "Cannot create the game's save directory."
        }

        NSLog("[J2ME Treo] Entering JVM initialization")
        let initResult = jvm_bridge_init(resRoot, saveRoot, jarPath, width, height, scale, fps)
        NSLog("[J2ME Treo] JVM initialization returned %d", initResult)
        guard initResult == 0 else { return "Java runtime initialization failed (\(initResult))." }

        NSLog("[J2ME Treo] Entering MIDlet runner")
        let runResult = jvm_bridge_run_midlet(jarPath)
        NSLog("[J2ME Treo] MIDlet runner returned %d; cleaning up", runResult)
        jvm_bridge_destroy()
        NSLog("[J2ME Treo] JVM cleanup complete")
        return runResult == 0 ? nil : "Game execution failed (\(runResult))."
    }

    @objc private func backTapped() {
        stopJarAudit()
        backButton.isEnabled = false
        discardCPUProfile()
        finishStartupWatchdog()
        for code in Array(heldDirections) { releaseDirection(code) }
        jvm_bridge_request_stop()
    }

    // ============================================================
    // MARK: - View switching
    // ============================================================

    func showCanvasView() {
        emulatorView.isHidden = false
        joystickView?.isHidden = layoutMode == .portrait
        numpadView?.isHidden = false
        formView.isHidden = true
        listView.isHidden = true
        if layoutMode == .ngage { numpadView?.updateCommands() }
        applyPadMode()
    }

    func showFormView() {
        finishStartupWatchdog()
        placeholderIconView?.isHidden = true
        formView.buildFromNativeData()
        formView.isHidden = false
        emulatorView.isHidden = true
        joystickView?.isHidden = true
        numpadView?.isHidden = true
        listView.isHidden = true
        for code in Array(heldDirections) { releaseDirection(code) }
        applyPadMode()
    }

    func showListView() {
        finishStartupWatchdog()
        placeholderIconView?.isHidden = true
        listView.buildFromNativeData()
        listView.isHidden = false
        emulatorView.isHidden = true
        joystickView?.isHidden = true
        numpadView?.isHidden = true
        formView.isHidden = true
        for code in Array(heldDirections) { releaseDirection(code) }
        applyPadMode()
    }

    func showAlert() {
        finishStartupWatchdog()
        let revision = j2me_ui_revision()
        let title = String(cString: j2me_ui_get_form_title())
        let text = String(cString: j2me_ui_get_alert_text())

        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)

        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let cmdCount = j2me_ui_get_command_count()
        if cmdCount == 0 {
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.alertTimeoutWork?.cancel()
                j2me_input_post_touch(Int32(J2ME_UI_ALERT_DISMISSED), revision, 0)
            })
        } else {
            for i in 0..<cmdCount {
                let label = String(cString: j2me_ui_get_command_label(Int32(i)))
                let cmdId = j2me_ui_get_command_id(Int32(i))
                alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                    self?.alertTimeoutWork?.cancel()
                    j2me_input_post_touch(Int32(J2ME_UI_COMMAND_ACTION), revision, cmdId)
                })
            }
        }

        present(alert, animated: true)

        let timeout = j2me_ui_get_alert_timeout()
        if timeout > 0 {
            let work = DispatchWorkItem { [weak alert] in
                alert?.dismiss(animated: true) {
                    j2me_input_post_touch(Int32(J2ME_UI_ALERT_DISMISSED), revision, 0)
                }
            }
            alertTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeout) / 1000.0, execute: work)
        }
    }
}

// MARK: - Game UI callback (global)

private(set) weak var activeGameViewController: GameViewController?

let gameUICallback: @convention(c) (Int32, Int32) -> Void = { action, revision in
    DispatchQueue.main.async {
        j2me_ui_lock_screen()
        defer { j2me_ui_unlock_screen() }
        guard revision == j2me_ui_revision(), let vc = activeGameViewController else { return }
        switch action {
        case Int32(J2ME_UI_ACTION_SHOW_FORM), Int32(J2ME_UI_ACTION_SHOW_TEXTBOX),
             Int32(J2ME_UI_ACTION_SHOW_LIST), Int32(J2ME_UI_ACTION_SHOW_ALERT):
            vc.stopAfkPaintTestForPrompt()
        default: break
        }
        switch action {
        case Int32(J2ME_UI_ACTION_SHOW_CANVAS):
            vc.showCanvasView()
            treo_afk_ui_canvas_applied(revision)
        case Int32(J2ME_UI_ACTION_SHOW_FORM), Int32(J2ME_UI_ACTION_SHOW_TEXTBOX): vc.showFormView()
        case Int32(J2ME_UI_ACTION_SHOW_LIST):    vc.showListView()
        case Int32(J2ME_UI_ACTION_SHOW_ALERT):   vc.showAlert()
        default: break
        }
        vc.keepBlackoutOnTop()
    }
}
