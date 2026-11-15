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
        setGlobalEmulatorView(nil)
        alertTimeoutWork?.cancel()
    }

    private var alertTimeoutWork: DispatchWorkItem?
    private var didStartGame = false

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
        screenMenu.menu = UIMenu(children: [
            UIAction(title: "Phím điều hướng", state: padMode == .directions ? .on : .off) { [weak self] _ in self?.setPadMode(.directions) },
            UIAction(title: "Phím số", state: padMode == .numbers ? .on : .off) { [weak self] _ in self?.setPadMode(.numbers) },
            UIAction(title: "Ẩn phím · màn hình lớn", state: padMode == .hidden ? .on : .off) { [weak self] _ in self?.setPadMode(.hidden) },
            UIAction(title: "Treo với màn hình đen") { [weak self] _ in self?.showBlackout() }
        ])
    }

    private func showBlackout() {
        guard blackout == nil else { return }
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
    }

    @objc private func hideBlackout() {
        blackout?.removeFromSuperview()
        blackout = nil
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
                    for code in Array(self.heldDirections) { self.releaseDirection(code) }
                }
                if let failure {
                    self?.showLaunchFailure(failure)
                } else {
                    self?.dismiss(animated: true)
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: worker)
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
        backButton.isEnabled = false
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
        let title = String(cString: j2me_ui_get_form_title())
        let text = String(cString: j2me_ui_get_alert_text())

        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)

        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let cmdCount = j2me_ui_get_command_count()
        if cmdCount == 0 {
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.alertTimeoutWork?.cancel()
                j2me_input_post_key(Int32(J2ME_UI_ALERT_DISMISSED), 0)
            })
        } else {
            for i in 0..<cmdCount {
                let label = String(cString: j2me_ui_get_command_label(Int32(i)))
                let cmdId = j2me_ui_get_command_id(Int32(i))
                alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                    self?.alertTimeoutWork?.cancel()
                    j2me_input_post_key(Int32(J2ME_UI_COMMAND_ACTION), cmdId)
                })
            }
        }

        present(alert, animated: true)

        let timeout = j2me_ui_get_alert_timeout()
        if timeout > 0 {
            let work = DispatchWorkItem { [weak alert] in
                alert?.dismiss(animated: true) {
                    j2me_input_post_key(Int32(J2ME_UI_ALERT_DISMISSED), 0)
                }
            }
            alertTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeout) / 1000.0, execute: work)
        }
    }
}

// MARK: - Game UI callback (global)

private(set) weak var activeGameViewController: GameViewController?

let gameUICallback: @convention(c) (Int32, UnsafePointer<CChar>?) -> Void = { action, data in
    DispatchQueue.main.async {
        guard let vc = activeGameViewController else { return }
        switch action {
        case Int32(J2ME_UI_ACTION_SHOW_CANVAS):  vc.showCanvasView()
        case Int32(J2ME_UI_ACTION_SHOW_FORM), Int32(J2ME_UI_ACTION_SHOW_TEXTBOX): vc.showFormView()
        case Int32(J2ME_UI_ACTION_SHOW_LIST):    vc.showListView()
        case Int32(J2ME_UI_ACTION_SHOW_ALERT):   vc.showAlert()
        default: break
        }
    }
}
