import AppKit
import SwiftUI

private struct SeshControlRefreshPayload: Sendable {
    let status: SeshControlStatus?
    let selection: SeshWorkspaceSelection?
    let errorMessage: String?
}

@MainActor
final class SeshControlController: ObservableObject {
    @Published private(set) var selection: SeshWorkspaceSelection?
    @Published private(set) var status: SeshControlStatus?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isActing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var economyOn = false

    private let backend: SeshControlBackend
    private var refreshGeneration = 0

    init(backend: SeshControlBackend) {
        self.backend = backend
    }

    var hasProject: Bool { selection != nil }

    var hasSavedManagedTask: Bool {
        selection?.hasSavedManagedCodexState == true
    }

    var stateLabel: String {
        guard hasProject else { return "NO PROJECT" }
        switch status?.conductor?.phase {
        case .working: return "WORKING"
        case .complete: return "COMPLETE"
        case .failed: return "FAILED"
        case nil: return hasSavedManagedTask ? "MANAGED" : "READY"
        }
    }

    var isConductorWorking: Bool {
        status?.conductor?.phase == .working
    }

    var primaryActionTitle: String {
        hasSavedManagedTask ? "Resume Managed Task" : "Start Managed Task"
    }

    var projectLabel: String {
        selection?.url.lastPathComponent ?? "Choose a project"
    }

    var projectPath: String {
        selection?.url.path ?? "No project selected"
    }

    var quotaText: String? {
        guard let quota = status?.quota else { return nil }
        let order = ["codex", "claude"]
        let parts = order.compactMap { key -> String? in
            guard let value = quota[key] else { return nil }
            let label = key.prefix(1).uppercased() + key.dropFirst()
            return "\(label) \(Int(value.remainingPercent.rounded()))%"
        }
        return parts.isEmpty ? nil : "Capacity input: " + parts.joined(separator: "  |  ")
    }

    var phaseText: String? {
        guard let conductor = status?.conductor else { return nil }
        let workers = conductor.workers
        let routeText = workers.planned == 0
            ? "direct provider thread"
            : "\(workers.planned) delegated worker\(workers.planned == 1 ? "" : "s") planned"
        return "Phase: \(Self.display(conductor.phase.rawValue)); \(routeText)"
    }

    var urgencyText: String? {
        guard let urgency = status?.conductor?.urgency ?? status?.latestRun?.urgency else {
            return nil
        }
        return "Inferred urgency: \(Self.display(urgency.rawValue))"
    }

    var topologyText: String? {
        if let run = status?.latestRun {
            let observed = Self.display(run.topology.rawValue)
            let recommended = Self.display(run.recommendedTopology.rawValue)
            return observed == recommended
                ? "Observed topology: \(observed)"
                : "Observed topology: \(observed); recommended \(recommended)"
        }
        guard let conductor = status?.conductor else { return nil }
        return "Observed topology: pending; current plan \(Self.display(conductor.topology.rawValue))"
    }

    var routesText: String? {
        let routes = status?.latestRun?.routes ?? status?.conductor?.routes ?? []
        let topology = status?.latestRun?.topology ?? status?.conductor?.topology
        guard !routes.isEmpty else { return nil }
        let parts = routes.prefix(4).map { route in
            let stage = topology == .direct && route.stage == "conductor"
                ? "Direct"
                : Self.display(route.stage)
            let tier = route.serviceTier == "priority" ? ", priority" : ""
            let count = route.count > 1 ? " x\(route.count)" : ""
            return "\(stage) \(route.model) / \(route.effort)\(tier)\(count)"
        }
        return "Routes: " + parts.joined(separator: "  |  ")
    }

    var usageText: String? {
        guard let run = status?.latestRun else { return nil }
        guard run.usageComplete, let total = run.totalTokens else {
            return "Usage: incomplete provider tree; no savings claim"
        }
        let scope = run.usageScope == "fresh-thread-tree-cumulative-total"
            ? "complete fresh-thread tree"
            : "complete turn tree"
        return "Usage: \(Self.compactCount(total)) total tokens; \(scope)"
    }

    var verificationText: String? {
        if let run = status?.latestRun {
            return "Verification: \(Self.display(run.verification.rawValue)); outcome \(Self.display(run.outcome))"
        }
        guard let verification = status?.conductor?.verification else { return nil }
        return "Verification: \(Self.display(verification.rawValue))"
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        errorMessage = nil

        Task { [backend] in
            let payload = await Task.detached(priority: .userInitiated) {
                Self.readPayload(backend: backend)
            }.value
            guard generation == self.refreshGeneration else { return }
            self.apply(payload)
            self.isRefreshing = false
        }
    }

    /// Used only by the headless screenshot diagnostic, where there is no run
    /// loop to await the normal asynchronous refresh.
    func refreshSynchronouslyForScreenshot() {
        apply(Self.readPayload(backend: backend))
        isRefreshing = false
    }

    func selectWorkspace(_ url: URL) {
        guard !isActing else { return }
        isActing = true
        errorMessage = nil
        notice = nil

        Task { [backend] in
            do {
                let selected = try await Task.detached(priority: .userInitiated) {
                    try backend.selectWorkspace(url)
                }.value
                self.selection = selected
                self.status = try await Task.detached(priority: .userInitiated) {
                    try backend.status(for: selected.url)
                }.value
            } catch {
                self.errorMessage = Self.safeMessage(error)
            }
            self.isActing = false
        }
    }

