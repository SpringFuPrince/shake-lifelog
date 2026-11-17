import SwiftUI

enum TimelineZoomEvent {
    case began(CGPoint, scrollBy: (CGFloat) -> Bool)
    case delta(Double)
    case ended
}

/// Interpolates the actual photo frames, so both tile size and position follow
/// the gesture between adjacent column counts. Each instance lays out a lazy chunk.
struct TimelinePhotoLayout: Layout {
    static let gap: CGFloat = 4
    var columns: Double
    var animatableData: Double {
        get { columns }
        set { columns = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        guard !subviews.isEmpty else { return CGSize(width: width, height: 0) }
        return CGSize(width: width, height: tileFrame(at: subviews.count - 1, width: width).maxY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            let tile = tileFrame(at: index, width: bounds.width)
            subview.place(
                at: CGPoint(x: bounds.minX + tile.minX, y: bounds.minY + tile.minY),
                anchor: .topLeading, proposal: ProposedViewSize(width: tile.width, height: tile.height)
            )
        }
    }

    func tileFrame(at index: Int, width: CGFloat) -> CGRect {
        let (lower, upper, fraction) = interval
        let start = frame(at: index, columns: lower, width: width)
        let end = frame(at: index, columns: upper, width: width)
        let side = interpolate(start.width, end.width, fraction)
        return CGRect(x: interpolate(start.minX, end.minX, fraction),
                      y: interpolate(start.minY, end.minY, fraction), width: side, height: side)
    }

    private var interval: (Int, Int, CGFloat) {
        let count = max(2, min(6, columns))
        let lower = Int(count.rounded(.down))
        return (lower, min(6, lower + 1), CGFloat(count - Double(lower)))
    }

    private func frame(at index: Int, columns: Int, width: CGFloat) -> CGRect {
        let side = max(0, (width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns))
        let pitch = side + Self.gap
        return CGRect(x: CGFloat(index % columns) * pitch, y: CGFloat(index / columns) * pitch,
                      width: side, height: side)
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat, _ fraction: CGFloat) -> CGFloat {
        start + (end - start) * fraction
    }
}

private func pinchDelta(from previous: CGFloat, to current: CGFloat) -> Double {
    -2.7 * log2(Double(max(0.01, current) / max(0.01, previous)))
}

#if os(iOS)
struct TimelineMagnifier: UIViewRepresentable {
    let isActive: Bool
    let onZoom: (TimelineZoomEvent) -> Void
    func makeUIView(context: Context) -> Surface { Surface() }
    func updateUIView(_ view: Surface, context: Context) {
        view.isActive = isActive
        view.onZoom = onZoom
    }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.detach() }

