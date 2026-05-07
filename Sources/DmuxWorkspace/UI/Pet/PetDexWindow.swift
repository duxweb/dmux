import AppKit
import SwiftUI

@MainActor
enum PetDexWindowPresenter {
    private static var controller: NSWindowController?

    static func show(model: AppModel) {
        present(model: model, openCustomPetInstallerOnAppear: false)
    }

    static func showCustomPetInstaller(model: AppModel) {
        present(model: model, openCustomPetInstallerOnAppear: true)
    }

    private static func present(model: AppModel, openCustomPetInstallerOnAppear: Bool) {
        if let window = controller?.window {
            if let hosting = controller?.contentViewController as? NSHostingController<AnyView> {
                hosting.rootView = AnyView(PetDexWindowView(model: model, openCustomPetInstallerOnAppear: openCustomPetInstallerOnAppear))
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = AppWindowIdentifier.petDex
        applyStandardWindowChrome(window, title: petL("pet.dex.window.title", "Pet Dex"))
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 780, height: 560)
        let hosting = NSHostingController(rootView: AnyView(PetDexWindowView(model: model, openCustomPetInstallerOnAppear: openCustomPetInstallerOnAppear)))
        window.contentViewController = hosting
        let controller = NSWindowController(window: window)
        self.controller = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root View

private struct PetDexWindowView: View {
    let model: AppModel
    var openCustomPetInstallerOnAppear = false

    @State private var spotlightIdentity: PetIdentity?
    @State private var customPets = CodexPetPackageService().customPets()
    @State private var showsArchiveConfirmation = false
    @State private var showsCustomPetInstallSheet = false
    @State private var didHandleInitialCustomPetInstall = false
    @State private var customPetInstallURL = ""
    @State private var customPetInstallName = ""
    @State private var customPetInstallRequest: CodexPetInstallRequest?
    @State private var customPetInstallPhase: DexCustomPetInstallPhase = .idle
    @State private var customPetInstallError: String?
    @State private var isResolvingCustomPet = false
    @State private var isInstallingCustomPet = false

    private var petStore: PetStore { model.petStore }

    private var unlockedSpecies: Set<PetSpecies> {
        var unlocked = Set<PetSpecies>()
        for record in petStore.legacy {
            if let species = record.petIdentity.bundledSpecies {
                unlocked.insert(species)
            }
        }
        if petStore.isClaimed, let species = petStore.currentIdentity.bundledSpecies {
            unlocked.insert(species)
        }
        return unlocked
    }

    private var collectionCount: Int {
        unlockedSpecies.count + customPets.count
    }

    private var totalCount: Int {
        PetDexEntry.allCases.count + customPets.count
    }

    private var currentRecord: PetLegacyRecord? {
        guard petStore.isClaimed else { return nil }
        return PetLegacyRecord(
            id: UUID(),
            species: petStore.species,
            identity: petStore.currentIdentity,
            customName: petStore.customName,
            evoPath: petStore.currentEvoPath(),
            totalXP: petStore.currentExperienceTokens,
            stats: petStore.currentStats,
            retiredAt: petStore.claimedAt ?? Date()
        )
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                DexSidebar(
                    currentRecord: currentRecord,
                    claimedAt: petStore.claimedAt,
                    legacyCount: petStore.legacy.count,
                    unlockedCount: collectionCount,
                    totalCount: totalCount,
                    isClaimed: petStore.isClaimed,
                    onArchive: { showsArchiveConfirmation = true },
                    onClaim: showClaimDialog,
                    onInstallCustomPet: presentCustomPetInstallSheet
                )
                .frame(width: 270)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        DexSpeciesGrid(
                            unlockedSpecies: unlockedSpecies,
                            customPets: customPets,
                            onSelect: { identity in
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                    spotlightIdentity = identity
                                }
                            }
                        )

                        if !petStore.legacy.isEmpty {
                            DexHistorySection(
                                records: petStore.legacy,
                                onRestore: restoreArchivedPet
                            )
                        }
                    }
                    .padding(20)
                }
            }
            .frame(minWidth: 780, minHeight: 560)
            .background(Color(NSColor.windowBackgroundColor))

