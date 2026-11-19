import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI

/// Cold-launch splash. Which animation plays follows the app icon the user picked
/// in Settings › Theme, so opening the app looks like the icon they tapped:
///
///   classic    the brand turntable cube on near-black
///   graffiti   the wildstyle mural, rotated a quarter turn to run top-to-bottom
///   vennlight  the three discs sliding together along bezier arcs
///   sun        the 16-bit rising-sun bathhouse mural
///
/// The Groovebox theme (or its icon) plays its own: its guidebook scene draws itself in
/// (grid fades up, then the pastel objects appear), as on the web.
///
/// All four share the same chrome: a scrim and an indeterminate loading bar in the
/// lower third. Shown once per process launch, then faded away.
///
/// One thing the OS will not let us match: `UILaunchScreen` paints a single static
/// colour from the asset catalog before SwiftUI mounts, and it cannot vary by the
/// user's choice. `LaunchBackground` is therefore a neutral dark, and each splash
/// cross-fades its own ground in over ~0.3s so the hand-off reads as a deliberate
/// dissolve rather than a flash — most visible on `vennlight`, which is white.
struct LaunchSplash: View {
    /// Called once the fade-out completes so the host can drop the splash.
    var onFinished: () -> Void

    @State private var icon = AppIconOption.classic
    @State private var contentIn = false
    @State private var coverOpacity = 1.0
    @Environment(\.theme) private var appTheme

    private var groovebox: Bool { appTheme.palette.guidebookGrid || icon == .groovebox }
    private var theme: LaunchTheme {
        groovebox ? LaunchTheme(background: GrooveboxScene.ground, onLight: false) : LaunchTheme.for(icon)
    }

    var body: some View {
        ZStack {
            theme.background.ignoresSafeArea()

            Group {
                if groovebox {
                    GrooveboxLaunchScene()
                } else {
                    switch icon {
                    case .classic:
                        SpinningCubeBadge(diameter: 132, spinDelay: 1.0, badge: false)
                    case .graffiti:
                        LaunchArtwork(resource: "launch-graffiti")
                    case .sun:
                        LaunchArtwork(resource: "launch-sun")
                    case .vennlight:
                        LaunchVenn()
                    case .groovebox:
                        EmptyView()   // unreachable: `groovebox` covers it above
                    }
                }
            }
            .opacity(contentIn ? 1 : 0)

            VStack(spacing: 0) {
                Spacer()
                // The scrim lets the bar stay legible over artwork, whatever the
                // crop lands on for a given screen size.
                LinearGradient(
                    colors: [.clear, theme.background.opacity(0.5), theme.background.opacity(0.9)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 340)
                .overlay(alignment: .bottom) {
                    LaunchLoadingBar(onLight: theme.onLight)
                        .frame(width: 132, height: 5)
                        .padding(.bottom, 74)
                }
            }
            .ignoresSafeArea()
            .opacity(contentIn ? 1 : 0)
        }
        .opacity(coverOpacity)
        .task { await run() }
    }

    private func run() async {
        icon = AppIconOption.current
        withAnimation(.easeOut(duration: 0.3)) { contentIn = true }
        try? await Task.sleep(for: .milliseconds(2300))
        withAnimation(.easeInOut(duration: 0.4)) { coverOpacity = 0 }
        try? await Task.sleep(for: .milliseconds(400))
        onFinished()
    }
}

/// Per-icon splash ground. `onLight` flips the loading bar's track so it stays
/// readable — a white track vanishes on the venn's white ground.
struct LaunchTheme {
    let background: Color
    let onLight: Bool

    static func `for`(_ icon: AppIconOption) -> LaunchTheme {
        switch icon {
        // The app's own near-black, as the cube splash always had.
        case .classic: LaunchTheme(background: Color(red: 0x09 / 255, green: 0x0A / 255, blue: 0x0E / 255),
                                   onLight: false)
        // Quantised from the mural itself, not eyeballed.
        case .graffiti: LaunchTheme(background: Color(red: 0x43 / 255, green: 0x2C / 255, blue: 0x54 / 255),
                                    onLight: false)
        // Sampled from the bottom band of the 8-bit stage the bar sits over, so the
        // scrim deepens the salmon rather than shifting its hue. Luminance ~63%, so
        // the bar needs its dark track.
        case .sun: LaunchTheme(background: Color(red: 0xED / 255, green: 0x86 / 255, blue: 0x6E / 255),
                               onLight: true)
        case .vennlight: LaunchTheme(background: .white, onLight: true)
        case .groovebox: LaunchTheme(background: GrooveboxScene.ground, onLight: false)
        }
    }
}

/// A full-bleed launch image from a loose bundle JPEG.
///
/// Loaded by resource path, not `Image(_:)` or `UIImage(named:)`: the first only
/// searches asset catalogs, and `imageNamed:` assumes a `.png` extension when none
/// is given, so a `.jpg` comes back nil and renders a bare background with no error.
private struct LaunchArtwork: View {
    let resource: String

