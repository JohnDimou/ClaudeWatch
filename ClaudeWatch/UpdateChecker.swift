//
//  UpdateChecker.swift
//  ClaudeWatch
//
//  Checks the app's GitHub repo for newer releases and exposes the
//  result to the UI. Simple semver comparison against the bundled
//  CFBundleShortVersionString. Results are cached in UserDefaults so
//  we don't hammer the GitHub API on every popover open.
//
//  Distribution is currently unsigned ZIP — we don't attempt in-place
//  installs. When an update is available the UI points the user at
//  the release page so they can download the new .zip manually.
//
//  Author: John Dimou - OptimalVersion.io
//  License: MIT
//

import Foundation
import AppKit

// MARK: - Models

/// Minimal GitHub Release payload — only the fields we care about.
struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let htmlUrl: String
    let body: String?
    let publishedAt: String?
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlUrl = "html_url"
        case body
        case publishedAt = "published_at"
        case prerelease
    }
}

/// A pending update, ready to show in the UI.
struct AvailableUpdate: Equatable {
    let currentVersion: String
    let latestVersion: String
    let releaseName: String
    let releaseNotes: String
    let releaseURL: URL
    let publishedAt: Date?
}

// MARK: - Checker

/// Singleton that talks to GitHub and publishes update state to SwiftUI.
final class UpdateChecker: ObservableObject {

    static let shared = UpdateChecker()

    // Published state — drives the banner + Settings row.
    @Published var availableUpdate: AvailableUpdate?
    @Published var isChecking: Bool = false
    @Published var lastCheckedDate: Date?
    @Published var lastCheckError: String?

    // Configuration — repository the app checks against.
    private let owner = "JohnDimou"
    private let repo = "ClaudeWatch"

    // Cache lifetime for opportunistic checks (manual checks bypass this).
    private let cacheDuration: TimeInterval = 6 * 60 * 60

    private enum DefaultsKey {
        static let lastChecked = "updateLastChecked"
        static let dismissedVersion = "updateDismissedVersion"
    }

    private init() {
        self.lastCheckedDate = UserDefaults.standard.object(forKey: DefaultsKey.lastChecked) as? Date
    }

    // MARK: Derived values

    /// Version string baked into the app bundle at build time.
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Whether enough time has passed since the last check to warrant hitting
    /// the network again. Manual "Check Now" always bypasses this.
    private var cacheExpired: Bool {
        guard let last = lastCheckedDate else { return true }
        return Date().timeIntervalSince(last) > cacheDuration
    }

    /// A user can dismiss a specific version — we persist it so the banner
    /// stays hidden until a newer release is published.
    private var dismissedVersion: String? {
        UserDefaults.standard.string(forKey: DefaultsKey.dismissedVersion)
    }

    // MARK: Public API

    /// Fetch the latest release from GitHub. Caches for `cacheDuration` unless
    /// `force` is true (used by the "Check Now" button).
    func checkForUpdates(force: Bool = false) {
        if !force && !cacheExpired { return }
        if isChecking { return }

        isChecking = true
        lastCheckError = nil

        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            isChecking = false
            lastCheckError = "Invalid release URL"
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeWatch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handleResponse(data: data, response: response, error: error)
            }
        }.resume()
    }

    /// Open the GitHub release page so the user can download the new build.
    func openReleasePage() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.releaseURL)
    }

    /// Hide the banner for the current version until a newer one appears.
    func dismissCurrentUpdate() {
        if let version = availableUpdate?.latestVersion {
            UserDefaults.standard.set(version, forKey: DefaultsKey.dismissedVersion)
        }
        availableUpdate = nil
    }

    // MARK: Response handling

    private func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
        isChecking = false
        lastCheckedDate = Date()
        UserDefaults.standard.set(lastCheckedDate, forKey: DefaultsKey.lastChecked)

        if let error = error {
            lastCheckError = error.localizedDescription
            return
        }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            lastCheckError = "GitHub returned HTTP \(http.statusCode)"
            return
        }

        guard let data = data else {
            lastCheckError = "Empty response"
            return
        }

        do {
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            // Skip prereleases — only surface stable tags to users.
            guard !release.prerelease else {
                availableUpdate = nil
                return
            }

            guard let releaseURL = URL(string: release.htmlUrl) else {
                lastCheckError = "Invalid release URL in response"
                return
            }

            let latest = Self.normalizeVersion(release.tagName)
            let current = currentVersion

            guard Self.isVersion(latest, newerThan: current) else {
                availableUpdate = nil
                return
            }

            // Respect the user's prior dismissal.
            if let dismissed = dismissedVersion,
               !Self.isVersion(latest, newerThan: dismissed) {
                availableUpdate = nil
                return
            }

            let publishedAt = release.publishedAt.flatMap {
                ISO8601DateFormatter().date(from: $0)
            }

            availableUpdate = AvailableUpdate(
                currentVersion: current,
                latestVersion: latest,
                releaseName: release.name ?? release.tagName,
                releaseNotes: release.body ?? "",
                releaseURL: releaseURL,
                publishedAt: publishedAt
            )
        } catch {
            lastCheckError = "Parse error: \(error.localizedDescription)"
        }
    }

    // MARK: Semver helpers

    /// Strip leading "v" or "V", trim whitespace.
    private static func normalizeVersion(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if v.first == "v" || v.first == "V" { v.removeFirst() }
        return v
    }

    /// Returns true when `candidate` sorts strictly higher than `baseline`.
    /// Numeric components are compared left-to-right; missing components
    /// count as zero, so "1.4" is equal to "1.4.0".
    private static func isVersion(_ candidate: String, newerThan baseline: String) -> Bool {
        let a = parseComponents(candidate)
        let b = parseComponents(baseline)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l > r { return true }
            if l < r { return false }
        }
        return false
    }

    private static func parseComponents(_ s: String) -> [Int] {
        // Split on any non-digit; drop empties; take up to the first 4 numbers
        // so "1.4.0-beta.2" still compares sensibly.
        return s.split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}