            if let identity = spotlightIdentity {
                DexSpotlightOverlay(identity: identity) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        spotlightIdentity = nil
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear {
            refreshCustomPets()
            guard openCustomPetInstallerOnAppear, !didHandleInitialCustomPetInstall else {
                return
            }
            didHandleInitialCustomPetInstall = true
            presentCustomPetInstallSheet()
        }
        .alert(petL("pet.archive.alert.title", "Archive Current Pet"), isPresented: $showsArchiveConfirmation) {
            Button(petL("common.cancel", "Cancel"), role: .cancel) {}
            Button(petL("pet.archive.confirm", "Confirm Archive")) {
                archiveCurrentPet()
            }
        } message: {
            Text(petL("pet.archive.alert.message", "Archive this pet into the dex and choose a new companion."))
        }
        .sheet(isPresented: $showsCustomPetInstallSheet) {
            DexCustomPetInstallSheet(
                urlText: $customPetInstallURL,
                displayName: $customPetInstallName,
                request: customPetInstallRequest,
                phase: customPetInstallPhase,
                isResolving: isResolvingCustomPet,
                isInstalling: isInstallingCustomPet,
                errorMessage: customPetInstallError,
                onOpenPetMarket: openPetMarket,
                onCancel: {
                    guard !isResolvingCustomPet && !isInstallingCustomPet else { return }
                    showsCustomPetInstallSheet = false
                },
                onResolve: {
                    Task {
                        await resolveCustomPet()
                    }
                },
                onInstall: {
                    Task {
                        await installCustomPet()
                    }
                }
            )
        }
    }

    private func refreshCustomPets() {
        customPets = CodexPetPackageService().customPets()
    }

    private func presentCustomPetInstallSheet() {
        refreshCustomPets()
        resetCustomPetInstallSheet()
        showsCustomPetInstallSheet = true
    }

    private func resetCustomPetInstallSheet(keepURL: Bool = false) {
        if !keepURL {
            customPetInstallURL = ""
        }
        customPetInstallName = ""
        customPetInstallRequest = nil
        customPetInstallPhase = .idle
        customPetInstallError = nil
        isResolvingCustomPet = false
        isInstallingCustomPet = false
    }

    private func archiveCurrentPet() {
        petStore.archiveCurrentPet()
        refreshCustomPets()
        model.statusMessage = String(localized: "pet.archive.success", defaultValue: "Archived current pet.", bundle: .module)
    }

    private func restoreArchivedPet(_ recordID: UUID) {
        petStore.restoreArchivedPet(recordID)
        model.petRefreshCoordinator.refreshNow(reason: .claim)
        model.statusMessage = String(localized: "pet.archive.restore.success", defaultValue: "Restored archived pet.", bundle: .module)
    }

    private func showClaimDialog() {
        guard !petStore.isClaimed,
              let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow else {
            return
        }
        refreshCustomPets()
        PetClaimDialogPresenter.present(
            dialog: PetClaimDialogState(
                selectedOption: .voidcat,
                customPets: customPets
            ),
            staticMode: model.appSettings.pet.staticMode,
            parentWindow: parentWindow,
            onAddCustomPet: {
                PetDexWindowPresenter.showCustomPetInstaller(model: model)
            }
        ) { result in
            guard let result else { return }
            let hiddenSpeciesChance = model.aiStatsStore.hiddenPetSpeciesChanceAcrossProjects(model.projects)
            petStore.claim(
                identity: result.selection.resolveIdentity(hiddenSpeciesChance: hiddenSpeciesChance),
                customName: result.customName,
                totalNormalizedTokens: 0
            )
            model.petRefreshCoordinator.refreshNow(reason: .claim)
            model.statusMessage = String(localized: "pet.claim.success", defaultValue: "Claimed pet.", bundle: .module)
        }
    }

    @MainActor
    private func resolveCustomPet() async {
        guard !isResolvingCustomPet && !isInstallingCustomPet else { return }
        let rawURL = customPetInstallURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            customPetInstallError = String(localized: "pet.custom.install.url_required", defaultValue: "Please enter a Petdex pet page URL.", bundle: .module)
            customPetInstallPhase = .failed
            return
        }

