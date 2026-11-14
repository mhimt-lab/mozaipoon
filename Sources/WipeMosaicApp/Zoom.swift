import AppKit

/// Where the video sits in the viewer when it is enlarged, shared by the player (AppKit) and
/// the face boxes and text outlines drawn over it (SwiftUI), so both move together.
///
/// `center` is the point of the video shown at the middle of the viewer, in fractions of the
/// video (0…1, top-left origin). It is kept independent of the viewer's size, so resizing the
/// window keeps the same part of the video in view.
enum ZoomGeometry {
    static let levels: [CGFloat] = [1, 1.5, 2, 3, 4, 6, 8]
    static var maxZoom: CGFloat { levels[levels.count - 1] }

    /// The video's rectangle in the viewer (top-left origin). Edges never come inside the
    /// viewer while the video is larger than it; a side that fits is centered.
    static func videoRect(viewer: CGSize, video: CGSize, zoom: CGFloat, center: CGPoint) -> CGRect {
        guard viewer.width > 0, viewer.height > 0, video.width > 0, video.height > 0 else {
            return CGRect(origin: .zero, size: viewer)
        }
        let fit = min(viewer.width / video.width, viewer.height / video.height)
        let size = CGSize(width: video.width * fit * zoom, height: video.height * fit * zoom)
        let c = clamped(center, viewer: viewer, shown: size)
        return CGRect(
            x: viewer.width / 2 - c.x * size.width, y: viewer.height / 2 - c.y * size.height,
            width: size.width, height: size.height)
    }

    /// Frame of the whole player view (the viewer enlarged `zoom` times, the video centered in
    /// it as `.resizeAspect` draws it) that puts the video at `videoRect`.
    static func playerFrame(viewer: CGSize, video: CGSize, zoom: CGFloat, center: CGPoint) -> CGRect {
        let r = videoRect(viewer: viewer, video: video, zoom: zoom, center: center)
        let w = viewer.width * zoom, h = viewer.height * zoom
        return CGRect(x: r.minX - (w - r.width) / 2, y: r.minY - (h - r.height) / 2, width: w, height: h)
    }

    /// The center that keeps the video point under `point` (viewer coordinates) under it when
    /// the zoom changes from `zoom` to `newZoom`.
    static func center(
        keeping point: CGPoint, viewer: CGSize, video: CGSize, zoom: CGFloat, newZoom: CGFloat, center: CGPoint
    ) -> CGPoint {
        let r = videoRect(viewer: viewer, video: video, zoom: zoom, center: center)
        let n = videoRect(viewer: viewer, video: video, zoom: newZoom, center: center)
        guard r.width > 0, r.height > 0, n.width > 0, n.height > 0 else { return center }
        let p = CGPoint(x: (point.x - r.minX) / r.width, y: (point.y - r.minY) / r.height)
        let c = CGPoint(
            x: p.x + (viewer.width / 2 - point.x) / n.width, y: p.y + (viewer.height / 2 - point.y) / n.height)
        return clamped(c, viewer: viewer, shown: n.size)
    }

    /// The center after moving the video by `delta` points (scrolling), within its edges.
    static func center(
        scrolledBy delta: CGVector, viewer: CGSize, video: CGSize, zoom: CGFloat, center: CGPoint
    ) -> CGPoint {
        let r = videoRect(viewer: viewer, video: video, zoom: zoom, center: center)
        guard r.width > 0, r.height > 0 else { return center }
        let c = CGPoint(
            x: (viewer.width / 2 - r.minX - delta.dx) / r.width, y: (viewer.height / 2 - r.minY - delta.dy) / r.height)
        return clamped(c, viewer: viewer, shown: r.size)
    }

    private static func clamped(_ c: CGPoint, viewer: CGSize, shown: CGSize) -> CGPoint {
        func axis(_ v: CGFloat, _ view: CGFloat, _ size: CGFloat) -> CGFloat {
            guard size > view, size > 0 else { return 0.5 }
            let half = view / 2 / size
            return min(max(v, half), 1 - half)
        }
        return CGPoint(x: axis(c.x, viewer.width, shown.width), y: axis(c.y, viewer.height, shown.height))
    }
}

extension AppModel {
    /// Size of the shown video for the zoom (as the viewer lays it out).
    private var zoomVideoSize: CGSize? { current?.info?.size }

