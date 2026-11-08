import MetalKit
import UIKit

public struct PaperPlaneItem {
    public let frame: CGRect
    public let image: CGImage
    public init(frame: CGRect, image: CGImage) {
        self.frame = frame
        self.image = image
    }
}

public struct PaperPlaneTheme {
    public var light: UIColor
    public var shade: UIColor
    public var paper: UIColor
    public var rim: UIColor
    public var trail: UIColor
    public var shadow: Float

    public init(light: UIColor, shade: UIColor, paper: UIColor, rim: UIColor, trail: UIColor, shadow: Float) {
        self.light = light
        self.shade = shade
        self.paper = paper
        self.rim = rim
        self.trail = trail
        self.shadow = shadow
    }

    public static let day = PaperPlaneTheme(light: UIColor(red: 0.98, green: 0.99, blue: 1, alpha: 1),
                                            shade: UIColor(red: 0.66, green: 0.79, blue: 0.87, alpha: 1),
                                            paper: UIColor(red: 0.985, green: 0.98, blue: 0.968, alpha: 1),
                                            rim: .white, trail: .white, shadow: 1)
    public static let night = PaperPlaneTheme(light: UIColor(red: 0.3, green: 0.72, blue: 0.98, alpha: 1),
                                              shade: UIColor(red: 0.07, green: 0.3, blue: 0.56, alpha: 1),
                                              paper: UIColor(red: 0.11, green: 0.16, blue: 0.23, alpha: 1),
                                              rim: UIColor(red: 0.72, green: 0.9, blue: 1, alpha: 1),
                                              trail: UIColor(red: 0.5, green: 0.81, blue: 1, alpha: 1), shadow: 1.5)
}

public final class PaperPlaneForwardAnimator {
    public let config: PaperPlaneConfig
    public let view: UIView

    public var onLaunch: (() -> Void)?
    public var onArrive: (() -> Void)?
    public var onCompletion: (() -> Void)?

    public private(set) var isRunning = false
    public var retainedUntilCompletion: PaperPlaneForwardAnimator?

    private let renderer: PaperPlaneRenderer
    private let metalView: MTKView
    private let sheetShadow = UIImageView()
    private var gatherViews: [UIView] = []
    private var link: CADisplayLink?
    private var run: PaperPlaneRun?
    private var time: Double = 0
    private var lastTick: CFTimeInterval = 0
    private var theme: PaperPlaneTheme = .day

    private let shadowOffsetPerHeight = SIMD2<Float>(0.2, 0.45)
    private let gatherLift: Float = 14
    private let logoHeading: CGFloat = -.pi * 0.27

