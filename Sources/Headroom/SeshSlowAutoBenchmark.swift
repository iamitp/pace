import Darwin
import Foundation

enum SeshSlowAutoBenchmarkVerdict: String, Equatable, Sendable {
    case pass
    case inconclusive
    case fail
}

struct SeshSlowAutoBenchmarkEvidence: Equatable, Sendable {
    let verdict: SeshSlowAutoBenchmarkVerdict
    let acceptedSessions: Int
    let integrityPassed: Bool
    let slowTokenRatioVsStandard: Double
    let slowUncachedRatioVsStandard: Double
    let slowLowerTasks: Int
    let slowMaximumTaskRatio: Double
    let autoPremiumRatioVsStandard: Double
    let autoPremiumRatioVsFast: Double
    let autoUncachedRatioVsStandard: Double
    let autoGeometricRegret: Double
    let autoMaximumTaskRegret: Double
    let autoSelectionMatchesPolicy: Bool
    let cacheStatus: String
    let observedAt: Date

    var uiLines: [String] {
        [
            "Retired single-route baseline: \(verdict.rawValue.uppercased()) (policy 3.0.1)",
            "Quality/integrity: PASS \(acceptedSessions)/9; 9/9 archive cross-checks; 9 provider turns",
            "Slow: total ratio \(Self.ratio(slowTokenRatioVsStandard)) vs Standard (\(Self.comparison(slowTokenRatioVsStandard))); uncached \(Self.ratio(slowUncachedRatioVsStandard)); \(slowLowerTasks)/3 tasks lower; max \(Self.ratio(slowMaximumTaskRatio))",
            "Auto: ratio \(Self.ratio(autoPremiumRatioVsStandard)) vs Standard (\(Self.comparison(autoPremiumRatioVsStandard))); uncached \(Self.ratio(autoUncachedRatioVsStandard)) (\(Self.comparison(autoUncachedRatioVsStandard))); regret \(Self.ratio(autoGeometricRegret)); max regret \(Self.ratio(autoMaximumTaskRegret))",
            "Fast: no native Fast run; \(Self.ratio(autoPremiumRatioVsFast)) is derived from the documented 2.5x proxy, not observed usage, credits, or quota.",
            "Disposition: retired single-route baseline only; cache \(cacheStatus); not conductor proof; \(Self.timestamp(observedAt))"
        ]
    }

    private static func comparison(_ ratio: Double) -> String {
        let change = 100 * abs(1 - ratio)
        if ratio < 1 { return "\(percent(change)) lower" }
        if ratio > 1 { return "\(percent(change)) higher" }
        return "the same"
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private static func ratio(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd 'UTC'"
        return formatter.string(from: value)
    }
}

enum SeshSlowAutoBenchmarkState: Equatable, Sendable {
    case pending
    case available(SeshSlowAutoBenchmarkEvidence)
    case rejected

    var uiLines: [String] {
        switch self {
        case .pending:
            return ["Retired single-route baseline: pending archived evidence"]
        case .rejected:
            return ["Retired single-route baseline: evidence rejected"]
        case .available(let evidence):
            return evidence.uiLines
        }
    }
}

enum SeshSlowAutoBenchmark {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sesh/calibration/latest-slow-auto-benchmark.json")

    private static let maximumBytes = 256 * 1_024
    private static let futureClockSkew: TimeInterval = 5 * 60
    private static let expectedPolicyVersion = "3.0.1"
    private static let expectedArtifactFilename = "1784343665-0113c1da-5aee8876.json"
    private static let expectedArtifactSHA256 = "465c077cbe211c55f81c2ccac0f44f3d5edbc748041618e053b7283ab31a350d"
    private static let expectedEvidenceSHA256 = "9c9978300e6f9e0eae6d89ee2a277a1d880c1011add8acd9d355aa577840e857"
    private static let expectedScheduleSHA256 = "84af0625a3c195d05a3787eb1f1220294b4b9738205f7e14aee0aa65ad7b2d5a"

    static func read(
        url: URL = defaultURL,
        now: Date = Date()
    ) -> SeshSlowAutoBenchmarkState {
        do {
            return .available(try decode(url: url, now: now))
        } catch let error as POSIXReadError where error.code == ENOENT {
            return .pending
        } catch {
            return .rejected
        }
    }

