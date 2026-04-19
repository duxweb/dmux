import SwiftUI

// MARK: - Evolution Effect Overlay
// Shown in popover when stage changes. Pixel particles scatter old sprite,
// flash, then new form assembles. Tap or auto-dismiss after 3.5s.

struct PetEvolutionEffectView: View {
    let species: PetSpecies
    let evoPath: PetEvoPath
    let fromStage: PetStage
    let toStage: PetStage
    let onComplete: () -> Void

    @State private var oldOpacity: Double = 1
    @State private var oldBlur: Double = 0
    @State private var flashOpacity: Double = 0
    @State private var newOpacity: Double = 0
    @State private var newScale: Double = 0.4
    @State private var newBlur: Double = 6
    @State private var labelOpacity: Double = 0
    @State private var particles: [EvoParticle] = []
    @State private var showParticles = false
    @State private var glowOpacity: Double = 0

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.88))
                .ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [toStage.accentColor.opacity(0.55), .clear],
                        center: .center, startRadius: 0, endRadius: 90
                    )
                )
                .frame(width: 180, height: 180)
                .opacity(glowOpacity)
                .blur(radius: 12)

            Circle()
                .fill(Color.white)
                .frame(width: 240, height: 240)
                .blur(radius: 20)
                .opacity(flashOpacity)

            // Sprite layer (old dissolves, new assembles)
            ZStack {
                PetSpriteView(species: species, stage: fromStage, staticMode: true, displaySize: 120)
                    .opacity(oldOpacity)
                    .blur(radius: oldBlur)
                PetSpriteView(species: species, stage: toStage, staticMode: false, displaySize: 120)
                    .scaleEffect(newScale)
                    .blur(radius: newBlur)
                    .opacity(newOpacity)
            }
            .offset(y: -28)

            if showParticles {
                ForEach(particles) { p in
                    EvoParticleView(particle: p, accentColor: fromStage.accentColor)
                }
            }

            // Labels — tight below sprite
            VStack(spacing: 5) {
                Text(petL("pet.effect.evolution", "Evolution!"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(toStage.accentColor)
                Text(toStage.speciesName(for: species, evoPath: evoPath))
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(toStage.displayName)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                Text(petL("common.tap_to_continue", "Tap to continue"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 2)
            }
            .offset(y: 80)
            .opacity(labelOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(-14)
        .contentShape(Rectangle())
        .onTapGesture { onComplete() }
        .onAppear { spawnParticles(); runSequence() }
    }

    private func spawnParticles() {
        particles = (0..<28).map { _ in
            EvoParticle(
                id: UUID(),
                dx: CGFloat.random(in: -110...110),
                dy: CGFloat.random(in: -110...110),
                size: CGFloat.random(in: 3...7),
                delay: Double.random(in: 0...0.15)
            )
        }
    }

    private func runSequence() {
        showParticles = true
        withAnimation(.easeOut(duration: 0.5)) { oldOpacity = 0; oldBlur = 10 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeIn(duration: 0.12)) { flashOpacity = 0.75 }
            withAnimation(.easeOut(duration: 0.3).delay(0.12)) { flashOpacity = 0 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.72)) {
                newOpacity = 1; newScale = 1.05; newBlur = 0
            }
            withAnimation(.easeOut(duration: 0.4)) { glowOpacity = 1 }
            withAnimation(.easeInOut(duration: 0.3).delay(0.15)) { newScale = 1.0 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeIn(duration: 0.35)) { labelOpacity = 1 }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { onComplete() }
    }
}

// MARK: - Max Level (Lv.100) Effect

struct PetMaxLevelEffectView: View {
    let species: PetSpecies
    let stage: PetStage
    let onComplete: () -> Void

    @State private var spriteScale: Double = 0.6
    @State private var spriteOpacity: Double = 0
    @State private var crownScale: Double = 0.2
    @State private var crownOpacity: Double = 0
    @State private var glowOpacity: Double = 0
    @State private var ringsScale: Double = 0.3
    @State private var ringsOpacity: Double = 0
    @State private var labelOpacity: Double = 0
    @State private var particles: [EvoParticle] = []
    @State private var showParticles = false
    @State private var flashOpacity: Double = 0

    private let gold = Color(hex: 0xFFD700)
    private let deepGold = Color(hex: 0xCC8800)

    var body: some View {
        ZStack {
            // Dark backdrop with subtle gold tint
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.92), Color(hex: 0x1A1000).opacity(0.95)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .ignoresSafeArea()

            // Pulsing gold rings
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(gold.opacity(0.3 - Double(i) * 0.08), lineWidth: 1.5)
                    .frame(width: CGFloat(160 + i * 50), height: CGFloat(160 + i * 50))
                    .scaleEffect(ringsScale + Double(i) * 0.08)
                    .opacity(ringsOpacity - Double(i) * 0.1)
            }

            // Gold radial glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [gold.opacity(0.4), deepGold.opacity(0.15), .clear],
                        center: .center, startRadius: 0, endRadius: 110
                    )
                )
                .frame(width: 220, height: 220)
                .opacity(glowOpacity)
                .blur(radius: 8)

            // White flash
            Circle()
                .fill(Color.white)
                .frame(width: 260, height: 260)
                .blur(radius: 24)
                .opacity(flashOpacity)

            // Gold particles
            if showParticles {
                ForEach(particles) { p in
                    EvoParticleView(particle: p, accentColor: gold)
                }
            }

            // Crown + sprite + labels — all centered together
            VStack(spacing: 8) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [gold, deepGold], startPoint: .top, endPoint: .bottom))
                    .shadow(color: gold.opacity(0.8), radius: 8)
                    .scaleEffect(crownScale)
                    .opacity(crownOpacity)

                PetSpriteView(species: species, stage: stage, staticMode: false, displaySize: 120)
                    .scaleEffect(spriteScale)
                    .opacity(spriteOpacity)

                VStack(spacing: 5) {
                    Text(petL("pet.stage.awakened_complete", "Awakened"))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(gold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(gold.opacity(0.15)))
                    Text("Lv. 100")
                        .font(.system(size: 28, weight: .black, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [gold, deepGold], startPoint: .top, endPoint: .bottom))
                        .shadow(color: gold.opacity(0.5), radius: 4)
                    Text(petL("pet.inherit.unlock_effect", "Inheritance ability unlocked"))
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(petL("common.tap_to_continue", "Tap to continue"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.25))
                        .padding(.top, 2)
                }
                .opacity(labelOpacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(-14)
        .contentShape(Rectangle())
        .onTapGesture { onComplete() }
        .onAppear { spawnGoldParticles(); runMaxLevelSequence() }
    }

    private func spawnGoldParticles() {
        particles = (0..<36).map { _ in
            EvoParticle(
                id: UUID(),
                dx: CGFloat.random(in: -130...130),
                dy: CGFloat.random(in: -130...130),
                size: CGFloat.random(in: 2...6),
                delay: Double.random(in: 0...0.2)
            )
        }
    }

    private func runMaxLevelSequence() {
        // 0.0s — white flash
        withAnimation(.easeIn(duration: 0.1)) { flashOpacity = 0.9 }
        withAnimation(.easeOut(duration: 0.5).delay(0.1)) { flashOpacity = 0 }

        // 0.1s — sprite + glow appear
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                spriteScale = 1.0; spriteOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.6)) { glowOpacity = 1 }
        }

        // 0.3s — rings expand
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.easeOut(duration: 0.7)) { ringsScale = 1.0; ringsOpacity = 1 }
        }

        // 0.5s — gold particles burst
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showParticles = true
        }

        // 0.7s — crown drops in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                crownScale = 1.0; crownOpacity = 1
            }
        }

        // 1.1s — labels
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation(.easeIn(duration: 0.4)) { labelOpacity = 1 }
        }

        // 4.0s — auto dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { onComplete() }
    }
}

