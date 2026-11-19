import SwiftUI
import SceneKit

// Full-screen native space shooter for the Bridge. `SpaceShooterGameScreen` owns the
// observable GameModel + the SceneKit engine and the start / game-over overlays;
// `SpaceShooterSceneView` hosts the low-res SCNView and routes drag/tap to the engine.
//
// Resume: a snapshot is saved to UserDefaults on background and on close, and restored
// on open (no JS bridge — native Codable). The retro look comes from a low-resolution
// drawable upscaled with nearest-neighbour filtering plus flat-shaded neon materials.

private let gameTitle = "NEON STRIKE"

struct SpaceShooterGameScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = GameModel()
    @State private var engine: SpaceShooterEngine?
    @State private var selectedShip = 0
    @State private var muted = GameMusic.shared.muted

    var body: some View {
        ZStack {
            Color(Synth.indigo).ignoresSafeArea()

            if let engine {
                SpaceShooterSceneView(engine: engine).ignoresSafeArea()
                GameHUD(model: model, onBomb: { engine.useBomb() })
            }

            switch model.status {
            case .idle: startOverlay
            case .over: gameOverOverlay
            default: EmptyView()
            }

            // Close (top-left) + mute (top-right).
            VStack {
                HStack {
                    Button { saveAndExit() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(AppFont.display)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(Space.s2)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // Top-right column: mute, then OVERDRIVE below it (kept clear of the
                    // bottom thumb-rest so it isn't pressed by accident).
                    VStack(alignment: .trailing, spacing: Space.s2) {
                        Button {
                            muted.toggle(); GameMusic.shared.setMuted(muted)
                        } label: {
                            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(AppFont.title3)
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(Space.s2)
                        }
                        .buttonStyle(.plain)
                        if let engine, model.status == .playing {
                            OverdriveButton(model: model) { engine.activateSuper() }
                            ShieldButton(model: model) { engine.activateBarrier() }
                        }
                    }
                }
                Spacer()
            }
        }
        .onAppear {
            if engine == nil {
                let e = SpaceShooterEngine(model: model)
                e.onGameOver = {}
                engine = e
                if let snap = GamePersistence.load() {
                    e.restore(snap)
                }
            }
            GameMusic.shared.start()
        }
        .onDisappear { GameMusic.shared.stop() }
        .onChange(of: scenePhase) { _, phase in
            guard let engine else { return }
            if phase == .active {
                engine.resume(); GameMusic.shared.start()
            } else {
                engine.pause(); GameMusic.shared.stop()
                if model.status == .playing || model.status == .paused {
                    GamePersistence.save(engine.snapshot())
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: overlays

    private var startOverlay: some View {
        VStack(spacing: Space.s5) {
            Text(gameTitle)
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(LinearGradient(colors: [Color(Synth.magenta), Color(Synth.cyan)],
                                                startPoint: .leading, endPoint: .trailing))
                .shadow(color: Color(Synth.magenta).opacity(0.7), radius: 14)
            Text("Drag to fly · auto-fire · BOMB lobs a nuke · OVERDRIVE when charged")
                .font(AppFont.sm).foregroundStyle(.white.opacity(0.7))

            VStack(spacing: Space.s2) {
                ForEach(Array(PlayerShip.all.enumerated()), id: \.offset) { i, ship in
                    Button { selectedShip = i } label: {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text(ship.name).font(AppFont.md)
                            Spacer()
                            if selectedShip == i { Image(systemName: "checkmark.circle.fill") }
                        }
                        .padding(.horizontal, Space.s4).padding(.vertical, Space.s3)
                        .frame(width: 240)
                        .background(RoundedRectangle(cornerRadius: Radius.lg)
                            .fill(.white.opacity(selectedShip == i ? 0.14 : 0.06)))
                        .overlay(RoundedRectangle(cornerRadius: Radius.lg)
                            .stroke(Color(Synth.cyan).opacity(selectedShip == i ? 0.9 : 0.2), lineWidth: 1.5))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button { engine?.startNew(shipId: selectedShip) } label: {
                Text("LAUNCH").font(.system(size: 20, weight: .bold))
                    .padding(.horizontal, Space.s8).padding(.vertical, Space.s3)
                    .background(Capsule().fill(LinearGradient(
                        colors: [Color(Synth.magenta), Color(Synth.purple)],
                        startPoint: .leading, endPoint: .trailing)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(Space.s8)
        .background(.black.opacity(0.45))
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gameOverOverlay: some View {
        VStack(spacing: Space.s4) {
            Text("GAME OVER")
                .font(.system(size: 36, weight: .heavy))
                .foregroundStyle(Color(Synth.red))
                .shadow(color: Color(Synth.red).opacity(0.7), radius: 12)
            Text("SCORE  \(model.score)").font(AppFont.lg).foregroundStyle(.white)
            Text("BEST  \(model.best)").font(AppFont.sm).foregroundStyle(.white.opacity(0.7))
            HStack(spacing: Space.s3) {
                Button { engine?.startNew(shipId: selectedShip) } label: {
                    Text("PLAY AGAIN").font(AppFont.md)
                        .padding(.horizontal, Space.s5).padding(.vertical, Space.s3)
                        .background(Capsule().fill(Color(Synth.cyan).opacity(0.9)))
                        .foregroundStyle(.black)
                }.buttonStyle(.plain)
                Button { saveAndExit() } label: {
                    Text("EXIT").font(AppFont.md)
                        .padding(.horizontal, Space.s5).padding(.vertical, Space.s3)
                        .background(Capsule().stroke(.white.opacity(0.4), lineWidth: 1.5))
                        .foregroundStyle(.white)
                }.buttonStyle(.plain)
            }
        }
        .padding(Space.s8)
        .background(.black.opacity(0.5))
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func saveAndExit() {
        if let engine, model.status == .playing || model.status == .paused {
            GamePersistence.save(engine.snapshot())
        }
        dismiss()
    }
}

// MARK: - HUD

// OVERDRIVE super-beam button — tap when the ring is full; charges over time. Lives in
// the top-right (under mute) so it isn't hit by accident from the bottom controls.
private struct OverdriveButton: View {
    @ObservedObject var model: GameModel
    var onSuper: () -> Void

    var body: some View {
        Button(action: onSuper) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3).frame(width: 50, height: 50)
                Circle().trim(from: 0, to: CGFloat(model.superActive ? 1 : model.superCharge))
                    .stroke(model.superActive ? Color(Synth.magenta) : Color(Synth.teal),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 50, height: 50)
                Image(systemName: "bolt.fill").font(.system(size: 19, weight: .bold))
                    .foregroundStyle(model.superCharge >= 1 || model.superActive ? .white : .white.opacity(0.4))
            }
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).allowsHitTesting(true)
    }
}

// Shield-wall button — raise the holographic barrier when the ring is full; recharges
// over time (mirrors OVERDRIVE). Sits under OVERDRIVE in the top-right column.
private struct ShieldButton: View {
    @ObservedObject var model: GameModel
    var onShield: () -> Void

    var body: some View {
        Button(action: onShield) {
            ZStack {
                Circle().stroke(.white.opacity(0.18), lineWidth: 3).frame(width: 50, height: 50)
                Circle().trim(from: 0, to: CGFloat(model.barrierActive ? 1 : model.barrierCharge))
                    .stroke(model.barrierActive ? Color(Synth.aqua) : Color(Synth.cyan),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 50, height: 50)
                Image(systemName: "shield.fill").font(.system(size: 18, weight: .bold))
                    .foregroundStyle(model.barrierCharge >= 1 || model.barrierActive ? .white : .white.opacity(0.4))
            }
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).allowsHitTesting(true)
    }
}

private struct GameHUD: View {
    @ObservedObject var model: GameModel
    var onBomb: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Top row: score / level / lives.
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(model.score)").font(AppFont.mono(22, .bold)).foregroundStyle(.white)
                    Text("BEST \(model.best)").font(AppFont.mono(11)).foregroundStyle(.white.opacity(0.55))
                }
                .padding(.leading, 44)   // clear the top-left close button
                Spacer()
                VStack(spacing: 2) {
                    Text("LEVEL \(model.level)").font(AppFont.mono(13, .semibold))
                        .foregroundStyle(Color(Synth.cyan))
                    Text(Biome.at(model.biome).name).font(AppFont.mono(10))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                // Shield meter (lives are shown as neon-green pips over the ship in 3D).
                VStack(alignment: .trailing, spacing: 4) {
                    if model.shield > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "shield.lefthalf.filled").font(.system(size: 11))
                                .foregroundStyle(Color(Synth.amber).opacity(0.85))
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.14)).frame(width: 70, height: 4)
                                Capsule().fill(Color(Synth.amber))
                                    .frame(width: 70 * CGFloat(min(model.shield / 8, 1)), height: 4)
                            }
                        }
                    }
                }
                .frame(minWidth: 60, alignment: .trailing)
                .padding(.trailing, 40)   // clear the top-right mute button
            }
            .padding(.horizontal, Space.s4).padding(.top, Space.s5)

            // Boss health bar.
            if model.bossHealth >= 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(Color(Synth.magenta))
                            .frame(width: geo.size.width * CGFloat(model.bossHealth))
                    }
                }
                .frame(height: 6)
                .padding(.horizontal, Space.s5).padding(.top, Space.s2)
            }

            Spacer()

            // Centre banner.
            if let banner = model.banner {
                Text(banner)
                    .font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: Color(Synth.magenta), radius: 16)
                    .transition(.scale.combined(with: .opacity))
            }

            Spacer()

            // Bottom row: weapon / shield / bombs.
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("FIREPOWER ×\(model.weaponLevel)").font(AppFont.mono(12, .semibold))
                        .foregroundStyle(Color(Synth.cyan))
                    if model.shield > 0 {
                        Text("SHIELD \(Int(ceil(model.shield)))s").font(AppFont.mono(11))
                            .foregroundStyle(Color(Synth.amber))
                    }
                }
                Spacer()
                // Bomb button (OVERDRIVE moved to the top-right under mute to avoid
                // accidental presses from the thumb resting here).
                Button(action: onBomb) {
                    HStack(spacing: 4) {
                        Image(systemName: "burst.fill")
                        Text("\(model.bombs)").font(AppFont.mono(16, .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.s4).padding(.vertical, Space.s3)
                    .background(Capsule().fill(Color(Synth.magenta).opacity(model.bombs > 0 ? 0.85 : 0.25)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).allowsHitTesting(true)
            }
            .padding(.horizontal, Space.s4).padding(.bottom, Space.s6)
        }
        .animation(.spring(response: 0.3), value: model.banner)
        // Boss-incoming timer — a vertical meter on the left that fills as the boss nears.
        .overlay(alignment: .leading) {
            if model.bossProgress >= 0 {
                VStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        .foregroundStyle(Color(Synth.magenta).opacity(0.85))
                    ZStack(alignment: .bottom) {
                        Capsule().fill(.white.opacity(0.12)).frame(width: 5, height: 130)
                        Capsule().fill(Color(Synth.magenta))
                            .frame(width: 5, height: 130 * CGFloat(model.bossProgress))
                    }
                    Text("BOSS").font(AppFont.mono(8, .bold)).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.leading, Space.s2)
            }
        }
    }
}

