import AVFoundation
import CoreImage
import Vision

// Slanted lines and four-cornered shapes (QR codes, lines on a screen filmed at an angle).

/// Slants a line is drawn slanted at (see `TextTrack.measureTilt`).
let minTilt = 2 * CGFloat.pi / 180, maxTilt = 35 * CGFloat.pi / 180

/// The slanted line whose upright box is `r`, at slant `angle`: its centre, length and height.
/// A line of length L and height h turned by θ has an upright box of L·cosθ + h·sinθ by
/// L·sinθ + h·cosθ; solved for L and h. Nil beyond `maxTilt` (near 45° the two are mixed up
/// and small errors of the box grow large) and when the box cannot be such a line.
func slantedBox(_ r: CGRect, angle: CGFloat) -> (center: CGPoint, length: CGFloat, height: CGFloat)? {
    guard abs(angle) <= maxTilt + 1e-9, r.width > 0, r.height > 0 else { return nil }
    let c = cos(angle), s = abs(sin(angle)), d = c * c - s * s
    let length = (r.width * c - r.height * s) / d, height = (r.height * c - r.width * s) / d
    guard length > 0, height > 0 else { return nil }
    return (CGPoint(x: r.midX, y: r.midY), length, height)
}

/// Least slack of a slant (see `TextTrack.tiltSlacks`): readings of a still line differ by
/// about this much.
let minTiltSlack = 0.25 * CGFloat.pi / 180

/// A slanted line where it is drawn (pixels, Core Image coordinates).
struct SlantedLine {
    let center: CGPoint, angle: CGFloat, length: CGFloat, height: CGFloat

    /// From its upright box (`slantedBox`), with at least `height` (its measured height).
    init?(box: CGRect, angle: CGFloat, height: CGFloat) {
        guard let b = slantedBox(box, angle: angle) else { return nil }
        center = b.center
        self.angle = angle
        length = b.length
        self.height = max(b.height, height)
    }

    var along: CGPoint { CGPoint(x: cos(angle), y: sin(angle)) }
    var up: CGPoint { CGPoint(x: -sin(angle), y: cos(angle)) }
    /// `u` along the line and `v` across it (up) from its centre.
    func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
        CGPoint(x: center.x + u * along.x + v * up.x, y: center.y + u * along.y + v * up.y)
    }
    /// Its bottom left corner, which the mosaic blocks line up with.
    var start: CGPoint { point(-length / 2, -height / 2) }

    /// The part `rel` (along the line from its start 0 to its end 1; across it from its bottom
    /// 0 to its top 1) of each of `lines` (one line at one slant, where it was and where it
    /// moved), with `along` and `across` added on each side, as one quad: top left, top right,
    /// bottom right, bottom left, as `codeBlocks` draws a quad. All of them and what lies
    /// between them (a line moving from one to the other) are inside. The slant may be off by
    /// `slack`, turning a point at distance r from the centre by r × `slack` across.
    static func quad(_ lines: [SlantedLine], rel: CGRect, along: CGFloat, across: CGFloat, slack: CGFloat) -> [CGPoint] {
        let base = lines[0]
        var u0 = CGFloat.infinity, u1 = -CGFloat.infinity, v0 = CGFloat.infinity, v1 = -CGFloat.infinity
        for l in lines {
            let a0 = (rel.minX - 0.5) * l.length, a1 = (rel.maxX - 0.5) * l.length
            let turn = max(abs(a0), abs(a1)) * slack
            let b0 = (rel.minY - 0.5) * l.height - across - turn, b1 = (rel.maxY - 0.5) * l.height + across + turn
            for p in [l.point(a0 - along, b0), l.point(a1 + along, b0), l.point(a1 + along, b1), l.point(a0 - along, b1)] {
                let dx = p.x - base.center.x, dy = p.y - base.center.y
                let u = dx * base.along.x + dy * base.along.y, v = dx * base.up.x + dy * base.up.y
                u0 = min(u0, u); u1 = max(u1, u); v0 = min(v0, v); v1 = max(v1, v)
            }
        }
        return [base.point(u0, v1), base.point(u1, v1), base.point(u1, v0), base.point(u0, v0)]
    }
}

/// `p` lies in the convex quad `q` (on its edge too).
func quadContains(_ q: [CGPoint], _ p: CGPoint) -> Bool {
    guard q.count == 4 else { return false }
    let s: CGFloat = signedArea(q) >= 0 ? 1 : -1
    return q.indices.allSatisfy { i in
        let a = q[i], b = q[(i + 1) % 4]
        return s * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)) >= -1e-6
    }
}

/// `q`'s corners renamed to lie nearest `ref`'s of the same name: of the 4 turns, either way
/// round, the one with the least distance between corners of the same name.
func alignedCorners(_ q: [CGPoint], to ref: [CGPoint]) -> [CGPoint] {
    guard q.count == 4, ref.count == 4 else { return q }
    var best = q, bestCost = CGFloat.infinity
    for order in [q, Array(q.reversed())] {
        for shift in 0..<4 {
            let c = (0..<4).map { order[($0 + shift) % 4] }
            let cost = zip(c, ref).reduce(0) { $0 + hypot($1.0.x - $1.1.x, $1.0.y - $1.1.y) }
            if cost < bestCost - 1e-9 { best = c; bestCost = cost }
        }
    }
    return best
}

func boundingBox(_ q: [CGPoint]) -> CGRect {
    let xs = q.map(\.x), ys = q.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}

/// Area of a polygon, positive when its corners run counter-clockwise (y up).
func signedArea(_ q: [CGPoint]) -> CGFloat {
    var a: CGFloat = 0
    for i in q.indices {
        let p = q[i], n = q[(i + 1) % q.count]
        a += p.x * n.y - n.x * p.y
    }
    return a / 2
}

/// The convex quad `q` with every edge moved `d` outward (corners where the moved edges meet).
func outset(_ q: [CGPoint], by d: CGFloat) -> [CGPoint] {
    guard d > 0, q.count == 4 else { return q }
    let s: CGFloat = signedArea(q) >= 0 ? 1 : -1  // outward normal side
    // Each edge as a point on it and its direction, moved along the outward normal.
    let edges = q.indices.map { i -> (p: CGPoint, v: CGPoint) in
        let a = q[i], b = q[(i + 1) % 4]
        let v = CGPoint(x: b.x - a.x, y: b.y - a.y), len = max(hypot(v.x, v.y), 1e-6)
        let n = CGPoint(x: s * v.y / len, y: -s * v.x / len)
        return (CGPoint(x: a.x + n.x * d, y: a.y + n.y * d), v)
    }
    return q.indices.map { i in
        let e0 = edges[(i + 3) % 4], e1 = edges[i]  // the edges meeting at corner i
        let den = e0.v.x * e1.v.y - e0.v.y * e1.v.x
        guard abs(den) > 1e-6 else { return e1.p }
        let t = ((e1.p.x - e0.p.x) * e1.v.y - (e1.p.y - e0.p.y) * e1.v.x) / den
        return CGPoint(x: e0.p.x + e0.v.x * t, y: e0.p.y + e0.v.y * t)
    }
}

/// Corners relative to a box (as `TextSample.corners`) placed in `box`.
func place(_ corners: [CGPoint], in box: CGRect) -> [CGPoint] {
    corners.map { CGPoint(x: box.minX + $0.x * box.width, y: box.minY + $0.y * box.height) }
}

func lerpPoints(_ a: [CGPoint], _ b: [CGPoint], _ u: CGFloat) -> [CGPoint] {
    zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * u, y: $0.y + ($1.y - $0.y) * u) }
}
