import AppKit
import SwiftUI
import Foundation
import Combine

let homeURL = FileManager.default.homeDirectoryForCurrentUser

enum ProductIdentity {
    static let displayName = "Pace"
    static var subtitleLocal: String { LocalMode.isCodexOnly ? "Codex usage monitor" : "AI pace monitor" }
    static let subtitleAppStore = "Snapshot monitor"
    static let legacyICloudFolderName = "Pace"
    static let installedAppPath = "/Applications/Pace.app"
}

enum PaceTheme {
    static let panel = Color(red: 0.09, green: 0.11, blue: 0.14)
    static let card = Color(red: 0.13, green: 0.15, blue: 0.19)
    static let cardAlt = Color(red: 0.16, green: 0.18, blue: 0.23)
    static let stroke = Color.white.opacity(0.08)
    static let teal = Color(red: 0.18, green: 0.78, blue: 0.70)
    static let amber = Color(red: 0.94, green: 0.72, blue: 0.30)
    static let coral = Color(red: 0.94, green: 0.34, blue: 0.31)
    static let blue = Color(red: 0.34, green: 0.58, blue: 0.96)
    static let green = Color(red: 0.36, green: 0.78, blue: 0.45)
    static let muted = Color(red: 0.62, green: 0.67, blue: 0.75)
}

enum RefreshCadence {
    static var renderRefresh: TimeInterval { LocalMode.isCodexOnly ? 1.0 : 0.025 }
    static var livePaceRefresh: TimeInterval { LocalMode.isCodexOnly ? 10.0 : 0.25 }
    static var fullRefresh: TimeInterval { LocalMode.isCodexOnly ? 60.0 : 30.0 }
    static var feedRefreshIfOlderThan: TimeInterval { LocalMode.isCodexOnly ? 30.0 : 20.0 }
}

enum DistributionMode {
    #if APPSTORE
    static let isAppStore = true
    static let label = "app-store"
    #else
    static let isAppStore = false
    static let label = "local"
    #endif
}

enum LocalMode {
    static var isCodexOnly: Bool {
        guard !DistributionMode.isAppStore else { return false }
        if let value = ProcessInfo.processInfo.environment["PACE_CODEX_ONLY"] {
            return ["1", "true", "yes", "enabled"].contains(value.lowercased())
        }
        if UserDefaults.standard.object(forKey: "CodexOnly") != nil {
            return UserDefaults.standard.bool(forKey: "CodexOnly")
        }
        return true
    }

    static var sourceKind: String {
        isCodexOnly ? "local-codex-only" : "local"
    }

    static var sourceLabel: String {
        isCodexOnly ? "Local Codex usage" : "Local Mac integrations"
    }
}

struct PaceSnapshot {
    var generatedAt: Date = Date()
    var sourceKind: String = DistributionMode.isAppStore ? "review-sample" : "local"
    var sourceLabel: String = DistributionMode.isAppStore ? "Bundled review sample" : "Local integrations"
    var sourceGeneratedAt: Date? = nil
    var sourceIsSample: Bool = DistributionMode.isAppStore
    var quotas: [QuotaReading] = []
    var burnRates: [BurnReading] = []
    var sessions: [SessionReading] = []
    var history: HistoryReading = .empty
    var system: SystemReading = .empty
    var todos: TodoReading = .empty
    var sync: SyncReading = .empty
    var alerts: [String] = []
    var codexResetsAvailable: Int? = nil
    var codexResetsExpireAt: Date? = nil
    var codexResetsExpiries: [Date] = []
    var codexResetsDetail: [ResetCredit] = []
    var codexResetsHistory: [ResetCredit] = []

    static func collect(refreshFeeds: Bool = false, includeSlowReadings: Bool = true, previous: PaceSnapshot? = nil, statusOnly: Bool = false) -> PaceSnapshot {
        if DistributionMode.isAppStore {
            return AppStoreSnapshotReader.read()
        }

        if refreshFeeds {
            QuotaFeedRefresher.refreshLocalFeedsIfNeeded()
        }

        var snapshot = PaceSnapshot()
        snapshot.sourceKind = LocalMode.sourceKind
        snapshot.sourceLabel = LocalMode.sourceLabel
        snapshot.sourceGeneratedAt = Date()
        snapshot.sourceIsSample = false
        if LocalMode.isCodexOnly {
            snapshot.quotas = QuotaReader.read(engine: "Codex", relativePath: ".claude/codex-usage.json", weeklyKey: "secondary")
        } else {
            snapshot.quotas = [
                QuotaReader.read(engine: "Claude", relativePath: ".claude/claude-usage.json", weeklyKey: "weekly"),
                QuotaReader.read(engine: "Codex", relativePath: ".claude/codex-usage.json", weeklyKey: "secondary")
            ].flatMap { $0 }
        }
        let metadata = CodexUsageMetadataReader.read()
        snapshot.codexResetsAvailable = metadata.resetsAvailable
        snapshot.codexResetsExpireAt = metadata.resetsExpireAt
        snapshot.codexResetsExpiries = metadata.resetsExpiries
        snapshot.codexResetsDetail = metadata.resetsDetail
        snapshot.codexResetsHistory = metadata.resetsHistory
        if statusOnly {
            snapshot.burnRates = previous?.burnRates ?? []
            snapshot.sessions = previous?.sessions ?? []
            snapshot.history = previous?.history ?? HistoryReading.empty
        } else {
            snapshot.burnRates = BurnRateReader.read(quotas: snapshot.quotas, scope: includeSlowReadings ? .full : .live)
            let recentSessions = SessionReader.recentSessions(limit: includeSlowReadings ? 160 : 20)
            snapshot.sessions = Array(recentSessions.prefix(10))
            snapshot.history = includeSlowReadings ? HistoryReader.history(from: recentSessions) : (previous?.history ?? HistoryReader.history(from: recentSessions))
        }
        if LocalMode.isCodexOnly {
            snapshot.system = previous?.system ?? SystemReading.empty
            snapshot.todos = previous?.todos ?? TodoReading.empty
            snapshot.sync = previous?.sync ?? SyncReading.empty
        } else if includeSlowReadings {
            snapshot.system = SystemReader.read()
            snapshot.todos = TodoReader.read()
            snapshot.sync = SyncReader.read()
        } else {
            snapshot.system = previous?.system ?? SystemReader.read()
            snapshot.todos = previous?.todos ?? TodoReading.empty
            snapshot.sync = previous?.sync ?? SyncReading.empty
        }
        snapshot.alerts = AlertBuilder.alerts(for: snapshot)
        return snapshot
    }

    var dumpText: String {
        var lines: [String] = []
        lines.append("generated_at=\(DateFormatting.dumpString(generatedAt))")
        lines.append("app_name=\(ProductIdentity.displayName)")
        lines.append("distribution=\(DistributionMode.label)")
        lines.append("mode=\(LocalMode.isCodexOnly ? "codex-only" : "full")")
        lines.append("source kind=\(sourceKind) label=\"\(sourceLabel)\" generated=\(sourceGeneratedAt.map(DateFormatting.dumpString) ?? "unknown") sample=\(sourceIsSample)")
        lines.append("menu_bar=icon=\(LocalMode.isCodexOnly ? "none" : "compact-dial") text_free=\(!LocalMode.isCodexOnly) click=popover")
        lines.append("menu_bar_title=\"\(StatusBarText.codexTitle(for: self))\"")
        for quota in quotas {
            lines.append("quota \(quota.engine) \(quota.window): \(quota.remainingPercentText) / \(quota.usedPercentText) reset=\(quota.resetClockText) countdown=\(quota.resetText) since_reset=\(quota.sinceResetText) pace=\"\(quota.paceText)\" state=\(quota.paceState) source_age=\(quota.sourceAgeText) freshness=\(quota.freshness)")
        }
        lines.append("codex_resets_available=\(codexResetsAvailable.map(String.init) ?? "unknown")")
        lines.append("codex_resets_expire_at=\(codexResetsExpireAt.map(DateFormatting.dumpString) ?? "unknown")")
        lines.append("codex_resets_expiries=\(codexResetsExpiries.isEmpty ? "unknown" : codexResetsExpiries.map(DateFormatting.dumpString).joined(separator: ","))")
        let resetDetail = codexResetsDetail.map { "\($0.label)|granted=\($0.grantedAt.map(DateFormatting.dumpString) ?? "unknown")|expires=\(DateFormatting.dumpString($0.expiresAt))" }.joined(separator: ",")
        lines.append("codex_resets_detail=\(resetDetail.isEmpty ? "unknown" : resetDetail)")
        let resetHistory = codexResetsHistory.map { "\($0.label)|status=\($0.status)|resolved=\($0.resolvedAt.map(DateFormatting.dumpString) ?? "unknown")|expires=\(DateFormatting.dumpString($0.expiresAt))" }.joined(separator: ",")
        lines.append("codex_resets_history=\(resetHistory.isEmpty ? "none" : resetHistory)")
        for burnRate in burnRates {
            lines.append("pace \(burnRate.engine): \(burnRate.tokensText) / \(burnRate.windowDurationText) = \(burnRate.tokensPerMinuteText) quota_pace=\(burnRate.quotaPaceText) cap=\(burnRate.capEstimateText) basis=\"\(burnRate.evidenceText)\" freshness=\(burnRate.freshness)")
        }
        let insightMap = SessionInsightStore.load()
        lines.append("session_insights_cached=\(insightMap.count)")
        for session in sessions {
            if let uuid = SessionInsightStore.uuid(forSessionID: session.id), let ins = insightMap[uuid] {
                lines.append("insight \(uuid.prefix(8)): useful=\(ins.usefulPercent.map(String.init) ?? "?")% \"\(ins.oneLine)\"")
            }
        }
        let graphBuckets = burnRates.map { $0.points.count }.max() ?? 0
        let graphActive = burnRates.reduce(0) { $0 + $1.activeSessions }
        lines.append("pace_graph=buckets=\(graphBuckets) active_sessions=\(graphActive) render_refresh=\(Int(RefreshCadence.renderRefresh * 1000))ms live_ingest=\(Int(RefreshCadence.livePaceRefresh * 1000))ms full_refresh=\(Int(RefreshCadence.fullRefresh))s primary_rate=\"\(burnRates.sorted { $0.tokensPerMinute > $1.tokensPerMinute }.first?.tokensPerMinuteText ?? "idle")\"")
        lines.append("sessions_recent=\(sessions.count)")
        for session in sessions.prefix(5) {
            lines.append("session \(session.source): \"\(session.title)\" workspace=\"\(session.workspace)\" cwd=\"\(session.cwd)\" tokens=\(session.tokens) basis=\"\(session.tokenBasis)\" status=\(session.status)")
        }
        lines.append("history 24h=\(history.sessions24h) sessions \(history.tokens24h) tokens")
        lines.append("sync mode=\(DistributionMode.isAppStore ? "sandbox" : "file") peers=\(sync.peerCount) enabled=\(sync.enabled)")
        lines.append("todos pending=\(todos.pending) active=\(todos.active) deferred=\(todos.deferred)")
        let diskText = DistributionMode.isAppStore ? system.diskFreeGB : "\(system.diskFreeGB)GB free"
        lines.append("system load=\(system.load) disk=\(diskText) power=\"\(system.power)\"")
        lines.append("alerts count=\(alerts.count) first=\"\(alerts.first ?? "clear")\"")
        lines.append("objective_audit=partial")
        return lines.joined(separator: "\n")
    }
}

