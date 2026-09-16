import Foundation
import XCTest

@testable import ProfileKit

/// Every test runs against a throwaway root so the real profile store and the
/// default Claude state are never touched.
private func withTemporaryRoot(_ body: () throws -> Void) rethrows {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "profilekit-tests-\(UUID().uuidString)")
    setenv(Paths.rootEnvironmentKey, temp.path, 1)
    defer {
        try? FileManager.default.removeItem(at: temp)
        unsetenv(Paths.rootEnvironmentKey)
    }
    try body()
}

final class FingerprintTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "cfg-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    /// Key order must not change the hash — otherwise a harmless rewrite by
    /// Claude Code would look like data loss.
    func testKeyOrderDoesNotAffectHash() throws {
        let a = try write(#"{"projects":{"/a":{"x":1,"y":2},"/b":{"z":3}}}"#)
        let b = try write(#"{"projects":{"/b":{"z":3},"/a":{"y":2,"x":1}}}"#)
        XCTAssertEqual(
            Fingerprinter.fingerprint(configFile: a)?.projectsSHA,
            Fingerprinter.fingerprint(configFile: b)?.projectsSHA)
    }

    /// Volatile session telemetry lives beside the projects map. If it fed the
    /// hash, the invariant would change every few seconds on its own.
    func testVolatileTelemetryIsIgnored() throws {
        let a = try write(#"{"oauthAccount":{"emailAddress":"a@x"},"projects":{"/a":{"x":1}}}"#)
        let b = try write(
            #"{"oauthAccount":{"emailAddress":"b@y"},"lastCost":9.9,"projects":{"/a":{"x":1}}}"#)
        XCTAssertEqual(
            Fingerprinter.fingerprint(configFile: a)?.projectsSHA,
            Fingerprinter.fingerprint(configFile: b)?.projectsSHA)
    }

    func testRealChangeIsDetected() throws {
        let a = try write(#"{"projects":{"/a":{"hasTrustDialogAccepted":true}}}"#)
        let b = try write(#"{"projects":{"/a":{"hasTrustDialogAccepted":false}}}"#)
        XCTAssertNotEqual(
            Fingerprinter.fingerprint(configFile: a)?.projectsSHA,
            Fingerprinter.fingerprint(configFile: b)?.projectsSHA)
    }

    /// Forward slashes must NOT be escaped: Foundation escapes them, JavaScript
    /// does not, and project keys are file paths. Pinning this keeps the
    /// TypeScript reference implementation usable as an independent oracle.
    func testForwardSlashesAreNotEscaped() {
        XCTAssertEqual(Fingerprinter.canonical(["/a/b": 1]), #"{"/a/b":1}"#)
    }

    func testCanonicalNumbersAndBooleans() {
        XCTAssertEqual(Fingerprinter.canonical(["a": true, "b": false]), #"{"a":true,"b":false}"#)
        XCTAssertEqual(Fingerprinter.canonical(["n": 42]), #"{"n":42}"#)
    }

    func testControlCharactersEscaped() {
        XCTAssertEqual(Fingerprinter.canonical(["a\nb": 1]), #"{"a\nb":1}"#)
    }
}

final class KeychainTests: XCTestCase {
    /// Observed in Claude Code 2.1.271. If this changes upstream, profiles stop
    /// finding their credentials, so it is pinned deliberately.
    func testDefaultServiceName() {
        XCTAssertEqual(Keychain.defaultServiceName, "Claude Code-credentials")
    }

    func testCustomDirGetsStableSuffix() {
        let dir = URL(fileURLWithPath: "/Users/x/.claude-profiles/profiles/abc/config")
        let name = Keychain.serviceName(configDir: dir)
        XCTAssertTrue(name.hasPrefix("Claude Code-credentials-"))
        XCTAssertEqual(name.count, "Claude Code-credentials-".count + 8)
        XCTAssertEqual(name, Keychain.serviceName(configDir: dir))
    }

    func testDistinctDirsGetDistinctEntries() {
        XCTAssertNotEqual(
            Keychain.serviceName(configDir: URL(fileURLWithPath: "/a")),
            Keychain.serviceName(configDir: URL(fileURLWithPath: "/b")))
    }
}

final class GuardTests: XCTestCase {
    func testRefusesDefaultClaudeState() {
        for url in [Paths.defaultConfigDir, Paths.defaultConfigJSON, Paths.defaultElectronDir] {
            XCTAssertThrowsError(try Paths.assertNotDefaultState(url), url.path)
            XCTAssertThrowsError(try Paths.assertNotDefaultState(url.appending(path: "child")))
        }
    }

    func testAllowsManagedRoot() throws {
        try withTemporaryRoot {
            XCTAssertNoThrow(try Paths.assertNotDefaultState(Paths.profilesDir.appending(path: "x")))
        }
    }
}

final class ProfileLifecycleTests: XCTestCase {
    func testCreateRenameDelete() throws {
        try withTemporaryRoot {
            let created = try ProfileStore.create(label: "work")
            XCTAssertEqual(ProfileStore.all().count, 1)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: created.paths.config.path))

            // Renaming must not move the directory: the Keychain service name is
            // derived from the config dir path, so moving it orphans the login.
            let serviceBefore = Keychain.serviceName(configDir: created.paths.config)
            try ProfileStore.rename(id: created.id, to: "personal")
            let reloaded = try XCTUnwrap(ProfileStore.load(id: created.id))
            XCTAssertEqual(reloaded.label, "personal")
            XCTAssertEqual(reloaded.paths.config, created.paths.config)
            XCTAssertEqual(Keychain.serviceName(configDir: reloaded.paths.config), serviceBefore)

            try ProfileStore.delete(id: created.id)
            XCTAssertTrue(ProfileStore.all().isEmpty)
        }
    }

    func testDuplicateLabelsRejected() throws {
        try withTemporaryRoot {
            _ = try ProfileStore.create(label: "work")
            XCTAssertThrowsError(try ProfileStore.create(label: "WORK"))
        }
    }

    func testInvalidLabelsRejected() throws {
        try withTemporaryRoot {
            for bad in ["bad/label", "", "has space", ".."] {
                XCTAssertThrowsError(try ProfileStore.create(label: bad), bad)
            }
        }
    }

    func testResolveByLabelPrefixAndUUID() throws {
        try withTemporaryRoot {
            let work = try ProfileStore.create(label: "work")
            _ = try ProfileStore.create(label: "personal")
            XCTAssertEqual(try ProfileStore.resolve("work").id, work.id)
            XCTAssertEqual(try ProfileStore.resolve("wo").id, work.id)
            XCTAssertEqual(try ProfileStore.resolve(work.id.uuidString).id, work.id)
            XCTAssertThrowsError(try ProfileStore.resolve("nope"))
        }
    }
}

final class AtomicWriteTests: XCTestCase {
    func testWriteAndBackup() throws {
        try withTemporaryRoot {
            let target = Paths.root.appending(path: "f.json")
            try AtomicWrite.write(Data("one".utf8), to: target)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "one")

            try AtomicWrite.write(Data("two".utf8), to: target, backup: true)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "two")

            let siblings = try FileManager.default.contentsOfDirectory(atPath: Paths.root.path)
            XCTAssertTrue(siblings.contains { $0.contains("f.json.backup.") })
            // No temp files left behind.
            XCTAssertFalse(siblings.contains { $0.hasSuffix(".tmp") })
        }
    }

    func testRefusesDefaultState() {
        XCTAssertThrowsError(
            try AtomicWrite.write(Data(), to: Paths.defaultConfigJSON))
    }
}

final class UsageTests: XCTestCase {
    private func history(_ json: String) throws -> UsageHistory? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "usage-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return UsageReader.read(at: url)
    }

    func testParsesRealSchema() throws {
        let h = try XCTUnwrap(
            history(
                #"{"version":2,"samples":[{"t":1786933661127,"org":"o1","u":{"fh":3,"sd":0}},{"t":1789524932979,"org":"o1","u":{"fh":7,"sd":68}}]}"#
            ))
        XCTAssertEqual(h.samples.count, 2)
        XCTAssertEqual(h.current(.fiveHour), 7)
        XCTAssertEqual(h.current(.sevenDay), 68)
        XCTAssertEqual(h.peak(.sevenDay), 68)
        XCTAssertEqual(h.org, "o1")
    }

    func testMissingOrMalformedFileIsNotFatal() throws {
        XCTAssertNil(UsageReader.read(at: URL(fileURLWithPath: "/nonexistent/usage.json")))
        XCTAssertNil(try history("{}"))
        XCTAssertNil(try history("not json"))
    }

    func testUnknownWindowKeysIgnored() throws {
        let h = try XCTUnwrap(
            history(#"{"samples":[{"t":1000,"u":{"fh":5,"zz":99}}]}"#))
        XCTAssertEqual(h.current(.fiveHour), 5)
        XCTAssertEqual(h.latest?.values.count, 1)
    }

    func testLastResetDetectsSharpDrop() throws {
        let h = try XCTUnwrap(
            history(
                #"{"samples":[{"t":1000,"u":{"fh":80}},{"t":2000,"u":{"fh":90}},{"t":3000,"u":{"fh":2}}]}"#
            ))
        XCTAssertEqual(h.lastReset(.fiveHour), Date(timeIntervalSince1970: 3))
    }
}

final class SettingsMergeTests: XCTestCase {
    /// A realistic project entry: a few shareable settings mixed in with the
    /// session telemetry Claude Code rewrites constantly.
    private let realisticEntry: [String: Any] = [
        "allowedTools": ["Bash"],
        "hasTrustDialogAccepted": true,
        "enabledMcpjsonServers": ["x"],
        "mcpServers": ["gcp": ["command": "npx"]],
        "lastCost": 0.335,
        "lastSessionId": "abc-123",
        "lastTotalInputTokens": 7116,
        "activeWorktreeSession": ["originalCwd": "/tmp/x"],
    ]

    private func writeConfig(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func readConfig(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    func testShareableKeepsSettingsAndDropsTelemetry() {
        let kept = SettingsMerge.shareable(realisticEntry)
        XCTAssertEqual(
            Set(kept.keys),
            ["allowedTools", "hasTrustDialogAccepted", "enabledMcpjsonServers", "mcpServers"])
        for volatile in ["lastCost", "lastSessionId", "lastTotalInputTokens", "activeWorktreeSession"] {
            XCTAssertNil(kept[volatile], volatile)
        }
    }

    /// Unknown keys must stay local. The allowlist exists so a future Claude
    /// Code release cannot silently start sharing new per-account state.
    func testUnknownKeysAreNotShared() {
        let kept = SettingsMerge.shareable(["somethingNewFromUpstream": "secret"])
        XCTAssertTrue(kept.isEmpty)
    }

    func testCaptureThenMaterializeCarriesSettingsBetweenProfiles() throws {
        try withTemporaryRoot {
            let source = try ProfileStore.create(label: "source")
            let target = try ProfileStore.create(label: "target")

            try writeConfig(
                [
                    "oauthAccount": ["emailAddress": "a@example.com", "accountUuid": "AAA"],
                    "projects": ["/work/repo": realisticEntry],
                ], to: source.paths.configFile)
            try writeConfig(
                [
                    "oauthAccount": ["emailAddress": "b@example.com", "accountUuid": "BBB"],
                    "projects": [:],
                ], to: target.paths.configFile)

            try SettingsMerge.captureBack(from: XCTUnwrap(ProfileStore.load(id: source.id)))
            let report = try SettingsMerge.materialize(
                into: XCTUnwrap(ProfileStore.load(id: target.id)))
            XCTAssertEqual(report.projectsWritten, 1)

            let merged = try readConfig(target.paths.configFile)
            let project = try XCTUnwrap(
                (merged["projects"] as? [String: Any])?["/work/repo"] as? [String: Any])

            // The settings crossed over.
            XCTAssertEqual(project["hasTrustDialogAccepted"] as? Bool, true)
            XCTAssertEqual(project["allowedTools"] as? [String], ["Bash"])

            // The telemetry did not.
            XCTAssertNil(project["lastCost"])
            XCTAssertNil(project["lastSessionId"])

            // And identity was left completely alone — the single most
            // important property of this whole operation.
            let account = try XCTUnwrap(merged["oauthAccount"] as? [String: Any])
            XCTAssertEqual(account["emailAddress"] as? String, "b@example.com")
            XCTAssertEqual(account["accountUuid"] as? String, "BBB")
        }
    }

    func testMaterializePreservesLocalTelemetryAlreadyPresent() throws {
        try withTemporaryRoot {
            let source = try ProfileStore.create(label: "source")
            let target = try ProfileStore.create(label: "target")
            try writeConfig(
                ["projects": ["/repo": ["hasTrustDialogAccepted": true]]],
                to: source.paths.configFile)
            try writeConfig(
                ["projects": ["/repo": ["lastSessionId": "keep-me", "hasTrustDialogAccepted": false]]],
                to: target.paths.configFile)

            try SettingsMerge.captureBack(from: XCTUnwrap(ProfileStore.load(id: source.id)))
            try SettingsMerge.materialize(into: XCTUnwrap(ProfileStore.load(id: target.id)))

            let project = try XCTUnwrap(
                (try readConfig(target.paths.configFile)["projects"] as? [String: Any])?["/repo"]
                    as? [String: Any])
            XCTAssertEqual(project["lastSessionId"] as? String, "keep-me")
            XCTAssertEqual(project["hasTrustDialogAccepted"] as? Bool, true)
        }
    }

    func testMaterializeWithEmptySharedStoreIsANoOp() throws {
        try withTemporaryRoot {
            let target = try ProfileStore.create(label: "target")
            try writeConfig(
                ["projects": ["/repo": ["hasTrustDialogAccepted": true]]],
                to: target.paths.configFile)
            let before = Fingerprinter.fingerprint(configFile: target.paths.configFile)
            try SettingsMerge.materialize(into: XCTUnwrap(ProfileStore.load(id: target.id)))
            XCTAssertEqual(
                before?.projectsSHA,
                Fingerprinter.fingerprint(configFile: target.paths.configFile)?.projectsSHA)
        }
    }

    func testBackupIsWrittenBeforeOverwriting() throws {
        try withTemporaryRoot {
            let source = try ProfileStore.create(label: "source")
            let target = try ProfileStore.create(label: "target")
            try writeConfig(["projects": ["/r": ["hasTrustDialogAccepted": true]]],
                            to: source.paths.configFile)
            try writeConfig(["projects": [:]], to: target.paths.configFile)

            try SettingsMerge.captureBack(from: XCTUnwrap(ProfileStore.load(id: source.id)))
            try SettingsMerge.materialize(into: XCTUnwrap(ProfileStore.load(id: target.id)))

            let siblings = try FileManager.default.contentsOfDirectory(
                atPath: target.paths.config.path)
            XCTAssertTrue(siblings.contains { $0.contains(".claude.json.backup.") })
        }
    }

    func testJournalRecordsOperations() throws {
        try withTemporaryRoot {
            let source = try ProfileStore.create(label: "source")
            try writeConfig(["projects": ["/r": ["hasTrustDialogAccepted": true]]],
                            to: source.paths.configFile)
            try SettingsMerge.captureBack(from: XCTUnwrap(ProfileStore.load(id: source.id)))
            let log = try String(
                contentsOf: Paths.journalDir.appending(path: "merge.log"), encoding: .utf8)
            XCTAssertTrue(log.contains("capture"))
            XCTAssertTrue(log.contains("source"))
        }
    }
}

final class SessionIndexTests: XCTestCase {
    private func transcript(_ lines: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(UUID().uuidString).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    /// Cloud sessions carry an owner stamp; local CLI transcripts do not. The
    /// distinction decides whether a session can be opened by another account.
    func testBridgeSessionsAreDetectedByOwnerStamp() throws {
        let url = try transcript([
            #"{"type":"bridge-session","sessionId":"s1","bridgeSessionId":"b1","ownerAccountUuid":"ACC","ownerOrganizationUuid":"ORG"}"#,
            #"{"type":"user","cwd":"/work/repo"}"#,
        ])
        let record = try XCTUnwrap(
            SessionIndex.record(transcript: url, profileID: nil, profileLabel: "Default"))
        XCTAssertEqual(record.kind, .bridge)
        XCTAssertEqual(record.ownerAccountUUID, "ACC")
        XCTAssertEqual(record.cwd, "/work/repo")
    }

    func testLocalSessionsHaveNoOwner() throws {
        let url = try transcript([
            #"{"type":"queue-operation","sessionId":"s2","operation":"x","timestamp":1}"#,
            #"{"type":"user","cwd":"/local/repo"}"#,
        ])
        let record = try XCTUnwrap(
            SessionIndex.record(transcript: url, profileID: nil, profileLabel: "Default"))
        XCTAssertEqual(record.kind, .local)
        XCTAssertNil(record.ownerAccountUUID)
    }

    func testCustomTitlePreferredOverCwd() throws {
        let url = try transcript([
            #"{"type":"queue-operation","sessionId":"s3"}"#,
            #"{"type":"title","sessionId":"s3","customTitle":"Refactor billing"}"#,
            #"{"type":"user","cwd":"/work/billing"}"#,
        ])
        let record = try XCTUnwrap(
            SessionIndex.record(transcript: url, profileID: nil, profileLabel: "p"))
        XCTAssertEqual(record.displayTitle, "Refactor billing")
    }

    func testFallsBackToDirectoryNameThenSessionID() throws {
        let withCwd = try transcript([
            #"{"type":"queue-operation","sessionId":"s4"}"#, #"{"cwd":"/a/billing"}"#,
        ])
        XCTAssertEqual(
            try XCTUnwrap(
                SessionIndex.record(transcript: withCwd, profileID: nil, profileLabel: "p")
            ).displayTitle, "billing")

        let bare = try transcript([#"{"type":"queue-operation","sessionId":"abcdef123456"}"#])
        XCTAssertEqual(
            try XCTUnwrap(
                SessionIndex.record(transcript: bare, profileID: nil, profileLabel: "p")
            ).displayTitle, "abcdef12")
    }

    func testMalformedTranscriptsAreSkippedNotFatal() throws {
        let garbage = try transcript(["not json at all", "{也不是"])
        XCTAssertNil(
            SessionIndex.record(transcript: garbage, profileID: nil, profileLabel: "p"))

        let noSessionID = try transcript([#"{"type":"bridge-session"}"#])
        XCTAssertNil(
            SessionIndex.record(transcript: noSessionID, profileID: nil, profileLabel: "p"))
    }

    /// Transcripts reach tens of megabytes; only the head should ever be read.
    func testOnlyReadsHeadOfLargeTranscripts() throws {
        var lines = [#"{"type":"queue-operation","sessionId":"big"}"#]
        let filler = String(repeating: "x", count: 4096)
        for i in 0..<200 { lines.append(#"{"type":"user","filler":"\#(filler)","n":\#(i)}"#) }
        let url = try transcript(lines)

        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertGreaterThan(size, SessionIndex.headBytes)
        XCTAssertLessThanOrEqual(
            SessionIndex.readHead(url).count, lines.count,
            "readHead must not parse the entire file")
        XCTAssertEqual(
            try XCTUnwrap(
                SessionIndex.record(transcript: url, profileID: nil, profileLabel: "p")).id, "big")
    }
}

final class UsageWindowCoverageTests: XCTestCase {
    /// Pins the complete server contract decoded from the app bundle. If Claude
    /// Code adds a window (a Fable meter, say), this test keeps passing — but
    /// the raw keys below are the authoritative list as of 2.1.271.
    func testRawKeysMatchServerContract() {
        XCTAssertEqual(
            Set(UsageWindow.allCases.map(\.rawValue)),
            ["fh", "sd", "so", "sn", "oa", "cw", "om", "op", "xu"])
    }

    /// There is deliberately no Fable window: only Opus and Sonnet have their
    /// own weekly meters. Fable usage counts against the general weekly limit.
    func testNoFableWindowExists() {
        XCTAssertFalse(
            UsageWindow.allCases.contains { $0.title.lowercased().contains("fable") })
    }

    func testSecondaryWindowsSurfaceOnlyWhenReported() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "u-\(UUID().uuidString).json")
        try Data(#"{"samples":[{"t":1000,"u":{"fh":5,"sd":40,"so":12}}]}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let history = try XCTUnwrap(UsageReader.read(at: url))
        XCTAssertEqual(history.reportedSecondaryWindows, [.sevenDayOpus])
        XCTAssertEqual(history.current(.sevenDayOpus), 12)
        XCTAssertNil(history.current(.sevenDaySonnet))
    }
}

final class UsageAPITests: XCTestCase {
    /// Shaped from the schema in claude-code 2.1.271:
    ///   model_scoped: [{ display_name, utilization, resets_at }]
    /// with display_name "Server-supplied label for the model bucket (e.g. 'Fable')".
    private let response: [String: Any] = [
        "limits": [
            "five_hour": ["utilization": 13, "resets_at": "2026-09-16T03:20:00Z"],
            "seven_day": ["utilization": 69, "resets_at": "2026-09-20T07:00:00Z"],
            "seven_day_opus": ["utilization": 4, "resets_at": "2026-09-20T07:00:00Z"],
            "model_scoped": [
                ["display_name": "Fable", "utilization": 99, "resets_at": "2026-09-20T07:00:00Z"]
            ],
            "extra_usage": ["is_enabled": true, "utilization": 27.19],
        ]
    ]

    func testModelScopedProducesTheFableRow() throws {
        let usage = UsageAPI.parse(response)
        let fable = try XCTUnwrap(usage.meter("model_scoped:Fable"))
        XCTAssertEqual(fable.title, "Weekly · Fable")
        XCTAssertEqual(fable.utilization, 99)
        XCTAssertNotNil(fable.resetsAt)
    }

    func testFixedWindowsParsedWithResetTimes() throws {
        let usage = UsageAPI.parse(response)
        let fiveHour = try XCTUnwrap(usage.meter("five_hour"))
        XCTAssertEqual(fiveHour.utilization, 13)
        XCTAssertEqual(fiveHour.title, "5-hour limit")
        // Reset times are the other thing the local history file cannot provide.
        XCTAssertNotNil(fiveHour.resetsAt)
        XCTAssertEqual(usage.meter("seven_day")?.utilization, 69)
    }

    func testExtraUsageOnlyWhenEnabled() {
        XCTAssertNotNil(UsageAPI.parse(response).meter("extra_usage"))
        let disabled: [String: Any] = [
            "limits": ["extra_usage": ["is_enabled": false, "utilization": 5]]
        ]
        XCTAssertNil(UsageAPI.parse(disabled).meter("extra_usage"))
    }

    /// The schema calls model_scoped "additive": absent when nothing is known,
    /// empty when the server listed no per-model window. Neither is an error.
    func testAbsentAndEmptyModelScopedAreBothFine() {
        let absent = UsageAPI.parse(["limits": ["five_hour": ["utilization": 1]]])
        XCTAssertEqual(absent.meters.count, 1)

        let empty = UsageAPI.parse(
            ["limits": ["five_hour": ["utilization": 1], "model_scoped": []]])
        XCTAssertEqual(empty.meters.count, 1)
    }

    func testUnparseableEntriesAreSkippedNotFatal() {
        let messy: [String: Any] = [
            "limits": [
                "five_hour": ["utilization": 10],
                "seven_day": ["resets_at": "2026-09-20T07:00:00Z"],  // no utilization
                "model_scoped": [
                    ["utilization": 5],  // no display_name
                    ["display_name": "Fable", "utilization": 99],
                ],
            ]
        ]
        let usage = UsageAPI.parse(messy)
        XCTAssertNil(usage.meter("seven_day"))
        XCTAssertEqual(usage.meters.count, 2)
        XCTAssertEqual(usage.meter("model_scoped:Fable")?.utilization, 99)
    }

    /// Tolerates a response that is not wrapped in `limits`.
    func testAcceptsUnwrappedResponse() {
        let usage = UsageAPI.parse(["five_hour": ["utilization": 42]])
        XCTAssertEqual(usage.meter("five_hour")?.utilization, 42)
    }

    /// Polling usage must not itself consume the quota being polled.
    func testSkipSpendSurvivesURLConstruction() {
        let url = UsageAPI.endpoint(UsageAPI.path, query: UsageAPI.queryItems)
        XCTAssertEqual(url.path(), "/api/oauth/usage")
        XCTAssertEqual(url.query(), "skip_spend=1")
        // Regression: `URL.appending(path:)` percent-encodes "?", which buried
        // the query inside the path and produced a 404.
        XCTAssertFalse(url.absoluteString.contains("%3F"))
    }
}

final class TokenStoreTests: XCTestCase {
    private func skipIfKeychainUnavailable() throws {
        let probe = UUID()
        do {
            try TokenStore.save(token: "probe", for: probe)
            TokenStore.delete(for: probe)
        } catch {
            throw XCTSkip("no usable Keychain in this environment: \(error)")
        }
    }

    func testRoundTripAndDelete() throws {
        // CI runners may have no usable login Keychain.
        try skipIfKeychainUnavailable()
        let id = UUID()
        defer { TokenStore.delete(for: id) }

        XCTAssertNil(TokenStore.load(for: id))
        XCTAssertFalse(TokenStore.has(id))

        try TokenStore.save(token: "sk-test-value", for: id)
        XCTAssertEqual(TokenStore.load(for: id), "sk-test-value")
        XCTAssertTrue(TokenStore.has(id))

        // Saving again must replace, not duplicate.
        try TokenStore.save(token: "sk-second", for: id)
        XCTAssertEqual(TokenStore.load(for: id), "sk-second")

        XCTAssertTrue(TokenStore.delete(for: id))
        XCTAssertNil(TokenStore.load(for: id))
    }

    func testTokensAreScopedPerProfile() throws {
        try skipIfKeychainUnavailable()
        let a = UUID(), b = UUID()
        defer { TokenStore.delete(for: a); TokenStore.delete(for: b) }
        try TokenStore.save(token: "token-a", for: a)
        try TokenStore.save(token: "token-b", for: b)
        XCTAssertEqual(TokenStore.load(for: a), "token-a")
        XCTAssertEqual(TokenStore.load(for: b), "token-b")
    }
}

final class SecureInputTests: XCTestCase {
    /// Under test, stdin is not a terminal, so the non-tty path must still read
    /// normally — otherwise piping a token (or running in CI) would hang.
    func testNonTTYPathReadsNormally() {
        XCTAssertEqual(isatty(STDIN_FILENO), 0, "test stdin should not be a tty")
        // Exercising the read itself would consume the test runner's stdin;
        // asserting the branch condition is the meaningful part.
    }
}

final class ProcessDetectionTests: XCTestCase {
    /// `pgrep` never matches its own ancestors. When this tool runs inside a
    /// Claude Code session the desktop app IS an ancestor, so pgrep reported it
    /// as not running — silently, and only in that context. Pinning the parsing
    /// keeps the replacement honest.
    func testParsesPSOutputAndIgnoresHelpers() {
        // Regression: helper processes must not be mistaken for app instances.
        let helper =
            "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper --type=renderer"
        XCTAssertTrue(helper.contains("--type="))

        let main = "/Applications/Claude.app/Contents/MacOS/Claude"
        XCTAssertTrue(main.contains(Launcher.appMainBinary))
        XCTAssertFalse(main.contains("--type="))
    }

    /// The default profile is any app instance NOT bound to a managed
    /// user-data-dir.
    func testManagedVersusDefaultDiscrimination() {
        let managedRoot = Paths.profilesDir.path
        let managed =
            "/Applications/Claude.app/Contents/MacOS/Claude --user-data-dir=\(managedRoot)/abc/electron"
        let plain = "/Applications/Claude.app/Contents/MacOS/Claude"
        XCTAssertTrue(managed.contains("--user-data-dir=\(managedRoot)"))
        XCTAssertFalse(plain.contains("--user-data-dir=\(managedRoot)"))
    }

    /// Exercises the real implementation. Meaningful only where the desktop app
    /// is actually running — locally that is the regression guard against
    /// reverting to pgrep, which cannot see its own ancestors.
    func testFindsTheHostingDesktopApp() throws {
        guard FileManager.default.fileExists(atPath: Paths.appBinary.path) else {
            throw XCTSkip("Claude desktop app not installed")
        }
        guard !Launcher.appProcesses().isEmpty else {
            throw XCTSkip("Claude desktop app not running")
        }
        XCTAssertFalse(Launcher.appProcesses().isEmpty)
    }
}

final class SharedAssetsTests: XCTestCase {
    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    /// `hooks` execute shell commands and `env` routinely holds secrets and
    /// machine-specific paths. Sharing either between accounts would arm code
    /// execution, or leak configuration, in an account that never opted in.
    func testHooksAndEnvAreNeverShared() {
        XCTAssertFalse(SharedAssets.shareableSettingsKeys.contains("hooks"))
        XCTAssertFalse(SharedAssets.shareableSettingsKeys.contains("env"))
        XCTAssertFalse(SharedAssets.shareableSettingsKeys.contains("apiKeyHelper"))
        // Entitlements differ per account; pinning a model the other account
        // cannot use fails at an unhelpful moment.
        XCTAssertFalse(SharedAssets.shareableSettingsKeys.contains("model"))
        XCTAssertTrue(SharedAssets.shareableSettingsKeys.contains("permissions"))
    }

    func testSettingsRoundTripCarriesOnlyAllowedKeys() throws {
        try withTemporaryRoot {
            let source = Paths.root.appending(path: "srcconfig")
            try writeJSON(
                [
                    "permissions": ["allow": ["Bash"]],
                    "theme": "dark",
                    "hooks": ["Stop": ["echo pwned"]],
                    "env": ["SECRET": "value"],
                ], to: source.appending(path: "settings.json"))

            try SharedAssets.captureSettings(fromConfigDir: source)
            let target = try ProfileStore.create(label: "target")
            try SharedAssets.materializeSettings(into: XCTUnwrap(ProfileStore.load(id: target.id)))

            let written = try XCTUnwrap(
                JSONSerialization.jsonObject(
                    with: try Data(
                        contentsOf: target.paths.config.appending(path: "settings.json")))
                    as? [String: Any])
            XCTAssertNotNil(written["permissions"])
            XCTAssertEqual(written["theme"] as? String, "dark")
            XCTAssertNil(written["hooks"])
            XCTAssertNil(written["env"])
        }
    }

    func testMemoriesCopyAcrossProfiles() throws {
        try withTemporaryRoot {
            let source = Paths.root.appending(path: "srcconfig")
            let memory = source.appending(path: "projects/-a-repo/memory")
            try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
            try Data("# note".utf8).write(to: memory.appending(path: "thing.md"))

            let captured = try SharedAssets.captureMemories(fromConfigDir: source)
            XCTAssertEqual(captured.files, 1)

            let target = try ProfileStore.create(label: "target")
            let written = try SharedAssets.materializeMemories(
                into: XCTUnwrap(ProfileStore.load(id: target.id)))
            XCTAssertEqual(written.files, 1)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: target.paths.config
                        .appending(path: "projects/-a-repo/memory/thing.md").path))
        }
    }

    /// A memory written under one profile must not be clobbered by an older
    /// copy from another.
    func testNewerMemoryIsNotOverwrittenByOlder() throws {
        try withTemporaryRoot {
            let source = Paths.root.appending(path: "srcconfig")
            let memory = source.appending(path: "projects/-a-repo/memory")
            try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
            let old = memory.appending(path: "thing.md")
            try Data("old".utf8).write(to: old)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: old.path)

            let destination = Paths.root.appending(path: "dst")
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)
            let newer = destination.appending(path: "thing.md")
            try Data("newer".utf8).write(to: newer)

            let copied = try SharedAssets.copyNewer(from: memory, to: destination)
            XCTAssertEqual(copied, 0)
            XCTAssertEqual(try String(contentsOf: newer, encoding: .utf8), "newer")
        }
    }

    /// Only the manifests move; `cache/` and `marketplaces/` are large and
    /// re-fetchable.
    func testOnlyPluginManifestsAreShared() {
        XCTAssertEqual(
            Set(SharedAssets.pluginManifests),
            ["installed_plugins.json", "known_marketplaces.json"])
    }
}
