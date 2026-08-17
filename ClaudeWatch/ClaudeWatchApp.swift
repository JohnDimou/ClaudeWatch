//
//  ClaudeWatchApp.swift
//  ClaudeWatch
//
//  A macOS menu bar app that displays Claude Code usage statistics.
//  Shows session and weekly usage percentages in the status bar,
//  with a detailed glassmorphic popup on click.
//
//  Requirements:
//  - macOS 13.0+
//  - Claude Code CLI installed (https://claude.ai/code)
//  - Python 3 (comes with macOS)
//
//  Author: John Dimou - OptimalVersion.io
//  License: MIT
//

import SwiftUI
import AppKit

// MARK: - App Entry Point

@main
struct ClaudeWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - App Delegate

/// Manages the menu bar status item and popover
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Properties

    /// The status bar item displayed in the menu bar
    var statusItem: NSStatusItem!

    /// The popover that shows detailed usage information
    var popover: NSPopover!

    /// Shared usage manager instance
    var usageManager = UsageManager.shared

    /// Timer for auto-refreshing usage data
    var timer: Timer?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon - this is a menu bar only app
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupAutoRefresh()

        // Initial fetch
        usageManager.fetchUsage()

        // Kick off a GitHub release check. Respects its own 6h cache
        // internally, so this is safe to call unconditionally on launch.
        UpdateChecker.shared.checkForUpdates()

        // Observe usage changes to update the status bar
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(usageDidUpdate),
            name: .usageDidUpdate,
            object: nil
        )

        // Observe refresh interval changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refreshIntervalChanged),
            name: .refreshIntervalChanged,
            object: nil
        )
    }

    // MARK: - Setup Methods

    /// Creates and configures the status bar item
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
            updateStatusButton()
        }
    }

    /// Creates and configures the popover
    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 600)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: UsagePopoverView())
    }

    /// Sets up the auto-refresh timer
    private func setupAutoRefresh() {
        timer?.invalidate()
        let interval = usageManager.refreshInterval
        if interval > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.usageManager.fetchUsage()
            }
        }
    }

    // MARK: - Actions

    /// Called when usage data is updated
    @objc func usageDidUpdate() {
        DispatchQueue.main.async {
            self.updateStatusButton()
        }
    }

    /// Called when refresh interval setting changes
    @objc func refreshIntervalChanged() {
        DispatchQueue.main.async {
            self.setupAutoRefresh()
        }
    }

    /// Updates the status bar button with current usage percentages
    func updateStatusButton() {
        guard let button = statusItem.button else { return }

        let usage = usageManager.currentUsage

        // Only buckets the CLI actually reported get a slot. Showing 0% for
        // a bucket we have no data on is the dangerous failure — it reads as
        // a full allowance remaining when it could be nearly exhausted — and
        // a "—" placeholder is just noise in a glanceable menu bar. So an
        // unreported bucket is dropped entirely, its separator with it:
        // three buckets render as "10% | 9% | 4%", two as "10% | 9%".
        //
        // The per-model bucket (third slot) is the one that commonly goes
        // missing: it loads asynchronously and not every account has one.
        var slots: [String] = []
        if let usage = usage {
            if usage.sessionReported {
                slots.append("\(Int(usage.sessionPercentage))%")
            }
            if usage.weeklyReported {
                slots.append("\(Int(usage.weeklyPercentage))%")
            }
            if usage.modelBucketReported {
                slots.append("\(Int(usage.modelBucketPercentage))%")
            }
        }
        // With no slots yet, say why: a fetch in flight reads "Loading…",
        // whereas a bare "—" means the fetch finished and returned nothing.
        let slotText: String
        if !slots.isEmpty {
            slotText = slots.joined(separator: " | ")
        } else if usageManager.isLoading {
            slotText = "Loading…"
        } else {
            slotText = "—"
        }

        // Create icon
        let attachment = NSTextAttachment()
        if let image = NSImage(systemSymbolName: "brain.head.profile", accessibilityDescription: "Claude") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            attachment.image = image.withSymbolConfiguration(config)
        }

        // Build attributed string: icon + all three percentages
        let iconString = NSAttributedString(attachment: attachment)
        let textString = NSAttributedString(
            string: " \(slotText)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )

        let combined = NSMutableAttributedString()
        combined.append(iconString)
        combined.append(textString)

        button.attributedTitle = combined
    }

    /// Toggles the popover visibility
    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                // Refresh data when opening (if enabled)
                if usageManager.refreshOnOpen {
                    usageManager.fetchUsage()
                }
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when usage data has been updated
    static let usageDidUpdate = Notification.Name("usageDidUpdate")

    /// Posted when refresh interval setting changes
    static let refreshIntervalChanged = Notification.Name("refreshIntervalChanged")
}
