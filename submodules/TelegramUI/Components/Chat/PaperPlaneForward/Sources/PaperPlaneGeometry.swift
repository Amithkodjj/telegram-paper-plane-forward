// Folds: F1 top corners, F2 slanted edges, F3 in half, F4 wings.

import CoreGraphics
import Foundation
import simd

public struct PaperPlaneConfig {
    public var sheetWidthFraction: CGFloat = 0.62
    public var sheetMaxWidth: CGFloat = 256
    public var sheetAspect: CGFloat = 1.3
    public var sheetCenterY: CGFloat = 0.44

    public var gatherDuration: Double = 0.5
    public var foldDuration: Double = 1.35
    public var holdDuration: Double = 0.38
    public var flightDuration: Double = 2.05
    public var trailFade: Double = 0.55

    public var cameraDistance: Float = 950
    public var bodyAngle: Float = 60 * .pi / 180
    public var wingAngle: Float = 46 * .pi / 180
    public var logoSpan: Float = 1.4
    public var logoSweep: Float = 0.5
    public var logoLength: Float = 0.72
    public var wingCreaseAtNose: Float = 0.025
    public var wingCreaseAtTail: Float = 0.165

    public var foldPitch: Float = -28 * .pi / 180
    public var heroPitch: Float = -12 * .pi / 180
    public var heroBank: Float = 26 * .pi / 180
    public var flightPitch: Float = -24 * .pi / 180
    public var heroScale: Float = 0.62
    public var flightScale: Float = 0.5
    public var landingScale: Float = 0.1
    public var maxBank: Float = 58 * .pi / 180

    public var trailWidth: Float = 2.6
    public var trailDash: Float = 15
    public var trailLifetime: Double = 1.05

    public init() {}
    public static let `default` = PaperPlaneConfig()
}

// MARK: - Facets

struct PaperHinge {
    var a: SIMD2<Float>
    var b: SIMD2<Float>

    var direction: SIMD2<Float> { simd_normalize(b - a) }

    func side(_ p: SIMD2<Float>) -> Float {
        let d = b - a
        let q = p - a
        return d.x * q.y - d.y * q.x
    }

    func reflect(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let d = direction
        let q = p - a
        return a + 2 * simd_dot(q, d) * d - q
    }

    var a3: SIMD3<Float> { SIMD3(a.x, a.y, 0) }
    var axis3: SIMD3<Float> { let d = direction; return SIMD3(d.x, d.y, 0) }
    var packed: SIMD4<Float> { let d = direction; return SIMD4(a.x, a.y, d.x, d.y) }
}

struct PaperFacet {
    var flat: [SIMD2<Float>]
    var folded: [SIMD2<Float>]
    var fold1 = -1
    var fold2 = -1
    var layer1 = 0
    var layer2 = 0
    var half = 0
    var wing = false
}

struct PaperFoldAngles {
    var f1: SIMD2<Float> = .zero
    var f2: SIMD2<Float> = .zero
    var body: Float = 0
    var wing: Float = 0
    var span: Float = 1
    var sweep: Float = 0
    var length: Float = 1
}

final class PaperPlaneModel {
    let width: Float
    let height: Float
    private(set) var facets: [PaperFacet] = []

    private(set) var f1: [PaperHinge] = []
    private(set) var f2: [PaperHinge] = []
    private(set) var wingHinge: [PaperHinge] = []
    private(set) var f1Member = SIMD2<Float>(1, 1)
    private(set) var f2Member = SIMD2<Float>(1, 1)
    private(set) var wingTips: [(facet: Int, corner: Int)] = []

    private var f1Sign = SIMD2<Float>(1, 1)
    private var f2Sign = SIMD2<Float>(1, 1)
    private var bodySign = SIMD2<Float>(1, -1)
    private var wingSign = SIMD2<Float>(1, -1)
    private let layerGap: Float = 0.45

    init(width: Float, height: Float, config: PaperPlaneConfig) {
        self.width = width
        self.height = height
        build(config: config)
    }

