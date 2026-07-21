import Darwin
import CryptoKit
import Foundation

struct SeshControlQuotaStatus: Decodable, Equatable, Sendable {
    let remainingPercent: Double
    let freshness: String

    enum CodingKeys: String, CodingKey {
        case remainingPercent = "remaining_percent"
        case freshness
    }
}

enum SeshControlState: String, Decodable, Equatable, Sendable {
    case idle
    case saved
    case legacy
}

enum SeshConductorPhase: String, Decodable, Equatable, Sendable {
    case working
    case complete
    case failed
}

enum SeshConductorUrgency: String, Decodable, Equatable, Sendable {
    case relaxed
    case normal
    case soon
    case immediate
}

enum SeshConductorTopology: String, Decodable, Equatable, Sendable {
    case exact
    case direct
    case assisted
    case parallel
    case delegated
}

enum SeshConductorVerification: String, Decodable, Equatable, Sendable {
    case pending
    case passed
    case failed
}

struct SeshControlRoute: Decodable, Equatable, Sendable {
    let stage: String
    let model: String
    let effort: String
    let serviceTier: String
    let count: Int

    enum CodingKeys: String, CodingKey {
        case stage
        case model
        case effort
        case serviceTier = "service_tier"
        case count
    }

        fileprivate var isValid: Bool {
        ["conductor", "worker"].contains(stage)
            && SeshStatusValidation.safeIdentifier(model, maximum: 100)
            && ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
                .contains(effort)
            && ["default", "priority"].contains(serviceTier)
            && (1...2).contains(count)
            && (stage != "conductor" || count == 1)
    }
}

struct SeshConductorWorkers: Decodable, Equatable, Sendable {
    let planned: Int
    let running: Int
    let completed: Int

    fileprivate var isValid: Bool {
        (0...2).contains(planned)
            && (0...2).contains(running)
            && (0...2).contains(completed)
            && running + completed <= planned
    }
}

struct SeshConductorStatus: Decodable, Equatable, Sendable {
    let policyVersion: String
    let automatic: Bool
    let phase: SeshConductorPhase
    let recommendedTopology: SeshConductorTopology
    let topology: SeshConductorTopology
    let urgency: SeshConductorUrgency
    let urgencyBasis: String
    let reasonCodes: [String]
    let workers: SeshConductorWorkers
    let verification: SeshConductorVerification
    let escalations: Int
    let routes: [SeshControlRoute]
    let startedAt: Int64
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case policyVersion = "policy_version"
        case automatic
        case phase
        case recommendedTopology = "recommended_topology"
        case topology
        case urgency
        case urgencyBasis = "urgency_basis"
        case reasonCodes = "reason_codes"
        case workers
        case verification
        case escalations
        case routes
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }

    fileprivate var isValid: Bool {
        let expectedWorkers: Int
        switch topology {
        case .direct: expectedWorkers = 0
        case .assisted: expectedWorkers = 1
        case .parallel: expectedWorkers = 2
        case .exact, .delegated: return false
        }
        return policyVersion == "4.2.0"
            && automatic
            && [.direct, .assisted, .parallel].contains(recommendedTopology)
            && workers.planned == expectedWorkers
            && (phase == .working || workers.completed == expectedWorkers)
            && urgencyBasis == "prompt-inference"
            && SeshStatusValidation.reasonCodes(reasonCodes)
            && workers.isValid
            && (0...2).contains(escalations)
            && !routes.isEmpty
            && routes.count <= 3
            && routes.allSatisfy(\.isValid)
            && routes.contains { $0.stage == "conductor" && $0.count == 1 }
            && startedAt > 0
            && updatedAt >= startedAt
    }
}

struct SeshLatestRunStatus: Decodable, Equatable, Sendable {
    let schema: Int
    let policyVersion: String
    let observedAt: Int64
    let provider: String
    let automatic: Bool
    let threadReference: String
    let turnReference: String
    let workItemReference: String
    let impact: String
    let difficulty: String
    let urgency: SeshConductorUrgency
    let recommendedTopology: SeshConductorTopology
    let topology: SeshConductorTopology
    let reasonCodes: [String]
    let model: String
    let effort: String
    let serviceTier: String
    let workerCount: Int
    let providerTurns: Int
    let escalations: Int
    let usageScope: String
    let usageComplete: Bool
    let inputTokens: Int64?
    let cachedInputTokens: Int64?
    let outputTokens: Int64?
    let reasoningOutputTokens: Int64?
    let totalTokens: Int64?
    let durationMilliseconds: Int64?
    let verification: SeshConductorVerification
    let outcome: String
    let routes: [SeshControlRoute]

