import Foundation
import Darwin

struct SeshCalibrationEvidence: Equatable, Sendable {
    let acceptedCaseCount: Int
    let autoTokenSavingsPercent: Double
    let autoQualityMatched: Bool
    let orchestratedAccepted: Bool
    let orchestratedTokenChangeVsAutoPercent: Double
    let orchestratedDecision: String
    let observedAt: Date

    var uiLines: [String] {
        let caseLabel = acceptedCaseCount == 1 ? "case" : "cases"
        return [
            "Calibration: \(acceptedCaseCount) accepted \(caseLabel)",
            "Auto vs fixed: \(Self.comparisonText(autoTokenSavingsPercent)); quality \(autoQualityMatched ? "matched" : "did not match")",
            "Orchestration: \(Self.orchestrationText(orchestratedTokenChangeVsAutoPercent)); \(orchestratedAccepted ? "accepted" : "not accepted"); \(orchestratedDecision)",
            "Evidence: \(Self.timestamp(observedAt))"
        ]
    }

    private static func comparisonText(_ value: Double) -> String {
        if value > 0 { return "\(percent(value)) fewer tokens" }
        if value < 0 { return "\(percent(abs(value))) more tokens" }
        return "same token use"
    }

    private static func orchestrationText(_ value: Double) -> String {
        if value > 0 { return "\(percent(value)) token overhead vs Auto" }
        if value < 0 { return "\(percent(abs(value))) fewer tokens vs Auto" }
        return "no token change vs Auto"
    }

    private static func percent(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f%%", value)
            : String(format: "%.1f%%", value)
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: value)
    }
}

enum SeshCalibrationEvidenceState: Equatable, Sendable {
    case pending
    case available(SeshCalibrationEvidence)
    case unavailable

    var matchedCaseCount: Int {
        guard case .available(let evidence) = self else { return 0 }
        return evidence.acceptedCaseCount
    }
}

struct SeshPaceAcidEvidence: Equatable, Sendable {
    struct PaceResult: Equatable, Sendable {
        let observedTokens: Int64
        let providerDurationMs: Int64
    }

    let qualityPassed: Bool
    let acceptedCases: Int
    let requiredCases: Int
    let tokenGradientPassed: Bool
    let cacheComparability: String
    let productionCalibrationSufficient: Bool
    let noRush: PaceResult
    let normal: PaceResult
    let live: PaceResult
    let noRushToNormalTokenReductionPercent: Double
    let normalToLiveTokenReductionPercent: Double
    let observedAt: Date

    var uiLines: [String] {
        let quality = qualityPassed ? "PASS" : "FAIL"
        let tokenGradient = tokenGradientPassed ? "PASS" : "FAIL"
        let cache = cacheComparability
        let production = productionCalibrationSufficient ? "sufficient" : "insufficient"
        return [
            "Quality parity: \(quality) \(acceptedCases)/\(requiredCases), this corpus only",
            "Speed: No rush \(Self.integer(noRush.providerDurationMs)) ms | Normal \(Self.integer(normal.providerDurationMs)) ms (\(Self.percent(speedReduction(from: noRush, to: normal))) faster)",
            "Speed: Live \(Self.integer(live.providerDurationMs)) ms (\(Self.percent(speedReduction(from: normal, to: live))) faster than Normal)",
            "Observed tokens: No rush \(Self.integer(noRush.observedTokens)) | Normal \(Self.integer(normal.observedTokens)) | Live \(Self.integer(live.observedTokens))",
            "Strict token gradient: \(tokenGradient) (\(Self.percent(noRushToNormalTokenReductionPercent)), then \(Self.percent(normalToLiveTokenReductionPercent)); 10% required each)",
            "Cache comparability: \(cache); production calibration: \(production)",
            "Acid test evidence: \(Self.timestamp(observedAt))"
        ]
    }

    private func speedReduction(from high: PaceResult, to low: PaceResult) -> Double {
        100 * Double(high.providerDurationMs - low.providerDurationMs)
            / Double(high.providerDurationMs)
    }

    private static func integer(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.2f%%", value)
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        return formatter.string(from: value)
    }
}

enum SeshPaceAcidEvidenceState: Equatable, Sendable {
    case pending
    case available(SeshPaceAcidEvidence)
    case unavailable
}

struct SeshMeasurementSummary: Equatable, Sendable {
    let windowDays: Int
    let conductorRuns: Int
    let verifiedRuns: Int
    let completeTreeTokenRuns: Int
    let completeTreeTokens: Int64
    let providerTurns: Int
    let topologyCounts: [String: Int]
    let workerCount: Int
    let workerCounts: [String: Int]
    let escalations: Int
    let routeStageCounts: [String: Int]
    let historicalSchema1Turns: Int
    let nonFrontierRoutes: Int
    let protectedFloorViolations: Int
    let modelCounts: [String: Int]
    let medianDurationMs: Double?
    let calibrationEvidence: SeshCalibrationEvidenceState
    let paceAcidEvidence: SeshPaceAcidEvidenceState

    // Compatibility aliases for the existing compact card. Current proof is
    // deliberately limited to schema 2 conductor runs.
    var validTurns: Int { conductorRuns }
    var verifiedSuccesses: Int { verifiedRuns }
    var tokenUsageTurns: Int { completeTreeTokenRuns }
    var observedTokens: Int64 { completeTreeTokens }
    var matchedCalibrationCases: Int { calibrationEvidence.matchedCaseCount }

    var rendered: String {
        let coverage = conductorRuns > 0
            ? 100 * Double(completeTreeTokenRuns) / Double(conductorRuns)
            : 0
        let coverageText = String(format: "%.1f", coverage)
        let duration = medianDurationMs.map(Self.formatNumber) ?? "unknown"
        let models = Self.renderModels(modelCounts)
        let topologies = Self.renderCounts(topologyCounts)
        let workerDistribution = Self.renderCounts(workerCounts)
        let routeStages = Self.renderCounts(routeStageCounts)
        return ([
            "sesh_measurement_scope=conductor-schema-2-only",
            "sesh_proof_window_days=\(windowDays)",
            "conductor_runs=\(conductorRuns)",
            "verified_runs=\(verifiedRuns)",
            "complete_tree_token_coverage=\(completeTreeTokenRuns)/\(conductorRuns) (\(coverageText)%)",
            "complete_tree_tokens=\(completeTreeTokens)",
            "provider_turns=\(providerTurns)",
            "topology_counts=\(topologies)",
            "worker_count=\(workerCount)",
            "worker_counts=\(workerDistribution)",
            "escalations=\(escalations)",
            "route_stage_counts=\(routeStages)",
            "historical_schema1_turns=\(historicalSchema1Turns)",
            "non_frontier_routes=\(nonFrontierRoutes)",
            "protected_floor_violations=\(protectedFloorViolations)",
            "model_counts=\(models)",
            "median_duration_ms=\(duration)",
            "matched_calibration_cases=\(matchedCalibrationCases)",
            "credits_and_quota_measurement=unobservable"
        ] + SeshMeasurement.renderedCalibration(calibrationEvidence)
            + SeshMeasurement.renderedPaceAcid(paceAcidEvidence)).joined(separator: "\n")
    }

    private static func formatNumber(_ value: Double) -> String {
        value.rounded() == value
            ? String(Int64(value))
            : String(format: "%.1f", value)
    }

    private static func renderModels(_ counts: [String: Int]) -> String {
        renderCounts(counts)
    }