    private func build(config: PaperPlaneConfig) {
        let hw = width / 2
        let hh = height / 2
        let rect: [SIMD2<Float>] = [SIMD2(-hw, -hh), SIMD2(hw, -hh), SIMD2(hw, hh), SIMD2(-hw, hh)]
        var pieces = [PaperFacet(flat: rect, folded: rect)]
        let tip = SIMD2<Float>(0, hh)

        // F1: top corners to the center line.
        f1 = [PaperHinge(a: tip, b: SIMD2(-hw, hh - hw)), PaperHinge(a: tip, b: SIMD2(hw, hh - hw))]
        let f1Corner: [SIMD2<Float>] = [SIMD2(-hw, hh), SIMD2(hw, hh)]
        for k in 0..<2 {
            let hinge = f1[k]
            let sign: Float = hinge.side(f1Corner[k]) > 0 ? 1 : -1
            f1Member[k] = sign
            var next: [PaperFacet] = []
            for piece in pieces {
                let (member, rest) = Self.split(piece, by: hinge, memberSign: sign)
                if var member {
                    member.folded = member.folded.map(hinge.reflect)
                    member.fold1 = k
                    member.layer1 = 1
                    next.append(member)
                }
                if let rest { next.append(rest) }
            }
            pieces = next
            f1Sign[k] = Self.towardViewerSign(hinge: hinge, probe: SIMD3(f1Corner[k].x, f1Corner[k].y, 0))
        }
        for i in pieces.indices { pieces[i].layer2 = pieces[i].layer1 }

        // F2: the slanted edges to the center line (hinge at 22.5° from the center line).
        let s = sin(Float.pi / 8)
        let c = cos(Float.pi / 8)
        f2 = [PaperHinge(a: tip, b: tip + SIMD2(-s, -c) * height * 2),
              PaperHinge(a: tip, b: tip + SIMD2(s, -c) * height * 2)]
        let f2Probe: [SIMD2<Float>] = [SIMD2(-hw, hh - hw), SIMD2(hw, hh - hw)]
        for k in 0..<2 {
            let hinge = f2[k]
            let sign: Float = hinge.side(f2Probe[k]) > 0 ? 1 : -1
            f2Member[k] = sign
            var next: [PaperFacet] = []
            for piece in pieces {
                let (member, rest) = Self.split(piece, by: hinge, memberSign: sign)
                if var member {
                    member.folded = member.folded.map(hinge.reflect)
                    member.fold2 = k
                    member.layer2 = 3 - member.layer1
                    next.append(member)
                }
                if let rest { next.append(rest) }
            }
            pieces = next
            f2Sign[k] = Self.towardViewerSign(hinge: hinge, probe: SIMD3(f2Probe[k].x, f2Probe[k].y, 0))
        }

        // F3: split along the spine.
        let spine = PaperHinge(a: SIMD2(0, -hh), b: SIMD2(0, hh))
        let leftSign: Float = spine.side(SIMD2(-1, 0)) > 0 ? 1 : -1
        var halves: [PaperFacet] = []
        for piece in pieces {
            let (left, right) = Self.split(piece, by: spine, memberSign: leftSign)
            if var left { left.half = 0; halves.append(left) }
            if var right { right.half = 1; halves.append(right) }
        }

        // F4: wing creases, slightly diverging from the nose to the tail.
        wingHinge = [PaperHinge(a: SIMD2(-config.wingCreaseAtNose * width, hh), b: SIMD2(-config.wingCreaseAtTail * width, -hh)),
                     PaperHinge(a: SIMD2(config.wingCreaseAtNose * width, hh), b: SIMD2(config.wingCreaseAtTail * width, -hh))]
        let wingProbe: [SIMD2<Float>] = [SIMD2(-hw, -hh), SIMD2(hw, -hh)]
        var result: [PaperFacet] = []
        for piece in halves {
            let hinge = wingHinge[piece.half]
            let sign: Float = hinge.side(wingProbe[piece.half]) > 0 ? 1 : -1
            let (wing, body) = Self.split(piece, by: hinge, memberSign: sign)
            if var wing { wing.wing = true; result.append(wing) }
            if let body { result.append(body) }
        }
        facets = result

        // F3: halves rise towards the viewer (the flaps end up inside the fuselage).
        let spineAxis = SIMD3<Float>(0, 1, 0)
        let leftProbe = Self.rotate(SIMD3(-hw, 0, 0), around: .zero, axis: spineAxis, angle: 0.1)
        bodySign = leftProbe.z > 0 ? SIMD2(1, -1) : SIMD2(-1, 1)
        // F4: in the half's own frame the wing goes away from the viewer; after F3 it lies flat again.
        for k in 0..<2 {
            let probe = SIMD3(wingProbe[k].x, wingProbe[k].y, 0)
            let moved = Self.rotate(probe, around: wingHinge[k].a3, axis: wingHinge[k].axis3, angle: 0.1)
            wingSign[k] = moved.z < 0 ? 1 : -1
        }

        wingTips = wingProbe.compactMap { corner in
            for (f, facet) in facets.enumerated() {
                if let i = facet.flat.firstIndex(where: { simd_distance($0, corner) < 0.01 }) {
                    return (f, i)
                }
            }
            return nil
        }
    }