        isResolvingCustomPet = true
        customPetInstallPhase = .resolving
        customPetInstallError = nil
        customPetInstallRequest = nil
        defer { isResolvingCustomPet = false }

        do {
            let request = try await Task.detached(priority: .userInitiated) {
                try await CodexPetPackageService().resolveInstallRequest(from: rawURL)
            }.value
            customPetInstallRequest = request
            customPetInstallName = request.resolvedDisplayName
            customPetInstallPhase = .ready
        } catch {
            customPetInstallPhase = .failed
            customPetInstallError = error.localizedDescription
        }
    }

    @MainActor
    private func installCustomPet() async {
        guard !isResolvingCustomPet && !isInstallingCustomPet else { return }

        let rawURL = customPetInstallURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if customPetInstallRequest?.pageURL.absoluteString != rawURL {
            customPetInstallRequest = nil
            await resolveCustomPet()
        }

        guard let request = customPetInstallRequest else {
            return
        }

        let displayName = customPetInstallName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            customPetInstallPhase = .failed
            customPetInstallError = String(localized: "pet.custom.install.name_required", defaultValue: "Please enter a pet name.", bundle: .module)
            return
        }

        isInstallingCustomPet = true
        customPetInstallPhase = .installing
        customPetInstallError = nil
        defer { isInstallingCustomPet = false }

        do {
            let installRequest = request.withDisplayName(displayName)
            let result = try await Task.detached(priority: .userInitiated) {
                try await CodexPetPackageService().install(from: installRequest)
            }.value
            customPetInstallPhase = .installed
            customPets = CodexPetPackageService().customPets()
            spotlightIdentity = .custom(result.pet)
            model.statusMessage = String(
                format: String(localized: "pet.custom.install.success_format", defaultValue: "Installed %@.", bundle: .module),
                result.pet.normalizedDisplayName
            )
            try? await Task.sleep(nanoseconds: 350_000_000)
            resetCustomPetInstallSheet()
            showsCustomPetInstallSheet = false
        } catch {
            customPetInstallPhase = .failed
            customPetInstallError = error.localizedDescription
        }
    }

    private func openPetMarket() {
        guard let url = URL(string: petL("pet.custom.market.url", "https://petdex.crafter.run/zh")) else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Left Sidebar

private struct DexSidebar: View {
    let currentRecord: PetLegacyRecord?
    let claimedAt: Date?
    let legacyCount: Int
    let unlockedCount: Int
    let totalCount: Int
    let isClaimed: Bool
    let onArchive: () -> Void
    let onClaim: () -> Void
    let onInstallCustomPet: () -> Void

    private var currentIdentity: PetResolvedIdentity? {
        currentRecord.map { $0.resolvedIdentity(for: .companion) }
    }

    private var widestStatText: String {
        currentRecord?.stats.widestCompactValueText ?? "0"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "books.vertical.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(petL("pet.dex.title", "Pet Dex"))
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                        }
                        Text(petL("pet.dex.subtitle", "A record of every coding companion you've raised"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)

                    Divider()

                    VStack(spacing: 8) {
                        DexStat(
                            label: petL("pet.dex.current_companion", "Current Companion"),
                            value: currentIdentity?.title ?? petL("pet.dex.unclaimed", "Not Claimed"),
                            sub: currentRecord.map {
                                let identity = $0.resolvedIdentity(for: .companion)
                                let prefix = identity.subtitle.map { "\($0) · " } ?? ""
                                return "\(prefix)Lv.\($0.progressInfo.level)"
                            } ?? "—"
                        )
                        DexStat(
                            label: petL("pet.dex.archived", "Archived"),
                            value: "\(legacyCount)",
                            sub: legacyCount == 0 ? petL("pet.dex.archived.none", "No archived pets yet") : petL("pet.dex.archived.history", "Past companions")
                        )
                        DexStat(
                            label: petL("pet.dex.collection", "Dex Collection"),
                            value: "\(unlockedCount)/\(totalCount)",
                            sub: unlockedCount == totalCount ? petL("pet.dex.collection.complete", "All companions unlocked") : petL("pet.dex.collection.continue", "Keep exploring")
                        )
                    }

                    Divider()

                    if let record = currentRecord {
                        DexCurrentPetDetail(
                            record: record,
                            claimedAt: claimedAt,
                            widestStatText: widestStatText
                        )
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "pawprint")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(petL("pet.dex.no_current_pet", "No active pet yet"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(16)
            }

            Divider()

            DexSidebarActions(
                isClaimed: isClaimed,
                legacyCount: legacyCount,
                onArchive: onArchive,
                onClaim: onClaim,
                onInstallCustomPet: onInstallCustomPet
            )
            .padding(16)
        }
        .background(Color.primary.opacity(0.02))
    }
}

private struct DexCurrentPetDetail: View {
    let record: PetLegacyRecord
    let claimedAt: Date?
    let widestStatText: String

    private var identity: PetResolvedIdentity {
        record.resolvedIdentity(for: .companion)
    }

    private var accent: Color {
        record.petIdentity.bundledSpecies?.dexAccent ?? AppTheme.focus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(petL("pet.dex.current_pet", "Current Pet"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                PetSpriteView(
                    identity: record.petIdentity,
                    stage: .companion,
                    staticMode: true,
                    displaySize: 80
                )
                .frame(width: 80, height: 80)

                Text(identity.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                if let subtitle = identity.subtitle {
                    Text("\(subtitle) · \(PetStage.companion.displayName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(PetStage.companion.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)

            let maxV = PetStats.traitDisplayMaxValue
            Group {
                DexAttrBar(emoji: "🧠", name: petL("pet.attribute.wisdom", "Wisdom"), value: record.stats.wisdom, maxValue: maxV, color: accent, widestValueText: widestStatText)
                DexAttrBar(emoji: "🔥", name: petL("pet.attribute.chaos", "Chaos"), value: record.stats.chaos, maxValue: maxV, color: Color(hex: 0xFF6030), widestValueText: widestStatText)
                DexAttrBar(emoji: "🌙", name: petL("pet.attribute.night", "Night"), value: record.stats.night, maxValue: maxV, color: Color(hex: 0x6060CC), widestValueText: widestStatText)
                DexAttrBar(emoji: "💪", name: petL("pet.attribute.stamina", "Stamina"), value: record.stats.stamina, maxValue: maxV, color: Color(hex: 0x20A060), widestValueText: widestStatText)
                DexAttrBar(emoji: "🩹", name: petL("pet.attribute.empathy", "Empathy"), value: record.stats.empathy, maxValue: maxV, color: Color(hex: 0xE060A0), widestValueText: widestStatText)
            }

            HStack(spacing: 6) {
                Text(record.stats.personaTag)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(accent.opacity(0.12)))

                Spacer()

                if let at = claimedAt {
                    Text(at, format: .dateTime.month().day())
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text(petL("pet.total_xp", "Total XP"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(petFormatCompactNumber(record.totalXP))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }
}

private struct DexSidebarActions: View {
    let isClaimed: Bool
    let legacyCount: Int
    let onArchive: () -> Void
    let onClaim: () -> Void
    let onInstallCustomPet: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if isClaimed {
                Button(role: .destructive, action: onArchive) {
                    Label(petL("pet.archive.action", "Archive"), systemImage: "archivebox.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: onClaim) {
                    Label(petL("pet.claim.action", "Claim Pet"), systemImage: "pawprint.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            Button(action: onInstallCustomPet) {
                Label(petL("pet.custom.install.action", "Add Custom Pet"), systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
    }
}

private struct DexStat: View {
    let label: String
    let value: String
    let sub: String

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(sub)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

private struct DexAttrBar: View {
    let emoji: String
    let name: String
    let value: Int
    let maxValue: Int
    let color: Color
    let widestValueText: String

    var body: some View {
        HStack(spacing: 6) {
            Text(emoji).font(.system(size: 12)).frame(width: 16)
            Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.12)).frame(height: 4)
                    RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.75))
                        .frame(width: geo.size.width * min(1, max(0, CGFloat(value) / CGFloat(max(1, maxValue)))), height: 4)
                }
            }
            .frame(height: 4)
            ZStack(alignment: .trailing) {
                Text(widestValueText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .hidden()
                Text(petFormatCompactNumber(value))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Species Grid

private struct DexSpeciesGrid: View {
    let unlockedSpecies: Set<PetSpecies>
    let customPets: [PetCustomPet]
    let onSelect: (PetIdentity) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(petL("pet.dex.bundled.section", "Bundled Pets"))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text(String(format: petL("pet.dex.unlocked_count", "%@/%@ unlocked"), "\(unlockedSpecies.count)", "\(PetDexEntry.allCases.count)"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(PetDexEntry.allCases) { entry in
                        DexSpeciesCard(
                            entry: entry,
                            unlocked: unlockedSpecies.contains(entry.species)
                        )
                        .onTapGesture {
                            guard unlockedSpecies.contains(entry.species) else { return }
                            onSelect(.bundled(entry.species))
                        }
                    }
                }
            }

            if !customPets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(petL("pet.claim.custom.section", "Custom Pets"))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Spacer()
                        Text(String(format: petL("pet.custom.installed_count", "%@ installed"), "\(customPets.count)"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(customPets) { pet in
                            DexCustomPetCard(pet: pet)
                                .onTapGesture {
                                    onSelect(.custom(pet))
                                }
                        }
                    }
                }
            }
        }
    }
}

private struct DexSpeciesCard: View {
    let entry: PetDexEntry
    let unlocked: Bool

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(unlocked ? entry.species.dexAccent.opacity(0.12) : Color.primary.opacity(0.05))
                    .frame(width: 56, height: 56)

                if unlocked {
                    PetSpriteView(
                        identity: .bundled(entry.species),
                        stage: .companion,
                        staticMode: true,
                        displaySize: 44
                    )
                    .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "questionmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                }
            }

            VStack(spacing: 3) {
                Text(unlocked ? entry.species.displayName : petL("pet.dex.unknown", "???"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(unlocked ? PetStage.companion.displayName : petL("pet.dex.locked", "Locked"))
                    .font(.system(size: 12))
                    .foregroundStyle(unlocked ? entry.species.dexAccent : .secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 136)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(unlocked ? entry.species.dexAccent.opacity(0.25) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .opacity(unlocked ? 1 : 0.82)
    }
}

private struct DexCustomPetCard: View {
    let pet: PetCustomPet

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(AppTheme.focus.opacity(0.12))
                    .frame(width: 56, height: 56)

                PetSpriteView(
                    identity: .custom(pet),
                    stage: .companion,
                    staticMode: true,
                    displaySize: 44
                )
                .frame(width: 44, height: 44)
            }

            VStack(spacing: 3) {
                Text(pet.normalizedDisplayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(petL("pet.custom.installed", "Custom pet"))
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.focus)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 136)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.focus.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - History Section

private struct DexHistorySection: View {
    let records: [PetLegacyRecord]
    let onRestore: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(petL("pet.archive.history", "Archive History"))
                .font(.system(size: 15, weight: .bold, design: .rounded))

            VStack(spacing: 6) {
                ForEach(records) { record in
                    DexHistoryRow(
                        record: record,
                        onRestore: { onRestore(record.id) }
                    )
                }
            }
        }
    }
}

private struct DexHistoryRow: View {
    let record: PetLegacyRecord
    let onRestore: () -> Void

    private var info: PetProgressInfo { record.progressInfo }
    private var accent: Color { record.petIdentity.bundledSpecies?.dexAccent ?? AppTheme.focus }

    var body: some View {
        HStack(spacing: 12) {
            PetSpriteView(
                identity: record.petIdentity,
                stage: info.stage,
                staticMode: true,
                displaySize: 36
            )
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                let identity = record.resolvedIdentity(for: info.stage)
                HStack(spacing: 6) {
                    Text(identity.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(info.stage.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }
                Text(historySubtitle(identity: identity, info: info))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(record.retiredAt, format: .dateTime.year().month().day())
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            Button(action: onRestore) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help(petL("pet.archive.restore.action", "Restore"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}

// MARK: - Install Sheet

private enum DexCustomPetInstallPhase: Equatable {
    case idle
    case resolving
    case ready
    case installing
    case installed
    case failed
}

private struct DexCustomPetInstallSheet: View {
    @Binding var urlText: String
    @Binding var displayName: String
    let request: CodexPetInstallRequest?
    let phase: DexCustomPetInstallPhase
    let isResolving: Bool
    let isInstalling: Bool
    let errorMessage: String?
    let onOpenPetMarket: () -> Void
    let onCancel: () -> Void
    let onResolve: () -> Void
    let onInstall: () -> Void

    private var isBusy: Bool {
        isResolving || isInstalling
    }

    private var canResolve: Bool {
        !isBusy && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canInstall: Bool {
        !isBusy && request != nil && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        AppDialogFormLayout(
            header: AppDialogHeaderSpec(
                title: petL("pet.custom.install.title", "Add Custom Pet"),
                message: petL("pet.custom.install.subtitle", "Paste a Petdex page, verify the package, then install it into Codux."),
                icon: "square.and.arrow.down",
                iconColor: AppTheme.focus
            ),
            width: 580,
            contentSpacing: 18,
            content: {
                DexInstallURLRow(
                    text: $urlText,
                    placeholder: petL("pet.custom.install.url.placeholder", "https://petdex.crafter.run/zh/pets/boba"),
                    disabled: isBusy,
                    isResolving: isResolving,
                    canResolve: canResolve,
                    parseLabel: request == nil
                        ? petL("pet.custom.install.resolve", "Parse")
                        : petL("pet.custom.install.resolve_again", "Parse Again"),
                    onOpenPetMarket: onOpenPetMarket,
                    onResolve: onResolve
                )

                if isResolving && request == nil {
                    DexInstallInlineMessage(
                        systemImage: "ellipsis.circle.fill",
                        text: petL("pet.custom.install.resolving", "Reading Petdex page..."),
                        tint: AppTheme.focus,
                        showsSpinner: true
                    )
                }

                if let request {
                    DexInstallPreviewHero(request: request)

                    DexInstallField(
                        label: petL("pet.custom.install.name.label", "Pet Name"),
                        text: $displayName,
                        placeholder: request.resolvedDisplayName,
                        disabled: isBusy
                    )

                    DexInstallChecks()
                }

                if isInstalling {
                    DexInstallInlineMessage(
                        systemImage: "arrow.down.circle.fill",
                        text: petL("pet.custom.install.installing.detail", "Downloading, unpacking, and validating the pet package."),
                        tint: AppTheme.focus,
                        showsSpinner: true
                    )
                }

                if phase == .installed {
                    DexInstallInlineMessage(
                        systemImage: "checkmark.circle.fill",
                        text: petL("pet.custom.install.installed", "Installed"),
                        tint: Color(nsColor: .systemGreen),
                        showsSpinner: false
                    )
                }

                if let errorMessage {
                    DexInstallInlineMessage(
                        systemImage: "exclamationmark.triangle.fill",
                        text: errorMessage,
                        tint: Color(nsColor: .systemRed),
                        showsSpinner: false
                    )
                }
            },
            actions: {
                Button(petL("common.cancel", "Cancel"), action: onCancel)
                    .buttonStyle(AppDialogSecondaryButtonStyle())
                    .disabled(isBusy)

                Button(action: onInstall) {
                    HStack(spacing: 6) {
                        if isInstalling {
                            ProgressView()
                                .scaleEffect(0.6)
                        }
                        Text(isInstalling
                            ? petL("pet.custom.install.installing", "Installing...")
                            : petL("pet.custom.install.confirm", "Install"))
                    }
                }
                .buttonStyle(AppDialogPrimaryButtonStyle())
                .disabled(!canInstall)
            }
        )
    }
}

private struct DexInstallURLRow: View {
    @Binding var text: String
    let placeholder: String
    let disabled: Bool
    let isResolving: Bool
    let canResolve: Bool
    let parseLabel: String
    let onOpenPetMarket: () -> Void
    let onResolve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(petL("pet.custom.install.url.label", "Petdex Page URL"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .disabled(disabled)

                Button(action: onOpenPetMarket) {
                    Label(petL("pet.custom.market.action", "Get Pets"), systemImage: "arrow.up.right.square")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppTheme.focus)
                .help(petL("pet.custom.market.detail", "Pick a pet there, then paste its page URL here."))

                Button(action: onResolve) {
                    HStack(spacing: 6) {
                        if isResolving {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        Text(parseLabel)
                    }
                }
                .buttonStyle(AppDialogSecondaryButtonStyle())
                .disabled(!canResolve)
            }
        }
    }
}

private struct DexInstallField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .disabled(disabled)
        }
    }
}

private struct DexInstallPreviewHero: View {
    let request: CodexPetInstallRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(petL("pet.custom.install.preview.label", "Pet Preview"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: request.imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(AppTheme.focus)
                    case .empty:
                        ProgressView()
                            .scaleEffect(0.8)
                    @unknown default:
                        Image(systemName: "pawprint.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(AppTheme.focus)
                    }
                }
                .frame(width: 88, height: 88)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.focus.opacity(0.10))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text(request.resolvedDisplayName)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .lineLimit(1)

                    if let description = request.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "link")
                            .font(.system(size: 10, weight: .semibold))
                        Text(request.pageURL.host ?? request.pageURL.absoluteString)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct DexInstallChecks: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DexCheckRow(text: petL("pet.custom.install.validation.page", "Petdex page verified"))
            DexCheckRow(text: petL("pet.custom.install.validation.package", "Package link found"))
            DexCheckRow(text: petL("pet.custom.install.validation.format", "Codex-format check runs during install"))
        }
    }
}

private struct DexCheckRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: .labelColor).opacity(0.85))
            Spacer(minLength: 0)
        }
    }
}

private struct DexInstallInlineMessage: View {
    let systemImage: String
    let text: String
    let tint: Color
    let showsSpinner: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsSpinner {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }
}

// MARK: - Spotlight Overlay

private struct DexSpotlightOverlay: View {
    let identity: PetIdentity
    let onDismiss: () -> Void

    @State private var spriteScale: CGFloat = 0.6
    @State private var spriteOpacity: Double = 0

    private var accent: Color {
        identity.bundledSpecies?.dexAccent ?? AppTheme.focus
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)

                    Circle()
                        .fill(accent.opacity(0.10))
                        .frame(width: 160, height: 160)

                    PetSpriteView(
                        identity: identity,
                        stage: .companion,
                        staticMode: false,
                        displaySize: 140
                    )
                    .frame(width: 140, height: 140)
                }
                .scaleEffect(spriteScale)
                .opacity(spriteOpacity)

                VStack(spacing: 6) {
                    Text(identity.displayName)
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text(identity.detailText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(accent.opacity(0.18)))
                }
                .opacity(spriteOpacity)

                Text(petL("common.click_anywhere_to_close", "Click anywhere to close"))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
                    .opacity(spriteOpacity)
            }
            .padding(40)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) {
                spriteScale = 1.0
                spriteOpacity = 1.0
            }
        }
    }
}

// MARK: - Shared helpers

private extension PetLegacyRecord {
    var progressInfo: PetProgressInfo {
        PetProgressInfo(totalXP: totalXP)
    }
}

struct PetDexEntry: CaseIterable, Identifiable {
    let species: PetSpecies

    var id: String { species.rawValue }

    static let allCases: [PetDexEntry] = PetSpecies.allCases.map { species in
        PetDexEntry(species: species)
    }
}

private extension PetSpecies {
    var dexAccent: Color {
        petAccentColor
    }
}

private func historySubtitle(identity: PetResolvedIdentity, info: PetProgressInfo) -> String {
    let parts = [
        identity.subtitle,
        "\(petFormatCompactNumber(info.totalXP)) XP",
        "Lv.\(info.level)",
    ].compactMap { $0 }
    return parts.joined(separator: " · ")
}
