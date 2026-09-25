import SwiftUI

/// Zoom and pan of the treemap. Owned by `ResultsModel` so toolbar buttons and the treemap share it without
/// passing closures through focused values.
@Observable
@MainActor
final class TreemapViewport {
    static let maxZoom: CGFloat = 50
    private static let stepFactor: CGFloat = 0.5

    private(set) var transform = TreemapTransform()
    /// Set by the treemap view on layout changes; bounds panning and centers toolbar zooms.
    @ObservationIgnored var viewSize: CGSize = .zero {
        didSet { if viewSize != oldValue { setTransform(clamped(transform)) } }
    }

    var canZoomIn: Bool { transform.zoom < Self.maxZoom }
    var canZoomOut: Bool { transform.zoom > 1 }

    /// Multiplies the zoom by `1 + factor`, keeping the content under `point` fixed on screen.
    func zoom(by factor: CGFloat, around point: CGPoint) {
        let newZoom = max(1, min(transform.zoom * (1 + factor), Self.maxZoom))
        guard newZoom != transform.zoom else { return }
        let anchor = transform.contentPoint(for: point)
        let pan = CGPoint(x: point.x - anchor.x * newZoom, y: point.y - anchor.y * newZoom)
        setTransform(clamped(TreemapTransform(zoom: newZoom, pan: pan)))
    }

    func zoomIn() {
        zoom(by: Self.stepFactor, around: center)
    }

    func zoomOut() {
        // Inverse of one zoom-in step.
        zoom(by: 1 / (1 + Self.stepFactor) - 1, around: center)
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        var moved = transform
        moved.pan.x += dx
        moved.pan.y += dy
        setTransform(clamped(moved))
    }

    func reset() {
        setTransform(TreemapTransform())
    }

    private var center: CGPoint {
        CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    /// Keeps the zoomed content covering the whole view.
    private func clamped(_ transform: TreemapTransform) -> TreemapTransform {
        var result = transform
        result.pan.x = min(0, max(viewSize.width - viewSize.width * transform.zoom, transform.pan.x))
        result.pan.y = min(0, max(viewSize.height - viewSize.height * transform.zoom, transform.pan.y))
        return result
    }

    /// Assigns only real changes so observers are not invalidated by no-op updates.
    private func setTransform(_ newValue: TreemapTransform) {
        if newValue != transform { transform = newValue }
    }
}
