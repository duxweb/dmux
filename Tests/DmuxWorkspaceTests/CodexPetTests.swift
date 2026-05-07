import XCTest
@testable import DmuxWorkspace

final class CodexPetAtlasSpecTests: XCTestCase {
    func testOfficialAtlasDimensionsAndRows() {
        XCTAssertEqual(CodexPetAtlasSpec.columns, 8)
        XCTAssertEqual(CodexPetAtlasSpec.rows, 9)
        XCTAssertEqual(CodexPetAtlasSpec.cellWidth, 192)
        XCTAssertEqual(CodexPetAtlasSpec.cellHeight, 208)
        XCTAssertEqual(CodexPetAtlasSpec.atlasWidth, 1536)
        XCTAssertEqual(CodexPetAtlasSpec.atlasHeight, 1872)

        XCTAssertEqual(CodexPetAtlasSpec.animation(for: .idle).row, 0)
        XCTAssertEqual(CodexPetAtlasSpec.animation(for: .waiting).row, 6)
        XCTAssertEqual(CodexPetAtlasSpec.animation(for: .review).row, 8)
        XCTAssertEqual(CodexPetAtlasSpec.animation(for: .runningRight).frameCount, 8)
    }

    func testPlaybackUsesCalmerCycleAndPreservesAtlasFrameHoldWeights() {
        let animation = CodexPetAtlasSpec.animation(for: .idle)
        let durations = CodexPetPlaybackPolicy.frameDurations(
            for: animation,
            activeFrameCount: animation.frameCount
        )

        XCTAssertEqual(durations.count, animation.frameCount)
        XCTAssertEqual(
            durations.reduce(0, +),
            CodexPetPlaybackPolicy.baseFrameDuration
                * Double(animation.frameCount)
                * CodexPetPlaybackPolicy.fullFrameCycleDurationMultiplier,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(durations[0], durations[1])
        XCTAssertGreaterThan(durations[durations.count - 1], durations[1])
        XCTAssertGreaterThan(durations[0], 2.0)
    }

    func testFeedbackAnimationsAreNotGloballySpedUp() {
        for state in CodexPetAnimationState.allCases where state != .waiting {
            XCTAssertGreaterThanOrEqual(
                CodexPetPlaybackPolicy.cycleDurationMultiplier(for: state),
                1.0
            )
        }
    }

    func testPlaybackUsesActiveFrameCountWithoutSpeedingUpShortRows() {
        let animation = CodexPetAtlasSpec.animation(for: .idle)
        let durations = CodexPetPlaybackPolicy.frameDurations(
            for: animation,
            activeFrameCount: animation.frameCount - 1
        )

        XCTAssertEqual(durations.count, animation.frameCount - 1)
        XCTAssertEqual(
            durations.reduce(0, +),
            CodexPetPlaybackPolicy.baseFrameDuration * Double(animation.frameCount),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(durations[0], durations[1])
    }

    func testPlaybackSlightlySpeedsUpOnlyFullFrameRows() {
        let animation = CodexPetAtlasSpec.animation(for: .runningRight)
        let fullFrameTotal = CodexPetPlaybackPolicy.frameDurations(
            for: animation,
            activeFrameCount: animation.frameCount
        ).reduce(0, +)
        let shortFrameTotal = CodexPetPlaybackPolicy.frameDurations(
            for: animation,
            activeFrameCount: animation.frameCount - 1
        ).reduce(0, +)

        XCTAssertEqual(
            fullFrameTotal,
            CodexPetPlaybackPolicy.baseFrameDuration
                * Double(animation.frameCount)
                * CodexPetPlaybackPolicy.fullFrameCycleDurationMultiplier,
            accuracy: 0.001
        )
        XCTAssertEqual(
            shortFrameTotal,
            CodexPetPlaybackPolicy.baseFrameDuration * Double(animation.frameCount),
            accuracy: 0.001
        )
        XCTAssertLessThan(
            fullFrameTotal,
            CodexPetPlaybackPolicy.baseFrameDuration * Double(animation.frameCount)
        )
    }

    func testPlaybackUsesActiveFrameCountWithoutRushingLongRows() {
        let animation = CodexPetAtlasSpec.animation(for: .idle)
        let activeFrameCount = animation.frameCount + 1
        let durations = CodexPetPlaybackPolicy.frameDurations(
            for: animation,
            activeFrameCount: activeFrameCount
        )

        XCTAssertEqual(durations.count, activeFrameCount)
        XCTAssertEqual(
            durations.reduce(0, +),
            CodexPetPlaybackPolicy.baseFrameDuration * Double(activeFrameCount),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(durations[0], durations[1])
    }

    func testWaitingPlaybackIsSlowerForSleepState() {
        let idle = CodexPetAtlasSpec.animation(for: .idle)
        let waiting = CodexPetAtlasSpec.animation(for: .waiting)
        let idleTotal = CodexPetPlaybackPolicy.frameDurations(
            for: idle,
            activeFrameCount: idle.frameCount
        ).reduce(0, +)
        let waitingTotal = CodexPetPlaybackPolicy.frameDurations(
            for: waiting,
            activeFrameCount: waiting.frameCount
        ).reduce(0, +)

        XCTAssertEqual(
            waitingTotal,
            CodexPetPlaybackPolicy.baseFrameDuration
                * Double(waiting.frameCount)
                * CodexPetPlaybackPolicy.cycleDurationMultiplier(for: .waiting)
                * CodexPetPlaybackPolicy.fullFrameCycleDurationMultiplier,
            accuracy: 0.001
        )
        XCTAssertGreaterThan(waitingTotal, idleTotal)
    }

    func testBundledAtlasesUseFlatSpeciesPackages() {
        for subdirectory in PetSpecies.allCases.map({ "Pets/\($0.assetFolder)" }) {
            XCTAssertNotNil(
                Bundle.module.url(
                    forResource: "spritesheet",
                    withExtension: "png",
                    subdirectory: subdirectory
                ),
                "Missing spritesheet for \(subdirectory)"
            )
            XCTAssertNotNil(
                Bundle.module.url(
                    forResource: "pet",
                    withExtension: "json",
                    subdirectory: subdirectory
                ),
                "Missing manifest for \(subdirectory)"
            )
        }
    }

    func testBundledPetResourcesExposeOnlyFlatPackages() throws {
        for species in PetSpecies.allCases.map(\.assetFolder) {
            let speciesURL = try XCTUnwrap(
                Bundle.module.url(forResource: species, withExtension: nil, subdirectory: "Pets"),
                "Missing bundled pet resource directory for \(species)"
            )
            let resourceURLs = try FileManager.default.contentsOfDirectory(
                at: speciesURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            XCTAssertEqual(Set(resourceURLs.map(\.lastPathComponent)), Set(["pet.json", "spritesheet.png"]))

            XCTAssertTrue(
                resourceURLs.allSatisfy { url in
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                },
                "Bundled pet runtime must expose only flat package files."
            )
        }
    }

    func testBundledPetManifestsUseStableNonLocalizedNames() throws {
        for species in PetSpecies.allCases {
            let manifestURL = try XCTUnwrap(
                Bundle.module.url(
                    forResource: "pet",
                    withExtension: "json",
                    subdirectory: "Pets/\(species.assetFolder)"
                )
            )
            let manifest = try JSONDecoder().decode(
                CodexPetManifest.self,
                from: Data(contentsOf: manifestURL)
            )

            XCTAssertEqual(manifest.displayName, species.assetFolder)
        }
    }
}

final class CodexPetActivityAnimationMapperTests: XCTestCase {
    func testMapsAIActivityPhasesToPetAnimationStates() {
        let finishedAt = Date()

        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .loading,
                sleeping: false,
                hasAnyRunningActivity: false
            ),
            .running
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .running(tool: "codex"),
                sleeping: false,
                hasAnyRunningActivity: false
            ),
            .running
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .waitingInput(tool: "codex"),
                sleeping: false,
                hasAnyRunningActivity: false
            ),
            .review
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .completed(tool: "codex", finishedAt: finishedAt, exitCode: 0),
                sleeping: false,
                hasAnyRunningActivity: false
            ),
            .waving
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .completed(tool: "codex", finishedAt: finishedAt, exitCode: nil),
                sleeping: false,
                hasAnyRunningActivity: false
            ),
            .waving
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .completed(tool: "codex", finishedAt: finishedAt, exitCode: 1),
                sleeping: false,
                hasAnyRunningActivity: false
            ),
            .failed
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .idle,
                sleeping: false,
                hasAnyRunningActivity: true
            ),
            .running
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .idle,
                sleeping: false,
                hasAnyRunningActivity: false
            ),
            .idle
        )
    }

    func testActiveProjectPhaseOverridesSleepingHint() {
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .running(tool: "codex"),
                sleeping: true,
                hasAnyRunningActivity: true
            ),
            .running
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .waitingInput(tool: "codex"),
                sleeping: true,
                hasAnyRunningActivity: true
            ),
            .review
        )
        XCTAssertEqual(
            CodexPetActivityAnimationMapper.animationState(
                for: .idle,
                sleeping: true,
                hasAnyRunningActivity: false
            ),
            .waiting
        )
    }
}

