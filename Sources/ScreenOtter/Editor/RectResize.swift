import CoreGraphics

/// Edges of a rect being dragged by a resize handle.
nonisolated struct RectEdges: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let left = RectEdges(rawValue: 1)
    static let right = RectEdges(rawValue: 2)
    static let top = RectEdges(rawValue: 4)
    static let bottom = RectEdges(rawValue: 8)
}

/// Resizing and moving a rectangle by its corners and edges (top-left origin), for the crop and for
/// redactions.
nonisolated enum RectResize {
    /// How far inside a rect its edges can be grabbed: the full tolerance on a big rect, but never more
    /// than a quarter of the side, so a small rect (a box around one line of text) keeps a middle band
    /// that moves it instead of resizing it, at any zoom.
    static func inwardReach(across side: CGFloat, tolerance: CGFloat) -> CGFloat {
        min(tolerance, abs(side) / 4)
    }

    /// Which edges a point grabs: a corner near two edges, an edge near one along its length, nothing in
    /// the middle or far away (which moves or misses instead). Outside the rect an edge reaches out by
    /// `tolerance`; inside only by its `inwardReach`, and opposite edges never both grab.
    static func edges(at p: CGPoint, of rect: CGRect, tolerance: CGFloat) -> RectEdges {
        let r = rect.standardized
        guard r.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return [] }
        let reachX = inwardReach(across: r.width, tolerance: tolerance)
        let reachY = inwardReach(across: r.height, tolerance: tolerance)
        var edges: RectEdges = []
        if p.x <= r.minX + reachX { edges.insert(.left) } else if p.x >= r.maxX - reachX { edges.insert(.right) }
        if p.y <= r.minY + reachY { edges.insert(.top) } else if p.y >= r.maxY - reachY { edges.insert(.bottom) }
        return edges
    }

    /// `original` with the dragged edges moved by `delta`. An edge stops `minimumSide` short of the one
    /// opposite, so the rect never flips or collapses under the pointer.
    static func resized(_ original: CGRect, edges: RectEdges, by delta: CGPoint, minimumSide: CGFloat) -> CGRect {
        let r = original.standardized
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        if edges.contains(.left) { minX = min(r.minX + delta.x, maxX - minimumSide) }
        if edges.contains(.right) { maxX = max(r.maxX + delta.x, minX + minimumSide) }
        if edges.contains(.top) { minY = min(r.minY + delta.y, maxY - minimumSide) }
        if edges.contains(.bottom) { maxY = max(r.maxY + delta.y, minY + minimumSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The part of `delta` that moves `rect` without leaving `bounds`: it stops at the edge and follows
    /// again once the pointer comes back. A rect already sticking out can still move back in.
    static func translation(moving rect: CGRect, by delta: CGPoint, within bounds: CGRect) -> CGPoint {
        let r = rect.standardized
        func clamp(_ d: CGFloat, low: CGFloat, high: CGFloat, boundsLow: CGFloat, boundsHigh: CGFloat) -> CGFloat {
            min(max(d, min(boundsLow - low, 0)), max(boundsHigh - high, 0))
        }
        return CGPoint(
            x: clamp(delta.x, low: r.minX, high: r.maxX, boundsLow: bounds.minX, boundsHigh: bounds.maxX),
            y: clamp(delta.y, low: r.minY, high: r.maxY, boundsLow: bounds.minY, boundsHigh: bounds.maxY)
        )
    }
}