    static func selfTest() -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("pace-slow-auto-benchmark-\(UUID().uuidString)")
        let validURL = directory.appendingPathComponent("result.json")
        let contractMismatchURL = directory.appendingPathComponent("contract-mismatch.json")
        let proxyMismatchURL = directory.appendingPathComponent("proxy-mismatch.json")
        let missingURL = directory.appendingPathComponent("missing.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: directory) }
            let fixture = fixtureRecord(observedAt: Int64(now.timeIntervalSince1970) - 10)
            let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
            try data.write(to: validURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: validURL.path)

            guard case .available(let evidence) = read(url: validURL, now: now),
                  evidence.verdict == .fail,
                  evidence.acceptedSessions == 9,
                  evidence.integrityPassed,
                  evidence.slowTokenRatioVsStandard == 0.925299,
                  evidence.slowUncachedRatioVsStandard == 0.932996,
                  evidence.slowLowerTasks == 2,
                  evidence.slowMaximumTaskRatio == 1.307818,
                  evidence.autoPremiumRatioVsStandard == 0.983965,
                  evidence.autoPremiumRatioVsFast == 0.393586,
                  evidence.autoUncachedRatioVsStandard == 1.207282,
                  evidence.autoGeometricRegret == 1.162911,
                  evidence.autoMaximumTaskRegret == 1.363756,
                  evidence.autoSelectionMatchesPolicy,
                  evidence.cacheStatus == "imbalanced",
                  read(url: missingURL, now: now) == .pending else {
                return false
            }
            let lines = evidence.uiLines.joined(separator: "\n")
            guard lines.contains("Retired single-route baseline: FAIL (policy 3.0.1)"),
                  lines.contains("Quality/integrity: PASS 9/9; 9/9 archive cross-checks; 9 provider turns"),
                  lines.contains("total ratio 0.925299 vs Standard (7.5% lower); uncached 0.932996; 2/3 tasks lower; max 1.307818"),
                  lines.contains("ratio 0.983965 vs Standard (1.6% lower); uncached 1.207282 (20.7% higher); regret 1.162911; max regret 1.363756"),
                  lines.contains("no native Fast run; 0.393586 is derived from the documented 2.5x proxy"),
                  lines.contains("not observed usage, credits, or quota"),
                  lines.contains("retired single-route baseline only"),
                  lines.contains("not conductor proof") else {
                return false
            }

            var contractMismatch = fixture
            contractMismatch["quality"] = [
                "accepted_sessions": 8,
                "required_sessions": 9
            ]
            try writeFixture(contractMismatch, to: contractMismatchURL)
            guard read(url: contractMismatchURL, now: now) == .rejected else { return false }

            guard var proxyMismatchAuto = fixture["auto"] as? [String: Any] else {
                return false
            }
            proxyMismatchAuto["premium_index_ratio_vs_fast"] = 0.35
            var proxyMismatch = fixture
            proxyMismatch["auto"] = proxyMismatchAuto
            try writeFixture(proxyMismatch, to: proxyMismatchURL)
            guard read(url: proxyMismatchURL, now: now) == .rejected else { return false }

            try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: validURL.path)
            return read(url: validURL, now: now) == .rejected
        } catch {
            return false
        }
    }

    private static func writeFixture(_ fixture: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func decode(
        url: URL,
        now: Date
    ) throws -> SeshSlowAutoBenchmarkEvidence {
        let data = try privateData(url: url)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schema == 1,
              record.experiment == "slow-auto-benchmark-v1",
              record.contract == "three-task-three-arm-one-turn-v1",
              record.evidenceKind == "real-codex-sessions",
              record.policyVersion == expectedPolicyVersion,
              record.usageScope == "fresh-thread-cumulative-total",
              record.threadLifecycle == "nine-fresh-one-turn-then-archived",
              record.taskCount == 3,
              record.armCount == 3,
              record.sessionCount == 9,
              record.providerTurns == 9,
              record.autoFastAllowed == false,
              record.artifactFilename == expectedArtifactFilename,
              record.artifactSHA256 == expectedArtifactSHA256,
              record.scheduleSHA256 == expectedScheduleSHA256,
              record.evidenceSHA256 == expectedEvidenceSHA256,
              validSHA256(record.artifactSHA256),
              validSHA256(record.scheduleSHA256),
              validSHA256(record.evidenceSHA256),
              record.observedAt > 0,
              record.observedAt <= Int64(now.addingTimeInterval(futureClockSkew).timeIntervalSince1970),
              record.claimScope == "three-task-engineering-benchmark",
              record.quotaClaim == "unobservable",
              record.fastWeighting == "documented-chatgpt-fast-2.5x-proxy-not-billing-observation",
              record.integrity.cumulativeArchiveCrosscheckedSessions == 9,
              record.integrity.nativePassThroughTasks == 3,
              record.integrity.premiumIndexContractSessions == 9,
              record.integrity.fastReferenceTasks == 3,
              record.quality.acceptedSessions == 9,
              record.quality.requiredSessions == 9,
              exact(record.slow.totalTokenRatioVsNormal, 0.925299),
              exact(record.slow.uncachedTokenRatioVsNormal, 0.932996),
              record.slow.lowerTokenTasks == 2,
              exact(record.slow.maximumTaskRatio, 1.307818),
              record.slow.usedFastSessions == 0,
              exact(record.auto.premiumIndexRatioVsNormal, 0.983965),
              exact(record.auto.premiumIndexRatioVsFast, 0.393586),
              exact(record.auto.premiumIndexRatioVsFastReference, 0.393586),
              validFastProxyRatio(
                  autoVsStandard: record.auto.premiumIndexRatioVsNormal,
                  autoVsFast: record.auto.premiumIndexRatioVsFast
              ),
              exact(record.auto.uncachedTokenRatioVsNormal, 1.207282),
              record.auto.lowerIndexTasks == 2,
              exact(record.auto.geometricRegretVsBestEligible, 1.162911),
              exact(record.auto.maximumTaskRegret, 1.363756),
              record.auto.selectionMatchesPolicy,
              record.auto.usedFastSessions == 0,
              record.cache.status == "imbalanced",
              record.cache.sensitivityDirectionPreserved == false,
              record.fastReference.claim == "documented-fast-premium-proxy-not-observed-usage-or-credits",
              record.fastReference.multiplier == 2.5,
              record.fastReference.providerSessions == 0,
              record.fastReference.source == "native-standard-total-token-volume",
              record.fastReference.supportedModelTasks == 3,
              record.runtimeCalibration.accepted == false,
              record.runtimeCalibration.routes == [
                  "complex": "slow",
                  "mechanical": "native-normal",
                  "standard": "slow"
              ] else {
            throw BenchmarkReadError.invalidContract
        }

        return SeshSlowAutoBenchmarkEvidence(
            verdict: .fail,
            acceptedSessions: record.quality.acceptedSessions,
            integrityPassed: true,
            slowTokenRatioVsStandard: record.slow.totalTokenRatioVsNormal,
            slowUncachedRatioVsStandard: record.slow.uncachedTokenRatioVsNormal,
            slowLowerTasks: record.slow.lowerTokenTasks,
            slowMaximumTaskRatio: record.slow.maximumTaskRatio,
            autoPremiumRatioVsStandard: record.auto.premiumIndexRatioVsNormal,
            autoPremiumRatioVsFast: record.auto.premiumIndexRatioVsFast,
            autoUncachedRatioVsStandard: record.auto.uncachedTokenRatioVsNormal,
            autoGeometricRegret: record.auto.geometricRegretVsBestEligible,
            autoMaximumTaskRegret: record.auto.maximumTaskRegret,
            autoSelectionMatchesPolicy: record.auto.selectionMatchesPolicy,
            cacheStatus: record.cache.status,
            observedAt: Date(timeIntervalSince1970: Double(record.observedAt))
        )
    }

    private static func privateData(url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXReadError(code: errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw POSIXReadError(code: code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0,
              info.st_mode & 0o400 != 0,
              info.st_size > 0,
              info.st_size <= maximumBytes else {
            Darwin.close(descriptor)
            throw BenchmarkReadError.unsafeFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw BenchmarkReadError.unsafeFile
        }
        return data
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func exact(_ value: Double, _ expected: Double) -> Bool {
        value.isFinite && abs(value - expected) <= 0.000_000_5
    }

    private static func validFastProxyRatio(
        autoVsStandard: Double,
        autoVsFast: Double
    ) -> Bool {
        abs(autoVsFast - (autoVsStandard / 2.5)) <= 0.000_002
    }

    private static func fixtureRecord(observedAt: Int64) -> [String: Any] {
        [
            "schema": 1,
            "experiment": "slow-auto-benchmark-v1",
            "contract": "three-task-three-arm-one-turn-v1",
            "evidence_kind": "real-codex-sessions",
            "policy_version": expectedPolicyVersion,
            "usage_scope": "fresh-thread-cumulative-total",
            "thread_lifecycle": "nine-fresh-one-turn-then-archived",
            "task_count": 3,
            "arm_count": 3,
            "session_count": 9,
            "provider_turns": 9,
            "auto_fast_allowed": false,
            "artifact_filename": expectedArtifactFilename,
            "artifact_sha256": expectedArtifactSHA256,
            "schedule_sha256": expectedScheduleSHA256,
            "evidence_sha256": expectedEvidenceSHA256,
            "observed_at": observedAt,
            "integrity": [
                "cumulative_archive_crosschecked_sessions": 9,
                "native_pass_through_tasks": 3,
                "premium_index_contract_sessions": 9,
                "fast_reference_tasks": 3
            ],
            "quality": ["accepted_sessions": 9, "required_sessions": 9],
            "slow": [
                "total_token_ratio_vs_normal": 0.925299,
                "uncached_token_ratio_vs_normal": 0.932996,
                "lower_token_tasks": 2,
                "maximum_task_ratio": 1.307818,
                "used_fast_sessions": 0
            ],
            "auto": [
                "premium_index_ratio_vs_normal": 0.983965,
                "premium_index_ratio_vs_fast": 0.393586,
                "premium_index_ratio_vs_fast_reference": 0.393586,
                "uncached_token_ratio_vs_normal": 1.207282,
                "lower_index_tasks": 2,
                "geometric_regret_vs_best_eligible": 1.162911,
                "maximum_task_regret": 1.363756,
                "selection_matches_policy": true,
                "used_fast_sessions": 0
            ],
            "cache": [
                "status": "imbalanced",
                "sensitivity_direction_preserved": false
            ],
            "fast_reference": [
                "claim": "documented-fast-premium-proxy-not-observed-usage-or-credits",
                "multiplier": 2.5,
                "provider_sessions": 0,
                "source": "native-standard-total-token-volume",
                "supported_model_tasks": 3
            ],
            "runtime_calibration": [
                "accepted": false,
                "routes": [
                    "complex": "slow",
                    "mechanical": "native-normal",
                    "standard": "slow"
                ]
            ],
            "claim_scope": "three-task-engineering-benchmark",
            "quota_claim": "unobservable",
            "fast_weighting": "documented-chatgpt-fast-2.5x-proxy-not-billing-observation"
        ]
    }
}

private struct POSIXReadError: Error {
    let code: Int32
}

private enum BenchmarkReadError: Error {
    case unsafeFile
    case invalidContract
}

private struct Record: Decodable {
    let schema: Int
    let experiment: String
    let contract: String
    let evidenceKind: String
    let policyVersion: String
    let usageScope: String
    let threadLifecycle: String
    let taskCount: Int
    let armCount: Int
    let sessionCount: Int
    let providerTurns: Int
    let autoFastAllowed: Bool
    let artifactFilename: String
    let artifactSHA256: String
    let scheduleSHA256: String
    let evidenceSHA256: String
    let observedAt: Int64
    let integrity: IntegrityRecord
    let quality: QualityRecord
    let slow: SlowRecord
    let auto: AutoRecord
    let cache: CacheRecord
    let fastReference: FastReferenceRecord
    let runtimeCalibration: RuntimeCalibrationRecord
    let claimScope: String
    let quotaClaim: String
    let fastWeighting: String

    enum CodingKeys: String, CodingKey {
        case schema, experiment, contract, integrity, quality, slow, auto, cache
        case evidenceKind = "evidence_kind"
        case policyVersion = "policy_version"
        case usageScope = "usage_scope"
        case threadLifecycle = "thread_lifecycle"
        case taskCount = "task_count"
        case armCount = "arm_count"
        case sessionCount = "session_count"
        case providerTurns = "provider_turns"
        case autoFastAllowed = "auto_fast_allowed"
        case artifactFilename = "artifact_filename"
        case artifactSHA256 = "artifact_sha256"
        case scheduleSHA256 = "schedule_sha256"
        case evidenceSHA256 = "evidence_sha256"
        case observedAt = "observed_at"
        case fastReference = "fast_reference"
        case runtimeCalibration = "runtime_calibration"
        case claimScope = "claim_scope"
        case quotaClaim = "quota_claim"
        case fastWeighting = "fast_weighting"
    }
}

private struct IntegrityRecord: Decodable {
    let cumulativeArchiveCrosscheckedSessions: Int
    let nativePassThroughTasks: Int
    let premiumIndexContractSessions: Int
    let fastReferenceTasks: Int

    enum CodingKeys: String, CodingKey {
        case cumulativeArchiveCrosscheckedSessions = "cumulative_archive_crosschecked_sessions"
        case nativePassThroughTasks = "native_pass_through_tasks"
        case premiumIndexContractSessions = "premium_index_contract_sessions"
        case fastReferenceTasks = "fast_reference_tasks"
    }
}

private struct QualityRecord: Decodable {
    let acceptedSessions: Int
    let requiredSessions: Int

    enum CodingKeys: String, CodingKey {
        case acceptedSessions = "accepted_sessions"
        case requiredSessions = "required_sessions"
    }
}

private struct SlowRecord: Decodable {
    let totalTokenRatioVsNormal: Double
    let uncachedTokenRatioVsNormal: Double
    let lowerTokenTasks: Int
    let maximumTaskRatio: Double
    let usedFastSessions: Int

    enum CodingKeys: String, CodingKey {
        case totalTokenRatioVsNormal = "total_token_ratio_vs_normal"
        case uncachedTokenRatioVsNormal = "uncached_token_ratio_vs_normal"
        case lowerTokenTasks = "lower_token_tasks"
        case maximumTaskRatio = "maximum_task_ratio"
        case usedFastSessions = "used_fast_sessions"
    }
}

private struct AutoRecord: Decodable {
    let premiumIndexRatioVsNormal: Double
    let premiumIndexRatioVsFast: Double
    let premiumIndexRatioVsFastReference: Double
    let uncachedTokenRatioVsNormal: Double
    let lowerIndexTasks: Int
    let geometricRegretVsBestEligible: Double
    let maximumTaskRegret: Double
    let selectionMatchesPolicy: Bool
    let usedFastSessions: Int

    enum CodingKeys: String, CodingKey {
        case premiumIndexRatioVsNormal = "premium_index_ratio_vs_normal"
        case premiumIndexRatioVsFast = "premium_index_ratio_vs_fast"
        case premiumIndexRatioVsFastReference = "premium_index_ratio_vs_fast_reference"
        case uncachedTokenRatioVsNormal = "uncached_token_ratio_vs_normal"
        case lowerIndexTasks = "lower_index_tasks"
        case geometricRegretVsBestEligible = "geometric_regret_vs_best_eligible"
        case maximumTaskRegret = "maximum_task_regret"
        case selectionMatchesPolicy = "selection_matches_policy"
        case usedFastSessions = "used_fast_sessions"
    }
}

private struct CacheRecord: Decodable {
    let status: String
    let sensitivityDirectionPreserved: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case sensitivityDirectionPreserved = "sensitivity_direction_preserved"
    }
}

private struct FastReferenceRecord: Decodable {
    let claim: String
    let multiplier: Double
    let providerSessions: Int
    let source: String
    let supportedModelTasks: Int

    enum CodingKeys: String, CodingKey {
        case claim, multiplier, source
        case providerSessions = "provider_sessions"
        case supportedModelTasks = "supported_model_tasks"
    }
}

private struct RuntimeCalibrationRecord: Decodable {
    let accepted: Bool
    let routes: [String: String]
}