struct QuotaReading: Identifiable {
    var id: String { "\(engine)-\(window)" }
    let engine: String
    let window: String
    let usedPercent: Double?
    let resetAt: Date?
    let source: String
    let updatedAt: Date?
    var sourceReadingAt: Date? = nil
    var windowMinutes: Double? = nil

    var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    var displayPercent: String {
        remainingPercentText
    }

    var usedPercentText: String {
        guard let usedPercent else { return "unknown used" }
        return "\(Int(usedPercent.rounded()))% used"
    }

    var remainingPercentText: String {
        guard let remainingPercent else { return "unknown" }
        return "\(Int(remainingPercent.rounded()))% left"
    }

    var resetText: String {
        guard let resetAt else { return "unknown" }
        let seconds = max(0, resetAt.timeIntervalSince(Date()))
        if seconds < 60 { return "0m" }
        let hours = Int(seconds / 3600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        }
        return "\(hours)h \(minutes)m"
    }

    var resetClockText: String {
        guard let resetAt else { return "unknown" }
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(resetAt) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "d MMM"
        }
        return formatter.string(from: resetAt)
    }

    var windowDuration: TimeInterval? {
        if let windowMinutes, windowMinutes > 0 { return windowMinutes * 60 }
        switch window {
        case "5h": return 5 * 3600
        case "week": return 7 * 24 * 3600
        default: return nil
        }
    }

    var sinceResetText: String {
        guard let resetAt, let windowDuration else { return "unknown" }
        let elapsed = windowDuration - resetAt.timeIntervalSince(Date())
        guard elapsed >= 0 else { return "unknown" }
        if elapsed < 60 { return "0m" }
        let hours = Int(elapsed / 3600)
        let minutes = Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60)
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours == 0 { return "\(minutes)m" }
        return "\(hours)h \(minutes)m"
    }

    var windowElapsedFraction: Double? {
        guard let resetAt, let windowDuration, windowDuration > 0 else { return nil }
        let remaining = resetAt.timeIntervalSince(Date())
        guard remaining >= 0, remaining <= windowDuration else { return nil }
        return 1 - remaining / windowDuration
    }

    // Usage judged against window position, not absolute level: 90% used
    // minutes before a reset is healthy, 20% used an hour into a week is not.
    // Ratio > 1 projects hitting the cap before the window resets.
    var paceRatio: Double? {
        guard let usedPercent, let elapsed = windowElapsedFraction, elapsed > 0.01 else { return nil }
        return (usedPercent / 100) / elapsed
    }

    var paceText: String {
        guard (usedPercent ?? 0) >= 5 else { return "quiet" }
        guard let paceRatio else { return "" }
        if paceRatio < 0.85 { return "under pace" }
        if paceRatio < 1.15 { return "on pace" }
        return String(format: "%.1f× pace", paceRatio)
    }

    enum PaceState { case unknown, good, hot, critical }

    var paceState: PaceState {
        guard let remaining = remainingPercent, let used = usedPercent else { return .unknown }
        if remaining <= 5 {
            if let resetAt, resetAt.timeIntervalSince(Date()) < 1800 { return .hot }
            return .critical
        }
        if used < 5 { return .good }
        if let paceRatio {
            if paceRatio >= 1.15 { return remaining <= 15 ? .critical : .hot }
            return .good
        }
        if remaining <= 10 { return .critical }
        if remaining <= 30 { return .hot }
        return .good
    }

    var resetDetailText: String {
        guard let resetAt else { return "unknown" }
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(resetAt) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "d MMM HH:mm"
        }
        return "\(formatter.string(from: resetAt)) (\(resetText))"
    }

    var freshness: String {
        guard let measuredAt else { return "missing" }
        let age = Date().timeIntervalSince(measuredAt)
        if age < 90 { return "live" }
        if age < 3 * 60 { return "fresh" }
        if age < 10 * 60 { return "lagging" }
        return "stale"
    }

    var sourceAgeText: String {
        guard let measuredAt else { return "missing" }
        let age = max(0, Date().timeIntervalSince(measuredAt))
        if age < 5 { return "now" }
        if age < 90 { return "\(Int(age))s ago" }
        if age < 60 * 60 { return "\(Int(age / 60))m ago" }
        if age < 24 * 60 * 60 { return "\(Int(age / 3600))h ago" }
        return "\(Int(age / 86400))d ago"
    }

    private var measuredAt: Date? {
        sourceReadingAt ?? updatedAt
    }
}

struct SessionReading: Identifiable {
    let id: String
    let source: String
    let repo: String
    let title: String
    let workspace: String
    let cwd: String
    let model: String
    let status: String
    let tokens: Int
    let tokenBasis: String
    let lastActivity: Date
}

struct SessionInsight {
    let oneLine: String
    let workedOn: String
    let produced: String
    let wasted: String
    let usefulPercent: Int?
}

enum SessionInsightStore {
    // The Python summariser (scripts/session-insight.py) caches results in this
    // file, keyed by the session's internal UUID.
    static let cachePath = homeURL.appendingPathComponent(".claude/pace-session-insights.json")
    // Where the app shells out to for an on-demand summary. Override with
    // PACE_INSIGHT_SCRIPT to point at your clone's scripts/session-insight.py.
    static var scriptPath: URL {
        if let override = ProcessInfo.processInfo.environment["PACE_INSIGHT_SCRIPT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return homeURL.appendingPathComponent(".claude/session-insight.py")
    }

    private static let uuidRegex = try? NSRegularExpression(
        pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

    // A rollout path is …/rollout-<timestamp>-<uuid>.jsonl; the summariser keys
    // its cache by that uuid, so pull it straight from the filename.
    static func uuid(forSessionID id: String) -> String? {
        guard let regex = uuidRegex else { return nil }
        let range = NSRange(id.startIndex..., in: id)
        var last: String?
        regex.enumerateMatches(in: id, range: range) { match, _, _ in
            if let m = match, let r = Range(m.range, in: id) { last = String(id[r]) }
        }
        return last
    }

    static func load() -> [String: SessionInsight] {
        guard
            let data = try? Data(contentsOf: cachePath),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var out: [String: SessionInsight] = [:]
        for (key, value) in object {
            guard let entry = value as? [String: Any] else { continue }
            func str(_ k: String) -> String { (entry[k] as? String) ?? "" }
            var pct: Int? = nil
            if let n = entry["useful_percent"] as? Int { pct = n }
            else if let d = entry["useful_percent"] as? Double { pct = Int(d) }
            else if let s = entry["useful_percent"] as? String { pct = Int(s) }
            out[key] = SessionInsight(
                oneLine: str("one_line"),
                workedOn: str("worked_on"),
                produced: str("produced"),
                wasted: str("wasted"),
                usefulPercent: pct
            )
        }
        return out
    }
}

struct PacePoint: Identifiable {
    var id: TimeInterval { bucketStart.timeIntervalSince1970 }
    let bucketStart: Date
    let tokens: Int
    let bucketSeconds: TimeInterval

    var tokensPerMinute: Double {
        guard bucketSeconds > 0 else { return 0 }
        return Double(tokens) / (bucketSeconds / 60)
    }
}

struct BurnReading: Identifiable {
    var id: String { engine }
    let engine: String
    let tokens: Int
    let tokensPerMinute: Double
    let windowSeconds: TimeInterval
    let quotaPercentPerMinute: Double?
    let remainingPercent: Double?
    let activeSessions: Int
    let lastEventAt: Date?
    let points: [PacePoint]

    var tokensPerMinuteText: String {
        guard tokensPerMinute > 0 else { return "idle" }
        if tokensPerMinute >= 1_000_000 {
            return String(format: "%.1fM tok/min", tokensPerMinute / 1_000_000)
        }
        if tokensPerMinute >= 1_000 {
            return String(format: "%.0fk tok/min", tokensPerMinute / 1_000)
        }
        return "\(Int(tokensPerMinute.rounded())) tok/min"
    }

    var tokensText: String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM tokens", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return String(format: "%.0fk tokens", Double(tokens) / 1_000)
        }
        return "\(tokens) tokens"
    }

    var windowDurationText: String {
        let minutes = max(1, Int((windowSeconds / 60).rounded()))
        return "\(minutes)m"
    }

    var windowText: String {
        "\(windowDurationText) avg"
    }

    var paceEquationText: String {
        "\(tokensText) / \(windowDurationText)"
    }

    var evidenceText: String {
        quotaPercentPerMinute == nil ? "session-log estimate" : "session log + quota delta"
    }

    var peakTokensPerMinute: Double {
        max(tokensPerMinute, points.map(\.tokensPerMinute).max() ?? 0)
    }

    var quotaPaceText: String {
        guard let quotaPercentPerMinute else { return "quota pace n/a" }
        if quotaPercentPerMinute <= 0.01 { return "quota flat" }
        return String(format: "+%.1f pp/min", quotaPercentPerMinute)
    }

    var capEstimateText: String {
        guard let quotaPercentPerMinute, quotaPercentPerMinute > 0.01, let remainingPercent else {
            return tokensPerMinute > 0 ? "cap unknown" : "idle"
        }
        let minutes = remainingPercent / quotaPercentPerMinute
        if minutes < 1 { return "cap <1m" }
        if minutes < 60 { return "cap in \(Int(minutes.rounded()))m" }
        return "cap in \(Int((minutes / 60).rounded()))h"
    }

    var freshness: String {
        guard let lastEventAt else { return "idle" }
        let age = Date().timeIntervalSince(lastEventAt)
        if age < 90 { return "live" }
        if age < 5 * 60 { return "fresh" }
        if age < 15 * 60 { return "cooling" }
        return "idle"
    }
}

struct HistoryReading {
    let sessions24h: Int
    let tokens24h: Int
    let sessions7d: Int
    let tokens7d: Int

    static let empty = HistoryReading(sessions24h: 0, tokens24h: 0, sessions7d: 0, tokens7d: 0)
}

struct SystemReading {
    let load: String
    let diskFreeGB: String
    let power: String

    static let empty = SystemReading(load: "unknown", diskFreeGB: "unknown", power: "unknown")
}

struct TodoReading {
    let pending: Int
    let active: Int
    let deferred: Int

    static let empty = TodoReading(pending: 0, active: 0, deferred: 0)
}

struct SyncReading {
    let enabled: Bool
    let peerCount: Int
    let latestSnapshot: String

    static let empty = SyncReading(enabled: false, peerCount: 0, latestSnapshot: "none")
}

struct ResetCredit {
    let grantedAt: Date?
    let expiresAt: Date
    let label: String
    var status: String = "available"
    var resolvedAt: Date? = nil
}