    enum CodingKeys: String, CodingKey {
        case schema
        case policyVersion = "policy_version"
        case observedAt = "observed_at"
        case provider
        case automatic
        case threadReference = "thread_ref"
        case turnReference = "turn_ref"
        case workItemReference = "work_item_ref"
        case impact
        case difficulty
        case urgency
        case recommendedTopology = "recommended_topology"
        case topology
        case reasonCodes = "reason_codes"
        case model
        case effort
        case serviceTier = "service_tier"
        case workerCount = "worker_count"
        case providerTurns = "provider_turns"
        case escalations
        case usageScope = "usage_scope"
        case usageComplete = "usage_complete"
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
        case durationMilliseconds = "duration_ms"
        case verification
        case outcome
        case routes
    }

    fileprivate var isValid: Bool {
        let tokenValues = [
            inputTokens,
            cachedInputTokens,
            outputTokens,
            reasoningOutputTokens,
            totalTokens,
        ].compactMap { $0 }
        let tokenTotalIsCoherent: Bool
        if let totalTokens, let inputTokens, let outputTokens {
            tokenTotalIsCoherent = totalTokens == inputTokens + outputTokens
        } else {
            tokenTotalIsCoherent = !usageComplete
        }
        return schema == 2
            && SeshStatusValidation.semanticVersion(policyVersion)
            && observedAt > 0
            && provider == "codex"
            && automatic
            && SeshStatusValidation.privateReference(threadReference)
            && SeshStatusValidation.privateReference(turnReference)
            && SeshStatusValidation.privateReference(workItemReference)
            && ["ordinary", "consequential", "protected", "irreversible"].contains(impact)
            && ["mechanical", "standard", "complex", "frontier"].contains(difficulty)
            && [.direct, .assisted, .parallel].contains(recommendedTopology)
            && [.direct, .assisted, .parallel].contains(topology)
            && SeshStatusValidation.reasonCodes(reasonCodes)
            && SeshStatusValidation.safeIdentifier(model, maximum: 100)
            && ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
                .contains(effort)
            && ["default", "priority"].contains(serviceTier)
            && (0...2).contains(workerCount)
            && (1...32).contains(providerTurns)
            && (0...2).contains(escalations)
            && ["fresh-thread-tree-cumulative-total", "turn-tree-last"].contains(usageScope)
            && tokenValues.allSatisfy { $0 >= 0 }
            && tokenTotalIsCoherent
            && (durationMilliseconds.map { $0 >= 0 } ?? true)
            && verification != .pending
            && [
                "verified-success", "quality-failure", "uncertain",
                "environment-blocker", "context-exceeded", "usage-limit",
                "server-transient", "safety-stop", "interrupted",
            ].contains(outcome)
            && !routes.isEmpty
            && routes.count <= 3
            && routes.allSatisfy(\.isValid)
            && routes.contains { $0.stage == "conductor" && $0.count == 1 }
            && topology == (workerCount == 0 ? .direct : workerCount == 1 ? .assisted : .parallel)
            && routes.filter { $0.stage == "worker" }.reduce(0) { $0 + $1.count } == workerCount
    }
}

struct SeshControlStatus: Decodable, Equatable, Sendable {
    let automatic: Bool
    let economy: String?
    let statePath: String
    let state: SeshControlState
    let schema: Int
    let conductor: SeshConductorStatus?
    let latestRun: SeshLatestRunStatus?
    let quota: [String: SeshControlQuotaStatus]?

