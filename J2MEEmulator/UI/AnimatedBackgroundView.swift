// JarBox low-power library background.
// A single opaque, unchanging system view: no gradient, bitmap allocation,
// blur, blending layers, display link, random movement or animation loop.
// Retain the existing class name/diagnostic interface for callers.
import UIKit

final class AnimatedBackgroundView: UIView {
    static let backgroundGray = UIColor(white: 0.16, alpha: 1.0)

    static private(set) var springboardAnimating = false
    static private(set) var springboardPauseLayers = 0
    static private(set) var springboardAnimationLoops: UInt64 = 0

    var activeAnimationLayers: Int { 0 }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        backgroundColor = Self.backgroundGray
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func logAnimationState(_ reason: String) {
        NSLog("[JarBoxBG] mode=solid_gray animated=no animation_layers=0 bitmap_renders=0 reason=%@", reason)
    }

    func setAnimationsActive(_ enabled: Bool, reason: String) {
        // No visual work exists to start/resume, even when the scene changes.
        Self.springboardAnimating = false
        Self.springboardPauseLayers = 0
        logAnimationState(reason)
    }
}
