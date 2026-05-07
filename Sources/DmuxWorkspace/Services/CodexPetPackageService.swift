import Foundation

struct CodexPetPackage: Equatable, Sendable {
    var directoryURL: URL
    var manifest: CodexPetManifest

    var spritesheetURL: URL {
        directoryURL.appendingPathComponent(manifest.spritesheetPath, isDirectory: false)
    }
}

struct CodexPetInstallRequest: Sendable {
    var pageURL: URL
    var zipURL: URL
    var slug: String
    var displayName: String?
    var description: String?
    var imageURL: URL?
    var customizedDisplayName: String?

    var resolvedDisplayName: String {
        let customName = customizedDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !customName.isEmpty {
            return customName
        }
        let pageName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return pageName.isEmpty ? slug : pageName
    }

    func withDisplayName(_ displayName: String) -> CodexPetInstallRequest {
        var copy = self
        copy.customizedDisplayName = displayName
        return copy
    }
}

struct CodexPetInstallResult: Equatable, Sendable {
    var pet: PetCustomPet
    var package: CodexPetPackage
}

struct CodexPetPackageService {
    var fileManager: FileManager = .default

    func packages(rootURL: URL = Self.defaultPetsRootURL()) -> [CodexPetPackage] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.compactMap(package(at:)).sorted {
            $0.manifest.displayName.localizedStandardCompare($1.manifest.displayName) == .orderedAscending
        }
    }

    func package(at directoryURL: URL) -> CodexPetPackage? {
        let manifestURL = directoryURL.appendingPathComponent("pet.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CodexPetManifest.self, from: data),
              manifest.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              manifest.spritesheetPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let package = CodexPetPackage(directoryURL: directoryURL, manifest: manifest)
        guard fileManager.fileExists(atPath: package.spritesheetURL.path) else {
            return nil
        }
        return package
    }

    func customPets(rootURL: URL = Self.defaultCustomPetsRootURL()) -> [PetCustomPet] {
        packages(rootURL: rootURL).map { package in
            PetCustomPet(
                id: package.manifest.id,
                displayName: package.manifest.displayName,
                description: package.manifest.description,
                spritesheetPath: package.manifest.spritesheetPath,
                directoryName: package.directoryURL.lastPathComponent,
                sourcePageURL: nil,
                sourceZipURL: nil,
                installedAt: nil
            )
        }
    }

    func resolveInstallRequest(from rawPageURL: String) async throws -> CodexPetInstallRequest {
        let trimmed = rawPageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageURL = URL(string: trimmed),
              let scheme = pageURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              Self.isAllowedPetdexHost(pageURL.host) else {
            throw AIProviderError.requestFailure(
                String(localized: "pet.custom.install.invalid_url", defaultValue: "Please enter a Petdex pet page URL.", bundle: .module)
            )
        }

        let (data, response) = try await URLSession.shared.data(from: pageURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AIProviderError.requestFailure(
                String(localized: "pet.custom.install.fetch_failed", defaultValue: "Failed to load the Petdex page.", bundle: .module)
            )
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw AIProviderError.requestFailure(
                String(localized: "pet.custom.install.decode_failed", defaultValue: "Unable to read the Petdex page.", bundle: .module)
            )
        }

        return try Self.installRequest(fromHTML: html, pageURL: pageURL)
    }

    func install(from request: CodexPetInstallRequest, rootURL: URL = Self.defaultCustomPetsRootURL()) async throws -> CodexPetInstallResult {
        let packageID = Self.normalizedPackageID(request.slug)
        guard !packageID.isEmpty else {
            throw AIProviderError.requestFailure(
                String(localized: "pet.custom.install.invalid_package", defaultValue: "The Petdex package name is invalid.", bundle: .module)
            )
        }

        let downloadURL = fileManager.temporaryDirectory
            .appendingPathComponent("codux-pet-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("\(packageID).zip", isDirectory: false)
        let stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("codux-pet-staging-\(UUID().uuidString)", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent(packageID, isDirectory: true)

        try fileManager.createDirectory(at: downloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: downloadURL.deletingLastPathComponent())
            try? fileManager.removeItem(at: stagingURL)
        }

        try await Self.download(from: request.zipURL, to: downloadURL)
        try Self.unzip(archiveURL: downloadURL, destinationURL: stagingURL)

        let packageSourceURL = try Self.resolvedPackageDirectory(in: stagingURL, fileManager: fileManager)
        guard let sourcePackage = package(at: packageSourceURL) else {
            throw AIProviderError.requestFailure(
                String(localized: "pet.custom.install.invalid_archive", defaultValue: "The downloaded package does not contain a valid pet.json and spritesheet.", bundle: .module)
            )
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: packageSourceURL, to: destinationURL)

        guard let installedPackage = package(at: destinationURL) else {
            throw AIProviderError.requestFailure(
                String(localized: "pet.custom.install.verify_failed", defaultValue: "Installed pet package could not be verified.", bundle: .module)
            )
        }

        let pet = PetCustomPet(
            id: installedPackage.manifest.id,
            displayName: request.resolvedDisplayName.isEmpty
                ? (installedPackage.manifest.displayName.isEmpty ? sourcePackage.manifest.displayName : installedPackage.manifest.displayName)
                : request.resolvedDisplayName,
            description: installedPackage.manifest.description.isEmpty
                ? (request.description ?? sourcePackage.manifest.description)
                : installedPackage.manifest.description,
            spritesheetPath: installedPackage.manifest.spritesheetPath,
            directoryName: destinationURL.lastPathComponent,
            sourcePageURL: request.pageURL,
            sourceZipURL: request.zipURL,
            installedAt: Date()
        )
        return CodexPetInstallResult(pet: pet, package: installedPackage)
    }

    static func defaultPetsRootURL(homeURL: URL? = nil) -> URL {
        if homeURL == nil,
           let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           codexHome.isEmpty == false {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("pets", isDirectory: true)
        }
        return (homeURL ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }

    static func defaultCustomPetsRootURL(
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> URL {
        if let appSupportURL = AppRuntimePaths.appSupportRootURL(fileManager: fileManager, bundle: bundle) {
            return appSupportURL.appendingPathComponent("custom-pets", isDirectory: true)
        }
        return defaultPetsRootURL()
    }

    static func normalizedPackageID(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        return String(scalars)
            .lowercased()
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }

    static func installRequest(fromHTML html: String, pageURL: URL) throws -> CodexPetInstallRequest {
        let slug = Self.slug(from: pageURL)
        guard let zipURL = Self.extractZipURL(from: html) else {
            throw AIProviderError.requestFailure(
                String(localized: "pet.custom.install.zip_missing", defaultValue: "Unable to find a Petdex package on this page.", bundle: .module)
            )
        }

        return CodexPetInstallRequest(
            pageURL: pageURL,
            zipURL: zipURL,
            slug: slug,
            displayName: Self.extractHTMLMetaContent(named: "og:title", from: html)?
                .components(separatedBy: " — ")
                .first ?? Self.extractJSONLDString(field: "name", from: html),
            description: Self.extractHTMLMetaContent(named: "description", from: html)
                ?? Self.extractJSONLDString(field: "description", from: html),
            imageURL: Self.extractHTMLMetaURL(named: "og:image", from: html)
                ?? Self.extractJSONLDURL(field: "image", from: html)
        )
    }

    private static func slug(from url: URL) -> String {
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if let petsIndex = pathComponents.lastIndex(of: "pets"),
           petsIndex + 1 < pathComponents.count {
            return pathComponents[petsIndex + 1]
        }
        return url.lastPathComponent
    }

    private static func isAllowedPetdexHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else {
            return false
        }
        return host == "petdex.crafter.run" || host.hasSuffix(".petdex.crafter.run")
    }

    private static func extractZipURL(from html: String) -> URL? {
        let patterns = [
            #"zipUrl\\":\\"([^"\\]+\.zip)"#,
            #""zipUrl"\s*:\s*"([^"]+\.zip)""#,
            #"https://[^"\\\s]+\.zip"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range) else {
                continue
            }
            let captureIndex = match.numberOfRanges > 1 ? 1 : 0
            guard let matchRange = Range(match.range(at: captureIndex), in: html) else {
                continue
            }
            let value = String(html[matchRange])
                .replacingOccurrences(of: #"\/"#, with: "/")
                .replacingOccurrences(of: #"\""#, with: "")
            if let url = URL(string: value) {
                return url
            }
        }
        return nil
    }

    private static func extractHTMLMetaContent(named name: String, from html: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            #"<meta[^>]+(?:name|property)="\#(escapedName)"[^>]+content="([^"]*)""#,
            #"<meta[^>]+content="([^"]*)"[^>]+(?:name|property)="\#(escapedName)""#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            guard let match = regex.firstMatch(in: html, range: range),
                  let capture = Range(match.range(at: 1), in: html) else {
                continue
            }
            return String(html[capture])
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func extractHTMLMetaURL(named name: String, from html: String) -> URL? {
        guard let value = extractHTMLMetaContent(named: name, from: html) else {
            return nil
        }
        return URL(string: value)
    }

    private static func extractJSONLDString(field: String, from html: String) -> String? {
        for object in jsonLDObjects(from: html) {
            if let value = object[field] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func extractJSONLDURL(field: String, from html: String) -> URL? {
        guard let value = extractJSONLDString(field: field, from: html) else {
            return nil
        }
        return URL(string: value)
    }

    private static func jsonLDObjects(from html: String) -> [[String: Any]] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script[^>]+type=["']application/ld\+json["'][^>]*>(.*?)</script>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).flatMap { match -> [[String: Any]] in
            guard let captureRange = Range(match.range(at: 1), in: html),
                  let data = String(html[captureRange]).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                return []
            }

            if let object = json as? [String: Any] {
                return [object]
            }
            if let array = json as? [[String: Any]] {
                return array
            }
            return []
        }
    }

    private static func download(from url: URL, to destinationURL: URL) async throws {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AIProviderError.requestFailure(
                String(localized: "pet.custom.install.download_failed", defaultValue: "Failed to download the pet package.", bundle: .module)
            )
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    private static func unzip(archiveURL: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]

        let outputPipe = Pipe()
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIProviderError.requestFailure(
                output?.isEmpty == false
                    ? output!
                    : String(localized: "pet.custom.install.unzip_failed", defaultValue: "Failed to unpack the pet package.", bundle: .module)
            )
        }
    }

    private static func resolvedPackageDirectory(in stagingURL: URL, fileManager: FileManager) throws -> URL {
        let directManifestURL = stagingURL.appendingPathComponent("pet.json", isDirectory: false)
        if fileManager.fileExists(atPath: directManifestURL.path) {
            return stagingURL
        }

        let directories = (try? fileManager.contentsOfDirectory(
            at: stagingURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for directory in directories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                continue
            }
            let manifestURL = directory.appendingPathComponent("pet.json", isDirectory: false)
            if fileManager.fileExists(atPath: manifestURL.path) {
                return directory
            }
        }

        throw AIProviderError.requestFailure(
            String(localized: "pet.custom.install.invalid_archive", defaultValue: "The downloaded package does not contain a valid pet.json and spritesheet.", bundle: .module)
        )
    }
}