    public init?(config: PaperPlaneConfig = .default) {
        guard let renderer = PaperPlaneRenderer(device: MTLCreateSystemDefaultDevice()) else { return nil }
        self.config = config
        self.renderer = renderer
        view = PaperPlanePassthroughView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear

        metalView = MTKView(frame: .zero, device: renderer.device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.sampleCount = renderer.sampleCount
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.isOpaque = false
        metalView.layer.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.delegate = renderer
        metalView.isHidden = true

        sheetShadow.alpha = 0
        view.addSubview(sheetShadow)
        view.addSubview(metalView)
    }

    /// Compiles the shaders off the main thread, otherwise the first run does it on the spot.
    public func prewarm() {
        renderer.prewarm()
    }

    public func start(items: [PaperPlaneItem], wallpaper: CGImage?, target: CGPoint, theme: PaperPlaneTheme = .day) {
        cancel()
        guard !items.isEmpty else { return }
        self.theme = theme
        let bounds = view.bounds
        let scale = view.traitCollection.displayScale
        metalView.frame = bounds

        let sheetWidth = (min(bounds.width * config.sheetWidthFraction, config.sheetMaxWidth)).rounded()
        let sheetHeight = (sheetWidth * config.sheetAspect).rounded()
        let sheetFrame = CGRect(x: ((bounds.width - sheetWidth) / 2).rounded(),
                                y: (bounds.height * config.sheetCenterY - sheetHeight / 2).rounded(),
                                width: sheetWidth, height: sheetHeight)
        let shown = Array(items.suffix(6))
        let placed = Self.layout(items: shown, sheet: sheetFrame, bounds: bounds)
        let paper = Self.paperImage(sheet: sheetFrame, viewSize: bounds.size, wallpaper: wallpaper, theme: theme, scale: scale)
        let composite = Self.composite(paper: paper, items: shown, placed: placed, sheet: sheetFrame, scale: scale)

        let model = PaperPlaneModel(width: Float(sheetWidth), height: Float(sheetHeight), config: config)
        let safeTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        let center = CGPoint(x: sheetFrame.midX, y: sheetFrame.midY)
        let path = PaperPlanePath(start: center, target: target, bounds: bounds, safeTop: safeTop)
        let run = PaperPlaneRun(model: model, sheet: sheetFrame, path: path, target: target)
        run.launchYaw = Self.yaw(heading: logoHeading)
        self.run = run
        isRunning = true
        time = 0
        renderer.reset()

        let device = renderer.device
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let texture = composite.cgImage.flatMap { PaperPlaneRenderer.makeTexture(device: device, image: $0) }
            DispatchQueue.main.async {
                guard let self, self.run === run else { return }
                run.texture = texture
            }
        }

        let sheetView = UIImageView(image: paper)
        sheetView.frame = sheetFrame
        sheetView.alpha = 0
        sheetView.transform = CGAffineTransform(scaleX: 0.93, y: 0.93)
        view.insertSubview(sheetView, belowSubview: metalView)
        gatherViews.append(sheetView)

        let offset = shadowOffsetPerHeight * gatherLift
        sheetShadow.image = Self.shadowImage()
        sheetShadow.transform = .identity
        sheetShadow.frame = sheetFrame.insetBy(dx: -24, dy: -24).offsetBy(dx: CGFloat(offset.x), dy: CGFloat(offset.y))
        sheetShadow.alpha = 0
        sheetShadow.transform = CGAffineTransform(scaleX: 0.93, y: 0.93)
        UIView.animate(withDuration: config.gatherDuration * 0.75, delay: 0.04, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            sheetView.alpha = 1
            sheetView.transform = .identity
            self.sheetShadow.alpha = 1
            self.sheetShadow.transform = .identity
        }

        let stagger = min(0.045, (config.gatherDuration * 0.3) / Double(max(shown.count - 1, 1)))
        for (index, item) in shown.enumerated() {
            let copy = UIImageView(image: UIImage(cgImage: item.image, scale: scale, orientation: .up))
            copy.frame = item.frame
            copy.layer.shadowColor = UIColor.black.cgColor
            copy.layer.shadowOpacity = 0
            copy.layer.shadowRadius = 10
            copy.layer.shadowOffset = CGSize(width: 0, height: 6)
            view.insertSubview(copy, belowSubview: metalView)
            gatherViews.append(copy)
            UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
                copy.transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
            }
            let shadow = CAKeyframeAnimation(keyPath: "shadowOpacity")
            shadow.values = [0, 0.22, 0]
            shadow.keyTimes = [0, 0.25, 1]
            shadow.duration = config.gatherDuration
            copy.layer.add(shadow, forKey: "lift")
            let delay = 0.1 + Double(index) * stagger
            UIView.animate(withDuration: config.gatherDuration - delay - 0.03, delay: delay, usingSpringWithDamping: 0.88, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
                copy.transform = .identity
                copy.frame = placed[index]
            }
        }

        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: PaperPlaneDisplayLinkTarget { [weak self] in self?.tick() }, selector: #selector(PaperPlaneDisplayLinkTarget.fire))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    public func cancel() {
        link?.invalidate()
        link = nil
        run = nil
        isRunning = false
        gatherViews.forEach { $0.removeFromSuperview() }
        gatherViews = []
        metalView.isHidden = true
        sheetShadow.alpha = 0
        renderer.reset()
    }

    // MARK: - Frame

    private func tick() {
        guard let run else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 30)
        lastTick = now

        if time >= config.gatherDuration && run.texture == nil {
            return // Hold the gathered sheet until the texture is ready (tens of ms at most).
        }
        time += dt
        guard time >= config.gatherDuration else { return }

        if !run.switchedToMetal {
            run.switchedToMetal = true
            renderer.texture = run.texture
            metalView.isHidden = false
            // The Metal sheet is drawn on top of the identical UIKit sheet; drop the UIKit copies a few
            // frames later, once the first drawable is surely on screen. Shadows cross-fade meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.gatherViews.forEach { $0.removeFromSuperview() }
                self?.gatherViews = []
            }
            UIView.animate(withDuration: 0.12) { self.sheetShadow.alpha = 0 }
        }

        let foldEnd = config.gatherDuration + config.foldDuration
        let holdEnd = foldEnd + config.holdDuration
        let flightEnd = holdEnd + config.flightDuration
        if time < foldEnd {
            drawFold(run, u: Float((time - config.gatherDuration) / config.foldDuration))
        } else if time < holdEnd {
            drawHold(run, h: Float((time - foldEnd) / config.holdDuration))
        } else if time < flightEnd {
            if !run.launched {
                run.launched = true
                onLaunch?()
            }
            drawFlight(run, v: (time - holdEnd) / config.flightDuration, dt: dt)
        } else if !run.arrived {
            run.arrived = true
            onArrive?()
            drawTrailsOnly(run)
        } else if time < flightEnd + config.trailFade {
            drawTrailsOnly(run)
        } else {
            let completion = onCompletion
            cancel()
            completion?()
            retainedUntilCompletion = nil
        }
    }

    private static func foldAngles(_ u: Float, config: PaperPlaneConfig) -> PaperFoldAngles {
        func phase(_ a: Float, _ b: Float) -> Float { PaperPlaneMath.easeInOut(PaperPlaneMath.clamp((u - a) / (b - a))) }
        var angles = PaperFoldAngles()
        angles.f1 = SIMD2(phase(0.05, 0.23) * .pi, phase(0.13, 0.31) * .pi)
        angles.f2 = SIMD2(phase(0.33, 0.51) * .pi, phase(0.41, 0.59) * .pi)
        angles.body = phase(0.6, 0.8) * config.bodyAngle
        let w = PaperPlaneMath.clamp((u - 0.7) / 0.22)
        angles.wing = PaperPlaneMath.easeOutBack(w, overshoot: 1.5) * config.wingAngle
        let open = phase(0.7, 0.98)
        angles.span = 1 + (config.logoSpan - 1) * open
        angles.sweep = config.logoSweep * open
        angles.length = 1 + (config.logoLength - 1) * open
        return angles
    }

    private func heroPose(_ run: PaperPlaneRun, u: Float) -> PaperPlanePose {
        let s = PaperPlaneMath.smoothstep
        let lean = s(0, 0.15, u)
        var pose = PaperPlanePose(center: CGPoint(x: run.sheet.midX, y: run.sheet.midY))
        pose.z = 34 * lean
        pose.pitch = config.foldPitch * lean + (config.heroPitch - config.foldPitch) * s(0.6, 1, u)
        pose.yaw = run.launchYaw * s(0.62, 1, u)
        pose.bank = config.heroBank * s(0.7, 1, u)
        pose.scale = 1 + (config.heroScale - 1) * s(0.5, 1, u)
        pose.lift = gatherLift + 30 * lean
        return pose
    }

    private func drawFold(_ run: PaperPlaneRun, u: Float) {
        let s = PaperPlaneMath.smoothstep
        let angles = Self.foldAngles(u, config: config)
        let pose = heroPose(run, u: u)
        let creases = SIMD4<Float>(s(0.1, 0.6, max(angles.f1.x, angles.f1.y) / .pi),
                                   s(0.1, 0.6, max(angles.f2.x, angles.f2.y) / .pi),
                                   s(0.1, 0.6, angles.body / config.bodyAngle),
                                   s(0.1, 0.6, min(angles.wing / config.wingAngle, 1)))
        render(run, angles: angles, pose: pose, creases: creases, logo: s(0.68, 0.94, u), glint: -2000, shadowOpacity: 0.26 * s(0, 0.05, u))
    }

    private func drawHold(_ run: PaperPlaneRun, h: Float) {
        var pose = heroPose(run, u: 1)
        pose.z += 9 * sin(h * .pi)
        pose.bank += 0.06 * sin(h * .pi * 2)
        pose.pitch += 0.04 * sin(h * .pi)
        let glint = -run.model.height * 0.75 + run.model.height * 1.5 * PaperPlaneMath.easeInOut(h)
        render(run, angles: Self.fullAngles(config), pose: pose, creases: SIMD4(repeating: 1), logo: 1, glint: glint, shadowOpacity: 0.26)
    }

    private func drawFlight(_ run: PaperPlaneRun, v: Double, dt: Double) {
        let s = PaperPlaneMath.smoothstep
        let windup = 0.09
        let launch = v < windup ? 0 : (v - windup) / (1 - windup)
        let progress = CGFloat(launch <= 0 ? 0 : 1 - pow(1 - launch, 1.45))
        let sample = run.path.sample(progress)
        let p = Float(progress)
        let vf = Float(v)

        let targetYaw = Self.yaw(heading: sample.heading)
        var yawDelta = targetYaw - run.launchYaw
        while yawDelta > .pi { yawDelta -= 2 * .pi }
        while yawDelta < -.pi { yawDelta += 2 * .pi }
        let yaw = run.launchYaw + yawDelta * s(0, 0.12, vf)
        let ahead = run.path.sample(min(progress + 0.006, 1))
        var turn = Self.yaw(heading: ahead.heading) - targetYaw
        while turn > .pi { turn -= 2 * .pi }
        while turn < -.pi { turn += 2 * .pi }
        let curvature = turn / Float(max(run.path.length * 0.006, 1))
        let targetBank = -PaperPlaneMath.clamp(curvature * 100, -1, 1) * config.maxBank
        run.bank += (targetBank - run.bank) * Float(min(1, dt * 9))

        let back: CGFloat
        if v < windup {
            back = 20 * CGFloat(PaperPlaneMath.easeInOut(Float(v / windup)))
        } else {
            back = 20 * (1 - CGFloat(s(0, 0.08, Float(v - windup))))
        }

        var pose = PaperPlanePose(center: CGPoint(x: sample.point.x - cos(sample.heading) * back,
                                                  y: sample.point.y - sin(sample.heading) * back))
        let climb: Float = p < 0.62 ? 170 * sin(.pi * p / 0.62) : -190 * s(0.62, 1, p)
        pose.z = 34 * (1 - s(0, 0.12, vf)) + climb * s(0, 0.12, vf)
        pose.yaw = yaw
        pose.pitch = config.heroPitch + (config.flightPitch - config.heroPitch) * s(0, 0.25, vf)
        pose.bank = config.heroBank * (1 - s(0, 0.12, vf)) + run.bank * s(0, 0.12, vf)
        pose.scale = (config.heroScale + (config.flightScale - config.heroScale) * s(0, 0.3, p))
            * (1 + (config.landingScale / config.flightScale - 1) * s(0.66, 1, p))
        pose.alpha = 1 - s(0.95, 1, vf)
        pose.lift = 40 + max(pose.z, 0) * 0.5
        let shadowOpacity = (0.12 * (1 - s(0.15, 0.5, vf)) + 0.04) * (1 - s(0.8, 1, vf))

        let tips = render(run, angles: Self.fullAngles(config), pose: pose, creases: SIMD4(repeating: 1), logo: 1, glint: -2000, shadowOpacity: shadowOpacity)
        if v > windup, tips.count == 2 {
            addTrailPoint(run, point: (tips[0] + tips[1]) / 2)
        }
        updateTrails(run)
        metalView.draw()
    }

    private func drawTrailsOnly(_ run: PaperPlaneRun) {
        renderer.vertices = []
        renderer.shadowOpacity = 0
        updateTrails(run)
        metalView.draw()
    }

    private static func fullAngles(_ config: PaperPlaneConfig) -> PaperFoldAngles {
        PaperFoldAngles(f1: SIMD2(.pi, .pi), f2: SIMD2(.pi, .pi), body: config.bodyAngle, wing: config.wingAngle,
                        span: config.logoSpan, sweep: config.logoSweep, length: config.logoLength)
    }

    private static func yaw(heading: CGFloat) -> Float {
        Float(atan2(-cos(heading), -sin(heading)))
    }

    private static func premultiplied(_ color: UIColor) -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r * a), Float(g * a), Float(b * a), Float(a))
    }

    @discardableResult
    private func render(_ run: PaperPlaneRun, angles: PaperFoldAngles, pose: PaperPlanePose, creases: SIMD4<Float>,
                        logo: Float, glint: Float, shadowOpacity: Float) -> [SIMD2<Float>] {
        let model = run.model
        let focus = SIMD2<Float>(Float(run.sheet.midX), Float(run.sheet.midY))
        let distance = config.cameraDistance
        let mesh = PaperPlaneMesh.build(model: model, angles: angles, pose: pose, focus: focus, distance: distance)

        let lines = model.creaseLines
        var uniforms = PaperPlaneUniforms()
        uniforms.viewSize = SIMD2(Float(view.bounds.width), Float(view.bounds.height))
        uniforms.focus = focus
        uniforms.cameraDistance = distance
        uniforms.alpha = pose.alpha
        uniforms.sheetSize = SIMD2(model.width, model.height)
        uniforms.creases = creases
        uniforms.signs = SIMD4(model.f1Member.x, model.f1Member.y, model.f2Member.x, model.f2Member.y)
        uniforms.l0 = lines[0]
        uniforms.l1 = lines[1]
        uniforms.l2 = lines[2]
        uniforms.l3 = lines[3]
        uniforms.l4 = lines[4]
        uniforms.l5 = lines[5]
        uniforms.l6 = lines[6]
        uniforms.planeLight = Self.premultiplied(theme.light)
        uniforms.planeShade = Self.premultiplied(theme.shade)
        uniforms.paperBack = Self.premultiplied(theme.paper)
        uniforms.rim = Self.premultiplied(theme.rim)
        uniforms.logo = logo
        uniforms.glint = glint

        renderer.vertices = mesh.vertices
        renderer.uniforms = uniforms
        renderer.shadow = PaperPlaneShadowUniforms(viewSize: uniforms.viewSize, offsetPerHeight: shadowOffsetPerHeight, lift: pose.lift)
        renderer.shadowOpacity = min(shadowOpacity * theme.shadow, 1) * pose.alpha
        renderer.blurTexels = 1.2 + pose.lift / 30
        if !run.launched {
            metalView.draw()
        }
        return mesh.tips
    }

    private func addTrailPoint(_ run: PaperPlaneRun, point: SIMD2<Float>) {
        if let last = run.trail.last {
            let step = simd_distance(last.position, point)
            guard step > 0.5 else { return }
            run.trailLength += step
        }
        run.trail.append(PaperPlaneTrailPoint(time: time, position: point, along: run.trailLength))
    }

    private func updateTrails(_ run: PaperPlaneRun) {
        let lifetime = config.trailLifetime
        run.trail.removeAll { time - $0.time > lifetime }
        var vertices: [PaperPlaneTrailVertex] = []
        var strips: [(start: Int, count: Int)] = []
        let points = run.trail
        if points.count >= 2 {
            for (i, point) in points.enumerated() {
                let prev = points[max(i - 1, 0)].position, next = points[min(i + 1, points.count - 1)].position
                var tangent = next - prev
                let length = simd_length(tangent)
                tangent = length > 1e-4 ? tangent / length : SIMD2(1, 0)
                let normal = SIMD2<Float>(-tangent.y, tangent.x)
                let age = Float((time - point.time) / lifetime)
                let width = config.trailWidth * (0.55 + 0.45 * (1 - age)) + 1.5
                let head = PaperPlaneMath.smoothstep(0, 0.05, Float(points.count - 1 - i) / Float(max(points.count - 1, 1)))
                let alpha = 0.92 * pow(max(1 - age, 0), 1.2) * (0.25 + 0.75 * head)
                vertices.append(PaperPlaneTrailVertex(position: point.position + normal * width / 2, alpha: alpha, along: point.along, across: 1))
                vertices.append(PaperPlaneTrailVertex(position: point.position - normal * width / 2, alpha: alpha, along: point.along, across: -1))
            }
            strips.append((0, vertices.count))
        }
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        theme.trail.getRed(&r, green: &g, blue: &b, alpha: &a)
        renderer.trailParameters = SIMD4(Float(r), Float(g), Float(b), config.trailDash)
        renderer.trailVertices = vertices
        renderer.trailStrips = strips
    }

    // MARK: - Layout and images

    private static func layout(items: [PaperPlaneItem], sheet: CGRect, bounds: CGRect) -> [CGRect] {
        let margin: CGFloat = 18
        let gap: CGFloat = 5
        let maxWidth = items.map(\.frame.width).max() ?? 1
        let totalHeight = items.reduce(0) { $0 + $1.frame.height }
        let availableHeight = sheet.height * 0.58
        var scale = min(0.92, (sheet.width - margin * 2) / max(maxWidth, 1))
        scale = min(scale, (availableHeight - gap * CGFloat(items.count - 1)) / max(totalHeight, 1))
        let stackHeight = totalHeight * scale + gap * CGFloat(items.count - 1)
        var y = sheet.minY + sheet.height * 0.64 - stackHeight / 2
        return items.map { item in
            let size = CGSize(width: item.frame.width * scale, height: item.frame.height * scale)
            let outgoing = item.frame.midX > bounds.midX
            let x = outgoing ? sheet.maxX - margin - size.width : sheet.minX + margin
            let rect = CGRect(x: x, y: y, width: size.width, height: size.height)
            y += size.height + gap
            return rect
        }
    }

    private static func paperImage(sheet: CGRect, viewSize: CGSize, wallpaper: CGImage?, theme: PaperPlaneTheme, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        format.opaque = true
        return UIGraphicsImageRenderer(size: sheet.size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: sheet.size)
            let cg = context.cgContext
            theme.paper.setFill()
            context.fill(bounds)
            let factor = CGFloat(wallpaper?.width ?? 0) / max(viewSize.width, 1)
            let crop = CGRect(x: sheet.minX * factor, y: sheet.minY * factor, width: sheet.width * factor, height: sheet.height * factor).integral
            if let patch = wallpaper?.cropping(to: crop) {
                cg.saveGState()
                cg.translateBy(x: 0, y: sheet.height)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(patch, in: bounds)
                cg.restoreGState()
                // fill(_:) alone copies (UIRectFill semantics) and would wipe the wallpaper: blend it.
                UIColor(white: 1, alpha: 0.08).setFill()
                context.fill(bounds, blendMode: .normal)
            }
            UIColor(patternImage: grainTile).setFill()
            context.fill(bounds, blendMode: .normal)
            theme.paper.setStroke()
            let border = UIBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
            border.lineWidth = 6
            border.stroke()
        }
    }

    private static let grainTile: UIImage = {
        let size = 96
        var random = SystemRandomNumberGenerator()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            for y in 0..<size {
                for x in 0..<size where Int.random(in: 0..<3, using: &random) == 0 {
                    let light = Bool.random(using: &random)
                    let alpha = CGFloat.random(in: 0.02...0.05, using: &random)
                    (light ? UIColor(white: 1, alpha: alpha) : UIColor(white: 0, alpha: alpha * 0.8)).setFill()
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1), blendMode: .normal)
                }
            }
        }
    }()

    private static func composite(paper: UIImage, items: [PaperPlaneItem], placed: [CGRect], sheet: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.preferredRange = .standard
        format.opaque = true
        return UIGraphicsImageRenderer(size: sheet.size, format: format).image { _ in
            paper.draw(at: .zero)
            for (item, rect) in zip(items, placed) {
                UIImage(cgImage: item.image).draw(in: rect.offsetBy(dx: -sheet.minX, dy: -sheet.minY))
            }
        }
    }

    private static func shadowImage() -> UIImage {
        let size = CGSize(width: 120, height: 120)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let shape = CGRect(x: 24, y: 24, width: 72, height: 72)
            cg.setShadow(offset: CGSize(width: 0, height: 1000), blur: 12, color: UIColor(white: 0, alpha: 0.26).cgColor)
            cg.translateBy(x: 0, y: -1000)
            UIColor.black.setFill()
            cg.fill(shape)
        }.resizableImage(withCapInsets: UIEdgeInsets(top: 50, left: 50, bottom: 50, right: 50), resizingMode: .stretch)
    }
}

