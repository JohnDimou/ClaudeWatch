//
//  UsageManager.swift
//  ClaudeUsageBar
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

    /// Human-readable weekly reset time (e.g., "Jan 16 at 10am")
    var weeklyReset: String = ""

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

    /// Fetches usage data asynchronously
    /// Posts `usageDidUpdate` notification when complete
    func fetchUsage() {
        isLoading = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let result = self.runPythonScript()

            DispatchQueue.main.async {
                self.isLoading = false

                switch result {
                case .success(let usage):
                    self.currentUsage = usage
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                }

                NotificationCenter.default.post(name: .usageDidUpdate, object: nil)
            }
        }
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

    /// Finds the Python script in the app bundle or same directory
    private func findScriptPath() -> String? {
        let possiblePaths = [
            // Inside app bundle (for distribution)
            Bundle.main.path(forResource: "get_claude_usage", ofType: "py"),
            // Same directory as app (for development)
            Bundle.main.bundleURL.deletingLastPathComponent()
                .appendingPathComponent(scriptName).path
        ].compactMap { $0 }

        return possiblePaths.first { FileManager.default.fileExists(atPath: $0) }
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