enum QuotaReader {
    static func read(engine: String, relativePath: String, weeklyKey: String) -> [QuotaReading] {
        let path = homeURL.appendingPathComponent(relativePath)
        guard
            let data = try? Data(contentsOf: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [
                QuotaReading(engine: engine, window: "5h", usedPercent: nil, resetAt: nil, source: path.path, updatedAt: nil),
                QuotaReading(engine: engine, window: "week", usedPercent: nil, resetAt: nil, source: path.path, updatedAt: nil)
            ]
        }

        let updatedAt = DateParsers.any(object["updated_at"])
            ?? DateParsers.any(object["fetched_at"])
        let sourceReadingAt = DateParsers.any(object["source_reading_at"])
            ?? DateParsers.any(object["source_event_ts"])
            ?? updatedAt
        let primary = quotaWindow(
            object,
            nestedKey: "primary",
            usedKey: "five_hour_used_pct",
            resetKey: "five_hour_resets_at_unix",
            windowKey: "five_hour_window_minutes"
        )
        let weekly = quotaWindow(
            object,
            nestedKey: weeklyKey,
            usedKey: "weekly_used_pct",
            resetKey: "weekly_resets_at_unix",
            windowKey: "weekly_window_minutes"
        )

        return [
            QuotaReading(
                engine: engine,
                window: "5h",
                usedPercent: number(primary["used_percent"]),
                resetAt: DateParsers.any(primary["resets_at"]),
                source: path.path,
                updatedAt: updatedAt,
                sourceReadingAt: sourceReadingAt,
                windowMinutes: number(primary["window_minutes"])
            ),
            QuotaReading(
                engine: engine,
                window: "week",
                usedPercent: number(weekly["used_percent"]),
                resetAt: DateParsers.any(weekly["resets_at"]),
                source: path.path,
                updatedAt: updatedAt,
                sourceReadingAt: sourceReadingAt,
                windowMinutes: number(weekly["window_minutes"])
            )
        ]
    }

    private static func quotaWindow(_ object: [String: Any], nestedKey: String, usedKey: String, resetKey: String, windowKey: String) -> [String: Any] {
        if let nested = object[nestedKey] as? [String: Any] {
            return nested
        }
        return [
            "used_percent": object[usedKey] as Any,
            "resets_at": object[resetKey] as Any,
            "window_minutes": object[windowKey] as Any
        ]
    }
}

enum CodexUsageMetadataReader {
    struct Metadata {
        let resetsAvailable: Int?
        let resetsExpireAt: Date?
        let resetsExpiries: [Date]
        let resetsDetail: [ResetCredit]
        let resetsHistory: [ResetCredit]
    }