// MARK: - Run state

struct PaperPlaneTrailPoint {
    var time: Double
    var position: SIMD2<Float>
    var along: Float
}

private final class PaperPlaneRun {
    let model: PaperPlaneModel
    let sheet: CGRect
    let path: PaperPlanePath
    let target: CGPoint
    var texture: MTLTexture?
    var switchedToMetal = false
    var launched = false
    var arrived = false
    var launchYaw: Float = 0
    var bank: Float = 0
    var trail: [PaperPlaneTrailPoint] = []
    var trailLength: Float = 0

    init(model: PaperPlaneModel, sheet: CGRect, path: PaperPlanePath, target: CGPoint) {
        self.model = model
        self.sheet = sheet
        self.path = path
        self.target = target
    }
}

private final class PaperPlanePassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private final class PaperPlaneDisplayLinkTarget {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

// MARK: - Metal

final class PaperPlaneRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let sampleCount: Int
    var texture: MTLTexture?
    var vertices: [PaperPlaneVertex] = []
    var uniforms = PaperPlaneUniforms()
    var shadow = PaperPlaneShadowUniforms()
    var shadowOpacity: Float = 0
    var blurTexels: Float = 2
    var trailVertices: [PaperPlaneTrailVertex] = []
    var trailStrips: [(start: Int, count: Int)] = []
    var trailParameters = SIMD4<Float>(1, 1, 1, 15)