    func position(_ facet: PaperFacet, _ index: Int, _ angles: PaperFoldAngles) -> SIMD3<Float> {
        if angles.body <= 0 && angles.wing <= 0 {
            var p = SIMD3<Float>(facet.flat[index].x, facet.flat[index].y, 0)
            var layer = 0
            if facet.fold1 >= 0 {
                let k = facet.fold1
                let angle = angles.f1[k]
                p = Self.rotate(p, around: f1[k].a3, axis: f1[k].axis3, angle: angle * f1Sign[k])
                if angle > .pi / 2 { layer = facet.layer1 }
            }
            if facet.fold2 >= 0 {
                let k = facet.fold2
                let angle = angles.f2[k]
                p = Self.rotate(p, around: f2[k].a3, axis: f2[k].axis3, angle: angle * f2Sign[k])
                if angle > .pi / 2 { layer = facet.layer2 }
            }
            p.z += Float(layer) * layerGap
            return p
        }
        var p = SIMD3<Float>(facet.folded[index].x, facet.folded[index].y, Float(facet.layer2) * layerGap)
        let h = facet.half
        if facet.wing {
            p = Self.rotate(p, around: wingHinge[h].a3, axis: wingHinge[h].axis3, angle: angles.wing * wingSign[h])
        }
        p = Self.rotate(p, around: .zero, axis: SIMD3(0, 1, 0), angle: angles.body * bodySign[h])
        p.x *= angles.span
        p.y = p.y * angles.length - abs(p.x) * angles.sweep
        return p
    }

    func uv(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(p.x / width + 0.5, 0.5 - p.y / height)
    }

    var creaseLines: [SIMD4<Float>] {
        let hh = height / 2
        let spine = PaperHinge(a: SIMD2(0, -hh), b: SIMD2(0, hh))
        return [f1[0].packed, f1[1].packed, f2[0].packed, f2[1].packed, spine.packed, wingHinge[0].packed, wingHinge[1].packed]
    }

    // MARK: Helpers

    static func rotate(_ p: SIMD3<Float>, around a: SIMD3<Float>, axis u: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        if angle == 0 { return p }
        let v = p - a
        let c = cos(angle)
        let s = sin(angle)
        return a + v * c + simd_cross(u, v) * s + u * simd_dot(u, v) * (1 - c)
    }

    private static func towardViewerSign(hinge: PaperHinge, probe: SIMD3<Float>) -> Float {
        let moved = rotate(probe, around: hinge.a3, axis: hinge.axis3, angle: 0.1)
        return moved.z > 0 ? 1 : -1
    }

    /// Sutherland-Hodgman against one line.
    static func split(_ facet: PaperFacet, by hinge: PaperHinge, memberSign: Float) -> (PaperFacet?, PaperFacet?) {
        func clip(_ keep: Float) -> PaperFacet? {
            var flat: [SIMD2<Float>] = []
            var folded: [SIMD2<Float>] = []
            let n = facet.folded.count
            for i in 0..<n {
                let j = (i + 1) % n
                let si = hinge.side(facet.folded[i]) * memberSign * keep
                let sj = hinge.side(facet.folded[j]) * memberSign * keep
                if si >= 0 {
                    flat.append(facet.flat[i])
                    folded.append(facet.folded[i])
                }
                if (si >= 0) != (sj >= 0) {
                    let t = si / (si - sj)
                    flat.append(facet.flat[i] + (facet.flat[j] - facet.flat[i]) * t)
                    folded.append(facet.folded[i] + (facet.folded[j] - facet.folded[i]) * t)
                }
            }
            var cleanFlat: [SIMD2<Float>] = []
            var cleanFolded: [SIMD2<Float>] = []
            for i in flat.indices {
                if let last = cleanFlat.last, simd_distance(last, flat[i]) < 1e-3 { continue }
                cleanFlat.append(flat[i])
                cleanFolded.append(folded[i])
            }
            if cleanFlat.count > 1, let first = cleanFlat.first, let last = cleanFlat.last, simd_distance(first, last) < 1e-3 {
                cleanFlat.removeLast()
                cleanFolded.removeLast()
            }
            guard cleanFlat.count >= 3, abs(area(cleanFlat)) > 0.25 else { return nil }
            var result = facet
            result.flat = cleanFlat
            result.folded = cleanFolded
            return result
        }
        return (clip(1), clip(-1))
    }

    static func area(_ polygon: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for i in polygon.indices {
            let a = polygon[i]
            let b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - a.y * b.x
        }
        return sum / 2
    }
}

// MARK: - Flight path

struct PaperPlanePath {
    let points: [CGPoint]
    let length: CGFloat