    static func read() -> Metadata {
        let path = homeURL.appendingPathComponent(".claude/codex-usage.json")
        guard
            let data = try? Data(contentsOf: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Metadata(resetsAvailable: nil, resetsExpireAt: nil, resetsExpiries: [], resetsDetail: [], resetsHistory: [])
        }
        let expiries = ((object["resets_expiries"] as? [Any]) ?? [])
            .compactMap { DateParsers.any($0) }
            .sorted()
        let detail = ((object["resets_detail"] as? [Any]) ?? [])
            .compactMap { value -> ResetCredit? in
                guard
                    let object = value as? [String: Any],
                    let expiresAt = DateParsers.any(object["expires_at"] ?? object["expiresAt"])
                else {
                    return nil
                }
                let rawLabel = object["label"] as? String
                let label = rawLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ResetCredit(
                    grantedAt: DateParsers.any(object["granted_at"] ?? object["grantedAt"]),
                    expiresAt: expiresAt,
                    label: label?.isEmpty == false ? label! : "Codex Team"
                )
            }
            .sorted { $0.expiresAt < $1.expiresAt }
        let history = ((object["resets_history"] as? [Any]) ?? [])
            .compactMap { value -> ResetCredit? in
                guard
                    let object = value as? [String: Any],
                    let expiresAt = DateParsers.any(object["expires_at"] ?? object["expiresAt"])
                else {
                    return nil
                }
                let rawLabel = (object["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawStatus = (object["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return ResetCredit(
                    grantedAt: DateParsers.any(object["granted_at"] ?? object["grantedAt"]),
                    expiresAt: expiresAt,
                    label: rawLabel?.isEmpty == false ? rawLabel! : "Codex Team",
                    status: rawStatus?.isEmpty == false ? rawStatus! : "redeemed",
                    resolvedAt: DateParsers.any(object["resolved_at"] ?? object["resolvedAt"])
                )
            }
            .sorted { ($0.resolvedAt ?? $0.expiresAt) > ($1.resolvedAt ?? $1.expiresAt) }
        return Metadata(
            resetsAvailable: optionalInt(object["resets_available"])
            ?? optionalInt(object["resetsAvailable"])
            ?? optionalInt(object["reset_count"])
            ?? optionalInt(object["resetCount"]),
            resetsExpireAt: DateParsers.any(object["resets_expire_at"])
            ?? DateParsers.any(object["resetsExpireAt"])
            ?? DateParsers.any(object["resets_expiry"])
            ?? DateParsers.any(object["resetsExpiry"])
            ?? DateParsers.any(object["resets_next_expiry"])
            ?? DateParsers.any(object["reset_allowance_expires_at"])
            ?? DateParsers.any(object["resetAllowanceExpiresAt"])
            ?? expiries.first,
            resetsExpiries: expiries,
            resetsDetail: detail,
            resetsHistory: history
        )
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

enum QuotaFeedRefresher {
    private static let feeds = [
        ("Claude", ".claude/claude-usage.json", ".claude/claude-usage-poll.py"),
        ("Codex", ".claude/codex-usage.json", ".claude/codex-usage-poll.py")
    ]

    static func refreshLocalFeedsIfNeeded() {
        let selectedFeeds = LocalMode.isCodexOnly ? feeds.filter { $0.0 == "Codex" } : feeds
        for (_, feedPath, scriptPath) in selectedFeeds {
            let feed = homeURL.appendingPathComponent(feedPath)
            guard shouldRefresh(feed) else { continue }
            runPythonScript(homeURL.appendingPathComponent(scriptPath))
        }
    }

    private static func shouldRefresh(_ feed: URL) -> Bool {
        guard let values = try? feed.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate else {
            return true
        }
        return Date().timeIntervalSince(modified) >= RefreshCadence.feedRefreshIfOlderThan
    }

    private static func runPythonScript(_ script: URL) {
        guard FileManager.default.isReadableFile(atPath: script.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }
}

enum BurnRateReader {
    enum ReadScope {
        case live
        case full

        var maxFilesPerRoot: Int {
            if LocalMode.isCodexOnly {
                switch self {
                case .live: return 8
                case .full: return 24
                }
            }
            switch self {
            case .live: return 20
            case .full: return 120
            }
        }

        var maxLinesPerFile: Int {
            if LocalMode.isCodexOnly {
                switch self {
                case .live: return 50
                case .full: return 120
                }
            }
            switch self {
            case .live: return 80
            case .full: return 240
            }
        }
    }

    private struct BurnEvent {
        let engine: String
        let tokens: Int
        let quotaUsedPercent: Double?
        let timestamp: Date
        let session: String
    }

    private static let windowSeconds: TimeInterval = 15 * 60

    static func read(quotas: [QuotaReading], scope: ReadScope = .full) -> [BurnReading] {
        let events = readEvents(scope: scope)
        let engines = LocalMode.isCodexOnly ? ["Codex"] : ["Codex", "Claude"]
        return engines.map { engine in
            reading(engine: engine, events: events.filter { $0.engine == engine }, quotas: quotas)
        }
    }

    private static func reading(engine: String, events: [BurnEvent], quotas: [QuotaReading]) -> BurnReading {
        let now = Date()
        let cutoff = now.addingTimeInterval(-windowSeconds)
        let recent = events.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
        let tokens = recent.reduce(0) { $0 + $1.tokens }
        let firstEventAt = recent.first?.timestamp
        let lastEventAt = recent.last?.timestamp
        let elapsed = firstEventAt.map { max(60, min(windowSeconds, now.timeIntervalSince($0))) } ?? windowSeconds
        let tokensPerMinute = tokens > 0 ? Double(tokens) / (elapsed / 60) : 0
        let activeSessions = Set(recent.map(\.session)).count
        let quotaPace = quotaPercentPerMinute(from: recent)
        let remaining = quotas.first { $0.engine == engine && $0.window == "5h" }?.remainingPercent
        let points = pacePoints(from: recent, now: now)
        return BurnReading(
            engine: engine,
            tokens: tokens,
            tokensPerMinute: tokensPerMinute,
            windowSeconds: elapsed,
            quotaPercentPerMinute: quotaPace,
            remainingPercent: remaining,
            activeSessions: activeSessions,
            lastEventAt: lastEventAt,
            points: points
        )
    }

    private static func pacePoints(from events: [BurnEvent], now: Date) -> [PacePoint] {
        let bucketCount = 12
        let bucketSeconds = windowSeconds / Double(bucketCount)
        let start = now.addingTimeInterval(-windowSeconds)
        var buckets = Array(repeating: 0, count: bucketCount)
        for event in events {
            let offset = event.timestamp.timeIntervalSince(start)
            guard offset >= 0 else { continue }
            let index = min(bucketCount - 1, max(0, Int(offset / bucketSeconds)))
            buckets[index] += event.tokens
        }
        return buckets.enumerated().map { index, tokens in
            PacePoint(
                bucketStart: start.addingTimeInterval(Double(index) * bucketSeconds),
                tokens: tokens,
                bucketSeconds: bucketSeconds
            )
        }
    }

    private static func quotaPercentPerMinute(from events: [BurnEvent]) -> Double? {
        let quotaEvents = events.compactMap { event -> (Date, Double)? in
            guard let quota = event.quotaUsedPercent else { return nil }
            return (event.timestamp, quota)
        }
        guard let first = quotaEvents.first, let last = quotaEvents.last, last.0.timeIntervalSince(first.0) >= 60 else {
            return nil
        }
        return max(0, (last.1 - first.1) / (last.0.timeIntervalSince(first.0) / 60))
    }

    private static func readEvents(scope: ReadScope) -> [BurnEvent] {
        if LocalMode.isCodexOnly {
            return readCodexEvents(scope: scope)
        }
        return readCodexEvents(scope: scope) + readClaudeEvents(scope: scope)
    }

    private static func readCodexEvents(scope: ReadScope) -> [BurnEvent] {
        let root = homeURL.appendingPathComponent(".codex/sessions")
        return recentJSONLFiles(root: root, limit: scope.maxFilesPerRoot).flatMap { file in
            recentLines(file, limit: scope.maxLinesPerFile).compactMap { line -> BurnEvent? in
                guard let object = jsonObject(line),
                      let timestamp = DateParsers.any(object["timestamp"]),
                      let payload = object["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count"
                else { return nil }

                let info = payload["info"] as? [String: Any]
                let lastUsage = info?["last_token_usage"] as? [String: Any]
                let totalUsage = info?["total_token_usage"] as? [String: Any]
                let tokens = int(lastUsage?["total_tokens"] ?? totalUsage?["total_tokens"])
                let rateLimits = payload["rate_limits"] as? [String: Any]
                let primary = rateLimits?["primary"] as? [String: Any]
                return BurnEvent(
                    engine: "Codex",
                    tokens: tokens,
                    quotaUsedPercent: number(primary?["used_percent"]),
                    timestamp: timestamp,
                    session: file.path
                )
            }
        }
    }

    private static func readClaudeEvents(scope: ReadScope) -> [BurnEvent] {
        let root = homeURL.appendingPathComponent(".claude/projects")
        var seenRequests = Set<String>()
        return recentJSONLFiles(root: root, limit: scope.maxFilesPerRoot).flatMap { file -> [BurnEvent] in
            var events: [BurnEvent] = []
            for line in recentLines(file, limit: scope.maxLinesPerFile) {
                guard let object = jsonObject(line),
                      let timestamp = DateParsers.any(object["timestamp"]),
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { continue }

                let tokens = int(usage["input_tokens"])
                    + int(usage["cache_read_input_tokens"])
                    + int(usage["cache_creation_input_tokens"])
                    + int(usage["output_tokens"])
                let requestKey = string(object["requestId"])
                    ?? string(message["id"])
                    ?? string(object["uuid"])
                    ?? "\(timestamp.timeIntervalSince1970)-\(tokens)"
                guard seenRequests.insert("\(file.path)|\(requestKey)").inserted else { continue }
                events.append(BurnEvent(
                    engine: "Claude",
                    tokens: tokens,
                    quotaUsedPercent: nil,
                    timestamp: timestamp,
                    session: file.path
                ))
            }
            return events
        }
    }

    private static func recentJSONLFiles(root: URL, limit: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            urls.append(url)
        }
        return urls.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.prefix(limit).map { $0 }
    }

    private static func recentLines(_ file: URL, limit: Int) -> Array<Substring> {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return Array(text.split(separator: "\n").suffix(limit))
    }

    private static func jsonObject(_ line: Substring) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

enum SessionReader {
    static func recentSessions(limit: Int) -> [SessionReading] {
        let roots = LocalMode.isCodexOnly
            ? [homeURL.appendingPathComponent(".codex/sessions")]
            : [
                homeURL.appendingPathComponent(".codex/sessions"),
                homeURL.appendingPathComponent(".claude/projects")
            ]
        let fileLimit = LocalMode.isCodexOnly ? min(limit, 30) : 80
        let files = roots.flatMap { recentJSONLFiles(root: $0, limit: fileLimit) }
        return files.compactMap(parseSession).sorted { $0.lastActivity > $1.lastActivity }.prefix(limit).map { $0 }
    }

    private static func parseSession(_ url: URL) -> SessionReading? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let allLines = text.split(separator: "\n")
        let lines: [Substring]
        if LocalMode.isCodexOnly, allLines.count > 180 {
            lines = Array(allLines.prefix(60)) + Array(allLines.suffix(120))
        } else if allLines.count <= 420 {
            lines = Array(allLines)
        } else {
            lines = Array(allLines.prefix(160)) + Array(allLines.suffix(260))
        }
        let source = url.path.contains(".codex") ? "Codex" : "Claude"
        var cwd = "unknown"
        var model = "unknown"
        var codexTokens = 0
        var claudeTokens = 0
        var claudeRequests = Set<String>()
        var explicitTitle: String?
        var fallbackTitle: String?
        var done = false

        for line in lines {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let aiTitle = titleCandidate(from: object["aiTitle"] ?? object["ai_title"]) {
                explicitTitle = aiTitle
            }
            if explicitTitle == nil,
               let lastPrompt = titleCandidate(from: object["lastPrompt"] ?? object["last_prompt"]) {
                fallbackTitle = fallbackTitle ?? lastPrompt
            }
            if let payload = object["payload"] as? [String: Any] {
                cwd = (payload["cwd"] as? String) ?? cwd
                model = (payload["model"] as? String) ?? model
                if (payload["type"] as? String) == "user_message",
                   let title = titleCandidate(from: payload["message"]) {
                    explicitTitle = title
                }
                if let info = payload["info"] as? [String: Any],
                   let usage = info["total_token_usage"] as? [String: Any] {
                    codexTokens = max(codexTokens, int(usage["total_tokens"]))
                }
                if payload["completed_at"] != nil { done = true }
            }
            cwd = (object["cwd"] as? String) ?? cwd
            if let payload = object["payload"] as? [String: Any],
               let payloadCwd = payload["cwd"] as? String {
                cwd = payloadCwd
            }
            if let payload = object["payload"] as? [String: Any],
               let payloadModel = payload["model"] as? String {
                model = payloadModel
            }
            if let payload = object["payload"] as? [String: Any],
               let info = payload["info"] as? [String: Any],
               let usage = info["last_token_usage"] as? [String: Any],
               codexTokens == 0 {
                codexTokens = max(codexTokens, int(usage["total_tokens"]))
            }
            if let summary = titleCandidate(from: object["summary"]) {
                fallbackTitle = fallbackTitle ?? summary
            }
            if let message = object["message"] as? [String: Any] {
                model = (message["model"] as? String) ?? model
                if (object["type"] as? String) == "user",
                   let title = titleCandidate(from: message["content"]) {
                    explicitTitle = explicitTitle ?? title
                }
                if let usage = message["usage"] as? [String: Any] {
                    let total = usageTokenTotal(usage)
                    if source == "Claude" {
                        let requestKey = string(object["requestId"])
                            ?? string(message["id"])
                            ?? string(object["uuid"])
                            ?? "\(string(object["timestamp"]) ?? url.lastPathComponent)-\(total)"
                        if claudeRequests.insert(requestKey).inserted {
                            claudeTokens += total
                        }
                    } else {
                        codexTokens = max(codexTokens, total)
                    }
                }
            }
            if (object["type"] as? String) == "result" { done = true }
        }

        let workspace = workspaceName(cwd: cwd, file: url)
        let title = explicitTitle ?? fallbackTitle ?? workspace
        let tokens = source == "Claude" ? claudeTokens : codexTokens
        let tokenBasis = source == "Claude" ? "deduped estimate" : "cumulative log"
        let age = Date().timeIntervalSince(modified)
        let status = done ? "done" : (age < 15 * 60 ? "running" : "waiting")
        return SessionReading(id: url.path, source: source, repo: title, title: title, workspace: workspace, cwd: cwd, model: model, status: status, tokens: tokens, tokenBasis: tokenBasis, lastActivity: modified)
    }

    private static func recentJSONLFiles(root: URL, limit: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if shouldSkipSessionFile(url) { continue }
            urls.append(url)
        }
        return urls.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.prefix(limit).map { $0 }
    }

    private static func shouldSkipSessionFile(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/subagents/")
            || path.contains("/workflows/")
            || url.lastPathComponent == "journal.jsonl"
    }

    private static func usageTokenTotal(_ usage: [String: Any]) -> Int {
        int(usage["input_tokens"])
            + int(usage["cache_read_input_tokens"])
            + int(usage["cache_creation_input_tokens"])
            + int(usage["output_tokens"])
    }

    private static func titleCandidate(from value: Any?) -> String? {
        if let text = string(value) {
            return cleanTitle(text)
        }
        if let row = value as? [String: Any] {
            if string(row["type"]) == "tool_result" || row["tool_use_id"] != nil {
                return nil
            }
            return titleCandidate(from: row["text"] ?? row["content"] ?? row["message"])
        }
        if let rows = value as? [Any] {
            for item in rows {
                if let title = titleCandidate(from: item) {
                    return title
                }
            }
        }
        return nil
    }

    private static func cleanTitle(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lowered = text.lowercased()
        if lowered.contains("<instructions>") ||
            lowered.hasPrefix("traceback") ||
            lowered.hasPrefix("total ") ||
            lowered.contains("base64") ||
            lowered.contains("tool_use_id") {
            return nil
        }

        if text.hasPrefix("In /"), let comma = text.firstIndex(of: ",") {
            text = String(text[text.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("Scope slice for "), let marker = text.range(of: ". Context:") {
            text = String(text[..<marker.lowerBound])
        }
        if let boilerplate = text.range(of: " You are ") {
            text = String(text[..<boilerplate.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.lowercased().hasPrefix("you are ") {
            return nil
        }

        let maxLength = 72
        if text.count > maxLength {
            let end = text.index(text.startIndex, offsetBy: maxLength)
            text = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }
        return text.isEmpty ? nil : text
    }

    private static func workspaceName(cwd: String, file: URL) -> String {
        let userName = NSUserName()
        if cwd != "unknown" {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if name == userName { return "home" }
            if !name.isEmpty { return name }
        }
        let parent = file.deletingLastPathComponent().lastPathComponent
        let cleaned = parent
            .replacingOccurrences(of: "-Users-\(userName)-", with: "")
            .replacingOccurrences(of: "-Users-\(userName)", with: "home")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "workspace" : cleaned
    }
}

enum HistoryReader {
    static func history(from sessions: [SessionReading]) -> HistoryReading {
        let now = Date()
        let sessions24 = sessions.filter { now.timeIntervalSince($0.lastActivity) <= 24 * 3600 }
        let sessions7 = sessions.filter { now.timeIntervalSince($0.lastActivity) <= 7 * 24 * 3600 }
        return HistoryReading(
            sessions24h: sessions24.count,
            tokens24h: sessions24.reduce(0) { $0 + $1.tokens },
            sessions7d: sessions7.count,
            tokens7d: sessions7.reduce(0) { $0 + $1.tokens }
        )
    }
}

enum SystemReader {
    static func read() -> SystemReading {
        let uptime = shell("/usr/bin/uptime")
        let load = uptime.split(separator: " ").suffix(3).joined(separator: " ").replacingOccurrences(of: ",", with: "")
        let disk = shell("/bin/df -g /").split(separator: "\n").dropFirst().first?.split(separator: " ")
        let freeGB = disk.flatMap { $0.count > 3 ? String($0[3]) : nil } ?? "unknown"
        let power = shell("/usr/bin/pmset -g batt").contains("AC Power") ? "AC" : "battery"
        return SystemReading(load: load.isEmpty ? "unknown" : load, diskFreeGB: freeGB, power: power)
    }
}

enum TodoReader {
    static func read() -> TodoReading {
        guard let override = ProcessInfo.processInfo.environment["PACE_TODO_FILE"], !override.isEmpty else {
            return .empty
        }
        let path = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return .empty }
        let headings = text.split(separator: "\n").filter { $0.hasPrefix("## ") }
        return TodoReading(
            pending: headings.filter { !$0.contains("[") }.count,
            active: headings.filter { $0.contains("[active]") }.count,
            deferred: headings.filter { $0.contains("[deferred:") }.count
        )
    }
}

enum SyncReader {
    static func read() -> SyncReading {
        let root = homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/\(ProductIdentity.legacyICloudFolderName)/snapshots")
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return .empty
        }
        let snapshots = files.filter { $0.pathExtension == "json" }
        let latest = snapshots.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.first?.lastPathComponent ?? "none"
        return SyncReading(enabled: !snapshots.isEmpty, peerCount: snapshots.count, latestSnapshot: latest)
    }
}

enum AppStoreSnapshotReader {
    private static let bookmarkKey = "PaceSnapshotBookmark"
    private static let sampleResource = "PaceSnapshot.sample"

    static func read() -> PaceSnapshot {
        if let selected = readBookmarkedSnapshot() {
            return selected
        }
        if let bundled = readBundledSample() {
            return bundled
        }
        return fallbackSnapshot()
    }

    @MainActor
    static func chooseSnapshotSource() -> PaceSnapshot? {
        let panel = NSOpenPanel()
        panel.title = "Connect Pace Snapshot"
        panel.message = "Choose a sanitized Pace snapshot JSON file or a folder containing snapshots."
        panel.prompt = "Connect"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            return readSnapshotSource(url, label: "User-selected snapshot")
        } catch {
            var snapshot = fallbackSnapshot()
            snapshot.alerts = ["Could not save snapshot access"]
            return snapshot
        }
    }

    private static func readBookmarkedSnapshot() -> PaceSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var snapshot = readSnapshotSource(url, label: stale ? "User-selected snapshot (reconnect recommended)" : "User-selected snapshot")
        if stale {
            snapshot?.alerts.append("Snapshot access should be reconnected")
        }
        return snapshot
    }

    private static func readBundledSample() -> PaceSnapshot? {
        guard let url = Bundle.main.url(forResource: sampleResource, withExtension: "json") else { return nil }
        return readSnapshotFile(url, fallbackLabel: "Bundled review sample", sourceKind: "review-sample", sample: true)
    }

    private static func readSnapshotSource(_ url: URL, label: String) -> PaceSnapshot? {
        guard let file = snapshotFile(from: url) else { return nil }
        return readSnapshotFile(file, fallbackLabel: label, sourceKind: "user-selected", sample: false)
    }

    private static func snapshotFile(from url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true else { return url }
        guard let files = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            .first
    }

    private static func readSnapshotFile(_ url: URL, fallbackLabel: String, sourceKind: String, sample: Bool) -> PaceSnapshot? {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        var snapshot = PaceSnapshot()
        snapshot.sourceKind = string(object["source_kind"]) ?? sourceKind
        snapshot.sourceLabel = string(object["source_label"]) ?? fallbackLabel
        snapshot.sourceGeneratedAt = DateParsers.any(object["generated_at"])
        snapshot.sourceIsSample = sample || snapshot.sourceKind.contains("sample")
        snapshot.quotas = parseQuotas(object["quotas"] as? [[String: Any]] ?? [])
        snapshot.burnRates = parseBurnRates(object["burn_rates"] as? [[String: Any]] ?? [])
        snapshot.sessions = parseSessions(object["sessions"] as? [[String: Any]] ?? [])
        snapshot.history = parseHistory(object["history"] as? [String: Any]) ?? HistoryReader.history(from: snapshot.sessions)
        snapshot.system = parseSystem(object["system"] as? [String: Any]) ?? SystemReading(load: "sandboxed", diskFreeGB: "hidden", power: "sandboxed")
        snapshot.todos = parseTodos(object["todos"] as? [String: Any]) ?? .empty
        snapshot.sync = parseSync(object["sync"] as? [String: Any]) ?? .empty
        snapshot.alerts = (object["alerts"] as? [String]) ?? []
        snapshot.alerts.append(contentsOf: AlertBuilder.alerts(for: snapshot))
        if snapshot.sourceIsSample {
            snapshot.alerts.insert("Review sample data", at: 0)
        }
        return snapshot
    }

    private static func parseQuotas(_ rows: [[String: Any]]) -> [QuotaReading] {
        rows.map { row in
            QuotaReading(
                engine: string(row["engine"]) ?? "Unknown",
                window: string(row["window"]) ?? "window",
                usedPercent: number(row["used_percent"]),
                resetAt: date(row: row, key: "resets_at", relativeKey: "resets_in_seconds"),
                source: string(row["source"]) ?? "snapshot",
                updatedAt: date(row: row, key: "updated_at", relativeKey: "updated_age_seconds")
            )
        }
    }

    private static func parseSessions(_ rows: [[String: Any]]) -> [SessionReading] {
        rows.enumerated().map { index, row in
            SessionReading(
                id: string(row["id"]) ?? "snapshot-session-\(index)",
                source: string(row["source"]) ?? "Snapshot",
                repo: string(row["repo"]) ?? "workspace",
                title: string(row["title"]) ?? string(row["repo"]) ?? "workspace",
                workspace: string(row["workspace"]) ?? string(row["repo"]) ?? "workspace",
                cwd: string(row["cwd"] ?? row["cwd_path"] ?? row["cwdPath"]) ?? string(row["workspace"]) ?? "unknown",
                model: string(row["model"]) ?? "unknown",
                status: string(row["status"]) ?? "done",
                tokens: int(row["tokens"]),
                tokenBasis: string(row["token_basis"] ?? row["tokenBasis"]) ?? "snapshot",
                lastActivity: date(row: row, key: "last_activity", relativeKey: "last_activity_age_seconds") ?? Date()
            )
        }
    }

    private static func parseBurnRates(_ rows: [[String: Any]]) -> [BurnReading] {
        rows.map { row in
            BurnReading(
                engine: string(row["engine"]) ?? "Unknown",
                tokens: int(row["tokens"]),
                tokensPerMinute: number(row["tokens_per_minute"] ?? row["tokensPerMinute"]) ?? 0,
                windowSeconds: number(row["window_seconds"] ?? row["windowSeconds"]) ?? 15 * 60,
                quotaPercentPerMinute: number(row["quota_percent_per_minute"] ?? row["quotaPercentPerMinute"]),
                remainingPercent: number(row["remaining_percent"] ?? row["remainingPercent"]),
                activeSessions: int(row["active_sessions"] ?? row["activeSessions"]),
                lastEventAt: date(row: row, key: "last_event_at", relativeKey: "last_event_age_seconds"),
                points: parsePacePoints(row)
            )
        }
    }

    private static func parsePacePoints(_ row: [String: Any]) -> [PacePoint] {
        let windowSeconds = number(row["window_seconds"] ?? row["windowSeconds"]) ?? 15 * 60
        let bucketCount = 12
        let bucketSeconds = max(1, windowSeconds / Double(bucketCount))
        let start = Date().addingTimeInterval(-windowSeconds)

        if let rows = row["points"] as? [[String: Any]], !rows.isEmpty {
            return rows.enumerated().map { index, point in
                let fallbackStart = start.addingTimeInterval(Double(index) * bucketSeconds)
                return PacePoint(
                    bucketStart: DateParsers.any(point["bucket_start"] ?? point["bucketStart"]) ?? fallbackStart,
                    tokens: int(point["tokens"]),
                    bucketSeconds: number(point["bucket_seconds"] ?? point["bucketSeconds"]) ?? bucketSeconds
                )
            }
        }

        return syntheticPacePoints(totalTokens: int(row["tokens"]), windowSeconds: windowSeconds)
    }

    private static func syntheticPacePoints(totalTokens: Int, windowSeconds: TimeInterval) -> [PacePoint] {
        let shape: [Double] = [0.18, 0.36, 0.22, 0.58, 0.42, 0.75, 0.62, 0.88, 0.46, 0.70, 0.35, 0.55]
        let totalShape = shape.reduce(0, +)
        let bucketSeconds = max(1, windowSeconds / Double(shape.count))
        let start = Date().addingTimeInterval(-windowSeconds)
        return shape.enumerated().map { index, weight in
            PacePoint(
                bucketStart: start.addingTimeInterval(Double(index) * bucketSeconds),
                tokens: Int((Double(totalTokens) * weight / totalShape).rounded()),
                bucketSeconds: bucketSeconds
            )
        }
    }

    private static func parseHistory(_ object: [String: Any]?) -> HistoryReading? {
        guard let object else { return nil }
        return HistoryReading(
            sessions24h: int(object["sessions24h"] ?? object["sessions_24h"]),
            tokens24h: int(object["tokens24h"] ?? object["tokens_24h"]),
            sessions7d: int(object["sessions7d"] ?? object["sessions_7d"]),
            tokens7d: int(object["tokens7d"] ?? object["tokens_7d"])
        )
    }

    private static func parseSystem(_ object: [String: Any]?) -> SystemReading? {
        guard let object else { return nil }
        return SystemReading(
            load: string(object["load"]) ?? "snapshot",
            diskFreeGB: string(object["disk_free_gb"] ?? object["diskFreeGB"]) ?? "hidden",
            power: string(object["power"]) ?? "snapshot"
        )
    }

    private static func parseTodos(_ object: [String: Any]?) -> TodoReading? {
        guard let object else { return nil }
        return TodoReading(
            pending: int(object["pending"]),
            active: int(object["active"]),
            deferred: int(object["deferred"])
        )
    }

    private static func parseSync(_ object: [String: Any]?) -> SyncReading? {
        guard let object else { return nil }
        return SyncReading(
            enabled: bool(object["enabled"]),
            peerCount: int(object["peer_count"] ?? object["peerCount"]),
            latestSnapshot: string(object["latest_snapshot"] ?? object["latestSnapshot"]) ?? "snapshot"
        )
    }

    private static func date(row: [String: Any], key: String, relativeKey: String) -> Date? {
        if let seconds = number(row[relativeKey]) {
            return Date().addingTimeInterval(-seconds)
        }
        return DateParsers.any(row[key])
    }

    private static func fallbackSnapshot() -> PaceSnapshot {
        var snapshot = PaceSnapshot()
        snapshot.sourceKind = "review-sample"
        snapshot.sourceLabel = "Built-in review sample"
        snapshot.sourceGeneratedAt = Date()
        snapshot.sourceIsSample = true
        snapshot.quotas = [
            QuotaReading(engine: "Codex", window: "5h", usedPercent: 34, resetAt: Date().addingTimeInterval(2.6 * 3600), source: "sample", updatedAt: Date()),
            QuotaReading(engine: "Codex", window: "week", usedPercent: 58, resetAt: Date().addingTimeInterval(4.2 * 24 * 3600), source: "sample", updatedAt: Date()),
            QuotaReading(engine: "Claude", window: "5h", usedPercent: 18, resetAt: Date().addingTimeInterval(3.8 * 3600), source: "sample", updatedAt: Date()),
            QuotaReading(engine: "Claude", window: "week", usedPercent: 72, resetAt: Date().addingTimeInterval(18 * 3600), source: "sample", updatedAt: Date())
        ]
        snapshot.burnRates = [
            BurnReading(engine: "Codex", tokens: 188000, tokensPerMinute: 12500, windowSeconds: 15 * 60, quotaPercentPerMinute: 0.4, remainingPercent: 66, activeSessions: 2, lastEventAt: Date().addingTimeInterval(-45), points: syntheticPacePoints(totalTokens: 188000, windowSeconds: 15 * 60)),
            BurnReading(engine: "Claude", tokens: 42000, tokensPerMinute: 2800, windowSeconds: 15 * 60, quotaPercentPerMinute: nil, remainingPercent: 82, activeSessions: 1, lastEventAt: Date().addingTimeInterval(-120), points: syntheticPacePoints(totalTokens: 42000, windowSeconds: 15 * 60))
        ]
        snapshot.sessions = [
            SessionReading(id: "sample-1", source: "Codex", repo: "your-project", title: "Prepare direct release packet", workspace: "your-project", cwd: "/Users/you/projects/your-project", model: "gpt-5.5", status: "running", tokens: 1320000, tokenBasis: "snapshot", lastActivity: Date().addingTimeInterval(-180)),
            SessionReading(id: "sample-2", source: "Codex", repo: "another-project", title: "Import usage snapshot", workspace: "another-project", cwd: "/Users/you/projects/another-project", model: "gpt-5.5", status: "done", tokens: 428000, tokenBasis: "snapshot", lastActivity: Date().addingTimeInterval(-2400)),
            SessionReading(id: "sample-3", source: "Local", repo: "pace-ui", title: "Tune Pace menu panel", workspace: "pace-ui", cwd: "/Users/you/projects/pace", model: "review fixture", status: "done", tokens: 206000, tokenBasis: "snapshot", lastActivity: Date().addingTimeInterval(-7200))
        ]
        snapshot.history = HistoryReader.history(from: snapshot.sessions)
        snapshot.system = SystemReading(load: "sample", diskFreeGB: "hidden", power: "AC")
        snapshot.todos = TodoReading(pending: 4, active: 1, deferred: 2)
        snapshot.sync = SyncReading(enabled: true, peerCount: 2, latestSnapshot: "review-sample.json")
        snapshot.alerts = ["Review sample data"]
        return snapshot
    }
}

enum AlertBuilder {
    static func alerts(for snapshot: PaceSnapshot) -> [String] {
        var alerts: [String] = []
        for quota in snapshot.quotas {
            if let remaining = quota.remainingPercent, remaining <= 10 {
                alerts.append("\(quota.engine) \(quota.window) near cap")
            }
        }
        guard !LocalMode.isCodexOnly else { return alerts }
        if snapshot.system.power == "battery", snapshot.sessions.contains(where: { $0.status == "running" }) {
            alerts.append("Agent running on battery")
        }
        if !snapshot.sync.enabled {
            alerts.append("Sync folder unavailable")
        }
        return alerts
    }
}

@MainActor
final class PaceStore: ObservableObject {
    @Published var snapshot = PaceSnapshot.collect(statusOnly: LocalMode.isCodexOnly)
    @Published var insights: [String: SessionInsight] = SessionInsightStore.load()
    @Published var summarising: Set<String> = []
    private var isRefreshing = false

    func insight(for session: SessionReading) -> SessionInsight? {
        guard let uuid = SessionInsightStore.uuid(forSessionID: session.id) else { return nil }
        return insights[uuid]
    }

    func isSummarising(_ session: SessionReading) -> Bool {
        guard let uuid = SessionInsightStore.uuid(forSessionID: session.id) else { return false }
        return summarising.contains(uuid)
    }

    // Shell out to the summariser for one session, then reload the cache. The
    // script defaults to the no-key codex CLI backend (spends ChatGPT plan quota,
    // no metered cost), so this can be slow; the UI shows a running state.
    func summarise(_ session: SessionReading) {
        guard let uuid = SessionInsightStore.uuid(forSessionID: session.id),
              !summarising.contains(uuid) else { return }
        summarising.insert(uuid)
        let path = session.id
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", SessionInsightStore.scriptPath.path, path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
            let reloaded = SessionInsightStore.load()
            await MainActor.run {
                self.insights = reloaded
                self.summarising.remove(uuid)
            }
        }
    }

    func refresh(refreshFeeds: Bool = false, includeSlowReadings: Bool = true, statusOnly: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let previous = snapshot
        Task.detached {
            let next = PaceSnapshot.collect(refreshFeeds: refreshFeeds, includeSlowReadings: includeSlowReadings, previous: previous, statusOnly: statusOnly)
            let reloadedInsights = SessionInsightStore.load()
            await MainActor.run {
                self.snapshot = next
                self.insights = reloadedInsights
                self.isRefreshing = false
            }
        }
    }

    func refreshLivePace() {
        refresh(refreshFeeds: false, includeSlowReadings: false)
    }

    func refreshFull() {
        refresh(refreshFeeds: true, includeSlowReadings: true)
    }

    func refreshStatus() {
        refresh(refreshFeeds: true, includeSlowReadings: false, statusOnly: true)
    }

    func connectSnapshotSource() {
        guard DistributionMode.isAppStore, let next = AppStoreSnapshotReader.chooseSnapshotSource() else {
            return
        }
        snapshot = next
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store = PaceStore()
    private var livePaceTimer: Timer?
    private var fullRefreshTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: LocalMode.isCodexOnly ? NSStatusItem.variableLength : NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            button.image = LocalMode.isCodexOnly ? nil : StatusIcon.make()
            button.imagePosition = LocalMode.isCodexOnly ? .noImage : .imageOnly
            button.toolTip = ProductIdentity.displayName
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusItem(with: store.snapshot)
        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateStatusItem(with: snapshot)
            }
            .store(in: &cancellables)

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 480, height: 520)
        popover.contentViewController = NSHostingController(rootView: PacePanelView(store: store))

        livePaceTimer = Timer.scheduledTimer(withTimeInterval: RefreshCadence.livePaceRefresh, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.popover.isShown else { return }
                self.store.refreshLivePace()
            }
        }
        fullRefreshTimer = Timer.scheduledTimer(withTimeInterval: RefreshCadence.fullRefresh, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if LocalMode.isCodexOnly {
                    self?.store.refreshStatus()
                } else {
                    self?.store.refreshFull()
                }
            }
        }
        if LocalMode.isCodexOnly {
            store.refreshStatus()
        } else {
            store.refreshFull()
        }
    }

    private func updateStatusItem(with snapshot: PaceSnapshot) {
        guard let button = statusItem.button else { return }
        if LocalMode.isCodexOnly {
            let color: NSColor
            switch snapshot.quotas.first(where: { $0.engine == "Codex" && $0.window == "5h" })?.paceState {
            case .good: color = .systemGreen
            case .hot: color = .systemOrange
            case .critical: color = .systemRed
            default: color = .labelColor
            }
            button.attributedTitle = NSAttributedString(
                string: StatusBarText.codexTitle(for: snapshot),
                attributes: [
                    .foregroundColor: color,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .regular), weight: .medium)
                ]
            )
            button.image = nil
            button.imagePosition = .noImage
            button.toolTip = StatusBarText.codexTooltip(for: snapshot)
            statusItem.length = NSStatusItem.variableLength
        } else {
            button.title = ""
            button.image = StatusIcon.make()
            button.imagePosition = .imageOnly
            button.toolTip = ProductIdentity.displayName
            statusItem.length = NSStatusItem.squareLength
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refreshFull()
            popover.contentViewController = NSHostingController(rootView: PacePanelView(store: store))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func verifyPopoverToggle() -> Bool {
        guard let button = statusItem.button else { return false }
        button.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let didShow = popover.isShown
        if didShow {
            popover.performClose(nil)
        }
        return didShow
    }
}

enum StatusIcon {
    static func make() -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let center = NSPoint(x: 11, y: 6.6)
        drawArc(center: center, radius: 7.5, start: 204, end: -24, color: .labelColor.withAlphaComponent(0.38), width: 2.8)
        drawArc(center: center, radius: 7.5, start: 204, end: 74, color: .labelColor, width: 2.8)