    private struct Pipelines {
        let paper: MTLRenderPipelineState
        let shadowMask: MTLRenderPipelineState
        let blur: MTLRenderPipelineState
        let composite: MTLRenderPipelineState
        let trail: MTLRenderPipelineState
    }

    private let queue: MTLCommandQueue
    private let paperDepth: MTLDepthStencilState
    private let noDepth: MTLDepthStencilState
    private let paperSampler: MTLSamplerState
    private let shadowSampler: MTLSamplerState
    private static let lock = NSLock()
    private static var pipelines: Pipelines?
    private var shadowA: MTLTexture?
    private var shadowB: MTLTexture?

    init?(device: MTLDevice?) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        let none = MTLDepthStencilDescriptor()
        none.depthCompareFunction = .always
        none.isDepthWriteEnabled = false
        guard let paperDepth = device.makeDepthStencilState(descriptor: depth),
              let noDepth = device.makeDepthStencilState(descriptor: none) else { return nil }
        self.paperDepth = paperDepth
        self.noDepth = noDepth
        let paper = MTLSamplerDescriptor()
        paper.minFilter = .linear
        paper.magFilter = .linear
        paper.mipFilter = .linear
        paper.sAddressMode = .clampToEdge
        paper.tAddressMode = .clampToEdge
        let soft = MTLSamplerDescriptor()
        soft.minFilter = .linear
        soft.magFilter = .linear
        soft.sAddressMode = .clampToZero
        soft.tAddressMode = .clampToZero
        guard let paperSampler = device.makeSamplerState(descriptor: paper),
              let shadowSampler = device.makeSamplerState(descriptor: soft) else { return nil }
        self.paperSampler = paperSampler
        self.shadowSampler = shadowSampler
        super.init()
    }

    func reset() {
        texture = nil
        vertices = []
        trailVertices = []
        trailStrips = []
        shadowOpacity = 0
    }

    func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async { _ = self.pipelineStates() }
    }

    private func pipelineStates() -> Pipelines? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let pipelines = Self.pipelines { return pipelines }
        do {
            let library = try device.makeLibrary(source: paperPlaneShaderSource, options: nil)
            func make(_ vertex: String, _ fragment: String, format: MTLPixelFormat, main: Bool, blend: Bool) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                let color = descriptor.colorAttachments[0]!
                color.pixelFormat = format
                if blend {
                    color.isBlendingEnabled = true
                    color.sourceRGBBlendFactor = .one
                    color.sourceAlphaBlendFactor = .one
                    color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                if main {
                    descriptor.depthAttachmentPixelFormat = .depth32Float
                    descriptor.rasterSampleCount = sampleCount
                }
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            Self.pipelines = Pipelines(
                paper: try make("pp_vertex", "pp_fragment", format: .bgra8Unorm, main: true, blend: true),
                shadowMask: try make("pp_shadow_vertex", "pp_shadow_fragment", format: .r8Unorm, main: false, blend: false),
                blur: try make("pp_fullscreen_vertex", "pp_blur_fragment", format: .r8Unorm, main: false, blend: false),
                composite: try make("pp_fullscreen_vertex", "pp_shadow_composite_fragment", format: .bgra8Unorm, main: true, blend: true),
                trail: try make("pp_trail_vertex", "pp_trail_fragment", format: .bgra8Unorm, main: true, blend: true)
            )
        } catch {
            print("PaperPlaneForward: failed to build the pipelines: \(error)")
        }
        return Self.pipelines
    }

    /// Redraws the image as 8-bit premultiplied BGRA in sRGB (wide-color snapshots would otherwise
    /// load as linear half-floats and come out darker), then builds the mip chain for the flight.
    static func makeTexture(device: MTLDevice, image: CGImage) -> MTLTexture? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let drawn: Bool = data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space, bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)
        if texture.mipmapLevelCount > 1, let queue = device.makeCommandQueue(), let commands = queue.makeCommandBuffer(),
           let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
        }
        return texture
    }

    private func shadowTextures(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let a = shadowA, let b = shadowB, a.width == width, a.height == height { return (a, b) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let a = device.makeTexture(descriptor: descriptor), let b = device.makeTexture(descriptor: descriptor) else { return nil }
        shadowA = a
        shadowB = b
        return (a, b)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipelines = pipelineStates(),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer() else { return }
        let vertexBuffer = vertices.isEmpty ? nil
            : device.makeBuffer(bytes: vertices, length: MemoryLayout<PaperPlaneVertex>.stride * vertices.count)

        var shadowTexture: MTLTexture?
        if shadowOpacity > 0.002, let vertexBuffer,
           let (a, b) = shadowTextures(width: max(Int(view.drawableSize.width) / 4, 1), height: max(Int(view.drawableSize.height) / 4, 1)) {
            let maskPass = MTLRenderPassDescriptor()
            maskPass.colorAttachments[0].texture = a
            maskPass.colorAttachments[0].loadAction = .clear
            maskPass.colorAttachments[0].storeAction = .store
            maskPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: maskPass) {
                var shadow = self.shadow
                encoder.setRenderPipelineState(pipelines.shadowMask)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&shadow, length: MemoryLayout<PaperPlaneShadowUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
                encoder.endEncoding()
            }
            func blur(from source: MTLTexture, to target: MTLTexture, step: SIMD2<Float>) {
                let blurPass = MTLRenderPassDescriptor()
                blurPass.colorAttachments[0].texture = target
                blurPass.colorAttachments[0].loadAction = .dontCare
                blurPass.colorAttachments[0].storeAction = .store
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: blurPass) else { return }
                var parameters = SIMD4<Float>(step.x, step.y, 0, 0)
                encoder.setRenderPipelineState(pipelines.blur)
                encoder.setFragmentTexture(source, index: 0)
                encoder.setFragmentSamplerState(shadowSampler, index: 0)
                encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            blur(from: a, to: b, step: SIMD2(blurTexels / Float(a.width), 0))
            blur(from: b, to: a, step: SIMD2(0, blurTexels / Float(a.height)))
            shadowTexture = a
        }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setCullMode(.none)
        if let shadowTexture {
            var opacity = shadowOpacity
            encoder.setRenderPipelineState(pipelines.composite)
            encoder.setDepthStencilState(noDepth)
            encoder.setFragmentTexture(shadowTexture, index: 0)
            encoder.setFragmentSamplerState(shadowSampler, index: 0)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        if !trailVertices.isEmpty,
           let trailBuffer = device.makeBuffer(bytes: trailVertices, length: MemoryLayout<PaperPlaneTrailVertex>.stride * trailVertices.count) {
            var viewSize = uniforms.viewSize
            encoder.setRenderPipelineState(pipelines.trail)
            encoder.setDepthStencilState(noDepth)
            encoder.setVertexBuffer(trailBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            var trailParameters = self.trailParameters
            encoder.setFragmentBytes(&trailParameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            for strip in trailStrips where strip.count >= 4 {
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: strip.start, vertexCount: strip.count)
            }
        }
        if let vertexBuffer, let texture {
            var uniforms = self.uniforms
            encoder.setRenderPipelineState(pipelines.paper)
            encoder.setDepthStencilState(paperDepth)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<PaperPlaneUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PaperPlaneUniforms>.stride, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(paperSampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Compiled at runtime with `makeLibrary(source:)`, so the module needs no Metal build step.
let paperPlaneShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct PPVertex { float4 position; float4 normal; float2 uv; float2 flat; };
struct PPUniforms {
    float2 viewSize; float2 focus; float cameraDistance; float alpha; float2 sheetSize;
    float4 creases; float4 signs;
    float4 l0; float4 l1; float4 l2; float4 l3; float4 l4; float4 l5; float4 l6;
    float4 planeLight; float4 planeShade; float4 paperBack; float4 rim;
    float logo; float glint; float2 pad;
};
struct PPOut {
    float4 position [[position]];
    float2 uv;
    float2 flat;
    float3 normal;
    float facing;
};

vertex PPOut pp_vertex(const device PPVertex *vertices [[buffer(0)]],
                       constant PPUniforms &u [[buffer(1)]],
                       uint vid [[vertex_id]]) {
    PPVertex v = vertices[vid];
    float3 p = v.position.xyz;
    float w = max((u.cameraDistance - p.z) / u.cameraDistance, 0.05);
    float2 rel = p.xy - u.focus;
    float2 c = (u.focus * 2.0 / u.viewSize - 1.0) * w + rel * 2.0 / u.viewSize;
    PPOut o;
    o.position = float4(c.x, -c.y, (0.5 - p.z / 4000.0) * w, w);
    o.uv = v.uv;
    o.flat = v.flat;
    o.normal = v.normal.xyz;
    float3 camera = float3(u.focus, u.cameraDistance);
    o.facing = dot(v.normal.xyz, camera - p);
    return o;
}

static float pp_hash(int2 c) {
    uint h = (uint(c.x) * 0x8da6b343u) ^ (uint(c.y) * 0xd8163841u);
    h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
    return float(h & 0xffffu) / 65535.0;
}

static float pp_noise(float2 p) {
    float2 i = floor(p);
    float2 f = p - i;
    float2 s = f * f * (3.0 - 2.0 * f);
    int2 c = int2(i);
    float a = pp_hash(c), b = pp_hash(c + int2(1, 0)), d = pp_hash(c + int2(0, 1)), e = pp_hash(c + int2(1, 1));
    return mix(mix(a, b, s.x), mix(d, e, s.x), s.y);
}

static float pp_side(float2 p, float4 l) { float2 q = p - l.xy; return l.z * q.y - l.w * q.x; }
static float2 pp_reflect(float2 p, float4 l) { float2 q = p - l.xy; return l.xy + 2.0 * dot(q, l.zw) * l.zw - q; }
static float pp_line(float2 p, float4 l) { float d = pp_side(p, l); return exp(-(d * d) / 0.5); }

static float pp_crease(float2 p0, constant PPUniforms &u) {
    float2 p1 = p0;
    if (pp_side(p0, u.l0) * u.signs.x > 0.0) { p1 = pp_reflect(p0, u.l0); }
    else if (pp_side(p0, u.l1) * u.signs.y > 0.0) { p1 = pp_reflect(p0, u.l1); }
    float2 p2 = p1;
    if (pp_side(p1, u.l2) * u.signs.z > 0.0) { p2 = pp_reflect(p1, u.l2); }
    else if (pp_side(p1, u.l3) * u.signs.w > 0.0) { p2 = pp_reflect(p1, u.l3); }
    float c = u.creases.x * max(pp_line(p0, u.l0), pp_line(p0, u.l1));
    c = max(c, u.creases.y * max(pp_line(p1, u.l2), pp_line(p1, u.l3)));
    c = max(c, u.creases.z * pp_line(p2, u.l4));
    c = max(c, u.creases.w * max(pp_line(p2, u.l5), pp_line(p2, u.l6)));
    return c;
}

fragment float4 pp_fragment(PPOut in [[stage_in]],
                            texture2d<float> tex [[texture(0)]],
                            sampler smp [[sampler(0)]],
                            constant PPUniforms &u [[buffer(1)]]) {
    bool front = in.facing > 0.0;
    float3 n = normalize(in.normal) * (front ? 1.0 : -1.0);
    float3 light = normalize(float3(-0.35, -0.6, 1.0));
    const float wrap = 0.5;
    float diffuse = max(dot(n, light) + wrap, 0.0) / (1.0 + wrap);
    float flatDiffuse = (light.z + wrap) / (1.0 + wrap);
    float shade = clamp(0.55 + 0.45 * diffuse / flatDiffuse, 0.0, 1.1);
    float3 h = normalize(light + float3(0.0, 0.0, 1.0));
    float sheen = 0.1 * max(pow(max(dot(n, h), 0.0), 24.0) - pow(h.z, 24.0), 0.0);

    float grain = pp_noise(in.flat * 1.4) - 0.5 + (pp_noise(in.flat * 0.25) - 0.5) * 0.6;
    float3 base;
    if (front) {
        base = tex.sample(smp, in.uv).rgb;
    } else {
        base = u.paperBack.rgb * (1.0 + grain * 0.04);
    }
    float crease = pp_crease(in.flat, u);
    float3 color = base * shade * (1.0 - 0.26 * crease) + sheen;

    if (u.logo > 0.0) {
        float lit = smoothstep(0.22, 0.86, clamp(dot(n, light) * 0.72 + 0.34, 0.0, 1.0));
        float along = clamp(in.flat.y / u.sheetSize.y + 0.5, 0.0, 1.0);
        float3 plane = mix(u.planeShade.rgb, u.planeLight.rgb, lit) * (0.965 + 0.055 * along);
        plane *= 1.0 + grain * 0.012;
        plane = mix(plane, plane * 0.78, crease * 0.75);
        float2 edge = u.sheetSize * 0.5 - abs(in.flat);
        float rim = smoothstep(1.5, 0.0, min(edge.x, edge.y));
        plane = mix(plane, u.rim.rgb, rim * 0.5);
        color = mix(color, plane + sheen * 0.8, u.logo);
    }
    if (u.glint > -1000.0) {
        float d = (in.flat.y + in.flat.x * 0.5 - u.glint) / 26.0;
        color += float3(0.5) * exp(-d * d) * (front ? 0.9 : 1.0);
    }
    return float4(min(color, float3(1.0)) * u.alpha, u.alpha);
}

struct PPShadowUniforms { float2 viewSize; float2 offsetPerHeight; float lift; float pad0; float2 pad1; };

vertex float4 pp_shadow_vertex(const device PPVertex *vertices [[buffer(0)]],
                               constant PPShadowUniforms &s [[buffer(1)]],
                               uint vid [[vertex_id]]) {
    float3 p = vertices[vid].position.xyz;
    float h = max(p.z + s.lift, 0.0);
    float2 q = p.xy + s.offsetPerHeight * h;
    return float4(q.x / s.viewSize.x * 2.0 - 1.0, 1.0 - q.y / s.viewSize.y * 2.0, 0.0, 1.0);
}

fragment half4 pp_shadow_fragment() { return half4(1.0h); }

struct PPFullscreen { float4 position [[position]]; float2 uv; };

vertex PPFullscreen pp_fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2(float((vid << 1) & 2), float(vid & 2));
    PPFullscreen o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

fragment half4 pp_blur_fragment(PPFullscreen in [[stage_in]],
                                texture2d<half> source [[texture(0)]],
                                sampler smp [[sampler(0)]],
                                constant float4 &b [[buffer(0)]]) {
    float weights[5] = { 0.2270270, 0.1945946, 0.1216216, 0.0540540, 0.0162162 };
    float sum = float(source.sample(smp, in.uv).r) * weights[0];
    for (int i = 1; i < 5; i++) {
        float2 offset = b.xy * float(i);
        sum += float(source.sample(smp, in.uv + offset).r) * weights[i];
        sum += float(source.sample(smp, in.uv - offset).r) * weights[i];
    }
    return half4(half(sum), 0.0h, 0.0h, 1.0h);
}

fragment float4 pp_shadow_composite_fragment(PPFullscreen in [[stage_in]],
                                             texture2d<half> mask [[texture(0)]],
                                             sampler smp [[sampler(0)]],
                                             constant float &opacity [[buffer(0)]]) {
    float a = float(mask.sample(smp, in.uv).r) * opacity;
    return float4(0.0, 0.02, 0.04, 1.0) * a;
}

struct PPTrailVertex { float2 position; float alpha; float along; float across; float pad; };
struct PPTrailOut { float4 position [[position]]; float alpha; float along; float across; };

vertex PPTrailOut pp_trail_vertex(const device PPTrailVertex *vertices [[buffer(0)]],
                                  constant float2 &viewSize [[buffer(1)]],
                                  uint vid [[vertex_id]]) {
    PPTrailVertex v = vertices[vid];
    PPTrailOut o;
    o.position = float4(v.position.x / viewSize.x * 2.0 - 1.0, 1.0 - v.position.y / viewSize.y * 2.0, 0.0, 1.0);
    o.alpha = v.alpha;
    o.along = v.along;
    o.across = v.across;
    return o;
}

fragment float4 pp_trail_fragment(PPTrailOut in [[stage_in]], constant float4 &p [[buffer(0)]]) {
    float period = p.a;
    float x = fract(in.along / period) * period - period * 0.5;
    float halfDash = period * 0.28;
    float reach = max(abs(x) - halfDash, 0.0) / 1.6;
    float d = sqrt(reach * reach + in.across * in.across);
    float aa = fwidth(d) * 1.2;
    float a = in.alpha * (1.0 - smoothstep(0.62 - aa, 0.62 + aa, d));
    return float4(p.rgb * a, a);
}
"""