// MARK: - Shared Particle

struct EvoParticle: Identifiable {
    let id: UUID
    let dx: CGFloat
    let dy: CGFloat
    let size: CGFloat
    let delay: Double
}

struct EvoParticleView: View {
    let particle: EvoParticle
    let accentColor: Color
    @State private var moved = false
    @State private var faded = false

    var body: some View {
        Rectangle()
            .fill(
                [accentColor, accentColor.adjustingBrightness(0.3), Color.white]
                    .randomElement()!
                    .opacity(0.9)
            )
            .frame(width: particle.size, height: particle.size)
            .offset(x: moved ? particle.dx : 0, y: moved ? particle.dy : 0)
            .opacity(faded ? 0 : 1)
            .onAppear {
                withAnimation(.easeOut(duration: 0.45).delay(particle.delay)) { moved = true }
                withAnimation(.easeIn(duration: 0.25).delay(particle.delay + 0.3)) { faded = true }
            }
    }
}

// MARK: - Level Up Effect
// Lightweight overlay shown inside the popover on each level-up.
// Semi-transparent so the pet is still visible. Auto-dismisses in 1.8s.

struct PetLevelUpEffectView: View {
    let level: Int
    let accentColor: Color
    let onComplete: () -> Void

    @State private var ringScale: Double = 0.5
    @State private var ringOpacity: Double = 0
    @State private var labelScale: Double = 0.6
    @State private var labelOpacity: Double = 0
    @State private var glowOpacity: Double = 0
    @State private var particles: [EvoParticle] = []
    @State private var showParticles = false