    final class Surface: UIView, UIGestureRecognizerDelegate {
        var isActive = false
        var onZoom: ((TimelineZoomEvent) -> Void)?
        private weak var attachedWindow: UIWindow?
        private var previousScale: CGFloat = 1
        private lazy var pinch: UIPinchGestureRecognizer = {
            let recognizer = UIPinchGestureRecognizer(target: self, action: #selector(zoomed(_:)))
            recognizer.cancelsTouchesInView = true
            recognizer.delegate = self
            return recognizer
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            attachedWindow = window
            window?.addGestureRecognizer(pinch)
            isUserInteractionEnabled = false
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(pinch)
            attachedWindow = nil
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isActive, window != nil, !isHidden, !bounds.isEmpty else { return false }
            return bounds.contains(gestureRecognizer.location(in: self))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        @objc private func zoomed(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                previousScale = 1
                let point = recognizer.location(in: self)
                onZoom?(.began(point, scrollBy: { [weak self] delta in
                    self?.scroll(by: delta, near: point) ?? false
                }))
                fallthrough
            case .changed:
                let current = recognizer.scale
                onZoom?(.delta(pinchDelta(from: previousScale, to: current)))
                previousScale = current
            case .ended, .cancelled, .failed:
                onZoom?(.ended)
            default: break
            }
        }

        private func scroll(by delta: CGFloat, near point: CGPoint) -> Bool {
            guard let window else { return false }
            var view = window.hitTest(convert(point, to: window), with: nil)
            while let candidate = view {
                if let scroll = candidate as? UIScrollView {
                    let inset = scroll.adjustedContentInset
                    let upper = max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
                    let y = min(upper, max(-inset.top, scroll.contentOffset.y + delta))
                    if abs(y - scroll.contentOffset.y) < 0.25 { return true }
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
                    return true
                }
                view = candidate.superview
            }
            return false
        }
    }
}
#else
struct TimelineMagnifier: NSViewRepresentable {
    let onZoom: (TimelineZoomEvent) -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.onZoom = onZoom
    }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.detach() }

    final class Surface: NSView, NSGestureRecognizerDelegate {
        var onZoom: ((TimelineZoomEvent) -> Void)?
        override var isFlipped: Bool { true }
        private weak var host: NSView?
        private var eventMonitor: Any?
        private var wheelEnd: DispatchWorkItem?
        private var wheelActive = false
        private var modifiedMagnificationPoint: CGPoint?
        private var previousScale: CGFloat = 1
        private lazy var pinch: NSMagnificationGestureRecognizer = {
            let recognizer = NSMagnificationGestureRecognizer(target: self, action: #selector(zoomed(_:)))
            recognizer.delegate = self
            return recognizer
        }()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard let root = window?.contentView else { return }
            host = root
            root.addGestureRecognizer(pinch)
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self else { return event }
                if event.type == .magnify { return self.handleModifiedMagnification(event) }
                return self.handleWheel(event)
            }
        }

        func detach() {
            host?.removeGestureRecognizer(pinch)
            host = nil
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            resetWheel()
            modifiedMagnificationPoint = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func gestureRecognizerShouldBegin(_ recognizer: NSGestureRecognizer) -> Bool {
            contains(recognizer.location(in: self))
        }

        func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }

        private func contains(_ point: CGPoint) -> Bool {
            window != nil && !isHiddenOrHasHiddenAncestor && bounds.contains(point) && visibleRect.contains(point)
        }

        private func begin(at point: CGPoint) {
            onZoom?(.began(point, scrollBy: { [weak self] delta in
                self?.scroll(by: delta, near: point) ?? false
            }))
        }

        @objc private func zoomed(_ recognizer: NSMagnificationGestureRecognizer) {
            switch recognizer.state {
            case .began:
                finishWheel()
                previousScale = 1
                begin(at: recognizer.location(in: self))
                fallthrough
            case .changed:
                let current = 1 + recognizer.magnification
                onZoom?(.delta(pinchDelta(from: previousScale, to: current)))
                previousScale = current
            case .ended, .cancelled, .failed:
                onZoom?(.ended)
            default: break
            }
        }

        private func hasCommand(_ event: NSEvent) -> Bool {
            event.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.command)
        }

        private func wheelPoint(for event: NSEvent, usePointer: Bool = false) -> CGPoint? {
            guard let window else { return nil }
            if let eventWindow = event.window {
                guard eventWindow === window else { return nil }
            } else if !window.isKeyWindow {
                return nil
            }
            let windowPoint = usePointer || event.window == nil
                ? window.convertPoint(fromScreen: NSEvent.mouseLocation)
                : event.locationInWindow
            let point = convert(windowPoint, from: nil)
            return contains(point) ? point : nil
        }

        private func handleModifiedMagnification(_ event: NSEvent) -> NSEvent? {
            if event.phase.contains(.began) {
                modifiedMagnificationPoint = nil
                guard hasCommand(event), let point = wheelPoint(for: event, usePointer: true) else { return event }
                finishWheel()
                // Mouse utilities may send magnification with a synthetic event location.
                modifiedMagnificationPoint = point
            }
            guard let point = modifiedMagnificationPoint else { return event }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                modifiedMagnificationPoint = nil
                finishWheel()
            } else if event.magnification != 0 {
                applyWheelZoom(pinchDelta(from: 1, to: 1 + event.magnification), at: point)
            }
            return nil
        }

        private func handleWheel(_ event: NSEvent) -> NSEvent? {
            guard hasCommand(event), let point = wheelPoint(for: event) else { return event }
            guard event.momentumPhase.isEmpty else { return nil }
            let rawDelta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
            guard rawDelta != 0 else { return event }
            let sensitivity = event.hasPreciseScrollingDeltas ? 0.012 : 0.55
            applyWheelZoom(-Double(rawDelta) * sensitivity, at: point)
            return nil
        }

        private func applyWheelZoom(_ delta: Double, at point: CGPoint) {
            var zoomDelta = delta
            if !wheelActive {
                begin(at: point)
                wheelActive = true
                // A single mouse notch must move far enough to settle at the next zoom level.
                zoomDelta = max(abs(zoomDelta), 0.55) * (zoomDelta < 0 ? -1 : 1)
            }
            onZoom?(.delta(zoomDelta))
            wheelEnd?.cancel()
            let finish = DispatchWorkItem { [weak self] in self?.finishWheel() }
            wheelEnd = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: finish)
        }

        private func finishWheel() {
            let wasActive = wheelActive
            resetWheel()
            if wasActive { onZoom?(.ended) }
        }

        private func resetWheel() {
            wheelEnd?.cancel()
            wheelEnd = nil
            wheelActive = false
        }

        private func scroll(by delta: CGFloat, near point: CGPoint) -> Bool {
            guard let host else { return false }
            var view = host.hitTest(convert(point, to: host.superview))
            while let candidate = view {
                if let scroll = candidate as? NSScrollView {
                    let clip = scroll.contentView
                    let y = delta * (clip.isFlipped ? 1 : -1)
                    var proposedBounds = clip.bounds
                    proposedBounds.origin.y += y
                    clip.scroll(to: clip.constrainBoundsRect(proposedBounds).origin)
                    scroll.reflectScrolledClipView(clip)
                    return true
                }
                view = candidate.superview
            }
            return false
        }
    }
}
#endif