    enum CodingKeys: String, CodingKey {
        case automatic
        case economy
        case statePath = "state_path"
        case state
        case schema
        case conductor
        case latestRun = "latest_run"
        case quota
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.contains(.conductor), values.contains(.latestRun) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schema,
                in: values,
                debugDescription: "Sesh schema 3 requires conductor and latest_run fields"
            )
        }
        automatic = try values.decode(Bool.self, forKey: .automatic)
        economy = try values.decodeIfPresent(String.self, forKey: .economy)
        statePath = try values.decode(String.self, forKey: .statePath)
        state = try values.decode(SeshControlState.self, forKey: .state)
        schema = try values.decode(Int.self, forKey: .schema)
        conductor = try values.decodeIfPresent(SeshConductorStatus.self, forKey: .conductor)
        latestRun = try values.decodeIfPresent(SeshLatestRunStatus.self, forKey: .latestRun)
        quota = try values.decodeIfPresent(
            [String: SeshControlQuotaStatus].self,
            forKey: .quota
        )
    }

    fileprivate var isValid: Bool {
        guard schema == 3,
              statePath.hasPrefix("/"),
              SeshStatusValidation.safeText(statePath, maximum: 4_096),
              conductor?.isValid != false,
              latestRun?.isValid != false,
              quota?.allSatisfy({ key, value in
                  ["codex", "claude"].contains(key)
                      && value.remainingPercent.isFinite
                      && (0...100).contains(value.remainingPercent)
                      && SeshStatusValidation.safeIdentifier(value.freshness, maximum: 24)
              }) != false
        else { return false }

        switch state {
        case .saved:
            return conductor != nil
        case .idle, .legacy:
            return conductor == nil && latestRun == nil
        }
    }
}

private enum SeshStatusValidation {
    static func safeText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x20 && scalar.value != 0x7f
            }
    }

    static func safeIdentifier(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximum
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value)
                    || (65...90).contains(scalar.value)
                    || (97...122).contains(scalar.value)
                    || [43, 45, 46, 47, 58, 95].contains(scalar.value)
            }
    }

    static func reasonCodes(_ values: [String]) -> Bool {
        let allowed = [
            "automatic-conductor", "bounded-delegation", "direct-default",
            "scout-not-required", "parallelism-not-required", "quality-floor-retained",
            "deadline-priority", "standard-credit-conservation", "topology-advisory",
        ]
        return !values.isEmpty
            && values.count <= allowed.count
            && values.allSatisfy(allowed.contains)
    }

    static func privateReference(_ value: String) -> Bool {
        value.utf8.count == 16
            && value.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            }
    }

    static func semanticVersion(_ value: String) -> Bool {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 3 && pieces.allSatisfy { !$0.isEmpty && Int($0) != nil }
    }
}

struct SeshWorkspaceSelection: Equatable, Sendable {
    let url: URL
    let hasSavedManagedCodexState: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url.standardizedFileURL.path == rhs.url.standardizedFileURL.path
            && lhs.hasSavedManagedCodexState == rhs.hasSavedManagedCodexState
    }
}

enum SeshManagedLaunchIntent: Equatable, Sendable {
    /// Resume this workspace's saved Sesh task when one exists; otherwise start it.
    case startOrResume
    /// Deliberately ask Sesh for a new provider conversation in this workspace.
    case fresh
}

enum SeshManagedLaunchAction: String, Equatable, Sendable {
    case start
    case resume
    case fresh
}

struct SeshManagedLaunchPlan: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let intent: SeshManagedLaunchIntent
    let action: SeshManagedLaunchAction

    var willResumeExistingTask: Bool { action == .resume }
}

struct SeshControlCommandOutput: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
}

enum SeshControlError: LocalizedError, Equatable {
    case missingCLI
    case processLaunch(String)
    case commandFailed(Int32, String)
    case invalidResponse
    case invalidWorkspace
    case workspaceTooBroad
    case unsafeSelection
    case unsafeManagedState

    var errorDescription: String? {
        switch self {
        case .missingCLI:
            "Pace's bundled Sesh controller is unavailable. Reinstall Pace."
        case .processLaunch(let message):
            "Pace could not start the Sesh controller: \(message)"
        case .commandFailed(let status, let message):
            message.isEmpty
                ? "Sesh exited with status \(status)."
                : "Sesh failed: \(message)"
        case .invalidResponse:
            "Sesh returned an unreadable status."
        case .invalidWorkspace:
            "Choose an existing project folder."
        case .workspaceTooBroad:
            "Choose a scoped project folder, not root or your whole home folder."
        case .unsafeSelection:
            "The saved Sesh workspace selection is unsafe or unreadable."
        case .unsafeManagedState:
            "The saved managed Codex state is unsafe or does not match this workspace."
        }
    }
}

/// A synchronous, UI-independent bridge to the installed Sesh controller.
///
/// Commands are always passed to `Process` as an executable plus an argument
/// array. No project path is ever interpolated into a shell command.
final class SeshControlBackend: @unchecked Sendable {
    typealias CommandRunner = (URL, [String], URL?) throws -> SeshControlCommandOutput

    private static let maximumCLIOutputBytes = 64 * 1_024
    private static let maximumSelectionBytes = 16 * 1_024
    private static let maximumManagedStateBytes = 1 * 1_024 * 1_024