    /// From the menu or keys: around the pointer when it is over the video, else the middle.
    func zoomIn() { setZoom(ZoomGeometry.levels.first { $0 > zoom + 0.01 } ?? ZoomGeometry.maxZoom, at: pointerInViewer) }
    func zoomOut() { setZoom(ZoomGeometry.levels.last { $0 < zoom - 0.01 } ?? 1, at: pointerInViewer) }
    func resetZoom() { setZoom(1) }

    private var pointerInViewer: CGPoint? {
        guard let view = viewerView, let w = view.window else { return nil }
        let p = view.convert(w.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return view.bounds.contains(p) ? p : nil
    }

    /// Moves the enlarged view by `delta` points (dragging the video, scrolling).
    func panZoom(by delta: CGVector) {
        guard zoom > 1, let view = viewerView, let video = zoomVideoSize else { return }
        zoomCenter = ZoomGeometry.center(
            scrolledBy: delta, viewer: view.bounds.size, video: video, zoom: zoom, center: zoomCenter)
    }

    /// While enlarged, brings `person`'s face in frame `f` to the middle (going to a person
    /// would otherwise show nothing when their face is outside the view).
    func showZoomed(person id: Int, atFrame f: Int) {
        guard zoom > 1, let analysis = current?.analysis, let video = zoomVideoSize,
            let face = analysis.faces(atFrame: f).first(where: { $0.person == id })
        else { return }
        let r = face.rect  // Core Image coordinates (bottom-left origin)
        zoomCenter = CGPoint(x: r.midX / video.width, y: 1 - r.midY / video.height)
    }

    /// Changes the zoom keeping `point` (viewer coordinates; the middle when nil) in place.
    func setZoom(_ z: CGFloat, at point: CGPoint? = nil) {
        let newZoom = min(max(z, 1), ZoomGeometry.maxZoom)
        if let view = viewerView, let video = zoomVideoSize {
            let viewer = view.bounds.size
            let p = point ?? CGPoint(x: viewer.width / 2, y: viewer.height / 2)
            zoomCenter = ZoomGeometry.center(
                keeping: p, viewer: viewer, video: video, zoom: zoom, newZoom: newZoom, center: zoomCenter)
        }
        if newZoom == 1 { zoomCenter = CGPoint(x: 0.5, y: 0.5) }
        zoom = newZoom
    }

    /// Pinch to zoom, double-tap with two fingers (smart zoom) and scroll to move, over the
    /// video in the main window (dragging the video is in `ZoomingPlayerView`). Scrolling is
    /// left to the rest of the window (the lists) while the video is not enlarged.
    func handleZoomEvent(_ e: NSEvent) -> Bool {
        guard let w = e.window, w === mainWindow, w.attachedSheet == nil, hasVideo,
            let view = viewerView, view.window === w, zoomVideoSize != nil
        else { return false }
        let p = view.convert(e.locationInWindow, from: nil)  // the viewer is flipped (top-left origin)
        switch e.type {
        case .magnify:
            // A pinch that started over the video keeps zooming if the pointer leaves it.
            if e.phase == .began { pinching = view.bounds.contains(p) }
            guard pinching else { return false }
            if e.phase == .ended || e.phase == .cancelled {
                pinching = false
                if zoom < 1.05 { setZoom(1) }
                return true
            }
            setZoom(zoom * (1 + e.magnification), at: p)
            return true
        case .smartMagnify:
            guard view.bounds.contains(p) else { return false }
            setZoom(zoom > 1 ? 1 : 2, at: p)
            return true
        case .scrollWheel:
            // A trackpad scroll and its momentum go where it started; a mouse wheel's clicks
            // (no phase) where the pointer is.
            if e.phase == .began || (e.phase.isEmpty && e.momentumPhase.isEmpty) {
                scrollOverViewer = view.bounds.contains(p)
            }
            guard zoom > 1, scrollOverViewer else { return false }
            // A mouse wheel reports lines, a trackpad points.
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
            panZoom(by: CGVector(dx: e.scrollingDeltaX * k, dy: e.scrollingDeltaY * k))
            return true
        default:
            return false
        }
    }

    /// "200%".
    var zoomLabel: String { "\(Int((zoom * 100).rounded()))%" }

    /// The part of the video in view, in fractions of the video (for the navigator).
    func visiblePart(viewer: CGSize, video: CGSize) -> CGRect {
        let r = ZoomGeometry.videoRect(viewer: viewer, video: video, zoom: zoom, center: zoomCenter)
        guard r.width > 0, r.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let x0 = max(0, -r.minX) / r.width, y0 = max(0, -r.minY) / r.height
        let x1 = min(viewer.width - r.minX, r.width) / r.width, y1 = min(viewer.height - r.minY, r.height) / r.height
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}
