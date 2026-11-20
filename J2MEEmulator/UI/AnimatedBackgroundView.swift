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