    let homeURL: URL
    let configDirectoryURL: URL
    let cliURL: URL

    private let fileManager: FileManager
    private let commandRunner: CommandRunner

    convenience init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bundledCLI = Bundle.main.resourceURL?
            .appendingPathComponent("Sesh", isDirectory: true)
            .appendingPathComponent("sesh", isDirectory: false)
        let installedCLI = home
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("sesh", isDirectory: false)
        let cli = bundledCLI.flatMap { candidate in
            FileManager.default.isExecutableFile(atPath: candidate.path)
                ? candidate
                : nil
        } ?? installedCLI
        self.init(
            homeURL: home,
            configDirectoryURL: home
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("sesh", isDirectory: true),
            cliURL: cli
        )
    }

    init(
        homeURL: URL,
        configDirectoryURL: URL,
        cliURL: URL,
        fileManager: FileManager = .default,
        commandRunner: @escaping CommandRunner = SeshControlBackend.runProcess
    ) {
        self.homeURL = homeURL.resolvingSymlinksInPath().standardizedFileURL
        self.configDirectoryURL = configDirectoryURL.standardizedFileURL
        self.cliURL = cliURL.standardizedFileURL
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    func status(for workspaceURL: URL?) throws -> SeshControlStatus {
        var arguments = ["--json", "status"]
        let workspace: URL?
        if let workspaceURL {
            let validated = try validatedWorkspace(workspaceURL)
            workspace = validated
            arguments.append(contentsOf: ["--cwd", validated.path])
        } else {
            workspace = nil
        }
        let result = try runCLI(arguments: arguments)
        let parsed = try decodeStatus(result.stdout)
        if let workspace {
            let expectedStatePath = managedCodexStateURL(forValidatedWorkspace: workspace)
                .standardizedFileURL.path
            guard URL(fileURLWithPath: parsed.statePath).standardizedFileURL.path
                    == expectedStatePath else {
                throw SeshControlError.invalidResponse
            }
        }
        return parsed
    }

    /// Saves the canonical project path in the same private file used by Sesh.
    @discardableResult
    func selectWorkspace(_ url: URL) throws -> SeshWorkspaceSelection {
        let workspace = try validatedWorkspace(url)
        try preparePrivateConfigDirectory()
        try writePrivateText(workspace.path, to: selectionFileURL)
        return try inspectWorkspace(workspace)
    }

    func selectedWorkspace() throws -> SeshWorkspaceSelection? {
        let target = selectionFileURL
        guard fileManager.fileExists(atPath: target.path) else { return nil }

        let values = try target.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumSelectionBytes,
              privateOwnedFile(at: target)
        else {
            throw SeshControlError.unsafeSelection
        }

        let data = try Data(contentsOf: target, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SeshControlError.unsafeSelection
        }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.contains("\n"),
              !path.contains("\r"),
              !path.contains("\0")
        else {
            throw SeshControlError.unsafeSelection
        }
        return try inspectWorkspace(URL(fileURLWithPath: path, isDirectory: true))
    }

    func inspectWorkspace(_ url: URL) throws -> SeshWorkspaceSelection {
        let workspace = try validatedWorkspace(url)
        return SeshWorkspaceSelection(
            url: workspace,
            hasSavedManagedCodexState: try hasSavedManagedCodexState(for: workspace)
        )
    }

    func validatedWorkspace(_ url: URL) throws -> URL {
        guard url.isFileURL,
              !url.path.contains("\n"),
              !url.path.contains("\r"),
              !url.path.contains("\0")
        else {
            throw SeshControlError.invalidWorkspace
        }

        let workspace = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SeshControlError.invalidWorkspace
        }
        guard workspace.path != "/", workspace.path != homeURL.path else {
            throw SeshControlError.workspaceTooBroad
        }
        return workspace
    }

    func hasSavedManagedCodexState(for url: URL) throws -> Bool {
        let workspace = try validatedWorkspace(url)
        let stateURL = managedCodexStateURL(forValidatedWorkspace: workspace)
        guard fileManager.fileExists(atPath: stateURL.path) else { return false }

        let values = try stateURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumManagedStateBytes,
              privateOwnedFile(at: stateURL)
        else {
            throw SeshControlError.unsafeManagedState
        }

        let data = try Data(contentsOf: stateURL, options: .mappedIfSafe)
        let state: ManagedCodexStateEnvelope
        do {
            state = try JSONDecoder().decode(ManagedCodexStateEnvelope.self, from: data)
        } catch {
            throw SeshControlError.unsafeManagedState
        }
        guard state.schema == 1,
              state.provider == "codex",
              state.cwd == workspace.path,
              !state.sessionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SeshControlError.unsafeManagedState
        }
        guard let conductor = state.conductor else {
            return false
        }
        return conductor.policyVersion == "4.2.0" && conductor.automatic
    }

    func managedCodexStateURL(for url: URL) throws -> URL {
        let workspace = try validatedWorkspace(url)
        return managedCodexStateURL(forValidatedWorkspace: workspace)
    }

    func launchPlan(
        for url: URL,
        intent: SeshManagedLaunchIntent
    ) throws -> SeshManagedLaunchPlan {
        let selection = try inspectWorkspace(url)
        var arguments = ["auto", "codex", "--cwd", selection.url.path]
        let action: SeshManagedLaunchAction
        switch intent {
        case .startOrResume:
            action = selection.hasSavedManagedCodexState ? .resume : .start
        case .fresh:
            arguments.append("--new")
            action = .fresh
        }
        return SeshManagedLaunchPlan(
            executableURL: cliURL,
            arguments: arguments,
            workingDirectoryURL: selection.url,
            intent: intent,
            action: action
        )
    }

    /// Persists only the scoped workspace and the user's resume/new intent.
    /// The bundled launcher reads these private files and starts Sesh in
    /// Terminal after this method returns.
    func prepareLauncherConfiguration(
        for url: URL,
        intent: SeshManagedLaunchIntent
    ) throws -> SeshManagedLaunchPlan {
        let selection = try selectWorkspace(url)
        let plan = try launchPlan(for: selection.url, intent: intent)
        try writePrivateText(intent == .fresh ? "new" : "resume", to: launchIntentFileURL)
        return plan
    }

    /// Purely local deterministic coverage. It never launches Sesh or a GUI.
    static func selfTest() -> Bool {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("pace-sesh-control-self-test-fixture", isDirectory: true)
        try? manager.removeItem(at: root)

        do {
            let home = root.appendingPathComponent("home", isDirectory: true)
            let config = home
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("sesh", isDirectory: true)
            let workspace = home
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent("project ; $(touch PWNED)", isDirectory: true)
            let cli = home
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("sesh", isDirectory: false)
            try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
            try manager.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: cli)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)

            final class Recorder {
                var arguments: [[String]] = []
            }
            let recorder = Recorder()
            let digest = SHA256.hash(data: Data(workspace.standardizedFileURL.path.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let expectedStateURL = config.appendingPathComponent(
                "auto-codex-\(digest.prefix(12)).json",
                isDirectory: false
            )
            let route: [String: Any] = [
                "stage": "conductor",
                "model": "gpt-5.6-terra",
                "effort": "medium",
                "service_tier": "default",
                "count": 1,
            ]
            let conductor: [String: Any] = [
                "policy_version": "4.2.0",
                "automatic": true,
                "phase": "complete",
                "recommended_topology": "direct",
                "topology": "direct",
                "urgency": "normal",
                "urgency_basis": "prompt-inference",
                "reason_codes": ["automatic-conductor", "topology-advisory"],
                "workers": ["planned": 0, "running": 0, "completed": 0],
                "verification": "passed",
                "escalations": 0,
                "routes": [route],
                "started_at": 1_784_400_000,
                "updated_at": 1_784_400_010,
            ]
            let latestRun: [String: Any] = [
                "schema": 2,
                "policy_version": "4.2.0",
                "observed_at": 1_784_400_010,
                "provider": "codex",
                "automatic": true,
                "thread_ref": "0123456789abcdef",
                "turn_ref": "123456789abcdef0",
                "work_item_ref": "23456789abcdef01",
                "impact": "ordinary",
                "difficulty": "complex",
                "urgency": "normal",
                "recommended_topology": "direct",
                "topology": "direct",
                "reason_codes": ["automatic-conductor", "scout-not-required"],
                "model": "gpt-5.6-terra",
                "effort": "medium",
                "service_tier": "default",
                "worker_count": 0,
                "provider_turns": 1,
                "escalations": 0,
                "usage_scope": "fresh-thread-tree-cumulative-total",
                "usage_complete": true,
                "input_tokens": 3_000,
                "cached_input_tokens": 2_000,
                "output_tokens": 1_000,
                "reasoning_output_tokens": 500,
                "total_tokens": 4_000,
                "duration_ms": 9_500,
                "verification": "passed",
                "outcome": "verified-success",
                "routes": [route],
            ]
            let statusJSON = try JSONSerialization.data(
                withJSONObject: [
                    "schema": 3,
                    "automatic": true,
                    "state_path": expectedStateURL.path,
                    "state": "saved",
                    "conductor": conductor,
                    "latest_run": latestRun,
                    "quota": [
                        "codex": ["remaining_percent": 42, "freshness": "fresh"]
                    ],
                ],
                options: [.sortedKeys]
            )
            let backend = SeshControlBackend(
                homeURL: home,
                configDirectoryURL: config,
                cliURL: cli,
                commandRunner: { executable, arguments, workingDirectory in
                    guard executable == cli, workingDirectory == nil else {
                        return SeshControlCommandOutput(
                            stdout: Data(),
                            stderr: Data("unexpected invocation".utf8),
                            terminationStatus: 9
                        )
                    }
                    recorder.arguments.append(arguments)
                    return SeshControlCommandOutput(
                        stdout: statusJSON,
                        stderr: Data(),
                        terminationStatus: 0
                    )
                }
            )

            let decodedStatus = try backend.status(for: workspace)
            guard decodedStatus.schema == 3,
                  decodedStatus.automatic,
                  decodedStatus.state == .saved,
                  decodedStatus.conductor?.phase == .complete,
                  decodedStatus.conductor?.urgency == .normal,
                  decodedStatus.latestRun?.topology == .direct,
                  decodedStatus.latestRun?.totalTokens == 4_000,
                  decodedStatus.latestRun?.verification == .passed,
                  recorder.arguments == [
                    ["--json", "status", "--cwd", workspace.standardizedFileURL.path]
                  ]
            else { return false }

            let schemaTwoBackend = SeshControlBackend(
                homeURL: home,
                configDirectoryURL: config,
                cliURL: cli,
                commandRunner: { _, _, _ in
                    SeshControlCommandOutput(
                        stdout: Data(
                            """
                            {"schema":2,"automatic":true,"state_path":"/private/state.json","state":"idle","conductor":null,"latest_run":null}
                            """.utf8
                        ),
                        stderr: Data(),
                        terminationStatus: 0
                    )
                }
            )
            do {
                _ = try schemaTwoBackend.status(for: nil)
                return false
            } catch SeshControlError.invalidResponse {}

            // Economy default OFF (`sesh off`) is a valid state the card must
            // display, not an error. This mirrors the on/off toggle contract.
            let disabledBackend = SeshControlBackend(
                homeURL: home,
                configDirectoryURL: config,
                cliURL: cli,
                commandRunner: { _, _, _ in
                    SeshControlCommandOutput(
                        stdout: Data(
                            """
                            {"schema":3,"automatic":false,"state_path":"/private/state.json","state":"idle","conductor":null,"latest_run":null}
                            """.utf8
                        ),
                        stderr: Data(),
                        terminationStatus: 0
                    )
                }
            )
            let disabledStatus = try disabledBackend.status(for: nil)
            guard disabledStatus.automatic == false,
                  disabledStatus.state == .idle,
                  disabledStatus.conductor == nil,
                  disabledStatus.latestRun == nil
            else { return false }

            // setEconomyMode issues the bare on/off subcommand, no cwd.
            let toggleRecorder = Recorder()
            let toggleBackend = SeshControlBackend(
                homeURL: home,
                configDirectoryURL: config,
                cliURL: cli,
                commandRunner: { executable, arguments, workingDirectory in
                    guard executable == cli, workingDirectory == nil else {
                        return SeshControlCommandOutput(
                            stdout: Data(),
                            stderr: Data("unexpected invocation".utf8),
                            terminationStatus: 9
                        )
                    }
                    toggleRecorder.arguments.append(arguments)
                    return SeshControlCommandOutput(
                        stdout: Data("ok".utf8),
                        stderr: Data(),
                        terminationStatus: 0
                    )
                }
            )
            try toggleBackend.setEconomyMode(on: true)
            try toggleBackend.setEconomyMode(on: false)
            guard toggleRecorder.arguments == [["on"], ["off"]] else { return false }

            var unsafeStatus = try JSONSerialization.jsonObject(with: statusJSON)
                as? [String: Any] ?? [:]
            var unsafeConductor = unsafeStatus["conductor"] as? [String: Any] ?? [:]
            var unsafeRoutes = unsafeConductor["routes"] as? [[String: Any]] ?? []
            guard !unsafeRoutes.isEmpty else { return false }
            unsafeRoutes[0]["model"] = "prompt text must never reach the card"
            unsafeConductor["routes"] = unsafeRoutes
            unsafeStatus["conductor"] = unsafeConductor
            let unsafeStatusJSON = try JSONSerialization.data(
                withJSONObject: unsafeStatus,
                options: [.sortedKeys]
            )
            let unsafeTextBackend = SeshControlBackend(
                homeURL: home,
                configDirectoryURL: config,
                cliURL: cli,
                commandRunner: { _, _, _ in
                    SeshControlCommandOutput(
                        stdout: unsafeStatusJSON,
                        stderr: Data(),
                        terminationStatus: 0
                    )
                }
            )
            do {
                _ = try unsafeTextBackend.status(for: nil)
                return false
            } catch SeshControlError.invalidResponse {}

            let initial = try backend.selectWorkspace(workspace)
            guard initial.url.path == workspace.standardizedFileURL.path,
                  !initial.hasSavedManagedCodexState,
                  try backend.selectedWorkspace() == initial,
                  try backend.launchPlan(for: workspace, intent: .startOrResume).action == .start
            else { return false }

            let stateURL = try backend.managedCodexStateURL(for: workspace)
            let state: [String: Any] = [
                "schema": 1,
                "provider": "codex",
                "cwd": workspace.path,
                "session_key": "thread-fixture",
                "conductor": ["policy_version": "4.2.0", "automatic": true]
            ]
            try manager.createDirectory(at: config, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                .write(to: stateURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            let managed = try backend.inspectWorkspace(workspace)
            let resume = try backend.launchPlan(for: workspace, intent: .startOrResume)
            let fresh = try backend.launchPlan(for: workspace, intent: .fresh)
            let preparedFresh = try backend.prepareLauncherConfiguration(
                for: workspace,
                intent: .fresh
            )
            let savedIntent = try String(contentsOf: backend.launchIntentFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard managed.hasSavedManagedCodexState,
                  resume.action == .resume,
                  resume.willResumeExistingTask,
                  resume.arguments == ["auto", "codex", "--cwd", workspace.path],
                  fresh.action == .fresh,
                  !fresh.willResumeExistingTask,
                  fresh.arguments == ["auto", "codex", "--cwd", workspace.path, "--new"],
                  preparedFresh == fresh,
                  savedIntent == "new",
                  !manager.fileExists(atPath: workspace.appendingPathComponent("PWNED").path),
                  permissionBits(at: config, manager: manager) == 0o700,
                  permissionBits(at: backend.selectionFileURL, manager: manager) == 0o600,
                  permissionBits(at: backend.launchIntentFileURL, manager: manager) == 0o600
            else { return false }

            var legacyState = state
            legacyState.removeValue(forKey: "conductor")
            try JSONSerialization.data(withJSONObject: legacyState, options: [.sortedKeys])
                .write(to: stateURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            let legacy = try backend.inspectWorkspace(workspace)
            guard !legacy.hasSavedManagedCodexState,
                  try backend.launchPlan(for: workspace, intent: .startOrResume).action == .start
            else { return false }

            do {
                _ = try backend.validatedWorkspace(home)
                return false
            } catch SeshControlError.workspaceTooBroad {}
            do {
                _ = try backend.validatedWorkspace(URL(fileURLWithPath: "/", isDirectory: true))
                return false
            } catch SeshControlError.workspaceTooBroad {}

            try manager.removeItem(at: stateURL)
            try manager.createSymbolicLink(
                at: stateURL,
                withDestinationURL: backend.selectionFileURL
            )
            do {
                _ = try backend.hasSavedManagedCodexState(for: workspace)
                return false
            } catch SeshControlError.unsafeManagedState {}

            try manager.removeItem(at: root)
            return true
        } catch {
#if SESH_CONTROL_STANDALONE_SELF_TEST
            print("sesh_control_self_test_error=\(error)")
#endif
            try? manager.removeItem(at: root)
            return false
        }
    }

    var selectionFileURL: URL {
        configDirectoryURL.appendingPathComponent("menu-cwd", isDirectory: false)
    }

    var launchIntentFileURL: URL {
        configDirectoryURL.appendingPathComponent("menu-launch-intent", isDirectory: false)
    }

    private func preparePrivateConfigDirectory() throws {
        if fileManager.fileExists(atPath: configDirectoryURL.path) {
            let values = try configDirectoryURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  privateOwnedDirectory(at: configDirectoryURL) else {
                throw SeshControlError.unsafeSelection
            }
        } else {
            try fileManager.createDirectory(
                at: configDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: configDirectoryURL.path
        )
    }

    private func writePrivateText(_ value: String, to target: URL) throws {
        try preparePrivateConfigDirectory()
        if fileManager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw SeshControlError.unsafeSelection
            }
        }
        try Data((value + "\n").utf8).write(to: target, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: target.path
        )
    }

    private func privateOwnedFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        let mode = permissions.intValue & 0o777
        return owner.uint32Value == getuid()
            && mode & 0o077 == 0
            && mode & 0o400 != 0
    }

    private func privateOwnedDirectory(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        return owner.uint32Value == getuid()
            && permissions.intValue & 0o077 == 0
    }

    private func managedCodexStateURL(forValidatedWorkspace workspace: URL) -> URL {
        let digest = SHA256.hash(data: Data(workspace.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return configDirectoryURL.appendingPathComponent(
            "auto-codex-\(digest.prefix(12)).json",
            isDirectory: false
        )
    }

    /// Flip the computer-wide economy default for new native Codex launches.
    /// `on` writes the economy gear into ~/.codex/config.toml; `off` restores
    /// the previously saved default. Running sessions are never re-geared.
    func setEconomyMode(on: Bool) throws {
        _ = try runCLI(arguments: [on ? "on" : "off"])
    }

    private func runCLI(arguments: [String]) throws -> SeshControlCommandOutput {
        guard cliURL.isFileURL, fileManager.isExecutableFile(atPath: cliURL.path) else {
            throw SeshControlError.missingCLI
        }
        let result: SeshControlCommandOutput
        do {
            result = try commandRunner(cliURL, arguments, nil)
        } catch let error as SeshControlError {
            throw error
        } catch {
            throw SeshControlError.processLaunch(Self.safeMessage(error.localizedDescription))
        }

        guard result.stdout.count <= Self.maximumCLIOutputBytes,
              result.stderr.count <= Self.maximumCLIOutputBytes
        else {
            throw SeshControlError.invalidResponse
        }
        guard result.terminationStatus == 0 else {
            let message = String(data: result.stderr, encoding: .utf8) ?? ""
            throw SeshControlError.commandFailed(
                result.terminationStatus,
                Self.safeMessage(message)
            )
        }
        return result
    }

    private func decodeStatus(_ data: Data) throws -> SeshControlStatus {
        do {
            let parsed = try JSONDecoder().decode(SeshControlStatus.self, from: data)
            guard parsed.isValid else {
                throw SeshControlError.invalidResponse
            }
            return parsed
        } catch let error as SeshControlError {
            throw error
        } catch {
            throw SeshControlError.invalidResponse
        }
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        workingDirectoryURL: URL?
    ) throws -> SeshControlCommandOutput {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectoryURL
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw SeshControlError.processLaunch(safeMessage(error.localizedDescription))
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SeshControlCommandOutput(
            stdout: output,
            stderr: errorOutput,
            terminationStatus: process.terminationStatus
        )
    }

    private static func safeMessage(_ value: String) -> String {
        let oneLine = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(oneLine.prefix(240))
    }

    private static func permissionBits(at url: URL, manager: FileManager) -> Int? {
        guard let value = try? manager.attributesOfItem(atPath: url.path)[.posixPermissions]
            as? NSNumber else {
            return nil
        }
        return value.intValue & 0o777
    }

    private struct ManagedCodexStateEnvelope: Decodable {
        let schema: Int
        let provider: String
        let cwd: String
        let sessionKey: String
        let conductor: ManagedConductorEnvelope?

        enum CodingKeys: String, CodingKey {
            case schema
            case provider
            case cwd
            case sessionKey = "session_key"
            case conductor
        }
    }

    private struct ManagedConductorEnvelope: Decodable {
        let policyVersion: String
        let automatic: Bool

        enum CodingKeys: String, CodingKey {
            case policyVersion = "policy_version"
            case automatic
        }
    }
}

#if SESH_CONTROL_STANDALONE_SELF_TEST
@main
private enum SeshControlSelfTestMain {
    static func main() {
        let passed = SeshControlBackend.selfTest()
        print(passed ? "sesh_control_self_test=pass" : "sesh_control_self_test=fail")
        exit(passed ? 0 : 1)
    }
}
#endif
