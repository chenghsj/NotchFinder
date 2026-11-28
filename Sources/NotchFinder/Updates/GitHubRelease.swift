import CoreServices
import CryptoKit
import Foundation

struct AppVersion: Comparable {
    private let components: [Int]

    init?(_ version: String) {
        let number = version.first == "v" || version.first == "V" ? version.dropFirst() : version[...]
        let parts = number.split(separator: ".", omittingEmptySubsequences: false)
        let components = parts.compactMap { part -> Int? in
            guard part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(part)
        }
        guard (1...3).contains(parts.count), components.count == parts.count else { return nil }
        self.components = components + Array(repeating: 0, count: 3 - components.count)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

struct GitHubRelease: Decodable {
    static let repositoryURL = URL(string: "https://github.com/chenghsj/NotchFinder")!
    private static let apiURL = URL(string: "https://api.github.com/repos/chenghsj/NotchFinder/releases")!
    private static let releasesURL = repositoryURL.appending(component: "releases")

    static func isReleaseDMG(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil
            && url.user == nil && url.password == nil
            && url.pathComponents.dropLast(2) == ["/", "chenghsj", "NotchFinder", "releases", "download"]
            && url.pathExtension == "dmg"
    }

    struct Asset: Decodable {
        let name: String
        let size: Int
        let digest: String?
        let state: String

        func validate(file: URL) throws {
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == size else {
                throw URLError(.cannotDecodeContentData)
            }
            guard let digest else { return }
            guard digest.hasPrefix("sha256:") else { throw URLError(.cannotDecodeContentData) }

            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == "sha256:\(actual)" else { throw URLError(.cannotDecodeContentData) }
        }
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var page: URL { Self.releasesURL.appending(component: "tag").appending(component: tagName) }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
    }

    func isNewer(than installed: AppVersion) -> Bool {
        guard !draft, let version = AppVersion(tagName) else { return false }
        return version > installed
    }

    func diskImage(for architecture: String) -> Asset? {
        let version = tagName.first == "v" || tagName.first == "V" ? String(tagName.dropFirst()) : tagName
        let images = assets.filter { $0.state == "uploaded" && $0.size > 0 }
        return images.first { $0.name == "NotchFinder-\(version)-\(architecture).dmg" }
            ?? images.first { $0.name == "NotchFinder-\(version)-universal.dmg" }
    }

    static func latest() async throws -> Self? {
        if let data = try await fetch(apiURL.appending(component: "latest")) {
            let release = try JSONDecoder().decode(Self.self, from: data)
            return release.draft || release.prerelease ? nil : release
        }

        // Until the first stable release, GitHub returns 404 for /latest.
        let listing = apiURL.appending(queryItems: [URLQueryItem(name: "per_page", value: "100")])
        guard let data = try await fetch(listing) else { return nil }
        return latestPreview(in: try JSONDecoder().decode([Self].self, from: data))
    }

    static func latestPreview(in releases: [Self]) -> Self? {
        releases.compactMap { release -> (release: Self, version: AppVersion)? in
            guard !release.draft, release.prerelease, let version = AppVersion(release.tagName) else { return nil }
            return (release, version)
        }.max { $0.version < $1.version }?.release
    }

    private static func fetch(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https" else {
            throw URLError(.badServerResponse)
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    func downloadDiskImage() async throws -> URL? {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        guard let asset = diskImage(for: architecture) else { return nil }

        let source = Self.releasesURL.appending(component: "download")
            .appending(component: tagName).appending(component: asset.name)
        let signatureURL = source.deletingLastPathComponent().appending(component: asset.name + ".sig")
        let (signatureData, signatureResponse) = try await URLSession.shared.data(from: signatureURL)
        guard let signatureResponse = signatureResponse as? HTTPURLResponse,
              signatureResponse.statusCode == 200, signatureResponse.url?.scheme == "https",
              let signature = String(data: signatureData, encoding: .utf8),
              let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            throw URLError(.cannotDecodeContentData)
        }
        let (temporaryFile, response) = try await URLSession.shared.download(from: source)
        defer { try? FileManager.default.removeItem(at: temporaryFile) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else { throw URLError(.badServerResponse) }
        try Self.verifyDiskImage(temporaryFile, signature: signature, publicKey: publicKey)

        let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        return try saveDiskImage(asset, from: temporaryFile, to: downloads, source: source)
    }

    static func verifyDiskImage(_ file: URL, signature: String, publicKey: String) throws {
        guard let keyData = Data(base64Encoded: publicKey),
              let signatureData = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signatureData, for: try Data(contentsOf: file, options: .mappedIfSafe)) else {
            throw URLError(.cannotDecodeContentData)
        }
    }

    func saveDiskImage(_ asset: Asset, from temporaryFile: URL, to directory: URL, source: URL) throws -> URL {
        try asset.validate(file: temporaryFile)
        var metadata = URLResourceValues()
        metadata.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
            kLSQuarantineAgentNameKey as String: "Notch Finder",
            kLSQuarantineOriginURLKey as String: page,
            kLSQuarantineDataURLKey as String: source
        ]
        var stagedFile = temporaryFile
        try stagedFile.setResourceValues(metadata)

        let manager = FileManager.default
        let basename = (asset.name as NSString).deletingPathExtension
        var destination = directory.appending(component: asset.name)
        var number = 2
        while true {
            try Task.checkCancellation()
            do {
                try manager.moveItem(at: stagedFile, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                destination = directory.appending(component: "\(basename) \(number).dmg")
                number += 1
            }
        }
    }
}