    private static func renderCounts(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty,
              let data = try? JSONSerialization.data(
                withJSONObject: counts,
                options: [.sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

enum SeshMeasurement {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sesh/decisions.jsonl")
    static let defaultCalibrationURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sesh/calibration/latest-summary.json")
    static let defaultPaceAcidURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sesh/calibration/latest-pace-acid.json")

    private static let windowDays = 7
    private static let maxReadBytes: UInt64 = 8 * 1_024 * 1_024
    private static let maxCalibrationBytes = 256 * 1_024
    private static let maxLines = 20_000
    private static let futureClockSkew: TimeInterval = 5 * 60
    private static let maximumMetricValue: Int64 = 1_000_000_000_000

    static func read(
        url: URL = defaultURL,
        calibrationURL: URL = defaultCalibrationURL,
        paceAcidURL: URL = defaultPaceAcidURL,
        now: Date = Date()
    ) throws -> SeshMeasurementSummary {
        let lines = try boundedLines(from: url)
        let calibrationEvidence = readCalibrationEvidence(url: calibrationURL, now: now)
        let paceAcidEvidence = readPaceAcidEvidence(url: paceAcidURL, now: now)
        let cutoff = Int64(now.addingTimeInterval(-Double(windowDays) * 86_400).timeIntervalSince1970)
        let latest = Int64(now.addingTimeInterval(futureClockSkew).timeIntervalSince1970)
        var records: [SeshTelemetryRecord] = []
        records.reserveCapacity(min(lines.count, maxLines))

        let decoder = JSONDecoder()
        for line in lines.suffix(maxLines) {
            guard let data = line.data(using: .utf8),
                  let record = try? decoder.decode(SeshTelemetryRecord.self, from: data),
                  record.isValid,
                  record.observedAt >= cutoff,
                  record.observedAt <= latest else {
                continue
            }
            records.append(record)
        }

        let conductorRecords = records.filter(\.isConductor)
        let historicalRecords = records.filter(\.isHistorical)
        let verified = conductorRecords.reduce(0) { count, record in
            count + (record.outcome == "verified-success" ? 1 : 0)
        }
        let usageRecords = conductorRecords.filter(\.hasCompleteTreeUsage)
        let observedTokens = usageRecords.reduce(Int64(0)) { total, record in
            total + (record.totalTokens ?? 0)
        }
        let providerTurns = conductorRecords.reduce(0) { total, record in
            total + (record.providerTurns ?? 0)
        }
        let workerCount = conductorRecords.reduce(0) { total, record in
            total + (record.workerCount ?? 0)
        }
        var workerCounts: [String: Int] = [:]
        for record in conductorRecords {
            workerCounts[String(record.workerCount ?? 0), default: 0] += 1
        }
        let escalations = conductorRecords.reduce(0) { total, record in
            total + (record.escalations ?? 0)
        }
        var topologyCounts: [String: Int] = [:]
        var routeStageCounts: [String: Int] = [:]
        for record in conductorRecords {
            if let topology = record.topology {
                topologyCounts[topology, default: 0] += 1
            }
            for route in record.routes ?? [] {
                routeStageCounts[route.stage, default: 0] += route.count
            }
        }
        let nonFrontier = conductorRecords.reduce(0) { count, record in
            count + (isFrontier(model: record.model) ? 0 : 1)
        }
        let floorViolations = conductorRecords.reduce(0) { count, record in
            count + (violatesProtectedFloor(record) ? 1 : 0)
        }
        var modelCounts: [String: Int] = [:]
        for record in conductorRecords {
            modelCounts[record.model, default: 0] += 1
        }
        let durations = conductorRecords.compactMap(\.durationMs).sorted()

        return SeshMeasurementSummary(
            windowDays: windowDays,
            conductorRuns: conductorRecords.count,
            verifiedRuns: verified,
            completeTreeTokenRuns: usageRecords.count,
            completeTreeTokens: observedTokens,
            providerTurns: providerTurns,
            topologyCounts: topologyCounts,
            workerCount: workerCount,
            workerCounts: workerCounts,
            escalations: escalations,
            routeStageCounts: routeStageCounts,
            historicalSchema1Turns: historicalRecords.count,
            nonFrontierRoutes: nonFrontier,
            protectedFloorViolations: floorViolations,
            modelCounts: modelCounts,
            medianDurationMs: median(durations),
            calibrationEvidence: calibrationEvidence,
            paceAcidEvidence: paceAcidEvidence
        )
    }

    static func readRendered(
        url: URL = defaultURL,
        calibrationURL: URL = defaultCalibrationURL,
        paceAcidURL: URL = defaultPaceAcidURL,
        now: Date = Date()
    ) -> String {
        let calibrationEvidence = readCalibrationEvidence(url: calibrationURL, now: now)
        let paceAcidEvidence = readPaceAcidEvidence(url: paceAcidURL, now: now)
        do {
            return try read(
                url: url,
                calibrationURL: calibrationURL,
                paceAcidURL: paceAcidURL,
                now: now
            ).rendered
        } catch let error as SeshMeasurementError {
            return ([
                "sesh_proof_status=unavailable",
                "reason=\(error.safeReason)"
            ] + renderedCalibration(calibrationEvidence)
                + renderedPaceAcid(paceAcidEvidence)).joined(separator: "\n")
        } catch {
            return ([
                "sesh_proof_status=unavailable",
                "reason=read-failed"
            ] + renderedCalibration(calibrationEvidence)
                + renderedPaceAcid(paceAcidEvidence)).joined(separator: "\n")
        }
    }

    static func readCalibrationEvidence(
        url: URL = defaultCalibrationURL,
        now: Date = Date()
    ) -> SeshCalibrationEvidenceState {
        do {
            return .available(try decodeCalibrationEvidence(url: url, now: now))
        } catch {
            return isMissingFileError(error) ? .pending : .unavailable
        }
    }

    static func readPaceAcidEvidence(
        url: URL = defaultPaceAcidURL,
        now: Date = Date()
    ) -> SeshPaceAcidEvidenceState {
        do {
            return .available(try decodePaceAcidEvidence(url: url, now: now))
        } catch {
            return isMissingFileError(error) ? .pending : .unavailable
        }
    }

    static func renderedCalibration(_ state: SeshCalibrationEvidenceState) -> [String] {
        switch state {
        case .pending:
            return ["calibration_evidence=insufficient"]
        case .unavailable:
            return ["calibration_evidence=unavailable"]
        case .available(let evidence):
            return [
                "calibration_evidence=available",
                "calibration_accepted_cases=\(evidence.acceptedCaseCount)",
                "calibration_auto_quality_match=\(evidence.autoQualityMatched)",
                "calibration_auto_vs_fixed_token_savings_percent=\(formatMetric(evidence.autoTokenSavingsPercent))",
                "calibration_orchestrated_accepted=\(evidence.orchestratedAccepted)",
                "calibration_orchestrated_token_change_vs_auto_percent=\(formatMetric(evidence.orchestratedTokenChangeVsAutoPercent))",
                "calibration_orchestrated_decision=\(evidence.orchestratedDecision)",
                "calibration_observed_at=\(Int64(evidence.observedAt.timeIntervalSince1970))"
            ]
        }
    }

    static func renderedPaceAcid(_ state: SeshPaceAcidEvidenceState) -> [String] {
        switch state {
        case .pending:
            return ["pace_acid_evidence=insufficient"]
        case .unavailable:
            return ["pace_acid_evidence=unavailable"]
        case .available(let evidence):
            return [
                "pace_acid_evidence=available",
                "pace_acid_quality_parity=\(evidence.qualityPassed ? "pass" : "fail")",
                "pace_acid_quality_cases=\(evidence.acceptedCases)/\(evidence.requiredCases)",
                "pace_acid_no_rush_duration_ms=\(evidence.noRush.providerDurationMs)",
                "pace_acid_normal_duration_ms=\(evidence.normal.providerDurationMs)",
                "pace_acid_live_duration_ms=\(evidence.live.providerDurationMs)",
                "pace_acid_no_rush_tokens=\(evidence.noRush.observedTokens)",
                "pace_acid_normal_tokens=\(evidence.normal.observedTokens)",
                "pace_acid_live_tokens=\(evidence.live.observedTokens)",
                "pace_acid_token_gradient=\(evidence.tokenGradientPassed ? "pass" : "fail")",
                "pace_acid_no_rush_to_normal_reduction_percent=\(formatMetric(evidence.noRushToNormalTokenReductionPercent))",
                "pace_acid_normal_to_live_reduction_percent=\(formatMetric(evidence.normalToLiveTokenReductionPercent))",
                "pace_acid_cache_comparability=\(evidence.cacheComparability)",
                "pace_acid_production_calibration=\(evidence.productionCalibrationSufficient ? "sufficient" : "insufficient")",
                "pace_acid_claim_scope=three-case-corpus-only",
                "pace_acid_observed_at=\(Int64(evidence.observedAt.timeIntervalSince1970))"
            ]
        }
    }

    static func selfTest() -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("pace-sesh-proof-\(UUID().uuidString)", isDirectory: true)
        let fixtureURL = directory.appendingPathComponent("decisions.jsonl")
        let calibrationURL = directory.appendingPathComponent("latest-summary.json")
        let paceAcidURL = directory.appendingPathComponent("latest-pace-acid.json")
        let invalidPaceAcidURL = directory.appendingPathComponent("invalid-pace-acid.json")
        let missingCalibrationURL = directory.appendingPathComponent("missing-summary.json")
        let missingPaceAcidURL = directory.appendingPathComponent("missing-pace-acid.json")
        let missingTelemetryURL = directory.appendingPathComponent("missing-decisions.jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: directory) }

            let current = Int64(now.timeIntervalSince1970)
            let privatePrompt = "PRIVATE_PROMPT_SENTINEL"
            let privateResponse = "PRIVATE_RESPONSE_SENTINEL"
            var invalidConductor = conductorFixtureRecord(
                observedAt: current - 300,
                topology: "direct",
                workerCount: 0,
                providerTurns: 1,
                outcome: "verified-success",
                inputTokens: 100,
                outputTokens: 25,
                durationMs: 4_000
            )
            invalidConductor["total_tokens"] = 126
            let fixtures: [[String: Any]] = [
                conductorFixtureRecord(
                    observedAt: current - 60,
                    topology: "direct",
                    workerCount: 0,
                    providerTurns: 1,
                    outcome: "verified-success",
                    inputTokens: 100,
                    outputTokens: 25,
                    durationMs: 1_000,
                    extras: ["prompt": privatePrompt, "response": privateResponse]
                ),
                conductorFixtureRecord(
                    observedAt: current - 120,
                    topology: "direct",
                    workerCount: 0,
                    providerTurns: 1,
                    outcome: "quality-failure",
                    inputTokens: 200,
                    outputTokens: 50,
                    durationMs: 3_000,
                    escalations: 1,
                    model: "gpt-5.6-sol",
                    effort: "ultra",
                    impact: "protected"
                ),
                conductorFixtureRecord(
                    observedAt: current - 180,
                    topology: "direct",
                    workerCount: 0,
                    providerTurns: 1,
                    outcome: "verified-success",
                    usageComplete: false,
                    inputTokens: 80,
                    outputTokens: 20,
                    durationMs: 2_000
                ),
                fixtureRecord(
                    observedAt: current - 240,
                    provider: "claude",
                    model: "claude-opus-4-8",
                    effort: "xhigh",
                    impact: "ordinary",
                    outcome: "verified-success",
                    inputTokens: 999,
                    outputTokens: 1,
                    durationMs: 9_000
                ),
                conductorFixtureRecord(
                    observedAt: current - 8 * 86_400,
                    topology: "direct",
                    workerCount: 0,
                    providerTurns: 1,
                    outcome: "verified-success",
                    inputTokens: 999,
                    outputTokens: 999,
                    durationMs: 9_999,
                    extras: ["model_marker": "old-model-that-must-not-appear"]
                ),
                invalidConductor
            ]
            let encoded = try fixtures.map { fixture -> String in
                let data = try JSONSerialization.data(withJSONObject: fixture, options: [.sortedKeys])
                return String(decoding: data, as: UTF8.self)
            }
            try ((encoded + ["not-json"]).joined(separator: "\n") + "\n")
                .write(to: fixtureURL, atomically: true, encoding: .utf8)

            let privateEvidencePath = "/private/PRIVATE_EVIDENCE_PATH_SENTINEL.json"
            let privateThreadID = "PRIVATE_THREAD_ID_SENTINEL"
            let privateModel = "PRIVATE_MODEL_SENTINEL"
            let calibrationFixture: [String: Any] = [
                "schema": 1,
                "case_ref": "fixture-case-1",
                "quality": [
                    "auto_gate_passed": true,
                    "fixed_gate_passed": true,
                    "same_final_tree": true
                ],
                "auto_vs_fixed": [
                    "auto_total_tokens": 600,
                    "fixed_total_tokens": 1_000,
                    "token_savings_percent": 40.0,
                    "auto_duration_ms": 900,
                    "fixed_duration_ms": 1_200
                ],
                "orchestrated": [
                    "accepted": true,
                    "total_tokens": 750,
                    "duration_ms": 1_500,
                    "provider_turns": 3,
                    "worker_count": 2,
                    "token_change_vs_auto_percent": 25.0,
                    "decision": "keep-single-turn"
                ],
                "observed_at": current - 30,
                "evidence_paths": [privateEvidencePath]
            ]
            let calibrationData = try JSONSerialization.data(
                withJSONObject: calibrationFixture,
                options: [.sortedKeys]
            )
            try calibrationData.write(to: calibrationURL, options: .atomic)
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: calibrationURL.path
            )

            let paceAcidFixturePayload = paceAcidFixture(
                observedAt: current - 20,
                privateEvidencePath: privateEvidencePath,
                privateThreadID: privateThreadID,
                privateModel: privateModel
            )
            let paceAcidData = try JSONSerialization.data(
                withJSONObject: paceAcidFixturePayload,
                options: [.sortedKeys]
            )
            try paceAcidData.write(to: paceAcidURL, options: .atomic)
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: paceAcidURL.path
            )

            let invalidPaceAcidFixture = paceAcidFixture(
                observedAt: current - 20,
                privateEvidencePath: privateEvidencePath,
                privateThreadID: privateThreadID,
                privateModel: privateModel,
                normalAggregateTokens: 54_111
            )
            let invalidPaceAcidData = try JSONSerialization.data(
                withJSONObject: invalidPaceAcidFixture,
                options: [.sortedKeys]
            )
            try invalidPaceAcidData.write(to: invalidPaceAcidURL, options: .atomic)
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: invalidPaceAcidURL.path
            )

            let summary = try read(
                url: fixtureURL,
                calibrationURL: calibrationURL,
                paceAcidURL: paceAcidURL,
                now: now
            )
            let rendered = summary.rendered
            guard case .available(let evidence) = summary.calibrationEvidence else {
                return false
            }
            guard case .available(let paceAcidEvidence) = summary.paceAcidEvidence else {
                return false
            }
            let evidenceText = evidence.uiLines.joined(separator: "\n")
            let paceAcidText = paceAcidEvidence.uiLines.joined(separator: "\n")

            let availableWithoutTelemetry = readRendered(
                url: missingTelemetryURL,
                calibrationURL: calibrationURL,
                paceAcidURL: paceAcidURL,
                now: now
            )
            let missingIsPending = readCalibrationEvidence(
                url: missingCalibrationURL,
                now: now
            ) == .pending
            let missingPaceAcidIsPending = readPaceAcidEvidence(
                url: missingPaceAcidURL,
                now: now
            ) == .pending
            let invalidArithmeticIsUnavailable = readPaceAcidEvidence(
                url: invalidPaceAcidURL,
                now: now
            ) == .unavailable
            try manager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: calibrationURL.path
            )
            let unsafeIsUnavailable = readCalibrationEvidence(
                url: calibrationURL,
                now: now
            ) == .unavailable
            try manager.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: paceAcidURL.path
            )
            let unsafePaceAcidIsUnavailable = readPaceAcidEvidence(
                url: paceAcidURL,
                now: now
            ) == .unavailable

