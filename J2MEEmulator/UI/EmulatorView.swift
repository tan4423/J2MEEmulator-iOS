//
//  EmulatorView.swift
//  J2MEEmulator
//
//  Displays the J2ME Canvas framebuffer on screen.
//  Handles touch events and converts to J2ME pointer events.
//

import UIKit

// One pending frame per view. The VM may submit from a background thread;
// UIKit is only touched by the main-queue drain.
nonisolated private final class LatestGameFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (image: CGImage, ownerKey: UInt64, token: UInt64)?
    private var scheduled = false

    func submit(_ frame: CGImage, ownerKey: UInt64, token: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pending != nil { treo_render_profile_replaced() }
        pending = (frame, ownerKey, token)
        if scheduled { return false }
        scheduled = true
        return true
    }

    func clearPending() {
        lock.lock()
        pending = nil
        // Keep the scheduled flag: an already queued drain still owns it.
        lock.unlock()
    }

    func take() -> (image: CGImage, ownerKey: UInt64, token: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        let frame = pending
        pending = nil
        scheduled = false
        return frame
    }
}

class EmulatorView: UIView {
    private nonisolated let latestFrame = LatestGameFrame()

    // J2ME virtual canvas size
    var canvasWidth: Int = 240
    var canvasHeight: Int = 320
    var inputSessionToken: UInt64 = 0
    private var activePointers: [ObjectIdentifier: (Int, Int)] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        contentMode = .scaleAspectFit
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
    }

    /// Called once when the first frame is rendered, then nilled out.
    var onFirstFrame: (() -> Void)?

    /// Called every frame with the CGImage (for glow mirror etc.)
    var onFrame: ((CGImage) -> Void)?

    /// Update the displayed image from a CGImage.
    func clearPendingGameFrame() { latestFrame.clearPending() }

    nonisolated func displayImage(_ cgImage: CGImage, ownerKey: UInt64, token: UInt64) {
        // Native Canvas already checked its own Treo mode. No process-global
        // AFK mirror or unowned destination is allowed in the owned route.
        guard token != 0, ownerKey != 0,
              j2me_render_visible_owner_key() == ownerKey,
              jvm_bridge_visible_session_token() == token,
              gameFrameDestination.lookup(token: token) === self,
              latestFrame.submit(cgImage, ownerKey: ownerKey, token: token) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let frame = self.latestFrame.take() else { return }
            guard self.inputSessionToken == frame.token,
                  gameFrameDestination.lookup(token: frame.token) === self,
                  jvm_bridge_visible_session_token() == frame.token,
                  j2me_render_visible_owner_key() == frame.ownerKey,
                  treo_mode_for_token(frame.token) == 0 else { return }
            self.layer.contents = frame.image
            treo_render_profile_submitted()
            self.onFrame?(frame.image)
            if let cb = self.onFirstFrame {
                self.onFirstFrame = nil
                cb()
            }
        }
    }

    // ============================================================
    // Touch handling
    // ============================================================

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputSessionToken != 0,
              jvm_bridge_visible_session_token() == inputSessionToken else { return }
        for touch in touches {
            if let (vx, vy) = convertToVirtual(touch.location(in: self)) {
                activePointers[ObjectIdentifier(touch)] = (vx, vy)
                j2me_input_post_touch_for_token(inputSessionToken, Int32(J2ME_INPUT_POINTER_PRESSED), Int32(vx), Int32(vy))
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard activePointers[id] != nil else { continue }
            if let (vx, vy) = convertToVirtual(touch.location(in: self)) {
                activePointers[id] = (vx, vy)
                j2me_input_post_touch_for_token(inputSessionToken, Int32(J2ME_INPUT_POINTER_DRAGGED), Int32(vx), Int32(vy))
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let last = activePointers.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            let (vx, vy) = convertToVirtual(touch.location(in: self)) ?? last
            j2me_input_post_touch_for_token(inputSessionToken, Int32(J2ME_INPUT_POINTER_RELEASED), Int32(vx), Int32(vy))
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    func cancelGameInput() {
        for (vx, vy) in activePointers.values {
            j2me_input_post_touch_for_token(inputSessionToken, Int32(J2ME_INPUT_POINTER_RELEASED), Int32(vx), Int32(vy))
        }
        activePointers.removeAll()
    }

    /// Convert screen point to J2ME virtual canvas coordinates.
    /// Returns nil if the touch is outside the canvas area.
    private func convertToVirtual(_ point: CGPoint) -> (Int, Int)? {
        let viewW = bounds.width
        let viewH = bounds.height
        guard viewW > 0 && viewH > 0 else { return nil }

        let cw = CGFloat(canvasWidth)
        let ch = CGFloat(canvasHeight)

        // Calculate aspect-fit layout (same as CALayer's .resizeAspect)
        let scaleX = viewW / cw
        let scaleY = viewH / ch
        let scale = min(scaleX, scaleY)

        let displayW = cw * scale
        let displayH = ch * scale
        let offsetX = (viewW - displayW) / 2
        let offsetY = (viewH - displayH) / 2

        // Convert screen coords to virtual coords
        let vx = (point.x - offsetX) * cw / displayW
        let vy = (point.y - offsetY) * ch / displayH

        // Clamp to canvas bounds
        let cx = max(0, min(cw - 1, vx))
        let cy = max(0, min(ch - 1, vy))

        return (Int(cx), Int(cy))
    }
}

// ============================================================
// Global flush callback
// ============================================================

// Weak foreground route: a delayed completion may clear only its own token.
nonisolated private final class GameFrameDestination<View: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private weak var view: View?
    private var token: UInt64 = 0

    func bind(_ view: View, token: UInt64) {
        guard token != 0 else { return }
        lock.lock()
        self.view = view
        self.token = token
        lock.unlock()
    }

    func unbind(token: UInt64) {
        guard token != 0 else { return }
        lock.lock()
        if self.token == token {
            view = nil
            self.token = 0
        }
        lock.unlock()
    }

    func lookup(token: UInt64) -> View? {
        guard token != 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return self.token == token ? view : nil
    }
}

private let gameFrameDestination = GameFrameDestination<EmulatorView>()

func bindGameFrameView(_ view: EmulatorView, token: UInt64) {
    gameFrameDestination.bind(view, token: token)
}

func unbindGameFrameView(token: UInt64) {
    gameFrameDestination.unbind(token: token)
}

// iOS always registers the owned callback. Consume the legacy retained
// image without displaying it: no token means no provable UIKit owner.
let flushCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void = { cgImagePtr, _, _ in
    guard let ptr = cgImagePtr else { return }
    _ = Unmanaged<CGImage>.fromOpaque(ptr).takeRetainedValue()
}

let ownedFlushCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, UInt64, UInt64) -> Void = {
    cgImagePtr, _, _, ownerKey, token in
    guard let ptr = cgImagePtr else { return }
    let cgImage = Unmanaged<CGImage>.fromOpaque(ptr).takeRetainedValue()
    guard ownerKey != 0, token != 0,
          j2me_render_visible_owner_key() == ownerKey,
          jvm_bridge_visible_session_token() == token,
          let view = gameFrameDestination.lookup(token: token) else { return }
    view.displayImage(cgImage, ownerKey: ownerKey, token: token)
}