        let needle = NSBezierPath()
        needle.lineWidth = 2
        needle.lineCapStyle = .round
        needle.move(to: center)
        needle.line(to: NSPoint(x: 15.4, y: 12.2))
        NSColor.labelColor.setStroke()
        needle.stroke()

        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - 2.2, y: center.y - 2.2, width: 4.4, height: 4.4))
        NSColor.labelColor.setFill()
        hub.fill()

        image.isTemplate = true
        return image
    }

    private static func drawArc(center: NSPoint, radius: CGFloat, start: CGFloat, end: CGFloat, color: NSColor, width: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        color.setStroke()
        path.stroke()
    }
}

enum StatusBarText {
    static func codexTitle(for snapshot: PaceSnapshot) -> String {
        guard let quota = snapshot.quotas.first(where: { $0.engine == "Codex" && $0.window == "5h" }),
              let remainingPercent = quota.remainingPercent else {
            return "--"
        }
        let pct = "\(Int(remainingPercent.rounded()))%"
        // Constrained window: count down to relief. Fresh window: count up
        // since the reset so a glance shows how young the allowance is.
        if remainingPercent <= 30 {
            return "\(pct) -\(quota.resetText)"
        }
        return "\(pct) +\(quota.sinceResetText)"
    }

    static func codexTooltip(for snapshot: PaceSnapshot) -> String {
        let fiveHour = snapshot.quotas.first { $0.engine == "Codex" && $0.window == "5h" }
        let weekly = snapshot.quotas.first { $0.engine == "Codex" && $0.window == "week" }
        let fiveHourText = fiveHour.map { "\($0.remainingPercentText), \($0.usedPercentText), \($0.paceText), \($0.sinceResetText) since reset, resets \($0.resetDetailText)" } ?? "5h unknown"
        let weeklyText = weekly.map { "\($0.remainingPercentText), \($0.usedPercentText), \($0.paceText), \($0.sinceResetText) since reset, resets \($0.resetDetailText)" } ?? "week unknown"
        let resetAllowance = resetAllowanceText(for: snapshot)
        return "Codex 5h: \(fiveHourText)\nCodex week: \(weeklyText)\n\(resetAllowance)"
    }