            return summary.conductorRuns == 3
                && summary.verifiedRuns == 2
                && summary.completeTreeTokenRuns == 2
                && summary.completeTreeTokens == 375
                && summary.providerTurns == 3
                && summary.topologyCounts == ["direct": 3]
                && summary.workerCount == 0
                && summary.workerCounts == ["0": 3]
                && summary.escalations == 1
                && summary.routeStageCounts == ["conductor": 3]
                && summary.historicalSchema1Turns == 1
                && summary.validTurns == 3
                && summary.verifiedSuccesses == 2
                && summary.tokenUsageTurns == 2
                && summary.observedTokens == 375
                && summary.nonFrontierRoutes == 2
                && summary.protectedFloorViolations == 0
                && summary.modelCounts == ["gpt-5.6-sol": 1, "gpt-5.6-terra": 2]
                && summary.medianDurationMs == 2_000
                && summary.matchedCalibrationCases == 1
                && evidence.acceptedCaseCount == 1
                && evidence.autoTokenSavingsPercent == 40
                && evidence.autoQualityMatched
                && evidence.orchestratedAccepted
                && evidence.orchestratedTokenChangeVsAutoPercent == 25
                && evidence.orchestratedDecision == "keep-single-turn"
                && evidence.observedAt == Date(timeIntervalSince1970: Double(current - 30))
                && evidence.uiLines.count == 4
                && evidenceText.contains("Calibration: 1 accepted case")
                && evidenceText.contains("Auto vs fixed: 40% fewer tokens; quality matched")
                && evidenceText.contains("Orchestration: 25% token overhead vs Auto; accepted; keep-single-turn")
                && evidenceText.contains("Evidence: ")
                && evidenceText.contains("UTC")
                && paceAcidEvidence.qualityPassed
                && paceAcidEvidence.acceptedCases == 3
                && paceAcidEvidence.requiredCases == 3
                && !paceAcidEvidence.tokenGradientPassed
                && paceAcidEvidence.cacheComparability == "imbalanced"
                && !paceAcidEvidence.productionCalibrationSufficient
                && paceAcidEvidence.noRush.observedTokens == 59_828
                && paceAcidEvidence.normal.observedTokens == 54_112
                && paceAcidEvidence.live.observedTokens == 47_271
                && paceAcidEvidence.noRush.providerDurationMs == 211_560
                && paceAcidEvidence.normal.providerDurationMs == 150_551
                && paceAcidEvidence.live.providerDurationMs == 87_141
                && paceAcidEvidence.noRushToNormalTokenReductionPercent == 9.55
                && paceAcidEvidence.normalToLiveTokenReductionPercent == 12.64
                && paceAcidText.contains("Quality parity: PASS 3/3, this corpus only")
                && paceAcidText.contains("No rush 211,560 ms")
                && paceAcidText.contains("Normal 150,551 ms (28.84% faster)")
                && paceAcidText.contains("Live 87,141 ms (42.12% faster than Normal)")
                && paceAcidText.contains("No rush 59,828 | Normal 54,112 | Live 47,271")
                && paceAcidText.contains("Strict token gradient: FAIL (9.55%, then 12.64%; 10% required each)")
                && paceAcidText.contains("Cache comparability: imbalanced; production calibration: insufficient")
                && rendered.contains("calibration_evidence=available")
                && rendered.contains("calibration_accepted_cases=1")
                && rendered.contains("calibration_auto_vs_fixed_token_savings_percent=40")
                && rendered.contains("calibration_auto_quality_match=true")
                && rendered.contains("calibration_orchestrated_accepted=true")
                && rendered.contains("calibration_orchestrated_token_change_vs_auto_percent=25")
                && rendered.contains("calibration_orchestrated_decision=keep-single-turn")
                && rendered.contains("pace_acid_evidence=available")
                && rendered.contains("pace_acid_quality_parity=pass")
                && rendered.contains("pace_acid_quality_cases=3/3")
                && rendered.contains("pace_acid_no_rush_duration_ms=211560")
                && rendered.contains("pace_acid_normal_duration_ms=150551")
                && rendered.contains("pace_acid_live_duration_ms=87141")
                && rendered.contains("pace_acid_no_rush_tokens=59828")
                && rendered.contains("pace_acid_normal_tokens=54112")
                && rendered.contains("pace_acid_live_tokens=47271")
                && rendered.contains("pace_acid_token_gradient=fail")
                && rendered.contains("pace_acid_no_rush_to_normal_reduction_percent=9.6")
                && rendered.contains("pace_acid_normal_to_live_reduction_percent=12.6")
                && rendered.contains("pace_acid_cache_comparability=imbalanced")
                && rendered.contains("pace_acid_production_calibration=insufficient")
                && rendered.contains("pace_acid_claim_scope=three-case-corpus-only")
                && rendered.contains("sesh_measurement_scope=conductor-schema-2-only")
                && rendered.contains("conductor_runs=3")
                && rendered.contains("verified_runs=2")
                && rendered.contains("complete_tree_token_coverage=2/3 (66.7%)")
                && rendered.contains("complete_tree_tokens=375")
                && rendered.contains("provider_turns=3")
                && rendered.contains("topology_counts={\"direct\":3}")
                && rendered.contains("worker_count=0")
                && rendered.contains("worker_counts={\"0\":3}")
                && rendered.contains("escalations=1")
                && rendered.contains("route_stage_counts={\"conductor\":3}")
                && rendered.contains("historical_schema1_turns=1")
                && rendered.contains("credits_and_quota_measurement=unobservable")
                && availableWithoutTelemetry.contains("sesh_proof_status=unavailable")
                && availableWithoutTelemetry.contains("calibration_evidence=available")
                && availableWithoutTelemetry.contains("pace_acid_evidence=available")
                && missingIsPending
                && missingPaceAcidIsPending
                && unsafeIsUnavailable
                && unsafePaceAcidIsUnavailable
                && invalidArithmeticIsUnavailable
                && !rendered.contains(privatePrompt)
                && !rendered.contains(privateResponse)
                && !rendered.contains(privateEvidencePath)
                && !rendered.contains(privateThreadID)
                && !rendered.contains(privateModel)
                && !availableWithoutTelemetry.contains(privateEvidencePath)
                && !evidenceText.contains(privateEvidencePath)
                && !paceAcidText.contains(privateEvidencePath)
                && !paceAcidText.contains(privateThreadID)
                && !paceAcidText.contains(privateModel)
                && !rendered.contains("old-model-that-must-not-appear")
        } catch {
            return false
        }
    }

    private static func decodeCalibrationEvidence(
        url: URL,
        now: Date
    ) throws -> SeshCalibrationEvidence {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maxCalibrationBytes else {
            throw SeshMeasurementError.unsafeFile
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o400 != 0,
              permissions & 0o077 == 0 else {
            throw SeshMeasurementError.unsafeFile
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxCalibrationBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maxCalibrationBytes else {
            throw SeshMeasurementError.unsafeFile
        }

        let record = try JSONDecoder().decode(SeshCalibrationRecord.self, from: data)
        guard record.schema == 1,
              safeSingleLine(record.caseRef, maximumUTF8Bytes: 128),
              positiveMetric(record.autoVsFixed.autoTotalTokens),
              positiveMetric(record.autoVsFixed.fixedTotalTokens),
              positiveMetric(record.autoVsFixed.autoDurationMs),
              positiveMetric(record.autoVsFixed.fixedDurationMs),
              positiveMetric(record.orchestrated.totalTokens),
              positiveMetric(record.orchestrated.durationMs),
              (1...100).contains(record.orchestrated.providerTurns),
              (1...100).contains(record.orchestrated.workerCount),
              record.orchestrated.providerTurns >= record.orchestrated.workerCount,
              safeSingleLine(record.orchestrated.decision, maximumUTF8Bytes: 160),
              !record.evidencePaths.isEmpty,
              record.evidencePaths.count <= 64,
              record.evidencePaths.allSatisfy({ safeSingleLine($0, maximumUTF8Bytes: 4_096) }),
              record.observedAt > 0,
              record.observedAt <= Int64(now.addingTimeInterval(futureClockSkew).timeIntervalSince1970) else {
            throw SeshMeasurementError.unsafeFile
        }

        let computedSavings = 100 * (
            Double(record.autoVsFixed.fixedTotalTokens - record.autoVsFixed.autoTotalTokens)
                / Double(record.autoVsFixed.fixedTotalTokens)
        )
        let computedOrchestrationChange = 100 * (
            Double(record.orchestrated.totalTokens - record.autoVsFixed.autoTotalTokens)
                / Double(record.autoVsFixed.autoTotalTokens)
        )
        guard record.autoVsFixed.tokenSavingsPercent.isFinite,
              record.orchestrated.tokenChangeVsAutoPercent.isFinite,
              abs(record.autoVsFixed.tokenSavingsPercent - computedSavings) <= 0.2,
              abs(record.orchestrated.tokenChangeVsAutoPercent - computedOrchestrationChange) <= 0.2 else {
            throw SeshMeasurementError.unsafeFile
        }

        let qualityMatched = record.quality.autoGatePassed
            && record.quality.fixedGatePassed
            && record.quality.sameFinalTree
        return SeshCalibrationEvidence(
            acceptedCaseCount: qualityMatched ? 1 : 0,
            autoTokenSavingsPercent: record.autoVsFixed.tokenSavingsPercent,
            autoQualityMatched: qualityMatched,
            orchestratedAccepted: record.orchestrated.accepted,
            orchestratedTokenChangeVsAutoPercent: record.orchestrated.tokenChangeVsAutoPercent,
            orchestratedDecision: record.orchestrated.decision,
            observedAt: Date(timeIntervalSince1970: Double(record.observedAt))
        )
    }

    private static func decodePaceAcidEvidence(
        url: URL,
        now: Date
    ) throws -> SeshPaceAcidEvidence {
        let data = try privateEvidenceData(url: url)
        let record = try JSONDecoder().decode(SeshPaceAcidRecord.self, from: data)
        guard record.schema == 1,
              record.experiment == "pace-acid-test-v1",
              record.usageScope == "fresh-thread-cumulative-total",
              record.executionProfile == "code-local-lean",
              record.threadLifecycle
                == "nine-fresh-persistent-multi-agent-disabled-then-archived",
              record.caseCount == 3,
              record.paceCount == 3,
              record.providerTurns == record.caseCount * record.paceCount,
              record.observedAt > 0,
              record.observedAt <= Int64(now.addingTimeInterval(futureClockSkew).timeIntervalSince1970),
              record.verdict.claimScope == "practical-separation-one-run-per-cell",
              record.verdict.productionCalibration == "insufficient" else {
            throw SeshMeasurementError.unsafeFile
        }

        let paceAggregates = [
            record.byPace.noRush,
            record.byPace.normal,
            record.byPace.live
        ]
        guard paceAggregates.allSatisfy({ aggregate in
            (0...record.caseCount).contains(aggregate.acceptedCases)
                && positiveMetric(aggregate.providerDurationMs)
                && positiveMetric(aggregate.usage.inputTokens)
                && optionalNonnegativeMetric(aggregate.usage.cachedInputTokens)
                && (aggregate.usage.cachedInputTokens ?? 0) <= aggregate.usage.inputTokens
                && positiveMetric(aggregate.usage.outputTokens)
                && optionalNonnegativeMetric(aggregate.usage.reasoningOutputTokens)
                && (aggregate.usage.reasoningOutputTokens ?? 0) <= aggregate.usage.outputTokens
                && positiveMetric(aggregate.usage.totalTokens)
                && aggregate.usage.totalTokens
                    == aggregate.usage.inputTokens + aggregate.usage.outputTokens
        }) else {
            throw SeshMeasurementError.unsafeFile
        }

        let quality = record.verdict.qualityParity
        let qualityPassed = quality.acceptedCases == quality.requiredCases
        guard quality.requiredCases == record.caseCount,
              (0...quality.requiredCases).contains(quality.acceptedCases),
              quality.externalBehavioralGateCases == quality.acceptedCases,
              (0...quality.requiredCases).contains(quality.sameFinalTreeCases),
              quality.status == (qualityPassed ? "pass" : "fail"),
              paceAggregates.allSatisfy({ $0.acceptedCases >= quality.acceptedCases }) else {
            throw SeshMeasurementError.unsafeFile
        }

        let gradient = record.verdict.tokenGradient
        let aggregateTokens = gradient.aggregateTokens
        let byPaceTokens = [
            record.byPace.noRush.usage.totalTokens,
            record.byPace.normal.usage.totalTokens,
            record.byPace.live.usage.totalTokens
        ]
        guard [aggregateTokens.noRush, aggregateTokens.normal, aggregateTokens.live]
                == byPaceTokens,
              gradient.materialThresholdPercent.isFinite,
              gradient.materialThresholdPercent > 0,
              gradient.materialThresholdPercent <= 100,
              positiveMetric(gradient.materialThresholdTokens),
              gradient.aggregateReductions.allFinite,
              gradient.geometricMeans.allFinite,
              gradient.perCase.count == record.caseCount,
              gradient.perCase.keys.allSatisfy({ safeSingleLine($0, maximumUTF8Bytes: 160) }),
              gradient.materialInversions.count <= record.caseCount * 2,
              gradient.materialInversions.allSatisfy({ safeSingleLine($0, maximumUTF8Bytes: 220) }) else {
            throw SeshMeasurementError.unsafeFile
        }

        let expectedNoRushToNormal = reductionPercent(
            high: aggregateTokens.noRush,
            low: aggregateTokens.normal
        )
        let expectedNormalToLive = reductionPercent(
            high: aggregateTokens.normal,
            low: aggregateTokens.live
        )
        let expectedNoRushToLive = reductionPercent(
            high: aggregateTokens.noRush,
            low: aggregateTokens.live
        )
        guard metricMatches(
                gradient.aggregateReductions.noRushToNormalPercent,
                expectedNoRushToNormal
              ),
              metricMatches(
                gradient.aggregateReductions.normalToLivePercent,
                expectedNormalToLive
              ),
              metricMatches(
                gradient.aggregateReductions.noRushToLivePercent,
                expectedNoRushToLive
              ) else {
            throw SeshMeasurementError.unsafeFile
        }

        var acceptedCaseCount = 0
        var endpointMaterialCaseCount = 0
        var expectedInversions: [String] = []
        var perCaseNoRush: [Int64] = []
        var perCaseNormal: [Int64] = []
        var perCaseLive: [Int64] = []
        for (caseRef, entry) in gradient.perCase {
            let tokens = entry.tokens
            guard positiveMetric(tokens.noRush),
                  positiveMetric(tokens.normal),
                  positiveMetric(tokens.live),
                  entry.noRushToLiveReductionPercent.isFinite,
                  metricMatches(
                    entry.noRushToLiveReductionPercent,
                    reductionPercent(high: tokens.noRush, low: tokens.live)
                  ) else {
                throw SeshMeasurementError.unsafeFile
            }
            if entry.acceptedAllPaces { acceptedCaseCount += 1 }
            let endpointMaterial = materialReduction(
                high: tokens.noRush,
                low: tokens.live,
                percentThreshold: gradient.materialThresholdPercent,
                tokenThreshold: gradient.materialThresholdTokens
            )
            guard entry.materialNoRushToLiveReduction == endpointMaterial else {
                throw SeshMeasurementError.unsafeFile
            }
            if endpointMaterial { endpointMaterialCaseCount += 1 }
            if materialInversion(
                expectedHigh: tokens.noRush,
                expectedLow: tokens.normal,
                percentThreshold: gradient.materialThresholdPercent,
                tokenThreshold: gradient.materialThresholdTokens
            ) {
                expectedInversions.append(caseRef + ":normal-over-no-rush")
            }
            if materialInversion(
                expectedHigh: tokens.normal,
                expectedLow: tokens.live,
                percentThreshold: gradient.materialThresholdPercent,
                tokenThreshold: gradient.materialThresholdTokens
            ) {
                expectedInversions.append(caseRef + ":live-over-normal")
            }
            perCaseNoRush.append(tokens.noRush)
            perCaseNormal.append(tokens.normal)
            perCaseLive.append(tokens.live)
        }

        guard acceptedCaseCount == quality.acceptedCases,
              endpointMaterialCaseCount == gradient.endpointMaterialCases,
              expectedInversions.sorted() == gradient.materialInversions.sorted(),
              perCaseNoRush.reduce(0, +) == aggregateTokens.noRush,
              perCaseNormal.reduce(0, +) == aggregateTokens.normal,
              perCaseLive.reduce(0, +) == aggregateTokens.live else {
            throw SeshMeasurementError.unsafeFile
        }

        let expectedGeometricMeans = SeshPaceAcidRecord.PaceDoubles(
            noRush: geometricMean(perCaseNoRush),
            normal: geometricMean(perCaseNormal),
            live: geometricMean(perCaseLive)
        )
        guard metricMatches(gradient.geometricMeans.noRush, expectedGeometricMeans.noRush),
              metricMatches(gradient.geometricMeans.normal, expectedGeometricMeans.normal),
              metricMatches(gradient.geometricMeans.live, expectedGeometricMeans.live) else {
            throw SeshMeasurementError.unsafeFile
        }

        let gradientPassed = expectedInversions.isEmpty
            && endpointMaterialCaseCount >= 2
            && materialReduction(
                high: aggregateTokens.noRush,
                low: aggregateTokens.normal,
                percentThreshold: gradient.materialThresholdPercent,
                tokenThreshold: gradient.materialThresholdTokens
            )
            && materialReduction(
                high: aggregateTokens.normal,
                low: aggregateTokens.live,
                percentThreshold: gradient.materialThresholdPercent,
                tokenThreshold: gradient.materialThresholdTokens
            )
            && expectedGeometricMeans.noRush >= expectedGeometricMeans.normal
            && expectedGeometricMeans.normal >= expectedGeometricMeans.live
        guard gradient.status == (gradientPassed ? "pass" : "fail"),
              record.verdict.overall == (qualityPassed && gradientPassed ? "pass" : "fail") else {
            throw SeshMeasurementError.unsafeFile
        }

        let cache = record.verdict.cacheComparability
        guard Set(cache.perCase.keys) == Set(gradient.perCase.keys) else {
            throw SeshMeasurementError.unsafeFile
        }
        var cacheImbalanced = false
        var cacheUnknown = false
        for entry in cache.perCase.values {
            let shares = entry.cachedInputSharePercent
            guard Set(shares.keys).isSubset(of: ["no-rush", "normal", "live"]),
                  shares.values.allSatisfy({ $0.isFinite && 0...100 ~= $0 }) else {
                throw SeshMeasurementError.unsafeFile
            }
            if shares.count == 3 {
                guard let reportedSpread = entry.spreadPoints, reportedSpread.isFinite else {
                    throw SeshMeasurementError.unsafeFile
                }
                let spread = roundedTwo(shares.values.max()! - shares.values.min()!)
                guard metricMatches(reportedSpread, spread) else {
                    throw SeshMeasurementError.unsafeFile
                }
                if spread > 10 { cacheImbalanced = true }
            } else {
                guard entry.spreadPoints == nil else {
                    throw SeshMeasurementError.unsafeFile
                }
                cacheUnknown = true
            }
        }
        let expectedCacheStatus = cacheImbalanced
            ? "imbalanced"
            : cacheUnknown ? "unknown" : "comparable"
        guard cache.status == expectedCacheStatus else {
            throw SeshMeasurementError.unsafeFile
        }

        return SeshPaceAcidEvidence(
            qualityPassed: qualityPassed,
            acceptedCases: quality.acceptedCases,
            requiredCases: quality.requiredCases,
            tokenGradientPassed: gradientPassed,
            cacheComparability: expectedCacheStatus,
            productionCalibrationSufficient: false,
            noRush: SeshPaceAcidEvidence.PaceResult(
                observedTokens: aggregateTokens.noRush,
                providerDurationMs: record.byPace.noRush.providerDurationMs
            ),
            normal: SeshPaceAcidEvidence.PaceResult(
                observedTokens: aggregateTokens.normal,
                providerDurationMs: record.byPace.normal.providerDurationMs
            ),
            live: SeshPaceAcidEvidence.PaceResult(
                observedTokens: aggregateTokens.live,
                providerDurationMs: record.byPace.live.providerDurationMs
            ),
            noRushToNormalTokenReductionPercent: expectedNoRushToNormal,
            normalToLiveTokenReductionPercent: expectedNormalToLive,
            observedAt: Date(timeIntervalSince1970: Double(record.observedAt))
        )
    }

    private static func privateEvidenceData(url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maxCalibrationBytes else {
            throw SeshMeasurementError.unsafeFile
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o400 != 0,
              permissions & 0o077 == 0,
              let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value,
              ownerID == getuid() else {
            throw SeshMeasurementError.unsafeFile
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxCalibrationBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maxCalibrationBytes else {
            throw SeshMeasurementError.unsafeFile
        }
        return data
    }

    private static func reductionPercent(high: Int64, low: Int64) -> Double {
        roundedTwo(100 * Double(high - low) / Double(high))
    }

    private static func materialReduction(
        high: Int64,
        low: Int64,
        percentThreshold: Double,
        tokenThreshold: Int64
    ) -> Bool {
        high > 0
            && high - low >= tokenThreshold
            && 100 * Double(high - low) / Double(high) >= percentThreshold
    }

    private static func materialInversion(
        expectedHigh: Int64,
        expectedLow: Int64,
        percentThreshold: Double,
        tokenThreshold: Int64
    ) -> Bool {
        expectedLow > expectedHigh
            && materialReduction(
                high: expectedLow,
                low: expectedHigh,
                percentThreshold: percentThreshold,
                tokenThreshold: tokenThreshold
            )
    }

    private static func geometricMean(_ values: [Int64]) -> Double {
        roundedTwo(exp(values.map { log(Double($0)) }.reduce(0, +) / Double(values.count)))
    }

    private static func roundedTwo(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func metricMatches(_ reported: Double, _ expected: Double) -> Bool {
        reported.isFinite && expected.isFinite && abs(reported - expected) <= 0.011
    }

    private static func formatMetric(_ value: Double) -> String {
        value.rounded() == value
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private static func positiveMetric(_ value: Int64) -> Bool {
        value > 0 && value <= maximumMetricValue
    }

    private static func nonnegativeMetric(_ value: Int64) -> Bool {
        value >= 0 && value <= maximumMetricValue
    }

    private static func optionalNonnegativeMetric(_ value: Int64?) -> Bool {
        guard let value else { return true }
        return nonnegativeMetric(value)
    }

    private static func safeSingleLine(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty
            && value == trimmed
            && value.utf8.count <= maximumUTF8Bytes
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == CocoaError.Code.fileReadNoSuchFile.rawValue
            || cocoa.code == CocoaError.Code.fileNoSuchFile.rawValue {
            return true
        }
        if cocoa.domain == NSPOSIXErrorDomain, cocoa.code == 2 {
            return true
        }
        guard let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isMissingFileError(underlying)
    }

    private static func boundedLines(from url: URL) throws -> [String] {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isSymbolicLink != true else { throw SeshMeasurementError.unsafeFile }
        guard values.isRegularFile == true else { throw SeshMeasurementError.unsafeFile }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > maxReadBytes ? size - maxReadBytes : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else {
            throw SeshMeasurementError.invalidEncoding
        }
        var lines = text.split(whereSeparator: \Character.isNewline).map(String.init)
        if start > 0, !data.starts(with: [0x0A, 0x0D]), !lines.isEmpty {
            lines.removeFirst()
        }
        return Array(lines.suffix(maxLines))
    }

    private static func median(_ values: [Int64]) -> Double? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (Double(values[middle - 1]) + Double(values[middle])) / 2
        }
        return Double(values[middle])
    }

    private static func isFrontier(model: String) -> Bool {
        let normalized = model.lowercased()
        return normalized.contains("sol")
            || normalized.contains("opus")
            || normalized.contains("fable")
    }

    private static func violatesProtectedFloor(_ record: SeshTelemetryRecord) -> Bool {
        guard record.impact == "protected" || record.impact == "irreversible" else {
            return false
        }
        return !isFrontier(model: record.model) || effortRank(record.effort) < effortRank("xhigh")
    }

    private static func effortRank(_ effort: String) -> Int {
        ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
            .firstIndex(of: effort.lowercased()) ?? -1
    }

    private static func conductorFixtureRecord(
        observedAt: Int64,
        topology: String,
        workerCount: Int,
        providerTurns: Int,
        outcome: String,
        usageComplete: Bool = true,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        durationMs: Int64? = nil,
        escalations: Int = 0,
        model: String = "gpt-5.6-terra",
        effort: String = "medium",
        impact: String = "ordinary",
        extras: [String: Any] = [:]
    ) -> [String: Any] {
        var routes: [[String: Any]] = [[
            "stage": "conductor",
            "model": model,
            "effort": effort,
            "service_tier": "default",
            "count": 1
        ]]
        if workerCount > 0 {
            routes.append([
                "stage": "worker",
                "model": "gpt-5.6-terra",
                "effort": "medium",
                "service_tier": "default",
                "count": workerCount
            ])
        }
        var record: [String: Any] = [
            "schema": 2,
            "policy_version": "4.2.0",
            "observed_at": observedAt,
            "provider": "codex",
            "automatic": true,
            "impact": impact,
            "difficulty": "standard",
            "urgency": "normal",
            "recommended_topology": topology,
            "topology": topology,
            "model": model,
            "effort": effort,
            "service_tier": "default",
            "worker_count": workerCount,
            "provider_turns": providerTurns,
            "escalations": escalations,
            "usage_scope": "fresh-thread-tree-cumulative-total",
            "usage_complete": usageComplete,
            "verification": outcome == "verified-success" ? "passed" : "failed",
            "outcome": outcome,
            "routes": routes
        ]
        if let inputTokens, let outputTokens {
            record["input_tokens"] = inputTokens
            record["output_tokens"] = outputTokens
            record["total_tokens"] = inputTokens + outputTokens
        }
        if let durationMs { record["duration_ms"] = durationMs }
        for (key, value) in extras { record[key] = value }
        return record
    }

    private static func fixtureRecord(
        observedAt: Int64,
        provider: String = "codex",
        model: String,
        effort: String,
        impact: String,
        outcome: String,
        inputTokens: Int64? = nil,
        outputTokens: Int64? = nil,
        durationMs: Int64? = nil,
        extras: [String: Any] = [:]
    ) -> [String: Any] {
        var record: [String: Any] = [
            "schema": 1,
            "observed_at": observedAt,
            "provider": provider,
            "model": model,
            "effort": effort,
            "impact": impact,
            "outcome": outcome
        ]
        if let inputTokens { record["input_tokens"] = inputTokens }
        if let outputTokens { record["output_tokens"] = outputTokens }
        if let durationMs { record["duration_ms"] = durationMs }
        for (key, value) in extras { record[key] = value }
        return record
    }

    private static func paceAcidFixture(
        observedAt: Int64,
        privateEvidencePath: String,
        privateThreadID: String,
        privateModel: String,
        normalAggregateTokens: Int64 = 54_112
    ) -> [String: Any] {
        let perCase: [String: Any] = [
            "case-mechanical": [
                "accepted_all_paces": true,
                "same_final_tree": true,
                "tokens": ["no-rush": 17_320, "normal": 17_025, "live": 13_779],
                "no_rush_to_live_reduction_percent": 20.44,
                "material_no_rush_to_live_reduction": true
            ],
            "case-standard": [
                "accepted_all_paces": true,
                "same_final_tree": false,
                "tokens": ["no-rush": 21_359, "normal": 17_720, "live": 15_666],
                "no_rush_to_live_reduction_percent": 26.65,
                "material_no_rush_to_live_reduction": true
            ],
            "case-complex": [
                "accepted_all_paces": true,
                "same_final_tree": false,
                "tokens": ["no-rush": 21_149, "normal": 19_367, "live": 17_826],
                "no_rush_to_live_reduction_percent": 15.71,
                "material_no_rush_to_live_reduction": true
            ]
        ]
        let cachePerCase: [String: Any] = [
            "case-mechanical": [
                "cached_input_share_percent": [
                    "no-rush": 93.71, "normal": 83.34, "live": 98.48
                ],
                "spread_points": 15.14
            ],
            "case-standard": [
                "cached_input_share_percent": [
                    "no-rush": 87.51, "normal": 94.64, "live": 97.04
                ],
                "spread_points": 9.53
            ],
            "case-complex": [
                "cached_input_share_percent": [
                    "no-rush": 96.71, "normal": 94.86, "live": 96.62
                ],
                "spread_points": 1.85
            ]
        ]
        return [
            "schema": 1,
            "experiment": "pace-acid-test-v1",
            "usage_scope": "fresh-thread-cumulative-total",
            "execution_profile": "code-local-lean",
            "thread_lifecycle": "nine-fresh-persistent-multi-agent-disabled-then-archived",
            "case_count": 3,
            "pace_count": 3,
            "provider_turns": 9,
            "by_pace": [
                "no-rush": [
                    "accepted_cases": 3,
                    "provider_duration_ms": 211_560,
                    "usage": [
                        "cached_input_tokens": 54_528,
                        "input_tokens": 58_893,
                        "output_tokens": 935,
                        "reasoning_output_tokens": 566,
                        "total_tokens": 59_828
                    ],
                    "routes": [["model": privateModel]]
                ],
                "normal": [
                    "accepted_cases": 3,
                    "provider_duration_ms": 150_551,
                    "usage": [
                        "cached_input_tokens": 48_896,
                        "input_tokens": 53_637,
                        "output_tokens": 475,
                        "reasoning_output_tokens": 113,
                        "total_tokens": 54_112
                    ]
                ],
                "live": [
                    "accepted_cases": 3,
                    "provider_duration_ms": 87_141,
                    "usage": [
                        "cached_input_tokens": 45_696,
                        "input_tokens": 46_964,
                        "output_tokens": 307,
                        "reasoning_output_tokens": 25,
                        "total_tokens": 47_271
                    ]
                ]
            ],
            "verdict": [
                "quality_parity": [
                    "status": "pass",
                    "accepted_cases": 3,
                    "external_behavioral_gate_cases": 3,
                    "same_final_tree_cases": 1,
                    "required_cases": 3
                ],
                "token_gradient": [
                    "status": "fail",
                    "material_threshold_percent": 10.0,
                    "material_threshold_tokens": 2_000,
                    "endpoint_material_cases": 3,
                    "material_inversions": [],
                    "aggregate_tokens": [
                        "no-rush": 59_828,
                        "normal": normalAggregateTokens,
                        "live": 47_271
                    ],
                    "aggregate_reductions": [
                        "no_rush_to_normal_percent": 9.55,
                        "normal_to_live_percent": 12.64,
                        "no_rush_to_live_percent": 20.99
                    ],
                    "case_normalized_geometric_mean_tokens": [
                        "no-rush": 19_852.09,
                        "normal": 18_011.0,
                        "live": 15_670.27
                    ],
                    "per_case": perCase
                ],
                "cache_comparability": [
                    "status": "imbalanced",
                    "per_case": cachePerCase
                ],
                "overall": "fail",
                "claim_scope": "practical-separation-one-run-per-cell",
                "production_calibration": "insufficient"
            ],
            "observed_at": observedAt,
            "workspaces_retained": false,
            "result_path": privateEvidencePath,
            "run_id": privateThreadID,
            "private_prompt": "PRIVATE_PROMPT_SENTINEL"
        ]
    }

    private struct SeshTelemetryRecord: Decodable {
        let schema: Int
        let policyVersion: String?
        let observedAt: Int64
        let provider: String
        let automatic: Bool?
        let impact: String
        let difficulty: String?
        let urgency: String?
        let recommendedTopology: String?
        let topology: String?
        let model: String
        let effort: String
        let serviceTier: String?
        let workerCount: Int?
        let providerTurns: Int?
        let escalations: Int?
        let usageScope: String?
        let usageComplete: Bool?
        let outcome: String
        let verification: String?
        let inputTokens: Int64?
        let cachedInputTokens: Int64?
        let outputTokens: Int64?
        let reasoningOutputTokens: Int64?
        let totalTokens: Int64?
        let durationMs: Int64?
        let routes: [Route]?

        enum CodingKeys: String, CodingKey {
            case schema
            case policyVersion = "policy_version"
            case observedAt = "observed_at"
            case provider
            case automatic
            case impact
            case difficulty
            case urgency
            case recommendedTopology = "recommended_topology"
            case topology
            case model
            case effort
            case serviceTier = "service_tier"
            case workerCount = "worker_count"
            case providerTurns = "provider_turns"
            case escalations
            case usageScope = "usage_scope"
            case usageComplete = "usage_complete"
            case outcome
            case verification
            case inputTokens = "input_tokens"
            case cachedInputTokens = "cached_input_tokens"
            case outputTokens = "output_tokens"
            case reasoningOutputTokens = "reasoning_output_tokens"
            case totalTokens = "total_tokens"
            case durationMs = "duration_ms"
            case routes
        }

        var isConductor: Bool { schema == 2 }
        var isHistorical: Bool { schema == 1 }
        var hasCompleteTreeUsage: Bool {
            isConductor && usageComplete == true && totalTokens != nil
        }

        var isValid: Bool {
            switch schema {
            case 1: return isValidHistorical
            case 2: return isValidConductor
            default: return false
            }
        }

        private var isValidHistorical: Bool {
            ["codex", "claude"].contains(provider)
                && ["ordinary", "consequential", "protected", "irreversible"].contains(impact)
                && safeText(model, maximumUTF8Bytes: 100)
                && safeText(effort, maximumUTF8Bytes: 24)
                && safeText(outcome, maximumUTF8Bytes: 64)
                && metricIsValid(inputTokens)
                && metricIsValid(outputTokens)
                && metricIsValid(durationMs)
        }

        private var isValidConductor: Bool {
            guard policyVersion == "4.2.0",
                  provider == "codex",
                  automatic == true,
                  ["ordinary", "consequential", "protected", "irreversible"].contains(impact),
                  let difficulty,
                  ["mechanical", "standard", "complex", "frontier"].contains(difficulty),
                  let urgency,
                  ["relaxed", "normal", "soon", "immediate"].contains(urgency),
                  let recommendedTopology,
                  ["direct", "assisted", "parallel"].contains(recommendedTopology),
                  let topology,
                  ["direct", "assisted", "parallel"].contains(topology),
                  safeText(model, maximumUTF8Bytes: 100),
                  ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort),
                  let serviceTier,
                  ["default", "priority"].contains(serviceTier),
                  let workerCount,
                  (0...2).contains(workerCount),
                  let providerTurns,
                  (1...1_000).contains(providerTurns),
                  (0...2).contains(escalations ?? 0),
                  let usageScope,
                  ["fresh-thread-tree-cumulative-total", "turn-tree-last"].contains(usageScope),
                  let usageComplete,
                  ["verified-success", "quality-failure", "uncertain", "environment-blocker",
                   "context-exceeded", "usage-limit", "server-transient", "safety-stop",
                   "interrupted"].contains(outcome),
                  let verification,
                  ["passed", "failed"].contains(verification),
                  metricIsValid(inputTokens),
                  metricIsValid(cachedInputTokens),
                  metricIsValid(outputTokens),
                  metricIsValid(reasoningOutputTokens),
                  metricIsValid(totalTokens),
                  metricIsValid(durationMs),
                  let routes,
                  !routes.isEmpty,
                  routes.allSatisfy(\.isValid) else {
                return false
            }
            let expectedTopology = workerCount == 0
                ? "direct"
                : workerCount == 1 ? "assisted" : "parallel"
            guard topology == expectedTopology,
                  verification == (outcome == "verified-success" ? "passed" : "failed"),
                  routes.filter({ $0.stage == "conductor" }).reduce(0, { $0 + $1.count }) == 1,
                  routes.filter({ $0.stage == "worker" }).reduce(0, { $0 + $1.count }) == workerCount,
                  tokenTupleIsValid,
                  !usageComplete || totalTokens != nil else {
                return false
            }
            return true
        }

        private var tokenTupleIsValid: Bool {
            let required = [inputTokens, outputTokens, totalTokens]
            if required.allSatisfy({ $0 == nil }) {
                return cachedInputTokens == nil && reasoningOutputTokens == nil
            }
            guard let inputTokens, let outputTokens, let totalTokens,
                  totalTokens == inputTokens + outputTokens,
                  (cachedInputTokens ?? 0) <= inputTokens,
                  (reasoningOutputTokens ?? 0) <= outputTokens else {
                return false
            }
            return true
        }

        private func metricIsValid(_ value: Int64?) -> Bool {
            guard let value else { return true }
            return value >= 0 && value <= SeshMeasurement.maximumMetricValue
        }

        private func safeText(_ value: String, maximumUTF8Bytes: Int) -> Bool {
            !value.isEmpty
                && value.utf8.count <= maximumUTF8Bytes
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.rangeOfCharacter(from: .controlCharacters) == nil
        }

        struct Route: Decodable {
            let stage: String
            let model: String
            let effort: String
            let serviceTier: String
            let count: Int

            enum CodingKeys: String, CodingKey {
                case stage, model, effort, count
                case serviceTier = "service_tier"
            }

            var isValid: Bool {
                ["conductor", "worker", "verification", "synthesis"].contains(stage)
                    && !model.isEmpty
                    && model.utf8.count <= 100
                    && model.rangeOfCharacter(from: .controlCharacters) == nil
                    && ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort)
                    && ["default", "priority"].contains(serviceTier)
                    && (1...100).contains(count)
            }
        }
    }

    private struct SeshCalibrationRecord: Decodable {
        let schema: Int
        let caseRef: String
        let quality: Quality
        let autoVsFixed: AutoVsFixed
        let orchestrated: Orchestrated
        let observedAt: Int64
        let evidencePaths: [String]

        enum CodingKeys: String, CodingKey {
            case schema
            case caseRef = "case_ref"
            case quality
            case autoVsFixed = "auto_vs_fixed"
            case orchestrated
            case observedAt = "observed_at"
            case evidencePaths = "evidence_paths"
        }

        struct Quality: Decodable {
            let autoGatePassed: Bool
            let fixedGatePassed: Bool
            let sameFinalTree: Bool

            enum CodingKeys: String, CodingKey {
                case autoGatePassed = "auto_gate_passed"
                case fixedGatePassed = "fixed_gate_passed"
                case sameFinalTree = "same_final_tree"
            }
        }

        struct AutoVsFixed: Decodable {
            let autoTotalTokens: Int64
            let fixedTotalTokens: Int64
            let tokenSavingsPercent: Double
            let autoDurationMs: Int64
            let fixedDurationMs: Int64

            enum CodingKeys: String, CodingKey {
                case autoTotalTokens = "auto_total_tokens"
                case fixedTotalTokens = "fixed_total_tokens"
                case tokenSavingsPercent = "token_savings_percent"
                case autoDurationMs = "auto_duration_ms"
                case fixedDurationMs = "fixed_duration_ms"
            }
        }

        struct Orchestrated: Decodable {
            let accepted: Bool
            let totalTokens: Int64
            let durationMs: Int64
            let providerTurns: Int
            let workerCount: Int
            let tokenChangeVsAutoPercent: Double
            let decision: String

            enum CodingKeys: String, CodingKey {
                case accepted
                case totalTokens = "total_tokens"
                case durationMs = "duration_ms"
                case providerTurns = "provider_turns"
                case workerCount = "worker_count"
                case tokenChangeVsAutoPercent = "token_change_vs_auto_percent"
                case decision
            }
        }
    }

    private struct SeshPaceAcidRecord: Decodable {
        let schema: Int
        let experiment: String
        let usageScope: String
        let executionProfile: String
        let threadLifecycle: String
        let caseCount: Int
        let paceCount: Int
        let providerTurns: Int
        let byPace: ByPace
        let verdict: Verdict
        let observedAt: Int64
        let workspacesRetained: Bool

        enum CodingKeys: String, CodingKey {
            case schema
            case experiment
            case usageScope = "usage_scope"
            case executionProfile = "execution_profile"
            case threadLifecycle = "thread_lifecycle"
            case caseCount = "case_count"
            case paceCount = "pace_count"
            case providerTurns = "provider_turns"
            case byPace = "by_pace"
            case verdict
            case observedAt = "observed_at"
            case workspacesRetained = "workspaces_retained"
        }

        struct ByPace: Decodable {
            let noRush: PaceAggregate
            let normal: PaceAggregate
            let live: PaceAggregate

            enum CodingKeys: String, CodingKey {
                case noRush = "no-rush"
                case normal
                case live
            }
        }

        struct PaceAggregate: Decodable {
            let acceptedCases: Int
            let providerDurationMs: Int64
            let usage: Usage

            enum CodingKeys: String, CodingKey {
                case acceptedCases = "accepted_cases"
                case providerDurationMs = "provider_duration_ms"
                case usage
            }
        }

        struct Usage: Decodable {
            let cachedInputTokens: Int64?
            let inputTokens: Int64
            let outputTokens: Int64
            let reasoningOutputTokens: Int64?
            let totalTokens: Int64

            enum CodingKeys: String, CodingKey {
                case cachedInputTokens = "cached_input_tokens"
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case reasoningOutputTokens = "reasoning_output_tokens"
                case totalTokens = "total_tokens"
            }
        }

        struct Verdict: Decodable {
            let qualityParity: QualityParity
            let tokenGradient: TokenGradient
            let cacheComparability: CacheComparability
            let overall: String
            let claimScope: String
            let productionCalibration: String

            enum CodingKeys: String, CodingKey {
                case qualityParity = "quality_parity"
                case tokenGradient = "token_gradient"
                case cacheComparability = "cache_comparability"
                case overall
                case claimScope = "claim_scope"
                case productionCalibration = "production_calibration"
            }
        }

        struct QualityParity: Decodable {
            let status: String
            let acceptedCases: Int
            let externalBehavioralGateCases: Int
            let sameFinalTreeCases: Int
            let requiredCases: Int

            enum CodingKeys: String, CodingKey {
                case status
                case acceptedCases = "accepted_cases"
                case externalBehavioralGateCases = "external_behavioral_gate_cases"
                case sameFinalTreeCases = "same_final_tree_cases"
                case requiredCases = "required_cases"
            }
        }

        struct TokenGradient: Decodable {
            let status: String
            let materialThresholdPercent: Double
            let materialThresholdTokens: Int64
            let endpointMaterialCases: Int
            let materialInversions: [String]
            let aggregateTokens: PaceTokens
            let aggregateReductions: Reductions
            let geometricMeans: PaceDoubles
            let perCase: [String: PerCase]

            enum CodingKeys: String, CodingKey {
                case status
                case materialThresholdPercent = "material_threshold_percent"
                case materialThresholdTokens = "material_threshold_tokens"
                case endpointMaterialCases = "endpoint_material_cases"
                case materialInversions = "material_inversions"
                case aggregateTokens = "aggregate_tokens"
                case aggregateReductions = "aggregate_reductions"
                case geometricMeans = "case_normalized_geometric_mean_tokens"
                case perCase = "per_case"
            }
        }

        struct PaceTokens: Decodable {
            let noRush: Int64
            let normal: Int64
            let live: Int64

            enum CodingKeys: String, CodingKey {
                case noRush = "no-rush"
                case normal
                case live
            }
        }

        struct PaceDoubles: Decodable {
            let noRush: Double
            let normal: Double
            let live: Double

            enum CodingKeys: String, CodingKey {
                case noRush = "no-rush"
                case normal
                case live
            }

            var allFinite: Bool {
                noRush.isFinite && normal.isFinite && live.isFinite
            }
        }

        struct Reductions: Decodable {
            let noRushToNormalPercent: Double
            let normalToLivePercent: Double
            let noRushToLivePercent: Double

            enum CodingKeys: String, CodingKey {
                case noRushToNormalPercent = "no_rush_to_normal_percent"
                case normalToLivePercent = "normal_to_live_percent"
                case noRushToLivePercent = "no_rush_to_live_percent"
            }

            var allFinite: Bool {
                noRushToNormalPercent.isFinite
                    && normalToLivePercent.isFinite
                    && noRushToLivePercent.isFinite
            }
        }

        struct PerCase: Decodable {
            let acceptedAllPaces: Bool
            let sameFinalTree: Bool
            let tokens: PaceTokens
            let noRushToLiveReductionPercent: Double
            let materialNoRushToLiveReduction: Bool

            enum CodingKeys: String, CodingKey {
                case acceptedAllPaces = "accepted_all_paces"
                case sameFinalTree = "same_final_tree"
                case tokens
                case noRushToLiveReductionPercent = "no_rush_to_live_reduction_percent"
                case materialNoRushToLiveReduction = "material_no_rush_to_live_reduction"
            }
        }

        struct CacheComparability: Decodable {
            let status: String
            let perCase: [String: CacheCase]

            enum CodingKeys: String, CodingKey {
                case status
                case perCase = "per_case"
            }
        }

        struct CacheCase: Decodable {
            let cachedInputSharePercent: [String: Double]
            let spreadPoints: Double?

            enum CodingKeys: String, CodingKey {
                case cachedInputSharePercent = "cached_input_share_percent"
                case spreadPoints = "spread_points"
            }
        }
    }
}

private enum SeshMeasurementError: Error {
    case unsafeFile
    case invalidEncoding

    var safeReason: String {
        switch self {
        case .unsafeFile: return "unsafe-file"
        case .invalidEncoding: return "invalid-encoding"
        }
    }
}