    var body: some View {
        if let path = Bundle.main.path(forResource: resource, ofType: "jpg"),
           let art = UIImage(contentsOfFile: path) {
            Image(uiImage: art)
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
        }
    }
}

/// The venn icon assembling itself: the three discs fly in from beyond their
/// resting places and settle together, each on its own bezier so they arrive at
/// slightly different moments and the overlaps build up rather than snapping on.
private struct LaunchVenn: View {
    /// Matches brand/alt-icons/vennlight.png — same colours, same overlaps.
    private static let top = Color(red: 0x3B / 255, green: 0x2E / 255, blue: 0x9E / 255)
    private static let left = Color(red: 0xFF / 255, green: 0x00 / 255, blue: 0x80 / 255)
    private static let right = Color(red: 0xFF / 255, green: 0xBF / 255, blue: 0x40 / 255)

    /// The brand "2" (brand/inbox2-mark.svg, slanted -6°) pre-rendered white on
    /// transparent, so the splash doesn't have to carry the glyph's path.
    private static let two: UIImage? = Bundle.main
        .path(forResource: "launch-two", ofType: "png")
        .flatMap(UIImage.init(contentsOfFile:))

    @State private var together = false
    @State private var twoIn = false

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let r = side * 0.30                 // disc radius
            let ring = r / sqrt(3)              // triangle circumradius, as in the icon
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Resting offsets, then the same direction pushed out to start from.
            let rest = [CGSize(width: 0, height: -ring),
                        CGSize(width: -r / 2, height: ring / 2),
                        CGSize(width: r / 2, height: ring / 2)]
            let colours = [Self.top, Self.left, Self.right]

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(colours[i])
                        // Multiply keeps the overlaps honest: each pair darkens to a
                        // real mix instead of the last disc painting over the others.
                        .blendMode(.multiply)
                        .frame(width: r * 2, height: r * 2)
                        .position(x: c.x, y: c.y)
                        .offset(together ? rest[i] : scattered(rest[i], side: side))
                        .opacity(together ? 1 : 0)
                        .animation(
                            // Overshoot-free bezier with a long tail, staggered so the
                            // discs land one after another.
                            .timingCurve(0.2, 0.9, 0.25, 1, duration: 1.15)
                                .delay(Double(i) * 0.12),
                            value: together
                        )
                }
            }
            // The group blends against white, so it needs an opaque white behind it.
            .compositingGroup()
            .background(Color.white)
            // The 2 sits outside the multiply group — inside it, white would blend
            // to nothing. It fades up once the discs have landed.
            .overlay {
                if let two = Self.two {
                    Image(uiImage: two)
                        .resizable()
                        .scaledToFit()
                        .frame(width: r * 1.35, height: r * 1.35)
                        .position(x: c.x, y: c.y)
                        .opacity(twoIn ? 1 : 0)
                }
            }
            .onAppear {
                together = true
                withAnimation(.easeInOut(duration: 0.9).delay(0.95)) { twoIn = true }
            }
        }
        .ignoresSafeArea()
    }

    /// The starting position: the resting direction, thrown out past the screen.
    private func scattered(_ rest: CGSize, side: CGFloat) -> CGSize {
        let len = max(1, sqrt(rest.width * rest.width + rest.height * rest.height))
        let reach = side * 0.95
        return CGSize(width: rest.width / len * reach, height: rest.height / len * reach)
    }
}

/// Indeterminate loading bar: a brand-gradient lozenge sweeping along a dim track.
/// Deliberately not `ProgressView` — the system spinner reads as a system alert on
/// top of artwork, and there is no real progress to report.
private struct LaunchLoadingBar: View {
    /// Pinned to the dark ring so the bar looks the same whatever theme is active.
    private static let ring = ThemePalette.dark.ringColors