    private static func resetAllowanceText(for snapshot: PaceSnapshot) -> String {
        guard let count = snapshot.codexResetsAvailable else {
            return "Banked resets: unavailable in local Codex feed"
        }
        let usedCount = snapshot.codexResetsHistory.filter { $0.status.lowercased() == "redeemed" }.count
        let expiredCount = snapshot.codexResetsHistory.count - usedCount
        var pastText = ""
        if usedCount > 0 { pastText += " · \(usedCount) used" }
        if expiredCount > 0 { pastText += " · \(expiredCount) expired" }
        let expiries = snapshot.codexResetsExpiries.isEmpty
            ? snapshot.codexResetsExpireAt.map { [$0] } ?? []
            : snapshot.codexResetsExpiries
        guard !expiries.isEmpty else {
            return "Banked resets: \(count) available; expiry unknown\(pastText)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        let schedule = expiries.map { formatter.string(from: $0) }.joined(separator: ", ")
        return "Banked resets: \(count), expiring \(schedule)\(pastText)"
    }
}

struct PacePanelView: View {
    @ObservedObject var store: PaceStore
    @State private var tab = ProcessInfo.processInfo.environment["PACE_DEBUG_TAB"] ?? "Now"

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                Text("Now").tag("Now")
                Text("Sessions").tag("Sessions")
                if !LocalMode.isCodexOnly {
                    Text("System").tag("System")
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)

            Divider()

            ScrollView {
                switch tab {
                case "Sessions":
                    sessionsView
                case "System":
                    systemView
                default:
                    nowView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PaceTheme.panel)
        }
        .frame(width: 480, height: 520)
        .background(PaceTheme.panel)
    }

