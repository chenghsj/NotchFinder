import CoreServices
import CryptoKit
import Foundation
import Testing
@testable import NotchFinder

struct GitHubReleaseTests {
    @Test func laterRemembersOnlyTheSelectedBuildUntilItsDeadline() throws {
        let domain = "NotchFinderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let schedule = UpdateSchedule(defaults: defaults)
        defaults.set("v0.1.2", forKey: "lastNotifiedUpdateTag")
        #expect(!schedule.isDeferred("3", now: now))
        schedule.remindLater(about: "3", now: now)

        let reloaded = UpdateSchedule(defaults: try #require(UserDefaults(suiteName: domain)))
        #expect(!reloaded.isDeferred("4", now: now))
        #expect(reloaded.isDeferred("3", now: now.addingTimeInterval(day - 1)))
        #expect(reloaded.nextCheckDelay(after: nil, now: now.addingTimeInterval(day - 1)) == 1)
        #expect(!reloaded.isDeferred("3", now: now.addingTimeInterval(day)))
        #expect(reloaded.nextCheckDelay(after: nil, now: now.addingTimeInterval(day)) == day)
    }

    @Test func transientNetworkFailuresRetryThenReturnToDailyChecks() throws {
        let domain = "NotchFinderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let schedule = UpdateSchedule(defaults: defaults)
        let day: TimeInterval = 24 * 60 * 60
        let offline = NSError(domain: "SUSparkleErrorDomain", code: 2001,
                              userInfo: [NSUnderlyingErrorKey: URLError(.notConnectedToInternet)])
        #expect(schedule.nextCheckDelay(after: offline) == 15 * 60)
        #expect(schedule.nextCheckDelay(after: URLError(.timedOut)) == 15 * 60)
        #expect(schedule.nextCheckDelay(after: nil) == day)
        #expect(schedule.nextCheckDelay(after: URLError(.cancelled)) == day)
        #expect(schedule.nextCheckDelay(after: URLError(.serverCertificateUntrusted)) == day)
        #expect(schedule.nextCheckDelay(after: NSError(domain: "SUSparkleErrorDomain", code: 3001)) == day)
    }

    @Test @MainActor func updatePreferencesPersistAndAutomaticUpdatesAreOptIn() throws {
        let domain = "NotchFinderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = NotchSettings(defaults: defaults)

        #expect(settings.checksForUpdates)
        #expect(!settings.automaticallyUpdates)
        settings.checksForUpdates = false
        settings.automaticallyUpdates = true

        let reloaded = NotchSettings(defaults: defaults)
        #expect(!reloaded.checksForUpdates)
        #expect(reloaded.automaticallyUpdates)
        #expect(!reloaded.installsUpdatesOnQuit)
        reloaded.checksForUpdates = true
        #expect(reloaded.installsUpdatesOnQuit)
        reloaded.automaticallyUpdates = false
        #expect(!reloaded.installsUpdatesOnQuit)
    }

    @Test(arguments: [false, true], [false, true])
    @MainActor func automaticUpdatesMigrateLegacyPreferences(downloads: Bool, installs: Bool) throws {
        let domain = "NotchFinderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(downloads, forKey: "automaticallyDownloadsUpdates")
        defaults.set(installs, forKey: "automaticallyInstallsUpdates")

        let settings = NotchSettings(defaults: defaults)
        #expect(settings.automaticallyUpdates == (downloads && installs))
        settings.automaticallyUpdates = true
        settings.automaticallyUpdates = false
        #expect(!NotchSettings(defaults: defaults).automaticallyUpdates)
    }

    @Test @MainActor func automaticUpdateCancelsDownloadAndRetriesAfterReenable() {
        var cancelled = 0
        var checks = 0
        let lifecycle = AutomaticUpdateLifecycle { _ in }
        lifecycle.setEnabled(true)
        lifecycle.check { checks += 1 }
        lifecycle.didStartDownload { cancelled += 1 }
        lifecycle.setEnabled(false)
        lifecycle.setEnabled(false)
        #expect(cancelled == 1)
        #expect(!lifecycle.acceptsUpdate)

        lifecycle.setEnabled(true)
        lifecycle.check { checks += 1 }
        #expect(checks == 1)
        lifecycle.didFinish()
        #expect(checks == 2)
        #expect(lifecycle.acceptsUpdate)
    }

    @Test @MainActor func automaticUpdateWaitsForExtractionCancellationBeforeQuitting() {
        var skipped = 0
        var quitReplies = 0
        var repeatedCheck = false
        let lifecycle = AutomaticUpdateLifecycle { _ in }
        lifecycle.setEnabled(true)
        lifecycle.didStartExtraction()
        lifecycle.setEnabled(false)
        lifecycle.setEnabled(true)
        lifecycle.check { repeatedCheck = true }
        #expect(lifecycle.deferQuitForCancellation { quitReplies += 1 })
        lifecycle.readyToInstall(install: { Issue.record("Cancelled update was installed") }, skip: { skipped += 1 })
        #expect(skipped == 1)
        #expect(quitReplies == 0)
        lifecycle.didFinish()
        lifecycle.didFinish()
        #expect(quitReplies == 1)
        #expect(!repeatedCheck)
    }

    @Test @MainActor func optingOutSkipsAnAlreadyPreparedUpdate() {
        var ready = false
        var skipped = 0
        let lifecycle = AutomaticUpdateLifecycle { ready = $0 }
        lifecycle.setEnabled(true)
        lifecycle.readyToInstall(install: { Issue.record("Opted-out update was installed") }, skip: { skipped += 1 })
        #expect(ready)
        #expect(!lifecycle.deferQuitForCancellation {})
        lifecycle.setEnabled(false)
        #expect(!ready)
        #expect(skipped == 1)
    }

    @Test @MainActor func manuallyInstallingPreparedUpdateRepliesOnlyOnce() {
        var ready = false
        var installed = 0
        let lifecycle = AutomaticUpdateLifecycle { ready = $0 }
        lifecycle.setEnabled(true)
        lifecycle.readyToInstall(install: { installed += 1 }, skip: { Issue.record("Confirmed update was skipped") })
        lifecycle.installNow()
        lifecycle.installNow()
        lifecycle.setEnabled(false)
        #expect(installed == 1)
        #expect(!ready)
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