    /// Light ground: the track has to darken instead of lighten, or it disappears.
    var onLight: Bool

    @State private var sweep: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.width * 1.45
            Capsule()
                .fill(onLight ? Color.black.opacity(0.14) : Color.white.opacity(0.22))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: Self.ring,
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * 0.45)
                        .offset(x: -geo.size.width * 0.45 + sweep * travel)
                }
                .clipShape(Capsule())
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: false)) {
                        sweep = 1
                    }
                }
        }
    }
}

/// The inbox2 cube — optionally on a light circular badge (`badge`) — playing the
/// brand turntable spin
/// when it appears — settling face-front on the "2" — and then re-spins on its own
/// every few seconds (`restPause`) so the mark stays lively. The same light-tile
/// treatment as `InboxLogoTile`, rounded: the cube sprites carry a baked light
/// edge-rim + ground shadow that fringes against a dark background, and the light
/// disc absorbs both so the mark reads cleanly. The cube is inset (~62% of the disc)
/// so its rim never reaches the badge edge. Used on the launch splash and the
/// onboarding hero.
struct SpinningCubeBadge: View {
    /// The brand ring (violet → pink → amber), pinned to the dark theme so the badge
    /// renders identically regardless of the user's appearance setting.
    private static let brandRing = ThemePalette.dark.ringColors

    var diameter: CGFloat = 132
    var spinDuration: Double = 0.95
    /// Idle beat held on the settled "2" between automatic re-spins.
    var restPause: Double = 2.5
    /// Beat held on the initial frame before the very first spin (the launch splash
    /// waits 1s so the cube reads as static for a moment before it turns).
    var spinDelay: Double = 0
    /// Gates the autoplay loop. The launch splash leaves this `true` (spins as soon
    /// as it appears); the onboarding hero flips it true only once the splash is gone
    /// (+ a beat), so the spin isn't played hidden behind the splash.
    var play: Bool = true
    /// Draw the light disc, brand rim and glow behind the cube. The launch splash
    /// passes `false` so only the mark itself turns on the dark cover.
    var badge: Bool = true

    /// Bumped on tap to replay the turn immediately.
    @State private var replayToken = 0

    /// Inset inside the disc; bare (no badge) the mark fills the frame.
    private var cubeSize: CGFloat { diameter * (badge ? 0.62 : 1) }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.unifiedLogoTile, Color.unifiedLogoTileDeep],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    // Brand gradient rim — the inbox2 ring palette (violet → pink →
                    // amber) swept around the edge and closed back to violet so the
                    // seam is seamless. Pinned to the *dark* ring (not theme-derived) so
                    // the badge looks the same on the splash regardless of the user's
                    // theme; single source in `ThemePalette.dark.ringColors`.
                    Circle().strokeBorder(
                        AngularGradient(
                            colors: Self.brandRing + [Self.brandRing[0]],
                            center: .center
                        ),
                        lineWidth: max(2.5, diameter * 0.03)
                    )
                )
                .frame(width: diameter, height: diameter)
                // Tinted glow halo matching the rim — two stacked passes that fall
                // off gently, plus a soft white core lift.
                .shadow(color: Self.brandRing[1].opacity(0.45), radius: diameter * 0.24)
                .shadow(color: Self.brandRing[0].opacity(0.30), radius: diameter * 0.12)
                .shadow(color: .bevel(0.20), radius: diameter * 0.08)
                // Grounding drop shadow under the badge.
                .shadow(color: .black.opacity(0.5), radius: diameter * 0.2, y: diameter * 0.09)
                // ponytail: opacity 0 drops the disc *and* its rim/glow shadows —
                // cheaper than hoisting the whole chain into an `if badge`.
                .opacity(badge ? 1 : 0)
            SpinningCube(
                play: play,
                spinDuration: spinDuration,
                restPause: restPause,
                spinDelay: spinDelay,
                replayToken: replayToken
            )
            .frame(width: cubeSize, height: cubeSize)
        }
        // Tap to replay immediately.
        .contentShape(Circle())
        .onTapGesture { replayToken += 1 }
    }
}