    init(start: CGPoint, target: CGPoint, bounds: CGRect, safeTop: CGFloat) {
        let w = bounds.width
        let h = bounds.height
        let top = safeTop + 70
        let loopY = max(top + h * 0.12, start.y - h * 0.2)
        let radius = min(w * 0.17, h * 0.085)
        let loopX = w * 0.54
        let waypoints: [CGPoint] = [
            start,
            CGPoint(x: start.x + w * 0.19, y: start.y - h * 0.11),
            CGPoint(x: w * 0.87, y: loopY - h * 0.02),
            CGPoint(x: w * 0.72, y: loopY - radius - h * 0.015),
            CGPoint(x: loopX, y: loopY - radius * 0.95),
            CGPoint(x: loopX - radius, y: loopY),
            CGPoint(x: loopX, y: loopY + radius),
            CGPoint(x: loopX + radius, y: loopY),
            CGPoint(x: loopX - radius * 0.1, y: loopY - radius * 1.02),
            CGPoint(x: w * 0.2, y: loopY + h * 0.03),
            CGPoint(x: w * 0.1, y: start.y + h * 0.08),
            CGPoint(x: target.x + w * 0.05, y: target.y - h * 0.14),
            target,
        ]

        // Centripetal Catmull-Rom (no cusps or self-intersections between waypoints).
        var raw: [CGPoint] = []
        let n = waypoints.count
        for i in 0..<(n - 1) {
            let p0 = waypoints[max(i - 1, 0)], p1 = waypoints[i], p2 = waypoints[i + 1], p3 = waypoints[min(i + 2, n - 1)]
            func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(pow(hypot(b.x - a.x, b.y - a.y), 0.5), 1e-3) }
            let t0: CGFloat = 0
            let t1 = t0 + knot(p0, p1)
            let t2 = t1 + knot(p1, p2)
            let t3 = t2 + knot(p2, p3)
            let steps = 90
            for s in 0..<steps {
                let t = t1 + (t2 - t1) * CGFloat(s) / CGFloat(steps)
                func lerp(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat) -> CGPoint {
                    let k = (t - ta) / max(tb - ta, 1e-6)
                    return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
                }
                let a1 = lerp(p0, p1, t0, t1), a2 = lerp(p1, p2, t1, t2), a3 = lerp(p2, p3, t2, t3)
                let b1 = lerp(a1, a2, t0, t2), b2 = lerp(a2, a3, t1, t3)
                raw.append(lerp(b1, b2, t1, t2))
            }
        }
        raw.append(target)

        // Resample by arc length.
        var cumulative: [CGFloat] = [0]
        for i in 1..<raw.count {
            cumulative.append(cumulative[i - 1] + hypot(raw[i].x - raw[i - 1].x, raw[i].y - raw[i - 1].y))
        }
        let total = cumulative.last ?? 1
        let count = 900
        var even: [CGPoint] = []
        var j = 0
        for i in 0...count {
            let s = total * CGFloat(i) / CGFloat(count)
            while j < raw.count - 2 && cumulative[j + 1] < s { j += 1 }
            let span = max(cumulative[j + 1] - cumulative[j], 1e-6)
            let t = min(max((s - cumulative[j]) / span, 0), 1)
            even.append(CGPoint(x: raw[j].x + (raw[j + 1].x - raw[j].x) * t, y: raw[j].y + (raw[j + 1].y - raw[j].y) * t))
        }
        points = even
        length = total
    }

    func sample(_ progress: CGFloat) -> (point: CGPoint, heading: CGFloat) {
        let x = min(max(progress, 0), 1) * CGFloat(points.count - 1)
        let i = min(Int(x), points.count - 2)
        let t = x - CGFloat(i)
        let a = points[i], b = points[i + 1]
        let point = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        let lo = max(i - 4, 0), hi = min(i + 5, points.count - 1)
        let heading = atan2(points[hi].y - points[lo].y, points[hi].x - points[lo].x)
        return (point, heading)
    }
}

// MARK: - Mesh

struct PaperPlanePose {
    var center: CGPoint
    var z: Float = 0
    var yaw: Float = 0
    var pitch: Float = 0
    var bank: Float = 0
    var scale: Float = 1
    var alpha: Float = 1
    var lift: Float = 0
}

struct PaperPlaneVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var uv: SIMD2<Float>
    var flat: SIMD2<Float>
}