// MARK: - SCNView host

private struct SpaceShooterSceneView: UIViewRepresentable {
    let engine: SpaceShooterEngine

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = engine.scene
        v.delegate = engine
        v.rendersContinuously = true
        v.preferredFramesPerSecond = 60
        v.antialiasingMode = .none
        v.isJitteringEnabled = false
        v.backgroundColor = Synth.indigo
        v.layer.magnificationFilter = .nearest
        v.layer.minificationFilter = .nearest

        // Flying is a drag on the scene. We deliberately DON'T add a full-screen tap
        // recognizer — it used to fire the bomb on any tap, which also swallowed taps
        // meant for the HUD buttons (OVERDRIVE / bomb felt dead). Bomb + OVERDRIVE are
        // now driven only by their HUD buttons. `cancelsTouchesInView = false` lets a
        // stationary touch still reach those SwiftUI buttons.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.onPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        v.addGestureRecognizer(pan)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Low internal resolution → chunky "yesterday's pixels" upscale.
        let h = uiView.bounds.height
        if h > 0 {
            let target: CGFloat = 300
            uiView.contentScaleFactor = max(0.25, min(1, target / h))
        }
        // Aspect-fill the 2:3 biome backdrop so it isn't stretched on a taller screen.
        let w = uiView.bounds.width
        if w > 0, h > 0 {
            let bg = engine.scene.background
            bg.wrapS = .clamp; bg.wrapT = .clamp
            let va = Float(w / h), ia: Float = 688.0 / 1024.0
            let vOff: Float = 0.16   // raise the backdrop (sun/egg sits higher); bottom hides behind the grid
            if va < ia {   // screen narrower than image → crop the sides
                let s = va / ia
                bg.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(s, 1, 1),
                                                      SCNMatrix4MakeTranslation((1 - s) / 2, vOff, 0))
            } else {       // crop top/bottom
                let s = ia / va
                bg.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(1, s, 1),
                                                      SCNMatrix4MakeTranslation(0, (1 - s) / 2 + vOff, 0))
            }
        }
    }

    final class Coordinator: NSObject {
        let engine: SpaceShooterEngine
        private var last: CGPoint = .zero
        init(engine: SpaceShooterEngine) { self.engine = engine }

        @objc func onPan(_ g: UIPanGestureRecognizer) {
            let t = g.translation(in: g.view)
            if g.state == .began { last = .zero }
            let dx = t.x - last.x, dy = t.y - last.y
            last = t
            engine.dragBy(dx: Float(dx), dy: Float(dy))
        }
    }
}