    private var header: some View {
        HStack(spacing: 12) {
            GaugeMark()
                .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(ProductIdentity.displayName)
                    .font(.system(size: 18, weight: .semibold))
                Text(DistributionMode.isAppStore ? ProductIdentity.subtitleAppStore : ProductIdentity.subtitleLocal)
                    .font(.caption)
                    .foregroundStyle(PaceTheme.muted)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("Refresh")
            if !DistributionMode.isAppStore && !LocalMode.isCodexOnly {
                Button {
                    NSWorkspace.shared.open(homeURL.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/\(ProductIdentity.legacyICloudFolderName)"))
                } label: {
                    Label("Open Snapshot Folder", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .help("Open snapshot folder")
            } else {
                Button {
                    store.connectSnapshotSource()
                } label: {
                    Label("Connect Snapshot", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.iconOnly)
                .help("Connect snapshot")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var nowView: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Usage") {
                quotaList
                if store.snapshot.codexResetsAvailable != nil {
                    bankedResetRow
                }
            }
            burnStrip
            activeSessionHighlights
            sourceBanner
            section("Alerts") {
                if store.snapshot.alerts.isEmpty {
                    row("Clear", detail: LocalMode.isCodexOnly ? "No active Codex alerts" : "No active Pace alerts", icon: "checkmark.circle", accent: PaceTheme.green)
                } else {
                    ForEach(store.snapshot.alerts, id: \.self) { alert in
                        row(alert, detail: "Needs attention", icon: "exclamationmark.triangle", accent: PaceTheme.amber)
                    }
                }
            }
            if !LocalMode.isCodexOnly {
                section("Continuity") {
                    row("Sync peers: \(store.snapshot.sync.peerCount)", detail: store.snapshot.sync.latestSnapshot, icon: "icloud", accent: PaceTheme.blue)
                    row("Todos: \(store.snapshot.todos.pending)", detail: "\(store.snapshot.todos.active) active, \(store.snapshot.todos.deferred) deferred", icon: "checklist", accent: PaceTheme.teal)
                }
            }
        }
        .padding(14)
    }

    // The live burn, as a compact strip rather than a graph: the sparkline did
    // not earn the vertical space it took at the top of the panel.
    @ViewBuilder
    private var burnStrip: some View {
        let burnRates = store.snapshot.burnRates.sorted(by: burnSort)
        let active = burnRates.filter { $0.activeSessions > 0 || $0.tokensPerMinute > 0 }
        if !active.isEmpty {
            section("Burn \u{00B7} last 15m") {
                VStack(spacing: 7) {
                    ForEach(active) { burnRate in
                        burnSummaryRow(burnRate)
                    }
                }
                .padding(10)
                .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PaceTheme.stroke))
            }
        }
    }

    private func burnSummaryRow(_ burnRate: BurnReading) -> some View {
        let accent = burnAccent(burnRate)
        return HStack(spacing: 8) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
            Text(burnRate.engine)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 48, alignment: .leading)
            Text(burnRate.tokensPerMinuteText)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .frame(width: 86, alignment: .leading)
            Text(burnRate.tokensText)
                .font(.caption2)
                .foregroundStyle(PaceTheme.muted)
                .frame(width: 82, alignment: .leading)
            Text(quotaBrief(for: burnRate.engine))
                .font(.caption2)
                .foregroundStyle(PaceTheme.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var activeSessionHighlights: some View {
        let active = store.snapshot.sessions.filter { $0.status == "running" }
        if !active.isEmpty {
            section("Active") {
                ForEach(Array(active.prefix(3))) { session in
                    compactSessionRow(session)
                }
            }
        }
    }

    private var sourceBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(store.snapshot.sourceIsSample ? PaceTheme.amber : PaceTheme.green)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.snapshot.sourceLabel)
                    .font(.system(size: 12, weight: .semibold))
                Text(sourceDetail)
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PaceTheme.stroke))
    }

    private var sourceDetail: String {
        if let generatedAt = store.snapshot.sourceGeneratedAt {
            return "generated \(relativeTime(generatedAt)) · \(store.snapshot.sourceKind)"
        }
        return "\(store.snapshot.sourceKind) · generated time unknown"
    }

    private var quotaList: some View {
        VStack(spacing: 8) {
            ForEach(store.snapshot.quotas.sorted(by: quotaSort)) { quota in
                quotaRow(quota)
            }
        }
    }

    @ViewBuilder
    private var bankedResetRow: some View {
        let credits = bankedResetCredits
        let history = store.snapshot.codexResetsHistory
        if credits.isEmpty && history.isEmpty {
            bankedResetSummaryRow
        } else {
            bankedResetLedger(credits: credits, history: history)
        }
    }

    private var bankedResetCredits: [ResetCredit] {
        if !store.snapshot.codexResetsDetail.isEmpty {
            return store.snapshot.codexResetsDetail
        }
        return store.snapshot.codexResetsExpiries.map {
            ResetCredit(grantedAt: nil, expiresAt: $0, label: "Reset credit")
        }
    }

    private var bankedResetSummaryRow: some View {
        let countText = store.snapshot.codexResetsAvailable.map { "\($0) available" } ?? "unknown"
        let expiries = store.snapshot.codexResetsExpiries.isEmpty
            ? store.snapshot.codexResetsExpireAt.map { [$0] } ?? []
            : store.snapshot.codexResetsExpiries
        let detail: String
        if let next = expiries.first {
            let formatter = DateFormatter()
            formatter.dateFormat = Calendar.current.isDateInToday(next) ? "'today' HH:mm" : "d MMM HH:mm"
            var text = "next expires \(formatter.string(from: next))"
            if expiries.count > 1 {
                let rest = DateFormatter()
                rest.dateFormat = "d MMM"
                text += " · then " + expiries.dropFirst().map { rest.string(from: $0) }.joined(separator: ", ")
            }
            detail = text
        } else {
            detail = "expiry unknown"
        }
        return row("Banked resets", detail: "\(countText) · \(detail)", icon: "arrow.counterclockwise.circle", accent: PaceTheme.blue)
    }

    private func bankedResetLedger(credits: [ResetCredit], history: [ResetCredit]) -> some View {
        let count = store.snapshot.codexResetsAvailable ?? credits.count
        let pastRows = Array(history.prefix(5))
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PaceTheme.blue)
                Text("Banked resets · \(count) available")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }
            VStack(spacing: 0) {
                ForEach(Array(credits.enumerated()), id: \.offset) { item in
                    resetCreditRow(item.element)
                    if item.offset < credits.count - 1 {
                        Divider()
                            .overlay(PaceTheme.stroke)
                    }
                }
            }
            if !pastRows.isEmpty {
                Text("Past resets")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PaceTheme.muted)
                    .textCase(.uppercase)
                VStack(spacing: 0) {
                    ForEach(Array(pastRows.enumerated()), id: \.offset) { item in
                        resetHistoryRow(item.element)
                        if item.offset < pastRows.count - 1 {
                            Divider()
                                .overlay(PaceTheme.stroke)
                        }
                    }
                }
                .opacity(0.75)
            }
        }
        .padding(10)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PaceTheme.stroke))
    }

    private func resetHistoryRow(_ credit: ResetCredit) -> some View {
        let wasUsed = credit.status.lowercased() == "redeemed"
        let badgeText = wasUsed ? "used" : "expired"
        let detail: String
        if wasUsed {
            let when = credit.resolvedAt.map { resetDateString($0, format: "d MMM HH:mm") }
            detail = when.map { "used \($0)" } ?? "used"
        } else {
            detail = "lapsed \(resetDateString(credit.expiresAt, format: "d MMM HH:mm"))"
        }
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credit.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PaceTheme.muted)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let grantedAt = credit.grantedAt {
                        Text("granted \(resetDateString(grantedAt, format: "d MMM"))")
                    }
                    Text(detail)
                }
                .font(.caption2)
                .foregroundStyle(PaceTheme.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(badgeText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(PaceTheme.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(minWidth: 58)
                .background(PaceTheme.muted.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.vertical, 6)
    }

    private func resetCreditRow(_ credit: ResetCredit) -> some View {
        let grantedText = credit.grantedAt.map { "granted \(resetDateString($0, format: "d MMM"))" }
        let expiresText = "expires \(resetDateString(credit.expiresAt, format: "d MMM HH:mm"))"
        let badgeAccent = resetBadgeAccent(credit.expiresAt)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credit.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let grantedText = grantedText {
                        Text(grantedText)
                    }
                    Text(expiresText)
                }
                .font(.caption2)
                .foregroundStyle(PaceTheme.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(resetDaysLeftText(credit.expiresAt))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(badgeAccent)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(minWidth: 58)
                .background(badgeAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.vertical, 6)
    }

    private func resetDateString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private func resetDaysLeftText(_ date: Date) -> String {
        let seconds = date.timeIntervalSince(Date())
        guard seconds > 0 else { return "expired" }
        let days = max(0, Int(seconds / 86_400))
        return days == 1 ? "1d left" : "\(days)d left"
    }

    private func resetBadgeAccent(_ date: Date) -> Color {
        let days = date.timeIntervalSince(Date()) / 86_400
        if days < 3 { return PaceTheme.coral }
        if days < 7 { return PaceTheme.amber }
        return PaceTheme.muted
    }

    private func quotaRow(_ quota: QuotaReading) -> some View {
        let accent = quotaAccent(quota)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(quota.engine) \(quota.window)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(quota.freshness)
                        .font(.caption2)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.16), in: Capsule())
                }
                Text("resets in \(quota.resetText) · \(quota.sinceResetText) since reset · source \(quota.sourceAgeText)")
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(quota.remainingPercentText)
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
                Text(quota.paceText.isEmpty ? quota.usedPercentText : "\(quota.usedPercentText) · \(quota.paceText)")
                    .font(.caption2)
                    .foregroundStyle(quota.paceState == .good ? PaceTheme.muted : accent)
                    .monospacedDigit()
                ProgressView(value: quota.remainingPercent ?? 0, total: 100)
                    .tint(accent)
                    .frame(width: 118)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 66)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(0.18)))
    }

    private var paceList: some View {
        section("Pace") {
            if store.snapshot.burnRates.isEmpty {
                row("No burn data", detail: "Recent token events not found", icon: "speedometer", accent: PaceTheme.muted)
            } else {
                ForEach(store.snapshot.burnRates.sorted(by: burnSort)) { burnRate in
                    burnRow(burnRate)
                }
            }
        }
    }

    private func burnRow(_ burnRate: BurnReading) -> some View {
        let accent = burnAccent(burnRate)
        return HStack(spacing: 12) {
            Image(systemName: "flame")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(burnRate.engine) pace")
                        .font(.system(size: 13, weight: .semibold))
                    Text(burnRate.freshness)
                        .font(.caption2)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accent.opacity(0.16), in: Capsule())
                }
                Text("\(burnRate.paceEquationText) · \(burnRate.evidenceText) · \(burnRate.activeSessions) active")
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(burnRate.tokensPerMinuteText)
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
                Text(burnRate.capEstimateText)
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 58)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(0.18)))
    }

    private var sessionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Recent Sessions") {
                ForEach(store.snapshot.sessions) { session in
                    sessionRow(session)
                }
            }
            section("History") {
                row("24h", detail: "\(store.snapshot.history.sessions24h) sessions, \(formattedTokens(store.snapshot.history.tokens24h)) estimated tokens", icon: "clock", accent: PaceTheme.teal)
                row("7d", detail: "\(store.snapshot.history.sessions7d) sessions, \(formattedTokens(store.snapshot.history.tokens7d)) estimated tokens", icon: "calendar", accent: PaceTheme.blue)
            }
        }
        .padding(18)
    }

    private var systemView: some View {
        VStack(alignment: .leading, spacing: 12) {
            section("Source") {
                row(store.snapshot.sourceLabel, detail: sourceDetail, icon: store.snapshot.sourceIsSample ? "doc.text" : "checkmark.seal", accent: store.snapshot.sourceIsSample ? PaceTheme.amber : PaceTheme.green)
            }
            section("Machine") {
                row("Load", detail: store.snapshot.system.load, icon: "cpu", accent: PaceTheme.teal)
                row("Disk", detail: DistributionMode.isAppStore ? "Hidden by sandbox" : "\(store.snapshot.system.diskFreeGB)GB free", icon: "internaldrive", accent: PaceTheme.blue)
                row("Power", detail: store.snapshot.system.power, icon: "powerplug", accent: PaceTheme.amber)
            }
            section("Actions") {
                if DistributionMode.isAppStore {
                    Button {
                        store.connectSnapshotSource()
                    } label: {
                        Label("Connect Snapshot Source", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    row("App Store build", detail: "Sandboxed snapshot viewer", icon: "lock", accent: PaceTheme.green)
                } else {
                    Button {
                        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: ProductIdentity.installedAppPath), configuration: NSWorkspace.OpenConfiguration())
                    } label: {
                        Label("Relaunch \(ProductIdentity.displayName)", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit \(ProductIdentity.displayName)", systemImage: "power")
                }
            }
        }
        .padding(18)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PaceTheme.muted)
                .textCase(.uppercase)
            content()
        }
    }

    private func row(_ title: String, detail: String, icon: String, accent: Color = PaceTheme.muted) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PaceTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PaceTheme.stroke))
    }

    private func sessionRow(_ session: SessionReading) -> some View {
        let insight = store.insight(for: session)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(session.source.prefix(2).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(sourceAccent(session.source))
                    .frame(width: 34, height: 24)
                    .background(sourceAccent(session.source).opacity(0.18), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(insight?.oneLine.isEmpty == false ? insight!.oneLine : session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(sessionDetail(session))
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(sessionTokenText(session))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text(session.tokenBasis)
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.muted)
                }
            }
            sessionInsightBlock(session, insight: insight)
        }
        .padding(10)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PaceTheme.stroke))
    }

    @ViewBuilder
    private func sessionInsightBlock(_ session: SessionReading, insight: SessionInsight?) -> some View {
        if let insight = insight {
            VStack(alignment: .leading, spacing: 4) {
                if !insight.produced.isEmpty {
                    insightLine(icon: "checkmark.seal", text: insight.produced, accent: PaceTheme.green)
                }
                if !insight.wasted.isEmpty && insight.wasted.lowercased() != "no obvious waste" {
                    insightLine(icon: "exclamationmark.triangle", text: insight.wasted, accent: PaceTheme.amber)
                }
                if let pct = insight.usefulPercent {
                    HStack(spacing: 6) {
                        Text("Useful")
                            .font(.caption2)
                            .foregroundStyle(PaceTheme.muted)
                        ProgressView(value: Double(max(0, min(100, pct))) / 100.0)
                            .frame(maxWidth: 90)
                            .tint(usefulAccent(pct))
                        Text("\(pct)%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(usefulAccent(pct))
                    }
                }
            }
            .padding(.leading, 44)
        } else if store.isSummarising(session) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarising…")
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
            }
            .padding(.leading, 44)
        } else if SessionInsightStore.uuid(forSessionID: session.id) != nil {
            Button {
                store.summarise(session)
            } label: {
                Label("Explain this session", systemImage: "sparkles")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PaceTheme.blue)
            .padding(.leading, 44)
        }
    }

    private func insightLine(icon: String, text: String, accent: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 14)
            Text(text)
                .font(.caption2)
                .foregroundStyle(PaceTheme.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func usefulAccent(_ pct: Int) -> Color {
        if pct >= 60 { return PaceTheme.green }
        if pct >= 30 { return PaceTheme.amber }
        return PaceTheme.coral
    }

    private func compactSessionRow(_ session: SessionReading) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.status == "running" ? "waveform.path.ecg" : "checkmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(sourceAccent(session.source))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(sessionDetail(session))
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(sessionTokenText(session))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(sourceAccent(session.source).opacity(0.16)))
    }

    private var cardFill: Color {
        PaceTheme.card.opacity(0.96)
    }

    private func quotaSort(_ lhs: QuotaReading, _ rhs: QuotaReading) -> Bool {
        (lhs.remainingPercent ?? 101) < (rhs.remainingPercent ?? 101)
    }

    private func quotaAccent(_ quota: QuotaReading) -> Color {
        switch quota.paceState {
        case .good: return PaceTheme.green
        case .hot: return PaceTheme.amber
        case .critical: return PaceTheme.coral
        case .unknown: return PaceTheme.muted
        }
    }

    private func burnSort(_ lhs: BurnReading, _ rhs: BurnReading) -> Bool {
        lhs.tokensPerMinute > rhs.tokensPerMinute
    }

    private func burnAccent(_ burnRate: BurnReading) -> Color {
        if let quotaPace = burnRate.quotaPercentPerMinute,
           quotaPace > 0.01,
           let remaining = burnRate.remainingPercent {
            let capMinutes = remaining / quotaPace
            if capMinutes <= 10 { return PaceTheme.coral }
            if capMinutes <= 30 { return PaceTheme.amber }
        }
        if burnRate.engine.lowercased().contains("codex") { return PaceTheme.teal }
        if burnRate.engine.lowercased().contains("claude") { return PaceTheme.amber }
        return PaceTheme.blue
    }

    private func sourceAccent(_ source: String) -> Color {
        if source.lowercased().contains("codex") { return PaceTheme.teal }
        if source.lowercased().contains("claude") { return PaceTheme.amber }
        return PaceTheme.blue
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    private func formattedTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }

    private func sessionTokenText(_ session: SessionReading) -> String {
        session.tokens > 0 ? formattedTokens(session.tokens) : "pending"
    }

    private func displayCwd(_ cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "unknown" else { return "cwd unknown" }

        let homePath = homeURL.path
        if trimmed == homePath { return "~" }
        if trimmed.hasPrefix(homePath + "/") {
            return "~" + String(trimmed.dropFirst(homePath.count))
        }
        return trimmed
    }

    private func sessionDetail(_ session: SessionReading) -> String {
        let model = session.model == "unknown" ? "" : " · \(session.model)"
        return "\(displayCwd(session.cwd))\(model) · \(session.status) · \(relativeTime(session.lastActivity))"
    }

    private func quotaBrief(for engine: String) -> String {
        guard let quota = store.snapshot.quotas.first(where: { $0.engine == engine && $0.window == "5h" }) else {
            return "quota unknown"
        }
        return "\(quota.remainingPercentText) · resets \(quota.resetDetailText)"
    }
}