struct PaperPlaneUniforms {
    var viewSize: SIMD2<Float> = SIMD2(1, 1)
    var focus: SIMD2<Float> = .zero
    var cameraDistance: Float = 950
    var alpha: Float = 1
    var sheetSize: SIMD2<Float> = SIMD2(1, 1)
    var creases: SIMD4<Float> = .zero
    var signs: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var l0: SIMD4<Float> = .zero
    var l1: SIMD4<Float> = .zero
    var l2: SIMD4<Float> = .zero
    var l3: SIMD4<Float> = .zero
    var l4: SIMD4<Float> = .zero
    var l5: SIMD4<Float> = .zero
    var l6: SIMD4<Float> = .zero
    var planeLight: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var planeShade: SIMD4<Float> = SIMD4(0.66, 0.79, 0.87, 1)
    var paperBack: SIMD4<Float> = SIMD4(0.985, 0.98, 0.968, 1)
    var rim: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var logo: Float = 0
    var glint: Float = -2000
    var pad: SIMD2<Float> = .zero
}

struct PaperPlaneShadowUniforms {
    var viewSize: SIMD2<Float> = SIMD2(1, 1)
    var offsetPerHeight: SIMD2<Float> = .zero
    var lift: Float = 0
    var pad0: Float = 0
    var pad1: SIMD2<Float> = .zero
}

struct PaperPlaneTrailVertex {
    var position: SIMD2<Float>
    var alpha: Float
    var along: Float
    var across: Float
    var pad: Float = 0
}

enum PaperPlaneMesh {
    static func build(model: PaperPlaneModel, angles: PaperFoldAngles, pose: PaperPlanePose, focus: SIMD2<Float>, distance: Float) -> (vertices: [PaperPlaneVertex], tips: [SIMD2<Float>]) {
        let screenCenter = SIMD2<Float>(Float(pose.center.x), Float(pose.center.y))
        let worldCenter = focus + (screenCenter - focus) * ((distance - pose.z) / distance)
        let rotation = PaperPlaneMath.rotationZ(pose.yaw) * PaperPlaneMath.rotationX(pose.pitch) * PaperPlaneMath.rotationY(pose.bank)

        func world(_ local: SIMD3<Float>) -> SIMD3<Float> {
            let r = rotation * (local * pose.scale)
            return SIMD3(worldCenter.x + r.x, worldCenter.y - r.y, pose.z + r.z)
        }
        func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
            focus + (SIMD2(p.x, p.y) - focus) * (distance / max(distance - p.z, 1))
        }

        var vertices: [PaperPlaneVertex] = []
        vertices.reserveCapacity(model.facets.count * 12)
        var screen: [SIMD3<Float>] = []
        for facet in model.facets {
            screen.removeAll(keepingCapacity: true)
            for i in facet.flat.indices {
                screen.append(world(model.position(facet, i, angles)))
            }
            // Newell's normal; negated because the y flip into screen space mirrors the winding.
            var n = SIMD3<Float>(0, 0, 0)
            for i in screen.indices {
                let a = screen[i], b = screen[(i + 1) % screen.count]
                n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
            }
            let length = simd_length(n)
            guard length > 1e-6 else { continue }
            let normal = SIMD4<Float>(-n / length, 0)
            for i in 1..<(screen.count - 1) {
                for j in [0, i, i + 1] {
                    vertices.append(PaperPlaneVertex(position: SIMD4(screen[j], 1), normal: normal,
                                                     uv: model.uv(facet.flat[j]), flat: facet.flat[j]))
                }
            }
        }
        let tips = model.wingTips.map { tip in
            project(world(model.position(model.facets[tip.facet], tip.corner, angles)))
        }
        return (vertices, tips)
    }
}

enum PaperPlaneMath {
    static func clamp(_ x: Float, _ lo: Float = 0, _ hi: Float = 1) -> Float { min(max(x, lo), hi) }
    static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = clamp((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }
    static func easeInOut(_ t: Float) -> Float {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    static func easeOutBack(_ t: Float, overshoot s: Float) -> Float {
        let x = t - 1
        return 1 + x * x * ((s + 1) * x + s)
    }
    static func rotationX(_ a: Float) -> simd_float3x3 {
        let c = cos(a), s = sin(a)
        return simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, c, s), SIMD3(0, -s, c)))
    }
    static func rotationY(_ a: Float) -> simd_float3x3 {
        let c = cos(a), s = sin(a)
        return simd_float3x3(columns: (SIMD3(c, 0, -s), SIMD3(0, 1, 0), SIMD3(s, 0, c)))
    }
    static func rotationZ(_ a: Float) -> simd_float3x3 {
        let c = cos(a), s = sin(a)
        return simd_float3x3(columns: (SIMD3(c, s, 0), SIMD3(-s, c, 0), SIMD3(0, 0, 1)))
    }
}