    func launch(_ intent: SeshManagedLaunchIntent) {
        guard let project = selection?.url, !isActing else { return }
        isActing = true
        errorMessage = nil
        notice = nil

        Task { [backend] in
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try backend.prepareLauncherConfiguration(for: project, intent: intent)
                }.value
                guard let commandURL = Bundle.main.url(
                    forResource: "Pace Managed Codex",
                    withExtension: "command"
                ), FileManager.default.isExecutableFile(atPath: commandURL.path) else {
                    throw SeshControlUIError.missingLauncher
                }
                guard NSWorkspace.shared.open(commandURL) else {
                    throw SeshControlUIError.launchFailed
                }
                switch plan.action {
                case .start:
                    self.notice = "Managed task opened in Terminal."
                case .resume:
                    self.notice = "Saved managed task reopened in Terminal."
                case .fresh:
                    self.notice = "New managed task opened in Terminal."
                }
                self.selection = try? backend.inspectWorkspace(project)
            } catch {
                self.errorMessage = Self.safeMessage(error)
            }
            self.isActing = false
        }
    }

    func setEconomy(_ on: Bool) {
        guard !isActing else { return }
        let workspace = selection?.url
        economyOn = on            // optimistic: the switch moves the instant it is tapped
        isActing = true
        errorMessage = nil
        notice = nil

        Task { [backend] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try backend.setEconomyMode(on: on)
                }.value
                let fresh = try await Task.detached(priority: .userInitiated) {
                    try backend.status(for: workspace)
                }.value
                self.status = fresh
                self.economyOn = (fresh.economy == "on")
            } catch {
                self.errorMessage = Self.safeMessage(error)
                self.economyOn = (self.status?.economy == "on")   // revert on failure
            }
            self.isActing = false
        }
    }

    private func apply(_ payload: SeshControlRefreshPayload) {
        status = payload.status
        selection = payload.selection
        errorMessage = payload.errorMessage
        if let economy = payload.status?.economy {
            economyOn = (economy == "on")
        }
    }

    nonisolated private static func readPayload(
        backend: SeshControlBackend
    ) -> SeshControlRefreshPayload {
        var firstError: String?
        let selection: SeshWorkspaceSelection?
        do {
            selection = try backend.selectedWorkspace()
        } catch {
            selection = nil
            if firstError == nil { firstError = safeMessage(error) }
        }

        let status: SeshControlStatus?
        do {
            status = try backend.status(for: selection?.url)
        } catch {
            status = nil
            if firstError == nil { firstError = safeMessage(error) }
        }

        return SeshControlRefreshPayload(
            status: status,
            selection: selection,
            errorMessage: firstError
        )
    }

    nonisolated private static func safeMessage(_ error: Error) -> String {
        let oneLine = error.localizedDescription
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(240))
    }

    nonisolated private static func compactCount(_ value: Int64) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return String(value)
    }

    nonisolated private static func display(_ value: String) -> String {
        value
            .split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

private enum SeshControlUIError: LocalizedError {
    case missingLauncher
    case launchFailed

    var errorDescription: String? {
        switch self {
        case .missingLauncher:
            "The Pace managed-task launcher is missing. Reinstall Pace."
        case .launchFailed:
            "Pace could not open the managed task in Terminal."
        }
    }
}

struct SeshControlCard: View {
    @ObservedObject var controller: SeshControlController

    private var isStaticRendering: Bool {
        CommandLine.arguments.contains("--screenshot")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Economy mode", systemImage: "leaf.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !isStaticRendering && controller.isActing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityIdentifier("sesh-economy-progress")
                }
                Button {
                    controller.setEconomy(!controller.economyOn)
                } label: {
                    Text(controller.economyOn ? "ON" : "OFF")
                        .font(.system(size: 11, weight: .heavy))
                        .frame(minWidth: 40)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(controller.economyOn ? PaceTheme.green : PaceTheme.muted)
                .disabled(controller.isActing)
                .accessibilityIdentifier("sesh-economy-toggle")
            }

            Text(controller.economyOn
                ? "New Codex chats start on the cheaper Terra model (medium effort). Tap OFF for full-power Sol."
                : "New Codex chats start on the full-power Sol model (high effort). Tap ON for the cheaper Terra model.")
                .font(.caption)
                .foregroundStyle(PaceTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(PaceTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PaceTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PaceTheme.stroke)
        )
        .onAppear { controller.refresh() }
    }

    private var stateBadge: some View {
        let color: Color
        switch controller.status?.conductor?.phase {
        case .working:
            color = PaceTheme.blue
        case .complete:
            color = PaceTheme.green
        case .failed:
            color = PaceTheme.coral
        case nil:
            color = controller.hasProject ? PaceTheme.amber : PaceTheme.muted
        }
        return Text(controller.stateLabel)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityIdentifier("sesh-status")
    }

    private func evidenceLine(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10.5))
            .foregroundStyle(PaceTheme.muted)
            .lineLimit(2)
    }

    private func feedbackLine(_ text: String, color: Color, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Choose the project for a managed task"
        panel.prompt = controller.hasProject ? "Use Project" : "Choose Project"
        panel.message = "Pace will keep this folder as the managed task's writable boundary."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if let current = controller.selection?.url {
            panel.directoryURL = current
        } else {
            let projects = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("projects", isDirectory: true)
            if FileManager.default.fileExists(atPath: projects.path) {
                panel.directoryURL = projects
            }
        }
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        controller.selectWorkspace(selected)
    }
}