/// The logo cube, rendered live in SceneKit from `logo-cube.obj` — the authored
/// 12-triangle GLB in `ui/web/public/logo-cube.glb`, converted by
/// `ui/web/scripts/glb-to-obj.mjs` (SceneKit/ModelIO read OBJ, never glTF).
///
/// SceneKit owns the whole turntable: `SCNAction`s on the node, not a value
/// SwiftUI animates. Driving it from SwiftUI needs `updateUIView` to be re-invoked
/// at display rate, which SwiftUI does not do for a representable — the cube just
/// sat there on its first pose. Nothing here depends on SwiftUI ticking.
private struct SpinningCube: UIViewRepresentable {
    /// Gates the autoplay loop (the onboarding hero holds it false until the splash
    /// is gone, so the spin isn't played hidden behind it).
    var play: Bool
    var spinDuration: Double
    var restPause: Double
    var spinDelay: Double
    /// Bumped by the badge's tap gesture to run one extra turn immediately.
    var replayToken: Int

    /// Resting yaw: the three-quarter view the logo is drawn at. Head-on the cube
    /// reads as a flat square with a "2" on it — the corner is what makes it a cube.
    static let restYaw: Float = -0.62

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SpinningCube.makeScene()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.isUserInteractionEnabled = false // the badge owns the tap gesture
        // Without this SCNView parks its display link: actions never advance and a
        // posed node never redraws.
        view.isPlaying = true
        context.coordinator.replayToken = replayToken
        sync(view, context: context)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        sync(view, context: context)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var replayToken = 0 }

    private func sync(_ view: SCNView, context: Context) {
        guard let cube = view.scene?.rootNode.childNode(withName: "cube", recursively: false) else { return }
        if replayToken != context.coordinator.replayToken {
            context.coordinator.replayToken = replayToken
            cube.removeAllActions()
            cube.runAction(SpinningCube.loop(spinDuration: spinDuration, restPause: restPause, delay: 0))
            return
        }
        guard play else { return cube.removeAllActions() }
        guard cube.action(forKey: "spin") == nil else { return }
        cube.runAction(
            SpinningCube.loop(spinDuration: spinDuration, restPause: restPause, delay: spinDelay),
            forKey: "spin"
        )
    }

    /// One turn after `delay`, then a turn every `restPause` seconds. Always the
    /// same direction — the old sheet ping-ponged only because it ran out of frames.
    private static func loop(spinDuration: Double, restPause: Double, delay: Double) -> SCNAction {
        let turn = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: spinDuration)
        turn.timingMode = .easeInEaseOut
        return .sequence([
            .wait(duration: delay),
            turn,
            .repeatForever(.sequence([.wait(duration: restPause), turn])),
        ])
    }

    static func makeScene() -> SCNScene {
        let scene = SCNScene()

        let cube = SCNNode()
        cube.name = "cube"
        if let url = Bundle.main.url(forResource: "logo-cube", withExtension: "obj"),
           let mesh = MDLAsset(url: url).object(at: 0) as? MDLMesh {
            cube.geometry = SCNGeometry(mdlMesh: mesh)
        } else {
            // Resource missing: a plain box still shows the mark rather than nothing.
            cube.geometry = SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)
        }
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = Bundle.main.path(forResource: "logo-cube", ofType: "png")
            .flatMap(UIImage.init(contentsOfFile:))
        // Matches the GLB's material: a dielectric sheen, not a mirror — a metal
        // with no environment to reflect renders as a black hole.
        material.metalness.contents = 0.15
        material.roughness.contents = 0.32
        cube.geometry?.firstMaterial = material
        cube.eulerAngles.y = restYaw
        scene.rootNode.addChildNode(cube)

        // Three-quarter view, slightly above the horizon — the logo's own angle.
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 28
        camera.position = SCNVector3(0, 0.78, 3.9)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)

        for (color, intensity, position) in [
            (UIColor.white, 1100.0, SCNVector3(2.5, 4, 3)),                                       // key
            (UIColor(red: 0.62, green: 0.70, blue: 1, alpha: 1), 520.0, SCNVector3(-3, 1.5, -2)), // cool rim
        ] {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = .directional
            node.light?.color = color
            node.light?.intensity = intensity
            node.position = position
            node.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(node)
        }
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 260
        scene.rootNode.addChildNode(ambient)

        return scene
    }
}
