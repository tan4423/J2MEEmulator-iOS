#if JARBOX_BG_ANIM_BASELINE
//
//  AnimatedBackgroundView.swift
//  J2MEEmulator
//
//  Animated colored blobs covered by a blur — creates a soft lava-lamp background.
//

import UIKit

final class AnimatedBackgroundView: UIView {

    private let circlesContainer = UIView()
    private let blurView = NeutralBlurView(radius: 40)
    private var circleViews: [UIView] = []
    private var animating = false
    private var animationAllowed = true
    private var initialLayoutDone = false
    private var completedLoops: UInt64 = 0
    // Invalidates queued UIView completion closures across rapid game
    // open/close and app background/foreground transitions.
    private var animationGeneration: UInt64 = 0

    // The springboard is occluded while a fullscreen game runs. These
    // main-actor values make it possible to verify whether its animation
    // still consumes render-loop work during Treo without per-frame probes.
    static private(set) var springboardAnimating = false
    static private(set) var springboardPauseLayers = 0
    static private(set) var springboardAnimationLoops: UInt64 = 0

    var activeAnimationLayers: Int {
        circleViews.reduce(0) { $0 + ($1.layer.animationKeys()?.count ?? 0) }
    }

    func logAnimationState(_ reason: String) {
        NSLog("[JarBoxBG] %@ running=%@ layers=%d totalLoops=%llu",
              reason, animating ? "yes" : "no",
              activeAnimationLayers, completedLoops)
    }

    func setAnimationsActive(_ enabled: Bool, reason: String) {
        if !enabled {
            // Game selection, viewWillDisappear and window detachment can all
            // request pause. Record active layers only on the first pause.
            if !animationAllowed && !animating {
                logAnimationState("already paused; \(reason)")
                return
            }
            // Set first: UIView.animate completion blocks may be invoked
            // synchronously when animations are removed.
            animationAllowed = false
            animating = false
            animationGeneration &+= 1
            let count = activeAnimationLayers
            Self.springboardPauseLayers = count
            Self.springboardAnimating = false
            for circle in circleViews { circle.layer.removeAllAnimations() }
            logAnimationState("paused \(reason); previously active layers \(count)")
            return
        }
        animationAllowed = true
        startAnimationsIfNeeded()
        logAnimationState("resumed \(reason)")
    }

    private func startAnimationsIfNeeded() {
        guard animationAllowed, initialLayoutDone, !animating, window != nil else { return }
        animating = true
        animationGeneration &+= 1
        Self.springboardAnimating = true
        startAnimations(generation: animationGeneration)
    }

    private static let colors: [UIColor] = [
        UIColor(red: 0.15, green: 0.22, blue: 0.55, alpha: 0.38),  // Blue
        UIColor(red: 0.42, green: 0.12, blue: 0.33, alpha: 0.33),  // Magenta
        UIColor(red: 0.06, green: 0.33, blue: 0.36, alpha: 0.33),  // Teal
        UIColor(red: 0.33, green: 0.15, blue: 0.45, alpha: 0.33),  // Purple
        UIColor(red: 0.10, green: 0.30, blue: 0.22, alpha: 0.28),  // Green
        UIColor(red: 0.48, green: 0.22, blue: 0.15, alpha: 0.28),  // Orange
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .black
        clipsToBounds = true

        circlesContainer.clipsToBounds = true
        addSubview(circlesContainer)

        for color in Self.colors {
            let circle = UIView()
            circle.backgroundColor = color
            circlesContainer.addSubview(circle)
            circleViews.append(circle)
        }

        blurView.backgroundColor = UIColor(white: 0, alpha: 0.3)
        addSubview(blurView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        circlesContainer.frame = bounds
        blurView.frame = bounds

        if !initialLayoutDone && bounds.width > 0 && bounds.height > 0 {
            // Lay out random circle positions exactly once. A paused view
            // must not restart animations just because Auto Layout runs.
            for circle in circleViews {
                let size = randomSize()
                circle.frame = CGRect(
                    x: CGFloat.random(in: -size/2 ... bounds.width - size/2),
                    y: CGFloat.random(in: -size/2 ... bounds.height - size/2),
                    width: size, height: size)
                circle.layer.cornerRadius = size / 2
            }
            initialLayoutDone = true
        }
        startAnimationsIfNeeded()
    }

    private func startAnimations(generation: UInt64) {
        for (i, circle) in circleViews.enumerated() {
            let delay = Double(i) * 1.5
            animateCircle(circle, delay: delay, generation: generation)
        }
    }

    private func animateCircle(_ circle: UIView, delay: TimeInterval,
                               generation: UInt64) {
        guard animating, animationAllowed, generation == animationGeneration else { return }
        let duration = Double.random(in: 10...16)
        let newSize = randomSize()

        UIView.animate(
            withDuration: duration,
            delay: delay,
            options: [.curveEaseInOut, .allowUserInteraction],
            animations: { [weak self] in
                guard let self, self.animating, self.animationAllowed,
                      generation == self.animationGeneration else { return }
                let x = CGFloat.random(in: -newSize/2 ... self.bounds.width - newSize/2)
                let y = CGFloat.random(in: -newSize/2 ... self.bounds.height - newSize/2)
                circle.frame = CGRect(x: x, y: y, width: newSize, height: newSize)
                circle.layer.cornerRadius = newSize / 2
            },
            completion: { [weak self, weak circle] finished in
                guard let self, let circle, finished,
                      self.animating, self.animationAllowed,
                      generation == self.animationGeneration else { return }
                self.completedLoops &+= 1
                Self.springboardAnimationLoops &+= 1
                self.animateCircle(circle, delay: 0, generation: generation)
            }
        )
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
#if !JARBOX_BG_ANIM_BASELINE
        if window == nil {
            // Fullscreen presentations can detach the springboard layer
            // without immediately triggering a lifecycle callback.
            setAnimationsActive(false, reason: "detached from window")
        } else if animationAllowed {
            startAnimationsIfNeeded()
        }
#endif
    }

    private func randomSize() -> CGFloat {
        let base = min(bounds.width, bounds.height)
        return CGFloat.random(in: base * 0.3 ... base * 0.7)
    }
}

#else

// Low-power springboard background.
//
// The old effect moves six UIKit views underneath a radius-40
// UIVisualEffectView. Although Core Animation does most of its work outside
// the app CPU budget, this keeps GPU compositing and backdrop filtering alive
// for as long as the library screen is visible. Replace it with one opaque
// raster drawn ONCE per size/scale. No layers animate or have live filters.
//
// JARBOX_BG_ANIM_BASELINE keeps the original implementation available as an
// opt-in matched build baseline. Deep Treo and Java rendering are untouched.
import UIKit

final class AnimatedBackgroundView: UIView {
    private let backdrop = UIImageView()
    private var renderedSize: CGSize = .zero
    private var renderedScale: CGFloat = 0
    private var renderCount: UInt64 = 0

