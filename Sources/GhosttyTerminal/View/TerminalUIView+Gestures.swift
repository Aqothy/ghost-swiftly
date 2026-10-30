#if os(iOS)
import GhosttyVT
import UIKit

extension TerminalUIView: @MainActor UIGestureRecognizerDelegate, @MainActor UIEditMenuInteractionDelegate {
    func setUpGestures() {
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.maximumNumberOfTouches = 1
        // Fingers, and a trackpad's or mouse wheel's scrolling. A trackpad
        // or mouse click is a mouse button (touchesBegan), not a gesture.
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.allowedTouchTypes = direct
        scroll.allowedScrollTypesMask = .all
        addGestureRecognizer(scroll)

        // A tap only after the pan fails, so a drag never opens the
        // keyboard or clicks (libghostty-spm 06d3b4e).
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = direct
        tap.require(toFail: scroll)
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.allowedTouchTypes = direct
        longPress.delegate = self
        addGestureRecognizer(longPress)

        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        addInteraction(UIEditMenuInteraction(delegate: self))
    }

    /// Pinch and two-finger pan move a zoomed drawing together.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer || gestureRecognizer is UIPanGestureRecognizer)
            && (other is UIPinchGestureRecognizer || other is UIPanGestureRecognizer)
            && gestureRecognizer.numberOfTouches > 1
    }

    /// A tap opens the keyboard; with it open, a tap is a left click there,
    /// as a trackpad's. The accessory bar hides the keyboard.
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        if isFirstResponder {
            stopMomentum()
            // The press activates the view.
            let point = gesture.location(in: self)
            surface.send(.mouseButton(.press, .left, [], point, local: nil))
            surface.send(.mouseButton(.release, .left, [], point, local: nil))
        } else if !becomeFirstResponder() {
            // Focusing activates the view; a tap that can't focus still does.
            surface.tapped()
        }
    }

    /// A trackpad or mouse pointer moving with no button down, for programs
    /// that track motion; leaving the view ends it.
    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        let modifiers = Self.modifiers(gesture.modifierFlags)
        switch gesture.state {
        case .began, .changed: surface.send(.mouseMoved(modifiers, gesture.location(in: self)))
        default: surface.send(.mouseMoved(modifiers, nil))
        }
    }

    // MARK: Scrolling

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMomentum()
            // Wheel reports go where the pointer last was; seed it from the
            // touch (libghostty-spm fe46cb1).
            surface.send(.mouseMoved([], gesture.location(in: self)))
        case .changed:
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            surface.send(.scroll(x: translation.x, y: translation.y, precise: true))
        case .ended:
            startMomentum(gesture.velocity(in: self))
        default:
            stopMomentum()
        }
    }

    /// Keeps scrolling after a flick, slowing each frame.
    private func startMomentum(_ velocity: CGPoint) {
        guard abs(velocity.y) > 50 || abs(velocity.x) > 50 else { return }
        momentumVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(momentumFrame(_:)))
        link.add(to: .main, forMode: .common)
        momentum = link
    }

    @objc private func momentumFrame(_ link: CADisplayLink) {
        momentumVelocity.x *= 0.92
        momentumVelocity.y *= 0.92
        guard abs(momentumVelocity.x) >= 50 || abs(momentumVelocity.y) >= 50 else {
            stopMomentum()
            return
        }
        let elapsed = link.targetTimestamp - link.timestamp
        surface.send(.scroll(x: momentumVelocity.x * elapsed, y: momentumVelocity.y * elapsed, precise: true))
    }

    func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }

    // MARK: Selection

    /// A long press selects the word under it, a drag extends the
    /// selection, and lifting offers Copy.
    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            stopMomentum()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            surface.send(.mouseButton(.press, .left, [], point, local: nil))
            surface.send(.deepPress)
        case .changed:
            surface.send(.mouseMoved([], point))
        case .ended:
            surface.send(.mouseButton(.release, .left, [], point, local: nil))
            let menu = interactions.compactMap { $0 as? UIEditMenuInteraction }.first
            menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
        default:
            surface.send(.mouseButton(.release, .left, [], point, local: nil))
        }
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                    suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: suggestedActions)
    }

    // MARK: Zoom

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed else { return }
        surface.zoom(by: gesture.scale, around: gesture.location(in: self))
        gesture.scale = 1
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        surface.pan(by: gesture.translation(in: self))
        gesture.setTranslation(.zero, in: self)
    }
}
#endif