struct GaugeMark: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(PaceTheme.cardAlt)
            GaugeShape(startDegrees: 205, endDegrees: -25)
                .stroke(PaceTheme.muted.opacity(0.34), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .padding(7)
            GaugeShape(startDegrees: 205, endDegrees: 72)
                .stroke(PaceTheme.teal, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .padding(7)
            GaugeShape(startDegrees: 68, endDegrees: 20)
                .stroke(PaceTheme.amber, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .padding(7)
            Rectangle()
                .fill(Color.white)
                .frame(width: 3, height: 14)
                .rotationEffect(.degrees(38))
                .offset(x: 4, y: -3)
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
        }
        .overlay(Circle().stroke(PaceTheme.stroke))
    }
}

struct GaugeShape: Shape {
    let startDegrees: Double
    let endDegrees: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.16)
        let radius = min(rect.width, rect.height) * 0.42
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(startDegrees),
            endAngle: .degrees(endDegrees),
            clockwise: true
        )
        return path
    }
}

struct PaceGraphView: View {
    let burnRates: [BurnReading]
    let renderDate: Date

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                gridPath(in: proxy.size)
                    .stroke(PaceTheme.stroke, style: StrokeStyle(lineWidth: 1, dash: [3, 5]))

                ForEach(burnRates) { burnRate in
                    graphPath(for: burnRate, in: proxy.size)
                        .stroke(accent(for: burnRate), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))

                    ForEach(Array(burnRate.points.enumerated()), id: \.offset) { index, point in
                        Circle()
                            .fill(accent(for: burnRate))
                            .frame(width: dotSize(for: point), height: dotSize(for: point))
                            .opacity(point.tokens > 0 ? dotOpacity : 0.24)
                            .position(position(for: point, index: index, count: burnRate.points.count, in: proxy.size))
                    }
                }

                scanlinePath(in: proxy.size)
                    .stroke(Color.white.opacity(0.20), style: StrokeStyle(lineWidth: 1.3, lineCap: .round))

                VStack {
                    Spacer()
                    HStack {
                        Text("15m ago")
                        Spacer()
                        Text("now")
                    }
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted.opacity(0.78))
                }
            }
        }
    }

    private var maxRate: Double {
        let rates = burnRates.flatMap { burnRate in
            burnRate.points.map(\.tokensPerMinute) + [burnRate.tokensPerMinute]
        }
        return max(1, rates.max() ?? 1)
    }

    private var dotOpacity: Double {
        0.66 + 0.24 * pulse
    }

    private var pulse: Double {
        let phase = renderDate.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
        return (sin(phase * 2 * .pi) + 1) / 2
    }

    private func dotSize(for point: PacePoint) -> CGFloat {
        guard point.tokens > 0 else { return 2 }
        return 3.4 + CGFloat(pulse) * 1.8
    }

    private func graphPath(for burnRate: BurnReading, in size: CGSize) -> Path {
        var path = Path()
        guard !burnRate.points.isEmpty else { return path }
        for (index, point) in burnRate.points.enumerated() {
            let position = position(for: point, index: index, count: burnRate.points.count, in: size)
            if index == 0 {
                path.move(to: position)
            } else {
                path.addLine(to: position)
            }
        }
        return path
    }

    private func scanlinePath(in size: CGSize) -> Path {
        var path = Path()
        let phase = renderDate.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
        let x = CGFloat(phase) * max(1, size.width)
        path.move(to: CGPoint(x: x, y: 6))
        path.addLine(to: CGPoint(x: x, y: max(7, size.height - 18)))
        return path
    }

    private func gridPath(in size: CGSize) -> Path {
        var path = Path()
        let top = CGFloat(8)
        let bottom = max(top + 1, size.height - 18)
        for step in 0...3 {
            let y = top + (bottom - top) * CGFloat(step) / 3
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        return path
    }

    private func position(for point: PacePoint, index: Int, count: Int, in size: CGSize) -> CGPoint {
        let usableHeight = max(1, size.height - 26)
        let top = CGFloat(8)
        let denominator = max(1, count - 1)
        let x = CGFloat(index) / CGFloat(denominator) * max(1, size.width)
        let normalized = min(1, max(0, point.tokensPerMinute / maxRate))
        let y = top + CGFloat(1 - normalized) * usableHeight
        return CGPoint(x: x, y: y)
    }

    private func accent(for burnRate: BurnReading) -> Color {
        if burnRate.engine.lowercased().contains("codex") { return PaceTheme.teal }
        if burnRate.engine.lowercased().contains("claude") { return PaceTheme.amber }
        return PaceTheme.blue
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusBarController()
    }
}

@MainActor
final class DebugWindowDelegate: NSObject, NSApplicationDelegate {
    private let store = PaceStore()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let controller = NSHostingController(rootView: PacePanelView(store: store))
        let window = NSWindow(contentViewController: controller)
        window.title = "\(ProductIdentity.displayName) Debug"
        window.setContentSize(NSSize(width: 440, height: 560))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        store.refreshFull()
    }
}

@MainActor
final class VerifyPopoverDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusController = StatusBarController()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let ok = self.statusController?.verifyPopoverToggle() ?? false
            print(ok ? "verify_popover_action=pass" : "verify_popover_action=fail")
            exit(ok ? 0 : 9)
        }
    }
}

enum DateFormatting {
    static func dumpString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: date)
    }
}

enum DateParsers {
    static func any(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        return fractional.date(from: string) ?? standard.date(from: string)
    }
}

func number(_ value: Any?) -> Double? {
    if let number = value as? Double { return number }
    if let number = value as? Int { return Double(number) }
    if let string = value as? String { return Double(string) }
    return nil
}

func int(_ value: Any?) -> Int {
    if let int = value as? Int { return int }
    if let double = value as? Double { return Int(double) }
    if let string = value as? String { return Int(string) ?? 0 }
    return 0
}

func bool(_ value: Any?) -> Bool {
    if let bool = value as? Bool { return bool }
    if let int = value as? Int { return int != 0 }
    if let string = value as? String {
        return ["1", "true", "yes", "enabled"].contains(string.lowercased())
    }
    return false
}

func string(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let int = value as? Int { return String(int) }
    if let double = value as? Double { return String(double) }
    if let bool = value as? Bool { return bool ? "true" : "false" }
    return nil
}

func shell(_ command: String) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    } catch {
        return ""
    }
}

let args = CommandLine.arguments
if args.contains("--dump-summary") {
    print(PaceSnapshot.collect(refreshFeeds: true).dumpText)
    exit(0)
}

let app = NSApplication.shared
if args.contains("--verify-popover-action") {
    let delegate = VerifyPopoverDelegate()
    app.delegate = delegate
    app.run()
} else if args.contains("--debug-window") {
    let delegate = DebugWindowDelegate()
    app.delegate = delegate
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