    var body: some View {
        ZStack {
            // Subtle dark scrim — not solid black, pet shows through
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()

            // Expanding ring
            Circle()
                .stroke(accentColor.opacity(0.6), lineWidth: 2)
                .frame(width: 160, height: 160)
                .scaleEffect(ringScale)
                .opacity(ringOpacity)

            // Soft glow
            Circle()
                .fill(RadialGradient(
                    colors: [accentColor.opacity(0.35), .clear],
                    center: .center, startRadius: 0, endRadius: 80
                ))
                .frame(width: 160, height: 160)
                .opacity(glowOpacity)
                .blur(radius: 10)

            // Particles
            if showParticles {
                ForEach(particles) { p in
                    EvoParticleView(particle: p, accentColor: accentColor)
                }
            }

            // Level badge — pops up from center
            VStack(spacing: 4) {
                Text("LEVEL UP")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(accentColor)
                Text("Lv.\(level)")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: accentColor.opacity(0.7), radius: 6)
                    .contentTransition(.numericText())
            }
            .scaleEffect(labelScale)
            .opacity(labelOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onComplete() }
        .onAppear { spawnParticles(); runSequence() }
    }

    private func spawnParticles() {
        particles = (0..<16).map { _ in
            EvoParticle(
                id: UUID(),
                dx: CGFloat.random(in: -80...80),
                dy: CGFloat.random(in: -80...80),
                size: CGFloat.random(in: 2...5),
                delay: Double.random(in: 0...0.1)
            )
        }
    }

    private func runSequence() {
        // Ring expands
        withAnimation(.easeOut(duration: 0.5)) { ringScale = 1.4; ringOpacity = 1 }
        withAnimation(.easeIn(duration: 0.3).delay(0.35)) { ringOpacity = 0 }

        // Glow
        withAnimation(.easeOut(duration: 0.3)) { glowOpacity = 1 }
        withAnimation(.easeIn(duration: 0.4).delay(0.5)) { glowOpacity = 0 }

        // Particles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { showParticles = true }

        // Label springs in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                labelScale = 1.0; labelOpacity = 1
            }
        }

        // Label fades out
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.35)) { labelOpacity = 0; labelScale = 1.1 }
        }

        // Dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { onComplete() }
    }
}

