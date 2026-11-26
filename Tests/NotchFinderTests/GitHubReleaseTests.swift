import CoreServices
import CryptoKit
import Foundation
import Testing
@testable import NotchFinder

struct GitHubReleaseTests {
    @Test @MainActor func updatePreferencesPersistAndDownloadsAreOptIn() throws {
        let domain = "NotchFinderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = NotchSettings(defaults: defaults)

        #expect(settings.checksForUpdates)
        #expect(!settings.automaticallyDownloadsUpdates)
        #expect(!settings.automaticallyInstallsUpdates)
        settings.checksForUpdates = false
        settings.automaticallyDownloadsUpdates = true
        settings.automaticallyInstallsUpdates = true

        let reloaded = NotchSettings(defaults: defaults)
        #expect(!reloaded.checksForUpdates)
        #expect(reloaded.automaticallyDownloadsUpdates)
        #expect(reloaded.automaticallyInstallsUpdates)
        #expect(!reloaded.installsUpdatesOnQuit)
        reloaded.checksForUpdates = true
        #expect(reloaded.installsUpdatesOnQuit)
        reloaded.automaticallyDownloadsUpdates = false
        #expect(!reloaded.installsUpdatesOnQuit)
    }

    @Test func updateDMGMustMatchTheEmbeddedEdDSAKey() throws {
        let archive = FileManager.default.temporaryDirectory.appending(component: "\(UUID()).dmg")
        defer { try? FileManager.default.removeItem(at: archive) }
        let key = Curve25519.Signing.PrivateKey()
        let original = Data("update archive".utf8)
        let signature = try key.signature(for: original).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        try original.write(to: archive)
        try GitHubRelease.verifyDiskImage(archive, signature: signature, publicKey: publicKey)

        let otherPublicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(throws: URLError.self) {
            try GitHubRelease.verifyDiskImage(archive, signature: signature, publicKey: otherPublicKey)
        }
        try Data("tampered".utf8).write(to: archive)
        #expect(throws: URLError.self) {
            try GitHubRelease.verifyDiskImage(archive, signature: signature, publicKey: publicKey)
        }
    }

    @Test func updaterAcceptsOnlyTheProjectsGitHubReleaseDMGs() throws {
        for url in [
            "http://github.com/chenghsj/NotchFinder/releases/download/v0.1.1/update.dmg",
            "https://github.com/chenghsj/OtherProject/releases/download/v0.1.1/update.dmg",
            "https://github.com/chenghsj/NotchFinder/releases/download/v0.1.1/update.pkg",
            "https://other.example/chenghsj/NotchFinder/releases/download/v0.1.1/update.dmg"
        ] {
            #expect(!GitHubRelease.isReleaseDMG(try #require(URL(string: url))))
        }
        let official = try #require(URL(string: "https://github.com/chenghsj/NotchFinder/releases/download/v0.1.1/update.dmg"))
        #expect(GitHubRelease.isReleaseDMG(official))
    }

    @Test func versionsCompareNumericallyAndMalformedTagsAreRejected() throws {
        let installed = try #require(AppVersion("1.9.2"))
        #expect(release("v1.10.0").isNewer(than: installed))
        #expect(!release("v1.9.2").isNewer(than: installed))
        #expect(!release("v1.9.1").isNewer(than: installed))
        #expect(!release("v2.0.0", draft: true).isNewer(than: installed))
        #expect(!release("v2..1").isNewer(than: installed))
        #expect(AppVersion("v1.9") == AppVersion("1.9.0"))
    }

    @Test func previewFallbackSelectsTheHighestPublishedNumericVersion() {
        let releases = [
            release("v0.9.0", prerelease: true),
            release("v0.10.0", prerelease: true),
            release("v0.11.0", draft: true, prerelease: true),
            release("v1.0.0", prerelease: true),
            release("v2.0.0-rc.1", prerelease: true)
        ]
        #expect(GitHubRelease.latestPreview(in: releases)?.tagName == "v1.0.0")
    }

    @Test func downloadUsesAnUploadedDiskImageForTheCurrentArchitecture() throws {
        let json = """
        {
          "tag_name": "v1.2.3", "draft": false, "prerelease": false,
          "assets": [
            { "name": "NotchFinder-1.2.3-x86_64.dmg", "size": 10, "state": "new" },
            { "name": "NotchFinder-1.2.3-universal.dmg", "size": 10, "state": "uploaded" },
            { "name": "NotchFinder-1.2.3-arm64.dmg", "size": 10, "state": "uploaded" }
          ]
        }
        """
        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))

        #expect(release.diskImage(for: "arm64")?.name == "NotchFinder-1.2.3-arm64.dmg")
        #expect(release.diskImage(for: "x86_64")?.name == "NotchFinder-1.2.3-universal.dmg")
        #expect(self.release("v1.2.3").diskImage(for: "arm64") == nil)
        #expect(release.page.absoluteString == "https://github.com/chenghsj/NotchFinder/releases/tag/v1.2.3")
    }

    @Test func downloadedFileIsValidatedQuarantinedAndDoesNotReplaceExistingFiles() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appending(component: "NotchFinderTests-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: directory) }
        let release = release("v1.2.3")
        let asset = GitHubRelease.Asset(
            name: "NotchFinder-1.2.3-arm64.dmg", size: 3,
            digest: "sha256:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            state: "uploaded"
        )
        let original = directory.appending(component: asset.name)
        let temporary = directory.appending(component: "download")
        let existingData = Data("existing file".utf8)
        try existingData.write(to: original)
        try Data("xyz".utf8).write(to: temporary)
        #expect(throws: URLError.self) {
            try release.saveDiskImage(asset, from: temporary, to: directory, source: release.page)
        }

        let downloadedData = Data("abc".utf8)
        try downloadedData.write(to: temporary)
        let saved = try release.saveDiskImage(asset, from: temporary, to: directory, source: release.page)
        #expect(saved.lastPathComponent == "NotchFinder-1.2.3-arm64 2.dmg")
        #expect(try Data(contentsOf: original) == existingData)
        #expect(try Data(contentsOf: saved) == downloadedData)
        let quarantine = try saved.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Notch Finder")
    }

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(tagName: tag, draft: draft, prerelease: prerelease, assets: [])
    }
}
