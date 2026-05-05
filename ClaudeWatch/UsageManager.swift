//
//  UsageManager.swift
//  ClaudeWatch
//
//  Manages fetching and parsing Claude Code usage data.
//  Runs the bundled Python script that interacts with Claude CLI
//  to retrieve current session and weekly usage statistics.
//
//  Author: John Dimou - OptimalVersion.io
//  License: MIT
//

import Foundation
import ServiceManagement

// MARK: - Data Models

/// One Last-24h insight as emitted by the CLI. Fully dynamic — the
/// titles and count come straight from `/usage`, so the app adapts
/// when Anthropic adds, removes, or rewords bullets.
struct UsageInsight: Identifiable, Codable {
    let id: UUID
    let percent: Int
    let title: String
    let description: String

    enum CodingKeys: String, CodingKey {
        case percent, title, description
    }

    init(percent: Int, title: String, description: String) {
        self.id = UUID()
        self.percent = percent
        self.title = title
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.percent = try c.decodeIfPresent(Int.self, forKey: .percent) ?? 0
        self.title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

/// Represents Claude Code usage statistics
struct ClaudeUsage {
    /// Current session usage percentage (0-100)
    var sessionPercentage: Double = 0

    /// Weekly usage percentage across all models (0-100)
    var weeklyPercentage: Double = 0

    /// Weekly usage percentage for Sonnet model only (0-100)
    var sonnetPercentage: Double = 0

    /// Human-readable session reset time (e.g., "5pm (Europe/Athens)")
    var sessionReset: String = ""

    /// Human-readable weekly reset time for all models (e.g., "Jan 16 at 10am")
    var weeklyReset: String = ""

    /// Human-readable weekly reset time for Sonnet (independent of all-models)
    var sonnetReset: String = ""

    /// Dynamic Last-24h insights (any count, sourced from CLI output)
    var insights: [UsageInsight] = []

    /// Plan name shown in the CLI status line (e.g., "Claude Max"); empty if unknown.
    var plan: String = ""

    /// Model descriptor shown in the CLI status line (e.g., "Opus 4.7 (1M context)").
    var model: String = ""

    /// Timestamp of when this data was fetched
    var lastUpdated: Date = Date()

    /// Raw output from the usage command (for debugging)
    var rawOutput: String = ""
}

/// JSON structure for parsing Python script output
struct UsageJSON: Codable {
    let session_percent: Int?
    let session_reset: String?
    let weekly_percent: Int?
    let weekly_reset: String?
    let sonnet_percent: Int?
    let sonnet_reset: String?
    let insights: [UsageInsight]?
    let plan: String?
    let model: String?
    let raw: String?
    let error: String?
}

// MARK: - Settings Keys

enum SettingsKey {
    static let refreshInterval = "refreshInterval"
    static let refreshOnOpen = "refreshOnOpen"
    static let launchAtLogin = "launchAtLogin"
}

// MARK: - Usage Manager

/// Singleton manager for fetching Claude Code usage statistics
class UsageManager: ObservableObject {

    // MARK: Singleton

    /// Shared instance
    static let shared = UsageManager()

    // MARK: Published Properties

    /// Current usage data (nil if not yet fetched)
    @Published var currentUsage: ClaudeUsage?

    /// Whether a fetch is in progress
    @Published var isLoading: Bool = false

    /// Error message from the last fetch attempt (nil if successful)
    @Published var errorMessage: String?

    /// Refresh interval in seconds
    @Published var refreshInterval: Double {
        didSet {
            UserDefaults.standard.set(refreshInterval, forKey: SettingsKey.refreshInterval)
            NotificationCenter.default.post(name: .refreshIntervalChanged, object: nil)
        }
    }

    /// Whether to refresh when UI opens
    @Published var refreshOnOpen: Bool {
        didSet {
            UserDefaults.standard.set(refreshOnOpen, forKey: SettingsKey.refreshOnOpen)
        }
    }

    /// Whether to launch at login
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: SettingsKey.launchAtLogin)
            updateLaunchAtLogin()
        }
    }

    // MARK: Configuration

    /// Name of the Python script bundled in the app
    private let scriptName = "get_claude_usage.py"

    /// Common paths where the Claude CLI might be installed
    private let claudePaths = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/bin/claude"
    ]

    // MARK: Initialization

    private init() {
        // Load settings from UserDefaults
        let defaults = UserDefaults.standard

        // Default refresh interval: 60 seconds
        if defaults.object(forKey: SettingsKey.refreshInterval) == nil {
            defaults.set(60.0, forKey: SettingsKey.refreshInterval)
        }
        self.refreshInterval = defaults.double(forKey: SettingsKey.refreshInterval)

        // Default refresh on open: true
        if defaults.object(forKey: SettingsKey.refreshOnOpen) == nil {
            defaults.set(true, forKey: SettingsKey.refreshOnOpen)
        }
        self.refreshOnOpen = defaults.bool(forKey: SettingsKey.refreshOnOpen)

        // Default launch at login: false
        if defaults.object(forKey: SettingsKey.launchAtLogin) == nil {
            defaults.set(false, forKey: SettingsKey.launchAtLogin)
        }
        self.launchAtLogin = defaults.bool(forKey: SettingsKey.launchAtLogin)
    }

    /// Updates the system launch at login setting
    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
    }

    // MARK: - Public Methods

    /// Fetches usage data asynchronously.
    ///
    /// Guards against concurrent invocations — launching two Claude CLI
    /// processes at the same time (e.g. app-launch fetch + refresh-on-open
    /// fetch) causes both to contend for the single interactive session
    /// and frequently returns an empty parse. If a fetch is already in
    /// flight, new requests are dropped.
    ///
    /// Posts `usageDidUpdate` notification on completion.
    func fetchUsage() {
        if isLoading { return }

        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let result = self.runPythonScript()

            DispatchQueue.main.async {
                self.isLoading = false

                switch result {
                case .success(let usage):
                    // Reject responses that contain no usable data. This
                    // happens on a cold start when the Python script times
                    // out before /usage finishes rendering — the JSON is
                    // structurally valid but every field is zero/empty,
                    // and showing that would stomp on any prior good data
                    // and mislead the user with fake "0%" readings.
                    if self.isLikelyEmpty(usage) {
                        // Preserve whatever we already had and surface an
                        // error so the UI offers "Try Again".
                        if self.currentUsage == nil {
                            self.errorMessage = "Claude CLI didn't finish /usage in time — tap refresh to retry."
                        }
                    } else {
                        self.currentUsage = usage
                    }
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }

                NotificationCenter.default.post(name: .usageDidUpdate, object: nil)
            }
        }
    }

    /// Heuristic for an "empty" parse result. A genuine response always
    /// includes at least one reset timestamp, so if every percentage is
    /// zero AND all reset strings are blank AND no insights landed, we
    /// treat it as a timed-out parse.
    private func isLikelyEmpty(_ usage: ClaudeUsage) -> Bool {
        let noPercents = usage.sessionPercentage == 0
            && usage.weeklyPercentage == 0
            && usage.sonnetPercentage == 0
        let noResets = usage.sessionReset.isEmpty
            && usage.weeklyReset.isEmpty
            && usage.sonnetReset.isEmpty
        let noInsights = usage.insights.isEmpty
        return noPercents && noResets && noInsights
    }

    // MARK: - Private Methods

    /// Locates and runs the bundled Python script
    /// - Returns: Result with parsed usage data or error
    private func runPythonScript() -> Result<ClaudeUsage, Error> {
        // Find the Python script in the app bundle or common locations
        guard let scriptPath = findScriptPath() else {
            return .failure(UsageError.scriptNotFound)
        }

        // Find Python 3 interpreter
        guard let pythonPath = findPythonPath() else {
            return .failure(UsageError.pythonNotFound)
        }

        // Run the script
        let task = Process()
        let pipe = Pipe()

        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [scriptPath]
        task.standardOutput = pipe
        task.standardError = pipe

        // IMPORTANT: Set working directory to /tmp to prevent Claude from scanning
        // user directories (Pictures, Music, OneDrive, etc.) which triggers permission dialogs
        task.currentDirectoryURL = URL(fileURLWithPath: "/tmp")

        // Set up environment with common paths for Claude CLI
        var env = ProcessInfo.processInfo.environment
        let homePath = env["HOME"] ?? NSHomeDirectory()
        env["PATH"] = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            "/bin",
            "\(homePath)/.local/bin",
            "\(homePath)/.nvm/versions/node/*/bin",
            env["PATH"] ?? ""
        ].joined(separator: ":")
        task.environment = env

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            guard let output = String(data: data, encoding: .utf8),
                  !output.isEmpty else {
                return .failure(UsageError.emptyOutput)
            }

            return parseScriptOutput(output)

        } catch {
            return .failure(error)
        }
    }

    /// Returns a runnable path to the Python script.
    ///
    /// We don't run the script directly out of the app bundle, because if
    /// the user keeps ClaudeWatch.app inside a TCC-protected folder
    /// (Desktop, Documents, Downloads, iCloud Drive, etc.), `/usr/bin/python3`
    /// — which is a foreign binary, not entitled by our app — triggers a
    /// "allow access to your Desktop" prompt every single poll cycle.
    ///
    /// Caches directory is not TCC-protected, so we mirror the bundled
    /// script there once per launch (refreshed when the bundle's copy
    /// changes) and execute Python against that copy.
    private func findScriptPath() -> String? {
        guard let bundledPath = bundledScriptPath() else { return nil }
        return mirrorScriptToCaches(from: bundledPath) ?? bundledPath
    }

    /// Locate the script as shipped in the bundle (or alongside it for dev).
    private func bundledScriptPath() -> String? {
        let candidates = [
            Bundle.main.path(forResource: "get_claude_usage", ofType: "py"),
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(scriptName).path
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Copy the script into ~/Library/Caches/<bundleID>/ so Python can
    /// read it without triggering Desktop/Documents TCC prompts. Re-copies
    /// when the source's modification date or size differs from the cached
    /// copy, so script updates ship with each app version automatically.
    private func mirrorScriptToCaches(from source: String) -> String? {
        let fm = FileManager.default
        let bundleID = Bundle.main.bundleIdentifier ?? "io.optimalversion.claudewatch"

        guard let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appCacheDir = cachesDir.appendingPathComponent(bundleID, isDirectory: true)
        let destURL = appCacheDir.appendingPathComponent("get_claude_usage.py")

        do {
            try fm.createDirectory(at: appCacheDir, withIntermediateDirectories: true)

            let srcAttrs = try fm.attributesOfItem(atPath: source)
            let srcSize = (srcAttrs[.size] as? NSNumber)?.intValue ?? -1
            let srcMtime = srcAttrs[.modificationDate] as? Date

            var needsCopy = true
            if fm.fileExists(atPath: destURL.path) {
                let dstAttrs = try fm.attributesOfItem(atPath: destURL.path)
                let dstSize = (dstAttrs[.size] as? NSNumber)?.intValue ?? -2
                let dstMtime = dstAttrs[.modificationDate] as? Date
                if dstSize == srcSize && dstMtime == srcMtime {
                    needsCopy = false
                }
            }

            if needsCopy {
                if fm.fileExists(atPath: destURL.path) {
                    try fm.removeItem(at: destURL)
                }
                try fm.copyItem(atPath: source, toPath: destURL.path)
            }

            return destURL.path
        } catch {
            // Fall back to the bundled path; worst case the prompt still
            // appears, but the app keeps working.
            return nil
        }
    }

    /// Finds the Python 3 interpreter
    private func findPythonPath() -> String? {
        let possiblePaths = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3"
        ]

        return possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Parses JSON output from the Python script
    private func parseScriptOutput(_ output: String) -> Result<ClaudeUsage, Error> {
        guard let jsonData = output.data(using: .utf8) else {
            return .failure(UsageError.invalidOutput)
        }

        do {
            let decoder = JSONDecoder()
            let usageJSON = try decoder.decode(UsageJSON.self, from: jsonData)

            // Check for error from script
            if let error = usageJSON.error {
                return .failure(UsageError.scriptError(error))
            }

            // Build usage struct
            var usage = ClaudeUsage()
            usage.sessionPercentage = Double(usageJSON.session_percent ?? 0)
            usage.weeklyPercentage = Double(usageJSON.weekly_percent ?? 0)
            usage.sonnetPercentage = Double(usageJSON.sonnet_percent ?? 0)
            usage.sessionReset = usageJSON.session_reset ?? ""
            usage.weeklyReset = usageJSON.weekly_reset ?? ""
            usage.sonnetReset = usageJSON.sonnet_reset ?? ""
            usage.insights = usageJSON.insights ?? []
            usage.plan = usageJSON.plan ?? ""
            usage.model = usageJSON.model ?? ""
            usage.rawOutput = usageJSON.raw ?? ""
            usage.lastUpdated = Date()

            return .success(usage)

        } catch {
            return .failure(UsageError.parseError(output))
        }
    }
}

// MARK: - Error Types

/// Errors that can occur during usage fetching
enum UsageError: LocalizedError {
    case scriptNotFound
    case pythonNotFound
    case emptyOutput
    case invalidOutput
    case scriptError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "Usage script not found. Please reinstall the app."
        case .pythonNotFound:
            return "Python 3 not found. Please install Python 3."
        case .emptyOutput:
            return "No output from usage script."
        case .invalidOutput:
            return "Invalid output format from script."
        case .scriptError(let message):
            return "Script error: \(message)"
        case .parseError(let output):
            return "Failed to parse output: \(output.prefix(100))..."
        }
    }
}