// MARK: - Hatch Effect
// Shown when egg hatches into infant. Egg shatters → infant appears.

struct PetHatchEffectView: View {
    let species: PetSpecies
    let onComplete: () -> Void

    @State private var eggOpacity: Double = 1
    @State private var eggScale: Double = 1
    @State private var eggShake: Double = 0
    @State private var flashOpacity: Double = 0
    @State private var infantOpacity: Double = 0
    @State private var infantScale: Double = 0.3
    @State private var infantBlur: Double = 8
    @State private var glowOpacity: Double = 0
    @State private var labelOpacity: Double = 0
    @State private var particles: [EvoParticle] = []
    @State private var showParticles = false

    private let shellColor = Color(hex: 0xF5DEB3)

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.88))
                .ignoresSafeArea()

            // Glow
            Circle()
                .fill(RadialGradient(
                    colors: [shellColor.opacity(0.5), .clear],
                    center: .center, startRadius: 0, endRadius: 90
                ))
                .frame(width: 180, height: 180)
                .opacity(glowOpacity)
                .blur(radius: 14)

            // Flash
            Circle()
                .fill(Color.white)
                .frame(width: 260, height: 260)
                .blur(radius: 22)
                .opacity(flashOpacity)

            // Egg + infant sprites
            ZStack {
                PetSpriteView(species: species, stage: .egg, staticMode: true, displaySize: 110)
                    .scaleEffect(eggScale)
                    .rotationEffect(.degrees(eggShake))
                    .opacity(eggOpacity)

                PetSpriteView(species: species, stage: .infant, staticMode: false, displaySize: 110)
                    .scaleEffect(infantScale)
                    .blur(radius: infantBlur)
                    .opacity(infantOpacity)
            }
            .offset(y: -28)

            // Shell particles
            if showParticles {
                ForEach(particles) { p in
                    EvoParticleView(particle: p, accentColor: shellColor)
                }
            }

            // Labels
            VStack(spacing: 6) {
                Text(petL("pet.effect.hatch_success", "Hatched!"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(shellColor)
                Text(petL("pet.stage.infant", "Infant"))
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(petL("common.tap_to_continue", "Tap to continue"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 4)
            }
            .offset(y: 80)
            .opacity(labelOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onComplete() }
        .onAppear { spawnShellParticles(); runHatchSequence() }
    }

    private func spawnShellParticles() {
        particles = (0..<24).map { _ in
            EvoParticle(
                id: UUID(),
                dx: CGFloat.random(in: -100...100),
                dy: CGFloat.random(in: -100...100),
                size: CGFloat.random(in: 3...8),
                delay: Double.random(in: 0...0.1)
            )
        }
    }

    private func runHatchSequence() {
        // 0.0–0.6s: egg shakes
        withAnimation(.easeInOut(duration: 0.08).repeatCount(6, autoreverses: true)) {
            eggShake = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.default) { eggShake = 0 }
        }

        // 0.55s: egg pulses bigger then shatters
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeIn(duration: 0.12)) { eggScale = 1.15 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.67) {
            withAnimation(.easeIn(duration: 0.12)) { flashOpacity = 0.8 }
            withAnimation(.easeOut(duration: 0.35).delay(0.12)) { flashOpacity = 0 }
            withAnimation(.easeIn(duration: 0.15)) { eggOpacity = 0; eggScale = 1.4 }
            showParticles = true
            withAnimation(.easeOut(duration: 0.5)) { glowOpacity = 1 }
        }

        // 0.85s: infant appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                infantOpacity = 1; infantScale = 1.0; infantBlur = 0
            }
        }

        // 1.2s: labels
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeIn(duration: 0.3)) { labelOpacity = 1 }
        }

        // 4.0s: auto dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { onComplete() }
    }
}