    // Retain the existing fields used by GameViewController's AFK report.
    static private(set) var springboardAnimating = false
    static private(set) var springboardPauseLayers = 0
    static private(set) var springboardAnimationLoops: UInt64 = 0

    var activeAnimationLayers: Int { 0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        backdrop.isOpaque = true
        backdrop.contentMode = .scaleToFill
        backdrop.isUserInteractionEnabled = false
        backdrop.accessibilityElementsHidden = true
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func logAnimationState(_ reason: String) {
        NSLog("[JarBoxBG] mode=static_bitmap reason=%@ animated=no animation_layers=0 renders=%llu cached_px=%dx%d",
              reason, renderCount,
              Int(renderedSize.width * renderedScale),
              Int(renderedSize.height * renderedScale))
    }

    func setAnimationsActive(_ enabled: Bool, reason: String) {
        // No periodic work to start or stop, including during app switching.
        Self.springboardAnimating = false
        Self.springboardPauseLayers = 0
        logAnimationState(reason)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return }
        // Cap the backing store at 2x resolution to avoid a large 3x
        // full-screen allocation while retaining smooth static gradients.
        let scale = min(window?.screen.scale ?? UIScreen.main.scale, 2.0)
        let size = bounds.size
        guard size != renderedSize || scale != renderedScale else { return }
        renderedSize = size
        renderedScale = scale
        backdrop.image = Self.makeBackground(size: size, scale: scale)
        renderCount &+= 1
        logAnimationState("bitmap prepared; one image, no blur/compositor loop")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Window scale can differ on an external display. The next layout
        // rerenders at most once if dimensions/scale really changed.
        if window != nil { setNeedsLayout() }
    }

    private static func makeBackground(size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let points: [(CGFloat, CGFloat, CGFloat, UIColor)] = [
            (0.10, 0.20, 0.55, UIColor(red: 0.17, green: 0.25, blue: 0.64, alpha: 0.46)),
            (0.91, 0.14, 0.51, UIColor(red: 0.49, green: 0.12, blue: 0.36, alpha: 0.40)),
            (0.75, 0.63, 0.65, UIColor(red: 0.04, green: 0.38, blue: 0.41, alpha: 0.39)),
            (0.17, 0.74, 0.56, UIColor(red: 0.36, green: 0.17, blue: 0.48, alpha: 0.38)),
            (0.45, 0.38, 0.49, UIColor(red: 0.10, green: 0.38, blue: 0.28, alpha: 0.28)),
            (0.86, 0.91, 0.57, UIColor(red: 0.53, green: 0.24, blue: 0.14, alpha: 0.30)),
        ]
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            UIColor(red: 0.015, green: 0.025, blue: 0.055, alpha: 1).setFill()
            renderer.fill(CGRect(origin: .zero, size: size))
            let context = renderer.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let base = min(size.width, size.height)
            for (x, y, radiusScale, color) in points {
                let radius = base * radiusScale
                let core = color.cgColor
                let outer = color.withAlphaComponent(0).cgColor
                guard let gradient = CGGradient(
                    colorsSpace: colorSpace,
                    colors: [core, outer] as CFArray,
                    locations: [0.0, 1.0]) else { continue }
                context.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: size.width * x, y: size.height * y),
                    startRadius: 0,
                    endCenter: CGPoint(x: size.width * x, y: size.height * y),
                    endRadius: radius,
                    options: [])
            }
        }
    }
}

#endif