final class CodexPetPackageServiceTests: XCTestCase {
    func testLoadsValidPackageOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-pet-package-\(UUID().uuidString)", isDirectory: true)
        let valid = root.appendingPathComponent("demo", isDirectory: true)
        let invalid = root.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{}".utf8).write(to: valid.appendingPathComponent("spritesheet.webp"))
        try Data(
            #"{"id":"demo","displayName":"Demo","description":"One line.","spritesheetPath":"spritesheet.webp"}"#.utf8
        ).write(to: valid.appendingPathComponent("pet.json"))
        try Data(
            #"{"id":"broken","displayName":"Broken","description":"Missing image.","spritesheetPath":"spritesheet.webp"}"#.utf8
        ).write(to: invalid.appendingPathComponent("pet.json"))

        let packages = CodexPetPackageService().packages(rootURL: root)

        XCTAssertEqual(packages.map(\.manifest.id), ["demo"])
        XCTAssertEqual(packages.first?.spritesheetURL.lastPathComponent, "spritesheet.webp")
    }

    func testCustomPetsScanInstalledPackages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-custom-pet-\(UUID().uuidString)", isDirectory: true)
        let valid = root.appendingPathComponent("boba", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{}".utf8).write(to: valid.appendingPathComponent("spritesheet.webp"))
        try Data(
            #"{"id":"boba","displayName":"Boba","description":"Bubble tea companion.","spritesheetPath":"spritesheet.webp"}"#.utf8
        ).write(to: valid.appendingPathComponent("pet.json"))

        let pets = CodexPetPackageService().customPets(rootURL: root)

        XCTAssertEqual(pets.count, 1)
        XCTAssertEqual(pets[0].id, "boba")
        XCTAssertEqual(pets[0].directoryName, "boba")
        XCTAssertEqual(pets[0].spritesheetURL(rootURL: root), valid.appendingPathComponent("spritesheet.webp"))
    }

    func testPetdexHTMLParsesPreviewMetadataAndPackageURL() throws {
        let html = #"""
        <html>
          <head>
            <meta property="og:title" content="Boba — Animated Codex pet"/>
            <meta name="description" content="A tiny otter sipping bubble tea."/>
            <meta property="og:image" content="https://petdex.crafter.run/pets/boba/opengraph-image"/>
            <script type="application/ld+json">
            [{"@type":"CreativeWork","name":"Boba","image":"https://cdn.example.test/boba.webp"}]
            </script>
          </head>
          <body>
            <script>self.__data={"zipUrl":"https://pub.example.test/curated/boba/boba.zip"}</script>
          </body>
        </html>
        """#

        let request = try CodexPetPackageService.installRequest(
            fromHTML: html,
            pageURL: try XCTUnwrap(URL(string: "https://petdex.crafter.run/zh/pets/boba"))
        )

        XCTAssertEqual(request.slug, "boba")
        XCTAssertEqual(request.displayName, "Boba")
        XCTAssertEqual(request.resolvedDisplayName, "Boba")
        XCTAssertEqual(request.description, "A tiny otter sipping bubble tea.")
        XCTAssertEqual(request.imageURL?.absoluteString, "https://petdex.crafter.run/pets/boba/opengraph-image")
        XCTAssertEqual(request.zipURL.absoluteString, "https://pub.example.test/curated/boba/boba.zip")
        XCTAssertEqual(request.withDisplayName("奶茶").resolvedDisplayName, "奶茶")
    }

    func testNormalizesPackageIDForInstallDestination() {
        XCTAssertEqual(CodexPetPackageService.normalizedPackageID(" Boba Pet! "), "boba-pet")
        XCTAssertEqual(CodexPetPackageService.normalizedPackageID("../bad"), "bad")
        XCTAssertEqual(CodexPetPackageService.normalizedPackageID("___"), "")
    }
}
