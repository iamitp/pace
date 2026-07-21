import AppKit
import SwiftUI
import Foundation
import Combine
import ServiceManagement

let homeURL = FileManager.default.homeDirectoryForCurrentUser

enum ProductIdentity {
    static let displayName = "Pace"
    static var subtitleLocal: String { LocalMode.isCodexOnly ? "Codex pace and session control" : "AI pace and session control" }
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
    // Codex-only live tick is 2s: burn ingestion is burn-only + tail-read +
    // date-scoped discovery, so each tick costs single-digit milliseconds.
    static var livePaceRefresh: TimeInterval { LocalMode.isCodexOnly ? 2.0 : 0.25 }
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
    var codexWeeklyPools: [WeeklyPool] = []

    static func collect(refreshFeeds: Bool = false, includeSlowReadings: Bool = true, previous: PaceSnapshot? = nil, statusOnly: Bool = false, burnOnly: Bool = false) -> PaceSnapshot {
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
            snapshot.quotas = QuotaReader.read(engine: "Codex", feedURL: PaceFeedPaths.codexFeed, weeklyKey: "secondary")
        } else {
            snapshot.quotas = [
                QuotaReader.read(engine: "Claude", relativePath: ".claude/claude-usage.json", weeklyKey: "weekly"),
                QuotaReader.read(engine: "Codex", feedURL: PaceFeedPaths.codexFeed, weeklyKey: "secondary")
            ].flatMap { $0 }
        }
        let metadata = CodexUsageMetadataReader.read()
        snapshot.codexResetsAvailable = metadata.resetsAvailable
        snapshot.codexResetsExpireAt = metadata.resetsExpireAt
        snapshot.codexResetsExpiries = metadata.resetsExpiries
        snapshot.codexResetsDetail = metadata.resetsDetail
        snapshot.codexResetsHistory = metadata.resetsHistory
        snapshot.codexWeeklyPools = metadata.weeklyPools
        if statusOnly {
            snapshot.burnRates = previous?.burnRates ?? []
            snapshot.sessions = previous?.sessions ?? []
            snapshot.history = previous?.history ?? HistoryReading.empty
        } else if burnOnly {
            // The 2s bar tick: fresh quotas + burn, everything slow reused.
            snapshot.burnRates = BurnRateReader.read(quotas: snapshot.quotas, scope: .live)
            snapshot.sessions = previous?.sessions ?? []
            snapshot.history = previous?.history ?? HistoryReading.empty
        } else {
            snapshot.burnRates = BurnRateReader.read(quotas: snapshot.quotas, scope: includeSlowReadings ? .full : .live)
            let recentSessions = SessionReader.recentSessions(limit: includeSlowReadings ? 160 : 20)
            snapshot.sessions = Array(recentSessions.prefix(10))
            snapshot.history = includeSlowReadings ? HistoryReader.history(from: recentSessions) : (previous?.history ?? HistoryReader.history(from: recentSessions))
        }
        // The usage feed alone can't distinguish "meter shows 100%" from
        // "server is refusing" — that verdict lives in the session rollouts.
        // Attach the freshest serving evidence to the Codex 5h reading so the
        // fumes state can render.
        if let idx = snapshot.quotas.firstIndex(where: { $0.engine == "Codex" && $0.window == "5h" }) {
            if let burn = snapshot.burnRates.first(where: { $0.engine == "Codex" }), burn.lastEventAt != nil {
                snapshot.quotas[idx].lastServedAt = burn.lastEventAt
                snapshot.quotas[idx].limitReached = burn.rateLimitReached
            } else if statusOnly {
                let signal = BurnRateReader.codexServingSignal()
                snapshot.quotas[idx].lastServedAt = signal.lastServedAt
                snapshot.quotas[idx].limitReached = signal.limitReached
            }
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
        let poolText = codexWeeklyPools.map { "\($0.name)=\($0.usedPercent)%used/resets=\($0.resetsAt.map(DateFormatting.dumpString) ?? "?")" }.joined(separator: ",")
        lines.append("codex_weekly_pools=\(poolText.isEmpty ? "none" : poolText)")
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
        if LocalMode.isCodexOnly {
            lines.append("status_bar_title=\"\(StatusBarText.codexTitle(for: self))\"")
        }
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
    var lastServedAt: Date? = nil
    var limitReached: Bool? = nil

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

    // When usage is ahead of elapsed time, turn the abstract pace multiple
    // into the decision the user actually needs: roughly how early the meter
    // would be exhausted if the current pace held.
    var projectedCapLeadText: String? {
        guard let usedPercent,
              usedPercent >= 5,
              let resetAt,
              let windowDuration,
              let elapsedFraction = windowElapsedFraction,
              elapsedFraction > 0.01,
              let paceRatio,
              paceRatio > 1 else { return nil }
        let elapsed = windowDuration * elapsedFraction
        let projectedTotal = elapsed / (usedPercent / 100)
        let projectedRemaining = max(0, projectedTotal - elapsed)
        let resetRemaining = max(0, resetAt.timeIntervalSince(Date()))
        let lead = resetRemaining - projectedRemaining
        guard lead >= 15 * 60 else { return nil }
        return compactDuration(lead)
    }

    private func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    var paceText: String {
        if isOnFumes { return "on fumes · still serving" }
        if limitReached == true, (remainingPercent ?? 100) <= 1 { return "capped" }
        guard (usedPercent ?? 0) >= 5 else { return "quiet" }
        guard let paceRatio else { return "" }
        if paceRatio < 0.85 { return "under pace" }
        if paceRatio < 1.15 { return "on pace" }
        return String(format: "%.1f× pace", paceRatio)
    }

    // The meter is a report, not a cutoff: Codex's 5h window is rolling and
    // enforcement happens per request, so a session can keep being served at
    // "0% left". The freshest in-session rate_limits block carries the server's
    // actual verdict (rate_limit_reached_type). Fumes = meter exhausted, no
    // enforcement flag, and requests landed within the last few minutes.
    var isOnFumes: Bool {
        guard window == "5h", let remaining = remainingPercent, remaining <= 1 else { return false }
        guard limitReached != true, let lastServedAt else { return false }
        return Date().timeIntervalSince(lastServedAt) < 180
    }

    enum PaceState { case unknown, good, hot, critical, fumes }

    var paceState: PaceState {
        if isOnFumes { return .fumes }
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
    let status: String
    let nextStep: String
    let usefulPercent: Int?
}

enum SessionInsightStore {
    // The Python summariser (scripts/session-insight.py) caches results in this
    // file, keyed by the session's internal UUID.
    static let cachePath = homeURL.appendingPathComponent(".claude/pace-session-insights.json")
    // Where the app shells out to for an on-demand summary.
    static let scriptPath = homeURL.appendingPathComponent(".claude/session-insight.py")

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
                status: str("status"),
                nextStep: str("next_step"),
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
    var rateLimitReached: Bool? = nil

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

    // Three-bucket thrust levels (0…1) for the menu bar. Present only while
    // tokens are flowing (live/fresh); empty so the idle bar stays clean.
    var barSparkLevels: [Double] {
        guard freshness == "live" || freshness == "fresh" else { return [] }
        let recent = points.suffix(3)
        guard !recent.isEmpty else { return [] }
        let peak = max(points.map(\.tokensPerMinute).max() ?? 0, 1)
        return recent.map { min(1, max(0, $0.tokensPerMinute / peak)) }
    }

    // Glyph rendering of the same levels for the text dump.
    var barSparkline: String {
        let glyphs: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇"]
        return String(barSparkLevels.map { level in
            glyphs[min(glyphs.count - 1, max(0, Int((level * Double(glyphs.count - 1)).rounded())))]
        })
    }

    // Minutes until the 5h cap at the current observed drain rate, or nil when
    // there is no live quota-delta evidence to project from.
    var capMinutes: Double? {
        guard let quotaPercentPerMinute, quotaPercentPerMinute > 0.01, let remainingPercent else { return nil }
        return remainingPercent / quotaPercentPerMinute
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

enum QuotaWindowClassifier {
    private enum Kind: Equatable { case fiveHour, weekly }

    // The API's field positions are not semantic. It can now return a seven-day
    // meter in `primary` with no `secondary`, so classify by duration and use
    // the legacy field roles only when a feed has no duration at all.
    static func canonical(
        primary: [String: Any]?,
        secondary: [String: Any]?
    ) -> (fiveHour: [String: Any]?, weekly: [String: Any]?) {
        let primary = primary.flatMap(hasReading)
        let secondary = secondary.flatMap(hasReading)
        let candidates = [primary, secondary].compactMap { $0 }

        var fiveHour = candidates.first { kind(of: $0) == .fiveHour }
        var weekly = candidates.first { kind(of: $0) == .weekly }
        if fiveHour == nil, let primary, kind(of: primary) == nil {
            fiveHour = primary
        }
        if weekly == nil, let secondary, kind(of: secondary) == nil {
            weekly = secondary
        }
        return (fiveHour, weekly)
    }

    private static func hasReading(_ window: [String: Any]) -> [String: Any]? {
        let hasValue = number(window["used_percent"]) != nil
            || number(window["window_minutes"]) != nil
            || DateParsers.any(window["resets_at"]) != nil
        return hasValue ? window : nil
    }

    private static func kind(of window: [String: Any]) -> Kind? {
        guard let minutes = number(window["window_minutes"]), minutes > 0 else { return nil }
        return minutes < 24 * 60 ? .fiveHour : .weekly
    }
}

enum QuotaReader {
    static func read(engine: String, relativePath: String, weeklyKey: String) -> [QuotaReading] {
        read(engine: engine, feedURL: homeURL.appendingPathComponent(relativePath), weeklyKey: weeklyKey)
    }

    static func read(engine: String, feedURL path: URL, weeklyKey: String) -> [QuotaReading] {
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
        let primaryCandidate = quotaWindow(
            object,
            nestedKey: "primary",
            usedKey: "five_hour_used_pct",
            resetKey: "five_hour_resets_at_unix",
            windowKey: "five_hour_window_minutes"
        )
        let weeklyCandidate = quotaWindow(
            object,
            nestedKey: weeklyKey,
            usedKey: "weekly_used_pct",
            resetKey: "weekly_resets_at_unix",
            windowKey: "weekly_window_minutes"
        )
        let windows = QuotaWindowClassifier.canonical(
            primary: primaryCandidate,
            secondary: weeklyCandidate
        )
        let primary = windows.fiveHour ?? [:]
        let weekly = windows.weekly ?? [:]

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

struct WeeklyPool: Identifiable {
    let name: String
    let usedPercent: Int
    let resetsAt: Date?
    var id: String { name }
}

enum CodexUsageMetadataReader {
    struct Metadata {
        let resetsAvailable: Int?
        let resetsExpireAt: Date?
        let resetsExpiries: [Date]
        let resetsDetail: [ResetCredit]
        let resetsHistory: [ResetCredit]
        let weeklyPools: [WeeklyPool]
    }

    static func read() -> Metadata {
        let path = PaceFeedPaths.codexFeed
        guard
            let data = try? Data(contentsOf: path),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Metadata(resetsAvailable: nil, resetsExpireAt: nil, resetsExpiries: [], resetsDetail: [], resetsHistory: [], weeklyPools: [])
        }
        let weeklyPools = ((object["weekly_pools"] as? [Any]) ?? [])
            .compactMap { value -> WeeklyPool? in
                guard let o = value as? [String: Any] else { return nil }
                let name = (o["name"] as? String) ?? "Codex"
                let used = optionalInt(o["used_percent"]) ?? 0
                return WeeklyPool(name: name, usedPercent: used, resetsAt: DateParsers.any(o["resets_at"]))
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
            resetsHistory: history,
            weeklyPools: weeklyPools
        )
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

enum PaceFeedPaths {
    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeURL.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Pace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var externalCodexFeed: URL { homeURL.appendingPathComponent(".claude/codex-usage.json") }
    static var nativeCodexFeed: URL { appSupportDir.appendingPathComponent("codex-usage.json") }
    static var nativeResetLedger: URL { appSupportDir.appendingPathComponent("codex-resets-ledger.json") }

    // Freshest available feed wins: machines running an external poller keep
    // the ~/.claude file newest; plain installs only ever have the native one.
    static var codexFeed: URL {
        mtime(externalCodexFeed) >= mtime(nativeCodexFeed) ? externalCodexFeed : nativeCodexFeed
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

// Native port of codex-usage-poll.py so public installs need no external
// scripts: polls the same wham endpoints the Codex app uses, with the token
// from ~/.codex/auth.json, and maintains the reset-credit ledger locally -
// the wham API drops a credit from its response once redeemed or expired,
// so this ledger is the only durable history.
enum NativeUsagePoller {
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private static let creditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    static func poll() {
        guard let auth = authToken() else { return }
        guard let usage = fetchJSON(usageURL, token: auth.token, account: auth.account),
              let rate = usage["rate_limit"] as? [String: Any] else { return }
        var out: [String: Any] = [
            "updated_at": Int(Date().timeIntervalSince1970),
            "source_reading_at": ISO8601DateFormatter().string(from: Date()),
            "source": "wham/usage"
        ]
        out["plan_type"] = usage["plan_type"]
        out["account_email"] = usage["email"]
        out["account_id"] = usage["account_id"]
        let windows = QuotaWindowClassifier.canonical(
            primary: windowDict(rate["primary_window"]),
            secondary: windowDict(rate["secondary_window"])
        )
        if let window = windows.fiveHour { out["primary"] = window }
        if let window = windows.weekly { out["secondary"] = window }
        var pools: [[String: Any]] = []
        if var main = windows.weekly {
            main["name"] = "Codex"
            pools.append(main)
        }
        for extra in (usage["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            let name = (extra["limit_name"] as? String) ?? (extra["metered_feature"] as? String) ?? "Codex"
            if let sub = extra["rate_limit"] as? [String: Any],
               var window = QuotaWindowClassifier.canonical(
                   primary: windowDict(sub["primary_window"]),
                   secondary: windowDict(sub["secondary_window"])
               ).weekly {
                window["name"] = name
                pools.append(window)
            }
        }
        out["weekly_pools"] = pools
        if let creditsPayload = fetchJSON(creditsURL, token: auth.token, account: auth.account) {
            let all = (creditsPayload["credits"] as? [[String: Any]]) ?? []
            out["resets_history"] = reconcileLedger(credits: all)
            let available = all.filter { ($0["status"] as? String) == "available" }
            out["resets_detail"] = available.compactMap { credit -> [String: Any]? in
                guard let expires = credit["expires_at"] else { return nil }
                var entry: [String: Any] = ["expires_at": expires, "label": creditLabel(credit)]
                entry["granted_at"] = credit["granted_at"]
                return entry
            }
            if let count = creditsPayload["available_count"] as? Int { out["resets_available"] = count }
            let expiries = available.compactMap { $0["expires_at"] as? String }.sorted()
            if let first = expiries.first {
                out["resets_next_expiry"] = first
                out["resets_expire_at"] = first
                out["resets_expiries"] = expiries
            }
        } else if let summary = usage["rate_limit_reset_credits"] as? [String: Any],
                  let count = summary["available_count"] as? Int {
            out["resets_available"] = count
        }
        let (model, effort) = codexModel()
        if let model { out["model"] = model }
        if let effort { out["model_reasoning_effort"] = effort }
        writeAtomically(out, to: PaceFeedPaths.nativeCodexFeed)
    }

    private static func authToken() -> (token: String, account: String)? {
        let url = homeURL.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let tokens = (object["tokens"] as? [String: Any]) ?? [:]
        let token = ((tokens["access_token"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let account = ((tokens["account_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (token, account)
    }

    private final class FetchBox: @unchecked Sendable {
        var value: [String: Any]?
    }

    private static func fetchJSON(_ url: URL, token: String, account: String) -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Pace usage poller", forHTTPHeaderField: "User-Agent")
        if !account.isEmpty { request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id") }
        let semaphore = DispatchSemaphore(value: 0)
        let box = FetchBox()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else { return }
            box.value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return box.value
    }

    private static func windowDict(_ value: Any?) -> [String: Any]? {
        guard let window = value as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        out["used_percent"] = window["used_percent"]
        if let seconds = number(window["limit_window_seconds"]) {
            out["window_minutes"] = Int(seconds / 60)
        }
        out["resets_at"] = window["reset_at"]
        return out
    }

    private static func creditLabel(_ credit: [String: Any]) -> String {
        let description = ((credit["description"] as? String) ?? "").lowercased()
        if description.contains("inviting") { return "Referral" }
        return (credit["profile_user_id"] as? String) ?? "Codex Team"
    }

    private static func reconcileLedger(credits: [[String: Any]]) -> [[String: Any]] {
        let nowISO = ISO8601DateFormatter().string(from: Date())
        var ledger: [String: Any] = [:]
        if let data = try? Data(contentsOf: PaceFeedPaths.nativeResetLedger),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            ledger = object
        }
        var entries = (ledger["credits"] as? [String: [String: Any]]) ?? [:]
        var seen = Set<String>()
        for credit in credits {
            let cid = (credit["id"] as? String) ?? "\(credit["granted_at"] ?? "")|\(credit["expires_at"] ?? "")"
            seen.insert(cid)
            var entry = entries[cid] ?? ["first_seen": nowISO]
            entry["granted_at"] = credit["granted_at"] ?? entry["granted_at"]
            entry["expires_at"] = credit["expires_at"] ?? entry["expires_at"]
            entry["label"] = creditLabel(credit)
            let status = (credit["status"] as? String) ?? "available"
            entry["status"] = status
            entry["last_seen"] = nowISO
            if status != "available", entry["resolved_at"] == nil {
                entry["resolved_at"] = credit["redeemed_at"] ?? nowISO
            }
            entries[cid] = entry
        }
        // Credits the API stopped returning were consumed or lapsed; record which.
        for (cid, entry) in entries {
            let status = entry["status"] as? String
            guard !seen.contains(cid), status == nil || status == "available" else { continue }
            var updated = entry
            let lapsed = DateParsers.any(entry["expires_at"]).map { Date() >= $0 } ?? false
            updated["status"] = lapsed ? "expired" : "redeemed"
            if updated["resolved_at"] == nil { updated["resolved_at"] = nowISO }
            entries[cid] = updated
        }
        ledger["credits"] = entries
        writeAtomically(ledger, to: PaceFeedPaths.nativeResetLedger)
        return entries.values
            .filter { ($0["status"] as? String) != "available" && $0["expires_at"] != nil }
            .sorted { (($0["resolved_at"] as? String) ?? "") > (($1["resolved_at"] as? String) ?? "") }
            .prefix(8)
            .map { entry in
                var out: [String: Any] = ["label": (entry["label"] as? String) ?? "Codex Team"]
                out["granted_at"] = entry["granted_at"]
                out["expires_at"] = entry["expires_at"]
                out["status"] = entry["status"]
                out["resolved_at"] = entry["resolved_at"]
                return out
            }
    }

    private static func codexModel() -> (model: String?, effort: String?) {
        guard let text = try? String(contentsOf: homeURL.appendingPathComponent(".codex/config.toml"), encoding: .utf8) else {
            return (nil, nil)
        }
        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
        return (capture("^\\s*model\\s*=\\s*\"([^\"]+)\""), capture("^\\s*model_reasoning_effort\\s*=\\s*\"([^\"]+)\""))
    }

    private static func writeAtomically(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

enum QuotaFeedRefresher {
    private static let feeds = [
        ("Claude", ".claude/claude-usage.json", ".claude/claude-usage-poll.py"),
        ("Codex", ".claude/codex-usage.json", ".claude/codex-usage-poll.py")
    ]

    static func refreshLocalFeedsIfNeeded() {
        let selectedFeeds = LocalMode.isCodexOnly ? feeds.filter { $0.0 == "Codex" } : feeds
        for (engine, feedPath, scriptPath) in selectedFeeds {
            let script = homeURL.appendingPathComponent(scriptPath)
            if FileManager.default.isReadableFile(atPath: script.path) {
                let feed = homeURL.appendingPathComponent(feedPath)
                guard shouldRefresh(feed) else { continue }
                runPythonScript(script)
            } else if engine == "Codex" {
                // No external poller on this machine (public install): poll
                // the wham endpoints natively into Application Support.
                guard shouldRefresh(PaceFeedPaths.nativeCodexFeed) else { continue }
                NativeUsagePoller.poll()
            }
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
        var rateLimitReached: Bool? = nil
    }

    private static let windowSeconds: TimeInterval = 15 * 60

    static func read(quotas: [QuotaReading], scope: ReadScope = .full) -> [BurnReading] {
        let events = readEvents(scope: scope)
        let engines = LocalMode.isCodexOnly ? ["Codex"] : ["Codex", "Claude"]
        return engines.map { engine in
            reading(engine: engine, events: events.filter { $0.engine == engine }, quotas: quotas)
        }
    }

    // Lightweight serving evidence for status-only refreshes, which skip the
    // full burn read: when did a Codex request last land, and has the server
    // flagged the limit as actually reached.
    static func codexServingSignal() -> (lastServedAt: Date?, limitReached: Bool?) {
        let events = readCodexEvents(scope: .live).sorted { $0.timestamp < $1.timestamp }
        return (events.last?.timestamp, events.reversed().compactMap(\.rateLimitReached).first)
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
        let limitFlag = recent.reversed().compactMap(\.rateLimitReached).first
        return BurnReading(
            engine: engine,
            tokens: tokens,
            tokensPerMinute: tokensPerMinute,
            windowSeconds: elapsed,
            quotaPercentPerMinute: quotaPace,
            remainingPercent: remaining,
            activeSessions: activeSessions,
            lastEventAt: lastEventAt,
            points: points,
            rateLimitReached: limitFlag
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

    // Rollouts are laid out by date (sessions/yyyy/MM/dd); anything live is in
    // today's or yesterday's directory, so scan just those instead of walking
    // months of history on every tick. Falls back to the full tree when the
    // scoped directories are empty (fresh installs, clock oddities).
    static func codexRecentFiles(limit: Int) -> [URL] {
        let root = homeURL.appendingPathComponent(".codex/sessions")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let days = [Date(), Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()]
        let scoped = days.flatMap { recentJSONLFiles(root: root.appendingPathComponent(formatter.string(from: $0)), limit: limit) }
        guard !scoped.isEmpty else {
            return recentJSONLFiles(root: root, limit: limit)
        }
        return Array(scoped.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.prefix(limit))
    }

    // Most files surfaced by discovery haven't changed between ticks — only
    // the actively-streaming rollout grows. Re-parsing unchanged tails every
    // 2s wasted the bulk of the tick, so parses are cached per (size, mtime).
    private struct EventCacheEntry {
        let size: UInt64
        let mtime: Date
        let lineLimit: Int
        let events: [BurnEvent]
    }
    nonisolated(unsafe) private static var eventCache: [String: EventCacheEntry] = [:]
    private static let eventCacheLock = NSLock()

    private static func readCodexEvents(scope: ReadScope) -> [BurnEvent] {
        let files = codexRecentFiles(limit: scope.maxFilesPerRoot)
        return files.flatMap { file -> [BurnEvent] in
            let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let mtime = (attributes?[.modificationDate] as? Date) ?? .distantPast
            eventCacheLock.lock()
            let cached = eventCache[file.path]
            eventCacheLock.unlock()
            if let cached, cached.size == size, cached.mtime == mtime, cached.lineLimit >= scope.maxLinesPerFile {
                return cached.events
            }
            let events = parseCodexEvents(file: file, limit: scope.maxLinesPerFile)
            eventCacheLock.lock()
            eventCache[file.path] = EventCacheEntry(size: size, mtime: mtime, lineLimit: scope.maxLinesPerFile, events: events)
            if eventCache.count > 256 {
                let keep = Set(files.map(\.path))
                eventCache = eventCache.filter { keep.contains($0.key) }
            }
            eventCacheLock.unlock()
            return events
        }
    }

    private static func parseCodexEvents(file: URL, limit: Int) -> [BurnEvent] {
        return recentLines(file, limit: limit).compactMap { line -> BurnEvent? in
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
                let secondary = rateLimits?["secondary"] as? [String: Any]
                let fiveHour = QuotaWindowClassifier.canonical(
                    primary: primary,
                    secondary: secondary
                ).fiveHour
                let reached: Bool? = rateLimits.map { limits in
                    guard let value = limits["rate_limit_reached_type"], !(value is NSNull) else { return false }
                    return true
                }
                return BurnEvent(
                    engine: "Codex",
                    tokens: tokens,
                    // A weekly-only payload must never drive the short-window
                    // cap ETA. Token throughput remains useful without it.
                    quotaUsedPercent: number(fiveHour?["used_percent"]),
                    timestamp: timestamp,
                    session: file.path,
                    rateLimitReached: reached
                )
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

    // The newest rollout file's mtime is the cheapest "is anything running"
    // signal; it gates the always-on bar refresh so idle periods cost nothing.
    static func codexActivity(within seconds: TimeInterval) -> Bool {
        guard let newest = codexRecentFiles(limit: 1).first,
              let modified = try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return Date().timeIntervalSince(modified) < seconds
    }

    private static func recentLines(_ file: URL, limit: Int) -> Array<Substring> {
        // Tail-read: long-running rollout files grow to many MB, and the live
        // refresh only needs the last `limit` lines. 256 KB covers that with
        // huge margin without loading the whole file each tick.
        let maxBytes: UInt64 = 262_144
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd() else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n")
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.suffix(limit))
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
        // The live tick (small limit) only needs what changed recently, so it
        // scans today's and yesterday's rollout directories instead of walking
        // the entire dated tree (which grows into the tens of thousands of
        // files). The launch/history path (large limit) still walks everything.
        let files = roots.flatMap { root -> [URL] in
            if limit <= 30, root.path.hasSuffix(".codex/sessions") {
                return codexScopedFiles(root: root, limit: fileLimit)
            }
            return recentJSONLFiles(root: root, limit: fileLimit)
        }
        return files.compactMap(parseSession).sorted { $0.lastActivity > $1.lastActivity }.prefix(limit).map { $0 }
    }

    private static func codexScopedFiles(root: URL, limit: Int) -> [URL] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        let days = [Date(), Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()]
        let scoped = days.flatMap { recentJSONLFiles(root: root.appendingPathComponent(formatter.string(from: $0)), limit: limit) }
        // Only trust the scoped scan when it can fill the whole list; on
        // semi-idle Macs (or any date/directory mismatch) fall back to the
        // full walk so the sessions list never silently shrinks.
        guard scoped.count >= limit else {
            return recentJSONLFiles(root: root, limit: limit)
        }
        return Array(scoped.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.prefix(limit))
    }

    // parseSession fully decoded every candidate file on every pass, and live
    // rollouts run to many MB. Unchanged files are served from a (size, mtime)
    // cache; only the actively-written file is re-read, and even that read is
    // head+tail chunks rather than the whole file (the parser only ever looks
    // at the first and last few dozen lines anyway).
    private struct SessionCacheEntry {
        let size: UInt64
        let mtime: Date
        let reading: SessionReading
    }
    nonisolated(unsafe) private static var sessionCache: [String: SessionCacheEntry] = [:]
    private static let sessionCacheLock = NSLock()

    private static func refreshedStatus(_ reading: SessionReading) -> SessionReading {
        guard reading.status != "done" else { return reading }
        let age = Date().timeIntervalSince(reading.lastActivity)
        let status = age < 15 * 60 ? "running" : "waiting"
        guard status != reading.status else { return reading }
        return SessionReading(id: reading.id, source: reading.source, repo: reading.repo, title: reading.title, workspace: reading.workspace, cwd: reading.cwd, model: reading.model, status: status, tokens: reading.tokens, tokenBasis: reading.tokenBasis, lastActivity: reading.lastActivity)
    }

    private static func sessionText(_ url: URL, size: UInt64) -> String {
        let tailBytes: UInt64 = 393_216
        let headLineTarget = 60
        let headByteCap = 4_194_304
        if size <= tailBytes + 262_144 {
            return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        // The parser wants the first `headLineTarget` lines, and rollout files
        // can open with single lines hundreds of KB long — so read forward in
        // chunks until enough full lines are buffered (with a byte cap).
        var headData = Data()
        var lineCount = 0
        while headData.count < headByteCap && lineCount <= headLineTarget {
            guard let chunk = try? handle.read(upToCount: 262_144), !chunk.isEmpty else { break }
            lineCount += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            headData.append(chunk)
        }
        if UInt64(headData.count) >= size {
            return String(decoding: headData, as: UTF8.self)
        }
        var head = String(decoding: headData, as: UTF8.self)
        if let cut = head.lastIndex(of: "\n") { head = String(head[..<cut]) }
        let tailOffset = max(size - tailBytes, UInt64(headData.count))
        guard (try? handle.seek(toOffset: tailOffset)) != nil,
              let tailData = try? handle.readToEnd() else { return head }
        var tail = String(decoding: tailData, as: UTF8.self)
        if let cut = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: cut)...]) }
        return head + "\n" + tail
    }

    private static func parseSession(_ url: URL) -> SessionReading? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let modified = (attributes[.modificationDate] as? Date) ?? .distantPast
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        sessionCacheLock.lock()
        let cached = sessionCache[url.path]
        sessionCacheLock.unlock()
        if let cached, cached.size == size, cached.mtime == modified {
            return refreshedStatus(cached.reading)
        }
        // Full mode parses far deeper into each file (prefix 160 + suffix 260
        // lines, with per-line token summation for Claude sessions), so the
        // byte-capped chunk read only stands in for the whole-file read in
        // Codex-only mode, where the parser wants prefix 60 + suffix 120.
        let text = LocalMode.isCodexOnly
            ? sessionText(url, size: size)
            : ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
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
        var isSubagent = false

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
                if (object["type"] as? String) == "session_meta",
                   let metaSource = payload["source"] as? [String: Any],
                   metaSource["subagent"] != nil {
                    isSubagent = true
                }
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

        // Review/guardian/worker rollouts are implementation detail, not
        // separate pieces of Amit's work. Showing them duplicates the parent
        // task and can attach a review verdict to the wrong project.
        if isSubagent { return nil }

        let workspace = workspaceName(cwd: cwd, file: url)
        let title = explicitTitle ?? fallbackTitle ?? workspace
        let tokens = source == "Claude" ? claudeTokens : codexTokens
        let tokenBasis = source == "Claude" ? "deduped estimate" : "cumulative log"
        let age = Date().timeIntervalSince(modified)
        let status = done ? "done" : (age < 15 * 60 ? "running" : "waiting")
        let reading = SessionReading(id: url.path, source: source, repo: title, title: title, workspace: workspace, cwd: cwd, model: model, status: status, tokens: tokens, tokenBasis: tokenBasis, lastActivity: modified)
        sessionCacheLock.lock()
        sessionCache[url.path] = SessionCacheEntry(size: size, mtime: modified, reading: reading)
        if sessionCache.count > 512 {
            let cutoff = Date().addingTimeInterval(-48 * 3600)
            sessionCache = sessionCache.filter { $0.value.mtime > cutoff }
        }
        sessionCacheLock.unlock()
        return reading
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
        if cwd != "unknown" {
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            if name == NSUserName() { return "home" }
            if !name.isEmpty { return name }
        }
        let parent = file.deletingLastPathComponent().lastPathComponent
        let cleaned = parent
            .replacingOccurrences(of: "-Users-\(NSUserName())-", with: "")
            .replacingOccurrences(of: "-Users-\(NSUserName())", with: "home")
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
        let path = ProcessInfo.processInfo.environment["PACE_TODO_FILE"].map { URL(fileURLWithPath: $0) }
            ?? homeURL.appendingPathComponent(".pace/todo.md")
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
            SessionReading(id: "sample-1", source: "Codex", repo: "release-readiness", title: "Prepare direct release packet", workspace: "release-readiness", cwd: "/Users/you/projects/pace", model: "gpt-5.5", status: "running", tokens: 1320000, tokenBasis: "snapshot", lastActivity: Date().addingTimeInterval(-180)),
            SessionReading(id: "sample-2", source: "Codex", repo: "snapshot-import", title: "Import usage snapshot", workspace: "snapshot-import", cwd: "/Users/you/Library/Mobile Documents/com~apple~CloudDocs/Pace", model: "gpt-5.5", status: "done", tokens: 428000, tokenBasis: "snapshot", lastActivity: Date().addingTimeInterval(-2400)),
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
    let seshControl = SeshControlController(backend: SeshControlBackend())
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

    func refresh(refreshFeeds: Bool = false, includeSlowReadings: Bool = true, statusOnly: Bool = false, burnOnly: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        let previous = snapshot
        Task.detached {
            let next = PaceSnapshot.collect(refreshFeeds: refreshFeeds, includeSlowReadings: includeSlowReadings, previous: previous, statusOnly: statusOnly, burnOnly: burnOnly)
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

    func refreshBurn() {
        refresh(refreshFeeds: false, includeSlowReadings: false, burnOnly: true)
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
    private var liveTick = 0
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
                guard let self else { return }
                if self.popover.isShown {
                    if LocalMode.isCodexOnly {
                        // Burn every tick (2s); sessions/history every 5th.
                        self.liveTick += 1
                        if self.liveTick % 5 == 0 {
                            self.store.refreshLivePace()
                        } else {
                            self.store.refreshBurn()
                        }
                    } else {
                        self.store.refreshLivePace()
                    }
                } else if LocalMode.isCodexOnly, BurnRateReader.codexActivity(within: 300) {
                    // Feed the bar sparkline while a session is writing;
                    // the mtime probe keeps idle periods at zero read cost.
                    self.store.refreshBurn()
                }
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
            let color = StatusBarText.codexBarColor(for: snapshot)
            if let parts = StatusBarText.codexTitleParts(for: snapshot) {
                button.attributedTitle = StatusBarText.attributedTitle(parts: parts, color: color)
            } else {
                button.attributedTitle = NSAttributedString(string: "--", attributes: [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
                ])
            }
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
    // Tiny drawn bar chart for the menu bar thrust display. Rounded caps,
    // older buckets faded, newest solid - crisper than font block glyphs.
    static func sparkImage(levels: [Double], color: NSColor) -> NSImage {
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2
        let height: CGFloat = 11
        let width = CGFloat(levels.count) * barWidth + CGFloat(max(0, levels.count - 1)) * gap
        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, level) in levels.enumerated() {
                let barHeight = max(2.5, height * CGFloat(min(1, max(0, level))))
                let rect = NSRect(x: CGFloat(index) * (barWidth + gap), y: 0, width: barWidth, height: barHeight)
                let alpha = index == levels.count - 1 ? 1.0 : 0.35 + 0.2 * CGFloat(index)
                color.withAlphaComponent(alpha).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
            }
            return true
        }
    }

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
    struct CodexTitleParts {
        enum DetailStyle {
            case none      // healthy window: just the percentage
            case ambient   // constrained: quiet countdown to the reset
            case urgent    // live drain will hit the cap before relief
            case fumes     // meter exhausted but requests still landing
        }

        let sparkLevels: [Double]
        let percentText: String
        let detailText: String
        let detailStyle: DetailStyle
    }

    // Weekly capacity is the durable planning number Amit wants at a glance.
    // A five-hour meter, when the account publishes one, remains a secondary
    // pressure signal and can still colour or annotate the headline.
    static func headlineQuota(for snapshot: PaceSnapshot) -> QuotaReading? {
        let codex = snapshot.quotas.filter { $0.engine == "Codex" && $0.usedPercent != nil }
        return codex.first(where: { $0.window == "week" })
            ?? codex.first(where: { $0.window == "5h" })
    }

    static func codexTitleParts(for snapshot: PaceSnapshot) -> CodexTitleParts? {
        guard let quota = headlineQuota(for: snapshot),
              let remainingPercent = quota.remainingPercent else {
            return nil
        }
        let burn = snapshot.burnRates.first { $0.engine == "Codex" }
        let pct = "\(Int(remainingPercent.rounded()))% \(quota.window == "week" ? "wk" : "5h")"
        let levels = burn?.barSparkLevels ?? []
        let fiveHour = snapshot.quotas.first {
            $0.engine == "Codex" && $0.window == "5h" && $0.usedPercent != nil
        }
        // Cap ETA outranks reset text, but only when it is the binding
        // constraint: live drain, hitting within 2h, and before the reset
        // would grant relief anyway.
        if let fiveHour, let capText = capText(quota: fiveHour, burn: burn) {
            return CodexTitleParts(sparkLevels: levels, percentText: pct, detailText: "5h \(capText)", detailStyle: .urgent)
        }
        // Meter exhausted but the server is still landing requests: say so
        // instead of showing a dead 0%.
        if let fiveHour, fiveHour.isOnFumes {
            return CodexTitleParts(sparkLevels: levels, percentText: pct, detailText: "5h \(fiveHour.resetText)", detailStyle: .fumes)
        }
        if let fiveHourRemaining = fiveHour?.remainingPercent, fiveHourRemaining <= 30 {
            return CodexTitleParts(sparkLevels: levels, percentText: pct, detailText: "5h \(Int(fiveHourRemaining.rounded()))%", detailStyle: .ambient)
        }
        if remainingPercent <= 30 {
            return CodexTitleParts(sparkLevels: levels, percentText: pct, detailText: quota.resetText, detailStyle: .ambient)
        }
        return CodexTitleParts(sparkLevels: levels, percentText: pct, detailText: "", detailStyle: .none)
    }

    static func codexBarColor(for snapshot: PaceSnapshot) -> NSColor {
        // Softer palette: neutral monochrome at rest, green only while
        // tokens are actually flowing, amber/red reserved for pressure.
        let burnLive = snapshot.burnRates.first { $0.engine == "Codex" }?.freshness == "live"
        let short = snapshot.quotas.first {
            $0.engine == "Codex" && $0.window == "5h" && $0.usedPercent != nil
        }
        let pressureQuota: QuotaReading?
        if let short {
            switch short.paceState {
            case .hot, .critical, .fumes: pressureQuota = short
            default: pressureQuota = headlineQuota(for: snapshot)
            }
        } else {
            pressureQuota = headlineQuota(for: snapshot)
        }
        switch pressureQuota?.paceState {
        case .good: return burnLive ? .systemGreen : .labelColor
        case .hot: return .systemOrange
        case .fumes: return .systemOrange
        case .critical: return .systemRed
        default: return .labelColor
        }
    }

    static func attributedTitle(parts: CodexTitleParts, color: NSColor) -> NSAttributedString {
        let title = NSMutableAttributedString()
        if !parts.sparkLevels.isEmpty {
            let attachment = NSTextAttachment()
            let image = StatusIcon.sparkImage(levels: parts.sparkLevels, color: color)
            attachment.image = image
            attachment.bounds = NSRect(x: 0, y: -1, width: image.size.width, height: image.size.height)
            title.append(NSAttributedString(attachment: attachment))
            title.append(NSAttributedString(string: " "))
        }
        title.append(NSAttributedString(string: parts.percentText, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: color
        ]))
        if parts.detailStyle != .none {
            // Quiet countdown vs urgent cap ETA: the small text carries
            // the meaning through weight and colour, not words. Fumes is the
            // one state that needs a word - "0%" alone reads as dead.
            let urgent = parts.detailStyle == .urgent
            let detail = parts.detailStyle == .fumes ? "fumes \(parts.detailText)" : parts.detailText
            title.append(NSAttributedString(string: " " + detail, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: urgent ? .semibold : .regular),
                .foregroundColor: urgent ? (color == .labelColor ? .systemOrange : color) : NSColor.secondaryLabelColor
            ]))
        }
        return title
    }

    static func codexTitle(for snapshot: PaceSnapshot) -> String {
        guard let parts = codexTitleParts(for: snapshot) else { return "--" }
        let spark = snapshot.burnRates.first { $0.engine == "Codex" }?.barSparkline ?? ""
        var pieces = [String]()
        if !spark.isEmpty { pieces.append(spark) }
        pieces.append(parts.percentText)
        switch parts.detailStyle {
        case .none: break
        case .ambient: pieces.append("-\(parts.detailText)")
        case .urgent: pieces.append("cap \(parts.detailText)")
        case .fumes: pieces.append("fumes -\(parts.detailText)")
        }
        return pieces.joined(separator: " ")
    }

    static func capText(quota: QuotaReading, burn: BurnReading?) -> String? {
        guard quota.window == "5h",
              let burn, burn.freshness == "live", let capMinutes = burn.capMinutes, capMinutes < 120 else { return nil }
        if let resetAt = quota.resetAt {
            let resetMinutes = max(0, resetAt.timeIntervalSince(Date()) / 60)
            guard capMinutes < resetMinutes else { return nil }
        }
        if capMinutes < 1 { return "<1m" }
        if capMinutes < 60 { return "\(Int(capMinutes.rounded()))m" }
        let hours = Int(capMinutes / 60)
        let minutes = Int(capMinutes.truncatingRemainder(dividingBy: 60).rounded())
        return minutes > 0 ? "\(hours)h\(String(format: "%02d", minutes))m" : "\(hours)h"
    }

    static func codexTooltip(for snapshot: PaceSnapshot) -> String {
        let fiveHour = snapshot.quotas.first { $0.engine == "Codex" && $0.window == "5h" }
        let weekly = snapshot.quotas.first { $0.engine == "Codex" && $0.window == "week" }
        let fiveHourText = fiveHour.flatMap { $0.usedPercent == nil ? nil : $0 }
            .map { "\($0.remainingPercentText), \($0.usedPercentText), \($0.paceText), \($0.sinceResetText) since reset, resets \($0.resetDetailText)" }
            ?? "not reported by this account"
        let weeklyText = weekly.flatMap { $0.usedPercent == nil ? nil : $0 }
            .map { "\($0.remainingPercentText), \($0.usedPercentText), \($0.paceText), \($0.sinceResetText) since reset, resets \($0.resetDetailText)" }
            ?? "not reported by this account"
        let resetAllowance = resetAllowanceText(for: snapshot)
        let paceLine: String
        if let burn = snapshot.burnRates.first(where: { $0.engine == "Codex" }), burn.tokensPerMinute > 0, burn.freshness != "idle" {
            paceLine = "Pace: \(burn.tokensPerMinuteText) (\(burn.freshness)) · \(burn.capEstimateText)"
        } else {
            paceLine = "Pace: idle"
        }
        let servingNote = fiveHour?.isOnFumes == true
            ? "\nMeter exhausted but requests are still landing. The 5h window is rolling, so capacity trickles back before the full reset."
            : ""
        return "Codex 5h: \(fiveHourText)\nCodex week: \(weeklyText)\(servingNote)\n\(paceLine)\n\(resetAllowance)"
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
                Text("Hours").tag("Hours")
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
                case "Hours":
                    hourlyView
                case "System":
                    systemView
                default:
                    nowView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PaceTheme.panel)
            .foregroundStyle(.white)
        }
        .frame(width: 480, height: 520)
        .background(PaceTheme.panel)
    }

    // Static composition for self-rendered README screenshots: Menu, Picker
    // and ScrollView do not survive offscreen ImageRenderer, so this uses a
    // buttonless header and the Now content directly.
    var screenshotBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                GaugeMark().frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ProductIdentity.displayName).font(.system(size: 18, weight: .semibold))
                    Text(ProductIdentity.subtitleLocal).font(.caption).foregroundStyle(PaceTheme.muted)
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider()
            nowView
        }
        .frame(width: 480)
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
            settingsMenu
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

    private var settingsMenu: some View {
        Menu {
            Toggle("Launch at Login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { enable in
                    do {
                        if enable {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        NSLog("Pace: launch-at-login toggle failed: \(error.localizedDescription)")
                    }
                }
            ))
            if !DistributionMode.isAppStore {
                Toggle("Also track Claude Code", isOn: Binding(
                    get: { !LocalMode.isCodexOnly },
                    set: { _ in switchMode() }
                ))
            }
            Divider()
            Button("Quit \(ProductIdentity.displayName)") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .labelStyle(.iconOnly)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
    }

    // Mode shapes the status item and timers at init; relaunch to apply.
    private func switchMode() {
        UserDefaults.standard.set(!LocalMode.isCodexOnly, forKey: "CodexOnly")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    private var needsOnboarding: Bool {
        let snapshot = store.snapshot
        let hasQuota = snapshot.quotas.contains { $0.usedPercent != nil }
        return !hasQuota && snapshot.sessions.isEmpty && snapshot.burnRates.allSatisfy { $0.tokens == 0 }
    }

    private var onboardingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Waiting for Codex data", systemImage: "binoculars")
                .font(.system(size: 13, weight: .semibold))
            Text("Pace reads ~/.codex on this Mac. Sign in to the Codex CLI or the ChatGPT desktop app and run something; usage appears here within a minute. Nothing leaves this Mac except a call to OpenAI's own usage endpoint with your token.")
                .font(.caption)
                .foregroundStyle(PaceTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PaceTheme.stroke))
    }

    private var hourlyView: some View {
        HourlyUsageView(includeClaude: !LocalMode.isCodexOnly)
    }

    private var nowView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if needsOnboarding {
                onboardingCard
            }
            if !DistributionMode.isAppStore {
                SeshControlCard(controller: store.seshControl)
            }
            capacityHero
            if !supplementalQuotas.isEmpty {
                section("Other limits") {
                    supplementalQuotaList
                }
            }
            if store.snapshot.codexResetsAvailable != nil {
                bankedResetSummaryRow
            }
            if !LocalMode.isCodexOnly {
                burnStrip
            }
            recentWorkHighlights
            if shouldShowSourceBanner {
                sourceBanner
            }
            if !store.snapshot.alerts.isEmpty {
                section("Needs attention") {
                    ForEach(store.snapshot.alerts, id: \.self) { alert in
                        row(alert, detail: "Action may be needed", icon: "exclamationmark.triangle", accent: PaceTheme.amber)
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
        .foregroundStyle(.white)
    }

    // Lead with a decision, not telemetry. Token flow is evidence; capacity and
    // whether work can continue are what the user actually needs to know.
    private var capacityHero: some View {
        let quota = StatusBarText.headlineQuota(for: store.snapshot)
        let accent = quota.map(quotaAccent) ?? PaceTheme.muted
        let burn = store.snapshot.burnRates.first { $0.engine == "Codex" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Capacity now")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PaceTheme.muted)
                    .textCase(.uppercase)
                Spacer()
                if let quota {
                    Text(quota.window == "week" ? "Weekly" : "5-hour")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(accent.opacity(0.16), in: Capsule())
                        .foregroundStyle(accent)
                }
            }
            if let quota {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(capacityHeadline(quota))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(quota.remainingPercentText)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
                Text(capacityRecommendation(quota))
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(capacityEvidence(quota))
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(accent)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(x: CGFloat((quota.remainingPercent ?? 0) / 100), anchor: .leading)
                }
                .frame(height: 6)
                if quota.window == "week" && !hasPublishedFiveHourQuota {
                    Text("The account is publishing a weekly meter only; Pace will not relabel it as 5h.")
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.muted)
                }
            } else {
                Text("Waiting for a quota reading")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Pace has session activity but no correctly classified capacity window yet.")
                    .font(.caption)
                    .foregroundStyle(PaceTheme.muted)
            }
            if let burn, burn.activeSessions > 0 {
                Label("\(burn.activeSessions) active session\(burn.activeSessions == 1 ? "" : "s") now", systemImage: "waveform.path.ecg")
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.teal)
            }
        }
        .padding(12)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(0.28)))
    }

    private var hasPublishedFiveHourQuota: Bool {
        store.snapshot.quotas.contains {
            $0.engine == "Codex" && $0.window == "5h" && $0.usedPercent != nil
        }
    }

    private func capacityHeadline(_ quota: QuotaReading) -> String {
        switch quota.paceState {
        case .critical: return "Capacity at risk"
        case .hot: return "Using faster than plan"
        case .fumes: return "Still serving"
        case .good:
            return (quota.remainingPercent ?? 0) >= 50 ? "Comfortable" : "On track"
        case .unknown: return "Reading available"
        }
    }

    private func capacityRecommendation(_ quota: QuotaReading) -> String {
        switch quota.paceState {
        case .critical:
            return quota.window == "5h"
                ? "Prioritise the current task; short-term capacity may run out before reset."
                : "Weekly capacity may run out before reset; prioritise the work that matters."
        case .hot:
            if let lead = quota.projectedCapLeadText {
                return "If this pace holds, capacity reaches 100% about \(lead) before reset."
            }
            return "Usage is ahead of elapsed time in this window; keep an eye on remaining capacity."
        case .fumes:
            return "Requests are still landing, but there is almost no measured short-term headroom."
        case .good:
            return "You can keep working normally; this pool is tracking to last until reset."
        case .unknown:
            return "Pace has the meter but not enough timing evidence for a forecast yet."
        }
    }

    private func capacityEvidence(_ quota: QuotaReading) -> String {
        let window = quota.window == "week" ? "the week" : "the 5-hour window"
        return "\(quota.usedPercentText) · \(quota.sinceResetText) into \(window) · resets in \(quota.resetText)"
    }

    // The live burn, as a compact strip rather than a graph: the sparkline did
    // not earn the vertical space it took at the top of the panel.
    @ViewBuilder
    private var burnStrip: some View {
        let burnRates = store.snapshot.burnRates.sorted(by: burnSort)
        let active = burnRates.filter { $0.activeSessions > 0 || $0.tokensPerMinute > 0 }
        if !active.isEmpty {
            section("Burn · last 15m") {
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
    private var recentWorkHighlights: some View {
        let recent = Array(store.snapshot.sessions.prefix(3))
        if !recent.isEmpty {
            section("Recent work") {
                ForEach(recent) { session in
                    workHighlightRow(session)
                }
            }
        }
    }

    private func workHighlightRow(_ session: SessionReading) -> some View {
        let insight = store.insight(for: session)
        let status = workStatus(session, insight: insight)
        let accent = workStatusAccent(status)
        let outcome = insight.flatMap { value in
            if !value.produced.isEmpty { return value.produced }
            if !value.workedOn.isEmpty { return value.workedOn }
            return nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: workStatusIcon(status))
                    .foregroundStyle(accent)
                    .frame(width: 18)
                Text(sessionLabel(session, insight))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(status)
                    .font(.system(size: 9, weight: .bold))
                    .textCase(.uppercase)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.14), in: Capsule())
            }
            Text(outcome ?? sessionDetail(session))
                .font(.caption2)
                .foregroundStyle(PaceTheme.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let next = insight?.nextStep, !next.isEmpty {
                Label("Next: \(next)", systemImage: "arrow.right.circle")
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.blue)
                    .lineLimit(2)
            } else if insight == nil && session.status != "running" {
                Text("Outcome analysis pending")
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted.opacity(0.78))
            }
        }
        .padding(10)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(0.16)))
    }

    private func workStatus(_ session: SessionReading, insight: SessionInsight?) -> String {
        if session.status == "running" { return "active" }
        let status = insight?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return status.isEmpty ? session.status : status
    }

    private func workStatusAccent(_ status: String) -> Color {
        switch status {
        case "done", "complete", "completed": return PaceTheme.green
        case "blocked": return PaceTheme.coral
        case "partial", "waiting": return PaceTheme.amber
        case "active", "running": return PaceTheme.teal
        default: return PaceTheme.muted
        }
    }

    private func workStatusIcon(_ status: String) -> String {
        switch status {
        case "done", "complete", "completed": return "checkmark.circle"
        case "blocked": return "xmark.octagon"
        case "partial": return "circle.lefthalf.filled"
        case "waiting": return "pause.circle"
        case "active", "running": return "waveform.path.ecg"
        default: return "questionmark.circle"
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

    private var shouldShowSourceBanner: Bool {
        store.snapshot.sourceIsSample || store.snapshot.quotas.contains {
            $0.usedPercent != nil && ["lagging", "stale", "missing"].contains($0.freshness)
        }
    }

    private var sourceDetail: String {
        if let generatedAt = store.snapshot.sourceGeneratedAt {
            return "generated \(relativeTime(generatedAt)) · \(store.snapshot.sourceKind)"
        }
        return "\(store.snapshot.sourceKind) · generated time unknown"
    }

    private var supplementalQuotas: [QuotaReading] {
        let known = store.snapshot.quotas.filter { $0.usedPercent != nil }
        guard let headline = StatusBarText.headlineQuota(for: store.snapshot) else { return known }
        return known.filter { $0.id != headline.id }
    }

    private var supplementalQuotaList: some View {
        VStack(spacing: 8) {
            ForEach(supplementalQuotas.sorted(by: quotaSort)) { quota in
                quotaRow(quota)
            }
        }
    }

    // The account can hold more than one weekly pool. The binding (most-used) one
    // is already shown above as the Codex week quota; surface the others here so
    // Pace reconciles with the Codex app, which sometimes headlines a fresher
    // pool (e.g. GPT-5.3-Codex-Spark) and reads more optimistic than reality.
    @ViewBuilder
    private var extraWeeklyPoolRows: some View {
        let pools = store.snapshot.codexWeeklyPools
        if pools.count > 1 {
            let binding = pools.max(by: { $0.usedPercent < $1.usedPercent })
            let others = pools.filter { $0.name != binding?.name }
            ForEach(others) { pool in
                weeklyPoolRow(pool)
            }
        }
    }

    private func weeklyPoolRow(_ pool: WeeklyPool) -> some View {
        let left = max(0, 100 - pool.usedPercent)
        let detail: String
        if let reset = pool.resetsAt {
            let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
            detail = "\(pool.usedPercent)% used · resets \(f.string(from: reset))"
        } else {
            detail = "\(pool.usedPercent)% used"
        }
        return HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .foregroundStyle(PaceTheme.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(poolDisplayName(pool.name)) week")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(left)% left")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(PaceTheme.muted)
        }
        .padding(10)
        .background(cardFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PaceTheme.stroke))
    }

    private func poolDisplayName(_ name: String) -> String {
        // Trim the verbose model label to something readable in a menu row.
        if name.lowercased().contains("spark") { return "Codex-Spark" }
        return name
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
                // Custom capsule instead of ProgressView: renders offscreen
                // (README screenshots) and matches the thrust-bar language.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(accent)
                        .frame(width: 118 * CGFloat(min(100, max(0, quota.remainingPercent ?? 0))) / 100)
                }
                .frame(width: 118, height: 5)
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
                row("24h", detail: "\(store.snapshot.history.sessions24h) user work sessions", icon: "clock", accent: PaceTheme.teal)
                row("7d", detail: "\(store.snapshot.history.sessions7d) user work sessions", icon: "calendar", accent: PaceTheme.blue)
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
                    Text(sessionLabel(session, insight))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(sessionDetail(session))
                        .font(.caption2)
                        .foregroundStyle(PaceTheme.muted)
                }
                Spacer(minLength: 0)
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
                if !insight.status.isEmpty {
                    let status = insight.status.lowercased()
                    Text(status)
                        .font(.system(size: 9, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(workStatusAccent(status))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(workStatusAccent(status).opacity(0.14), in: Capsule())
                }
                if !insight.workedOn.isEmpty {
                    insightLine(icon: "scope", text: insight.workedOn, accent: PaceTheme.blue)
                }
                if !insight.produced.isEmpty {
                    insightLine(icon: "checkmark.seal", text: insight.produced, accent: PaceTheme.green)
                }
                if !insight.nextStep.isEmpty {
                    insightLine(icon: "arrow.right.circle", text: "Next: \(insight.nextStep)", accent: PaceTheme.blue)
                }
                if !insight.wasted.isEmpty && insight.wasted.lowercased() != "no obvious waste" {
                    insightLine(icon: "exclamationmark.triangle", text: insight.wasted, accent: PaceTheme.amber)
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

    // Prefer the brain-style tag from the summariser. While a live session has
    // not settled long enough to summarise, a short task phrase is still more
    // useful than three identical "Working…" rows.
    private func sessionLabel(_ session: SessionReading, _ insight: SessionInsight?) -> String {
        if let tag = insight?.oneLine, !tag.isEmpty { return tag }
        let workspace = session.workspace.trimmingCharacters(in: .whitespaces)
        if !workspace.isEmpty, !["home", "workspace", "unknown"].contains(workspace.lowercased()) {
            return workspace
        }
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !["home", "workspace", "unknown"].contains(title.lowercased()),
           !title.lowercased().hasPrefix("you are ") {
            let sentence = title.prefix(1).uppercased() + String(title.dropFirst())
            if sentence.count <= 54 { return sentence }
            let end = sentence.index(sentence.startIndex, offsetBy: 51)
            return String(sentence[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return session.status == "running" ? "Working…" : "Codex session"
    }

    private func compactSessionRow(_ session: SessionReading) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.status == "running" ? "waveform.path.ecg" : "checkmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(sourceAccent(session.source))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(sessionLabel(session, store.insight(for: session)))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(sessionDetail(session))
                    .font(.caption2)
                    .foregroundStyle(PaceTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
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
        case .fumes: return PaceTheme.amber
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
        let available = store.snapshot.quotas.filter { $0.engine == engine && $0.usedPercent != nil }
        guard let quota = available.first(where: { $0.window == "week" })
            ?? available.first(where: { $0.window == "5h" }) else {
            return "quota unknown"
        }
        return "\(quota.remainingPercentText) \(quota.window == "week" ? "weekly" : "5h") · resets \(quota.resetDetailText)"
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

// MARK: - Hourly usage ("when do I burn tokens")

// Token totals bucketed by hour of day (local time) over a recent window, read
// from the same Codex/Claude session logs Pace already ingests. Answers "when
// do I use the most tokens" - the time-of-day pattern the live 15-minute burn
// graph cannot show. Self-contained (own file walk + parse) so it never touches
// the live poller path.
struct HourlyUsage: Sendable {
    var codex: [Int]   // 24 buckets, hour 0...23
    var claude: [Int]  // 24 buckets
    var days: Int
    var lastUpdated: Date

    static let empty = HourlyUsage(codex: Array(repeating: 0, count: 24),
                                   claude: Array(repeating: 0, count: 24),
                                   days: 0, lastUpdated: .distantPast)

    var total: Int { codex.reduce(0, +) + claude.reduce(0, +) }
    var hourTotals: [Int] { (0..<24).map { codex[$0] + claude[$0] } }
    var peakHour: Int? {
        let totals = hourTotals
        guard let peak = totals.max(), peak > 0 else { return nil }
        return totals.firstIndex(of: peak)
    }

    // Busiest 3-hour window and its share of activity. A ratio, so it stays
    // meaningful even when only a recent sample of sessions has been read.
    var peakWindow: (start: Int, share: Double)? {
        let totals = hourTotals
        let grand = totals.reduce(0, +)
        guard grand > 0 else { return nil }
        var bestStart = 0
        var bestSum = -1
        for start in 0..<24 {
            let sum = (0..<3).reduce(0) { $0 + totals[(start + $1) % 24] }
            if sum > bestSum { bestSum = sum; bestStart = start }
        }
        return (bestStart, Double(bestSum) / Double(grand))
    }
}

enum HourlyUsageReader {
    nonisolated(unsafe) private static var cache: HourlyUsage?
    private static let cacheLock = NSLock()
    private static let cacheTTL: TimeInterval = 300

    private static func cached(days: Int) -> HourlyUsage? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cache, cache.days == days, Date().timeIntervalSince(cache.lastUpdated) < cacheTTL {
            return cache
        }
        return nil
    }

    // Heavy file IO; call off the main actor.
    static func load(days: Int, includeClaude: Bool) -> HourlyUsage {
        if let hit = cached(days: days) { return hit }
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        let fileCutoff = cutoff.addingTimeInterval(-2 * 86400) // archived mtime slack
        var codex = Array(repeating: 0, count: 24)
        var claude = Array(repeating: 0, count: 24)
        let calendar = Calendar.current
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Formatters are created once here and used only on this thread, so no
        // shared non-Sendable state escapes across the actor boundary.
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        func parseDate(_ value: Any?) -> Date? {
            guard let s = value as? String else { return nil }
            return isoFractional.date(from: s) ?? isoPlain.date(from: s)
        }
        func bucket(_ date: Date, into buckets: inout [Int], tokens: Int) {
            guard date >= cutoff, tokens > 0 else { return }
            let hour = calendar.component(.hour, from: date)
            if hour >= 0, hour < 24 { buckets[hour] += tokens }
        }

        // Codex: live + archived rollouts. Bounded on both axes - most-recent
        // files, and a byte prefix per file - so a fortnight of history (which
        // can run to several GB, with the odd 200MB+ long-running session) never
        // turns a tab-open into a minute of IO. Recent sessions carry the
        // overwhelming majority of volume, so the time-of-day shape is intact.
        let codexRoots = [home.appendingPathComponent(".codex/sessions"),
                          home.appendingPathComponent(".codex/archived_sessions")]
        for file in jsonlFiles(under: codexRoots, modifiedAfter: fileCutoff, limit: 450) {
            for line in lines(of: file, maxBytes: 1_500_000) {
                guard line.contains("token_count"),
                      let object = jsonLine(line),
                      let payload = object["payload"] as? [String: Any],
                      (payload["type"] as? String) == "token_count",
                      let ts = parseDate(object["timestamp"]) else { continue }
                let info = payload["info"] as? [String: Any]
                let last = info?["last_token_usage"] as? [String: Any]
                bucket(ts, into: &codex, tokens: anyInt(last?["total_tokens"]))
            }
        }

        // Claude: per-message usage, deduped by message id.
        if includeClaude {
            var seen = Set<String>()
            let claudeRoot = home.appendingPathComponent(".claude/projects")
            for file in jsonlFiles(under: [claudeRoot], modifiedAfter: fileCutoff, limit: 200) {
                for line in lines(of: file, maxBytes: 1_500_000) {
                    guard line.contains("\"usage\""),
                          let object = jsonLine(line),
                          (object["type"] as? String) == "assistant",
                          let message = object["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any],
                          let id = message["id"] as? String,
                          let ts = parseDate(object["timestamp"]) else { continue }
                    if !seen.insert(id).inserted { continue }
                    let total = anyInt(usage["input_tokens"]) + anyInt(usage["output_tokens"])
                        + anyInt(usage["cache_creation_input_tokens"]) + anyInt(usage["cache_read_input_tokens"])
                    bucket(ts, into: &claude, tokens: total)
                }
            }
        }

        let result = HourlyUsage(codex: codex, claude: claude, days: days, lastUpdated: now)
        cacheLock.lock(); cache = result; cacheLock.unlock()
        return result
    }

    private static func jsonlFiles(under roots: [URL], modifiedAfter cutoff: Date, limit: Int) -> [URL] {
        let fm = FileManager.default
        var candidates: [(url: URL, modified: Date)] = []
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in walker {
                guard url.pathExtension == "jsonl" else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < cutoff { continue }
                candidates.append((url, modified))
            }
        }
        return candidates.sorted { $0.modified > $1.modified }.prefix(limit).map(\.url)
    }

    // Read at most `maxBytes` from the head of a file and return whole lines.
    // Caps the cost of pathologically large session rollouts (a live session
    // can grow past 200MB) without slurping the whole file into memory.
    private static func lines(of file: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        if data.isEmpty { return [] }
        var text = String(decoding: data, as: UTF8.self)
        // If we stopped at the byte cap we probably cut a line in half; drop it.
        if data.count >= maxBytes, let lastNewline = text.lastIndex(of: "\n") {
            text = String(text[..<lastNewline])
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private static func jsonLine<S: StringProtocol>(_ line: S) -> [String: Any]? {
        guard let data = String(line).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func anyInt(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }
}

enum HourlyFormat {
    static func tokens(_ value: Int) -> String {
        let v = Double(value)
        if v >= 1e9 { return String(format: "%.1fB", v / 1e9) }
        if v >= 1e6 { return String(format: "%.0fM", v / 1e6) }
        if v >= 1e3 { return String(format: "%.0fk", v / 1e3) }
        return "\(value)"
    }
}

struct HourlyUsageView: View {
    let includeClaude: Bool
    let days: Int
    let preloaded: HourlyUsage?
    @State private var usage: HourlyUsage
    @State private var loading: Bool

    init(includeClaude: Bool, days: Int = 14, preloaded: HourlyUsage? = nil) {
        self.includeClaude = includeClaude
        self.days = days
        self.preloaded = preloaded
        _usage = State(initialValue: preloaded ?? .empty)
        _loading = State(initialValue: preloaded == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            chart
            footer
            Text("History older than a couple of weeks is compressed out of the live logs, so only the last ~2 weeks show here.")
                .font(.caption2)
                .foregroundStyle(PaceTheme.muted.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .task(id: days) { if preloaded == nil { await reload() } }
    }

    private func reload() async {
        loading = true
        let snapshot = await Task.detached(priority: .utility) {
            HourlyUsageReader.load(days: days, includeClaude: includeClaude)
        }.value
        usage = snapshot
        loading = false
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("When you burn tokens")
                .font(.system(size: 15, weight: .semibold))
            Text("by hour of day · last \(usage.days == 0 ? days : usage.days) days · local time")
                .font(.caption)
                .foregroundStyle(PaceTheme.muted)
        }
    }

    private var maxHour: Double { Double(max(1, usage.hourTotals.max() ?? 1)) }

    private var chart: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in bar(for: hour) }
            }
            .frame(height: 150)
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? String(format: "%02d", hour) : "")
                        .font(.system(size: 8))
                        .foregroundStyle(PaceTheme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(PaceTheme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(PaceTheme.stroke))
        .overlay {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading session history…")
                        .font(.caption)
                        .foregroundStyle(PaceTheme.muted)
                }
            }
        }
        .opacity(loading ? 0.55 : 1)
        .animation(.easeOut(duration: 0.25), value: loading)
    }

    private func bar(for hour: Int) -> some View {
        let codexHeight = 150 * Double(usage.codex[hour]) / maxHour
        let claudeHeight = 150 * Double(usage.claude[hour]) / maxHour
        let isPeak = usage.peakHour == hour
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2).fill(PaceTheme.amber)
                .frame(height: max(0, claudeHeight))
            RoundedRectangle(cornerRadius: 2)
                .fill(isPeak ? PaceTheme.teal : PaceTheme.teal.opacity(0.7))
                .frame(height: max(usage.codex[hour] > 0 ? 2 : 0, codexHeight))
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(alignment: .top, spacing: 16) {
            if let peak = usage.peakHour {
                stat("Peak hour", String(format: "%02d:00", peak), PaceTheme.teal)
            }
            if let window = usage.peakWindow {
                stat("Busiest 3h",
                     String(format: "%02d–%02d · %.0f%%", window.start, (window.start + 3) % 24, window.share * 100),
                     .white)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                legend(PaceTheme.teal, "Codex")
                if includeClaude { legend(PaceTheme.amber, "Claude") }
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10)).foregroundStyle(PaceTheme.muted).textCase(.uppercase)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption2).foregroundStyle(PaceTheme.muted)
        }
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
if args.contains("--sesh-proof") {
    print(SeshMeasurement.readRendered())
    exit(0)
}
if args.contains("--self-test-sesh-proof") {
    let passed = SeshMeasurement.selfTest()
    print(passed ? "sesh_proof_self_test=pass" : "sesh_proof_self_test=fail")
    exit(passed ? 0 : 10)
}
if args.contains("--self-test-sesh-control") {
    let passed = SeshControlBackend.selfTest()
    print(passed ? "sesh_control_self_test=pass" : "sesh_control_self_test=fail")
    exit(passed ? 0 : 11)
}
if args.contains("--self-test-sesh-benchmark") {
    let passed = SeshSlowAutoBenchmark.selfTest()
    print(passed ? "sesh_benchmark_self_test=pass" : "sesh_benchmark_self_test=fail")
    exit(passed ? 0 : 12)
}
if args.contains("--dump-summary") {
    print(PaceSnapshot.collect(refreshFeeds: true).dumpText)
    exit(0)
}
if args.contains("--self-test-window-mapping") {
    func fixture(_ used: Double, _ minutes: Double? = nil) -> [String: Any] {
        var out: [String: Any] = ["used_percent": used, "resets_at": 1_900_000_000]
        if let minutes { out["window_minutes"] = minutes }
        return out
    }
    func minutes(_ window: [String: Any]?) -> Int? {
        number(window?["window_minutes"]).map { Int($0) }
    }
    let historical = QuotaWindowClassifier.canonical(
        primary: fixture(20, 300),
        secondary: fixture(40, 10_080)
    )
    let weeklyOnly = QuotaWindowClassifier.canonical(
        primary: fixture(7, 10_080),
        secondary: nil
    )
    let reversed = QuotaWindowClassifier.canonical(
        primary: fixture(7, 10_080),
        secondary: fixture(20, 300)
    )
    var weeklySnapshot = PaceSnapshot()
    weeklySnapshot.quotas = [
        QuotaReading(
            engine: "Codex",
            window: "week",
            usedPercent: 7,
            resetAt: Date().addingTimeInterval(6 * 86_400),
            source: "fixture",
            updatedAt: Date(),
            windowMinutes: 10_080
        )
    ]
    let title = StatusBarText.codexTitleParts(for: weeklySnapshot)?.percentText
    let passed = minutes(historical.fiveHour) == 300
        && minutes(historical.weekly) == 10_080
        && weeklyOnly.fiveHour == nil
        && minutes(weeklyOnly.weekly) == 10_080
        && minutes(reversed.fiveHour) == 300
        && minutes(reversed.weekly) == 10_080
        && title == "93% wk"
    print(passed ? "window_mapping=pass headline=\(title ?? "missing")" : "window_mapping=fail headline=\(title ?? "missing")")
    exit(passed ? 0 : 8)
}
struct BarMockView: View {
    let levels: [Double]
    let percent: String
    let detail: String
    let urgent: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(color.opacity(index == levels.count - 1 ? 1 : 0.35 + 0.2 * Double(index)))
                        .frame(width: 3, height: max(2.5, 11 * level))
                }
            }
            Text(percent)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10.5, weight: urgent ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(urgent ? color : Color.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 6))
    }
}

if let flagIndex = args.firstIndex(of: "--screenshot"), args.count > flagIndex + 1 {
    // Self-rendered README screenshots: no Screen Recording permission needed.
    let dir = URL(fileURLWithPath: args[flagIndex + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = PaceStore()
    store.snapshot = PaceSnapshot.collect(refreshFeeds: true)
    store.seshControl.refreshSynchronouslyForScreenshot()

    func writePNG<Content: View>(_ view: Content, name: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: dir.appendingPathComponent(name))
        print("wrote \(name)")
    }

    writePNG(PacePanelView(store: store).screenshotBody.fixedSize(horizontal: false, vertical: true), name: "popover.png")
    writePNG(
        BarMockView(levels: [0.35, 0.7, 1.0], percent: "90% wk", detail: "", urgent: false, color: Color(nsColor: .labelColor))
            .padding(8).background(Color(white: 0.16)),
        name: "menubar.png"
    )
    exit(0)
}
if args.contains("--native-poll") {
    // Diagnostic: exercise the built-in wham poller (the public-install path)
    // regardless of any external poller scripts on this machine.
    NativeUsagePoller.poll()
    print((try? String(contentsOf: PaceFeedPaths.nativeCodexFeed, encoding: .utf8)) ?? "no native feed written")
    exit(0)
}

if args.contains("--hours") {
    // Diagnostic: exercise the hour-of-day reader headlessly and render a
    // preview PNG, so the "Hours" tab can be verified without a GUI session.
    let usage = HourlyUsageReader.load(days: 14, includeClaude: true)
    var out = "hours last=\(usage.days)d peak=\(usage.peakHour.map { String(format: "%02d:00", $0) } ?? "-") total=\(HourlyFormat.tokens(usage.total))\n"
    for hour in 0..<24 {
        out += String(format: "  %02d  codex=%-6@ claude=%-6@\n", hour,
                      HourlyFormat.tokens(usage.codex[hour]) as NSString,
                      HourlyFormat.tokens(usage.claude[hour]) as NSString)
    }
    print(out)
    let renderer = ImageRenderer(content:
        HourlyUsageView(includeClaude: true, preloaded: usage)
            .frame(width: 480)
            .background(PaceTheme.panel)
            .foregroundStyle(.white))
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pace-hours.png")
        try? png.write(to: url)
        print("wrote \(url.path)")
    }
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
