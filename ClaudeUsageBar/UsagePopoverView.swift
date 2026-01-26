//
//  UsagePopoverView.swift
//  ClaudeUsageBar
//
//  The main popup view displaying Claude usage statistics
//  with a modern glassmorphic design and dark mode support.
//
//  Author: John Dimou - OptimalVersion.io
//  License: MIT
//

import SwiftUI

// MARK: - Main Popover View

struct UsagePopoverView: View {
    @ObservedObject var usageManager = UsageManager.shared
    @State private var showingInfo = false
    @State private var showingSettings = false
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            // Background
            backgroundGradient

            if showingSettings {
                // Settings View (replaces main content)
                SettingsView(showingSettings: $showingSettings)
            } else if showingInfo {
                // Info View (replaces main content)
                InfoDetailView(showingInfo: $showingInfo)
            } else {
                // Main Content
                VStack(spacing: 0) {
                    headerView
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    if usageManager.isLoading && usageManager.currentUsage == nil {
                        loadingView
                    } else if let error = usageManager.errorMessage {
                        errorView(error)
                    } else if let usage = usageManager.currentUsage {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 14) {
                                sessionCard(usage)
                                weeklyCard(usage)
                                if usage.sonnetPercentage > 0 {
                                    sonnetCard(usage)
                                }
                                executionInfoCard(usage)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 8)
                        }
                    } else {
                        emptyStateView
                    }

                    footerView
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
            }
        }
        .frame(width: 380, height: 520)
    }

    // MARK: - Background

    var backgroundGradient: some View {
        ZStack {
            // Solid base color (85% opaque)
            (colorScheme == .dark ? Color(hex: "1a1a2e") : Color(hex: "f0f0f5"))
                .opacity(0.85)

            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                .opacity(0.3)

            // Animated gradient orbs
            GeometryReader { geometry in
                ZStack {
                    // Purple orb
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.purple.opacity(0.15), Color.clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 150
                            )
                        )
                        .frame(width: 300, height: 300)
                        .offset(x: -100, y: -50)
                        .blur(radius: 60)

                    // Blue orb
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.blue.opacity(0.12), Color.clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 150
                            )
                        )
                        .frame(width: 250, height: 250)
                        .offset(x: 100, y: 200)
                        .blur(radius: 50)

                    // Cyan accent
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.cyan.opacity(0.1), Color.clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .offset(x: 50, y: 350)
                        .blur(radius: 40)
                }
            }
        }
    }

    // MARK: - Header

    var headerView: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                // Neutral colored icon
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 38, height: 38)

                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.primary.opacity(0.7))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude Code Usage")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.primary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Claude Max")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                // Settings button
                Button(action: { showingSettings = true }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(Circle())

                // Info button
                Button(action: { showingInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(Circle())

                // Refresh button
                Button(action: { usageManager.fetchUsage() }) {
                    RefreshIcon(isLoading: usageManager.isLoading)
                }
                .buttonStyle(.plain)
                .padding(6)
                .background(Color.primary.opacity(0.05))
                .clipShape(Circle())
            }
        }
    }

    // MARK: - Usage Cards

    func usageGradient(for percentage: Double) -> [Color] {
        if percentage < 50 {
            // Green
            return [Color(hex: "10b981"), Color(hex: "34d399")]
        } else if percentage < 75 {
            // Yellow/Orange
            return [Color(hex: "f59e0b"), Color(hex: "fbbf24")]
        } else {
            // Red
            return [Color(hex: "ef4444"), Color(hex: "f87171")]
        }
    }

    func sessionCard(_ usage: ClaudeUsage) -> some View {
        let gradient = usageGradient(for: usage.sessionPercentage)
        return EnhancedUsageCard(
            title: "Current Session",
            percentage: usage.sessionPercentage,
            resetText: usage.sessionReset.isEmpty ? nil : "Resets \(usage.sessionReset)",
            gradient: gradient,
            icon: "clock.fill",
            iconBackground: [gradient[0].opacity(0.25), gradient[1].opacity(0.25)]
        )
    }

    func weeklyCard(_ usage: ClaudeUsage) -> some View {
        let gradient = usageGradient(for: usage.weeklyPercentage)
        return EnhancedUsageCard(
            title: "Weekly Limit (All Models)",
            percentage: usage.weeklyPercentage,
            resetText: usage.weeklyReset.isEmpty ? nil : "Resets \(usage.weeklyReset)",
            gradient: gradient,
            icon: "calendar",
            iconBackground: [gradient[0].opacity(0.25), gradient[1].opacity(0.25)]
        )
    }

    func sonnetCard(_ usage: ClaudeUsage) -> some View {
        let gradient = usageGradient(for: usage.sonnetPercentage)
        return EnhancedUsageCard(
            title: "Weekly (Sonnet Only)",
            percentage: usage.sonnetPercentage,
            resetText: nil,
            gradient: gradient,
            icon: "sparkles",
            iconBackground: [gradient[0].opacity(0.25), gradient[1].opacity(0.25)]
        )
    }

    // MARK: - Execution Info Card

    func executionInfoCard(_ usage: ClaudeUsage) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.cyan)
                    Text("Last Fetch")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                    if usageManager.isLoading {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                Divider()
                    .background(Color.primary.opacity(0.1))

                VStack(spacing: 8) {
                    InfoRowSmall(
                        icon: "clock",
                        label: "Updated",
                        value: usage.lastUpdated.formatted(date: .omitted, time: .shortened)
                    )
                    InfoRowSmall(
                        icon: "checkmark.circle",
                        label: "Status",
                        value: usageManager.errorMessage == nil ? "Success" : "Error",
                        valueColor: usageManager.errorMessage == nil ? .green : .red
                    )
                    InfoRowSmall(
                        icon: "doc.text",
                        label: "Data Size",
                        value: "\(usage.rawOutput.count) chars"
                    )
                }
            }
        }
    }

    // MARK: - States

    var loadingView: some View {
        VStack(spacing: 20) {
            LoadingSpinner()

            VStack(spacing: 6) {
                Text("Fetching Usage Data")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)

                Text("Running /usage command...")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func errorView(_ error: String) -> some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(
                        LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom)
                    )
            }

            VStack(spacing: 8) {
                Text("Something went wrong")
                    .font(.system(size: 16, weight: .semibold))

                Text(error)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button(action: { usageManager.fetchUsage() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Try Again")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    var emptyStateView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 80, height: 80)

                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 36))
                    .foregroundColor(.blue)
            }

            VStack(spacing: 8) {
                Text("No Usage Data")
                    .font(.system(size: 16, weight: .semibold))

                Text("Click below to fetch your Claude usage")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Button(action: { usageManager.fetchUsage() }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle")
                    Text("Fetch Usage")
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [.purple, .blue], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    var footerView: some View {
        VStack(spacing: 10) {
            // Star on GitHub button
            Button(action: {
                if let url = URL(string: "https://github.com/JohnDimou/ClaudeCodeUsageBar") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 6) {
                    Text("⭐ Star on GitHub")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05))
            .clipShape(Capsule())
            .padding(.top, 8)

            HStack {
                if let usage = usageManager.currentUsage {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 6, height: 6)
                        Text("Updated \(usage.lastUpdated.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 9))
                        Text("Quit")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
            }
        }
    }
}

// MARK: - Enhanced Usage Card

struct EnhancedUsageCard: View {
    let title: String
    let percentage: Double
    let resetText: String?
    let gradient: [Color]
    let icon: String
    let iconBackground: [Color]

    @State private var animatedPercentage: Double = 0

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    // Icon with background
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(colors: iconBackground, startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                            .frame(width: 36, height: 36)

                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)

                        if let reset = resetText {
                            Text(reset)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    // Percentage with ring
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 4)
                            .frame(width: 50, height: 50)

                        Circle()
                            .trim(from: 0, to: animatedPercentage / 100)
                            .stroke(
                                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                            .frame(width: 50, height: 50)
                            .rotationEffect(.degrees(-90))

                        Text("\(Int(percentage))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(
                                LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                    }
                }

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 8)

                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(colors: gradient, startPoint: .leading, endPoint: .trailing)
                            )
                            .frame(width: geometry.size.width * min(animatedPercentage / 100, 1.0), height: 8)
                            .shadow(color: gradient.first?.opacity(0.5) ?? .clear, radius: 4, x: 0, y: 2)
                    }
                }
                .frame(height: 8)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.8)) {
                animatedPercentage = percentage
            }
        }
        .onChange(of: percentage) { newValue in
            withAnimation(.easeOut(duration: 0.5)) {
                animatedPercentage = newValue
            }
        }
    }
}

// MARK: - Info Detail View

struct InfoDetailView: View {
    @Binding var showingInfo: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 38, height: 38)

                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.7))
                    }

                    Text("About")
                        .font(.system(size: 15, weight: .bold))
                }

                Spacer()

                Button(action: { showingInfo = false }) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    // App Info
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SettingsHeader(title: "Application", icon: "app.badge")
                            VStack(alignment: .leading, spacing: 6) {
                                InfoDetailRow(label: "Version", value: "1.2.0")
                                InfoDetailRow(label: "Platform", value: "macOS 13.0+")
                                InfoDetailRow(label: "Framework", value: "SwiftUI")
                                InfoDetailRow(label: "License", value: "MIT")
                            }
                        }
                    }

                    // How It Works
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SettingsHeader(title: "How It Works", icon: "gearshape.2")
                            VStack(alignment: .leading, spacing: 8) {
                                StepRow(number: 1, text: "Spawns Claude CLI in a pseudo-terminal")
                                StepRow(number: 2, text: "Sends /usage command interactively")
                                StepRow(number: 3, text: "Parses terminal output for usage data")
                                StepRow(number: 4, text: "Displays results in native SwiftUI")
                            }
                        }
                    }

                    // Data Info
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SettingsHeader(title: "Privacy", icon: "lock.shield")
                            Text("This app runs locally. No data is sent to external servers. Usage stats are fetched via the Claude CLI.")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // Links
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SettingsHeader(title: "Links", icon: "link")
                            VStack(alignment: .leading, spacing: 8) {
                                LinkRow(title: "GitHub Repository", url: "https://github.com/JohnDimou/ClaudeCodeUsageBar", icon: "star.fill")
                                LinkRow(title: "Report Issue", url: "https://github.com/JohnDimou/ClaudeCodeUsageBar/issues", icon: "exclamationmark.bubble")
                                LinkRow(title: "OptimalVersion.io", url: "https://optimalversion.io", icon: "globe")
                            }
                        }
                    }

                    // Credits
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Text("John Dimou")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("OptimalVersion.io")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Spacer()
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @Binding var showingSettings: Bool
    @ObservedObject var usageManager = UsageManager.shared

    let intervalOptions: [(String, Double)] = [
        ("30 seconds", 30),
        ("1 minute", 60),
        ("2 minutes", 120),
        ("5 minutes", 300),
        ("10 minutes", 600),
        ("Never", 0)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 38, height: 38)

                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary.opacity(0.7))
                    }

                    Text("Settings")
                        .font(.system(size: 15, weight: .bold))
                }

                Spacer()

                Button(action: { showingSettings = false }) {
                    Image(systemName: "chevron.left.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    // Startup Section
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsHeader(title: "Startup", icon: "power")

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Launch at Login")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text("Start app when you log in")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $usageManager.launchAtLogin)
                                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "8b5cf6")))
                                    .labelsHidden()
                            }
                        }
                    }

                    // Auto Refresh Section
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsHeader(title: "Auto Refresh", icon: "clock.arrow.circlepath")

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                                ForEach(intervalOptions, id: \.1) { option in
                                    IntervalButton(
                                        title: option.0,
                                        isSelected: usageManager.refreshInterval == option.1,
                                        action: { usageManager.refreshInterval = option.1 }
                                    )
                                }
                            }
                        }
                    }

                    // Behavior Section
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 14) {
                            SettingsHeader(title: "Behavior", icon: "cursorarrow.click.2")

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Refresh on Open")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text("Fetch new data when popup opens")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $usageManager.refreshOnOpen)
                                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "8b5cf6")))
                                    .labelsHidden()
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            Spacer()
        }
    }
}

struct SettingsHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "8b5cf6"))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
        }
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
    }
}

struct IntervalButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected
                            ? LinearGradient(colors: [Color(hex: "8b5cf6"), Color(hex: "6366f1")], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [Color.primary.opacity(0.05), Color.primary.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.clear : Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Supporting Views

struct GlassCard<Content: View>: View {
    @Environment(\.colorScheme) var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.7))
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.2 : 0.5),
                                        Color.white.opacity(colorScheme == .dark ? 0.05 : 0.2)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
            )
    }
}

struct InfoRowSmall: View {
    let icon: String
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(width: 16)

            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(valueColor)
        }
    }
}

struct InfoSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.purple)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }

            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.03))
                )
        }
    }
}

struct InfoDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
        }
    }
}

struct StepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 22, height: 22)
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.purple)
            }

            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }
}

struct RequirementRow: View {
    let name: String
    let status: Bool

    var body: some View {
        HStack {
            Image(systemName: status ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(status ? .green : .red)

            Text(name)
                .font(.system(size: 12))
                .foregroundColor(.primary)

            Spacer()
        }
    }
}

struct LinkRow: View {
    let title: String
    let url: String
    let icon: String

    var body: some View {
        Button(action: {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
                    .frame(width: 20)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.blue)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Loading Spinner

struct LoadingSpinner: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 4)
                .frame(width: 50, height: 50)

            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(
                    LinearGradient(colors: [Color(hex: "10b981"), Color(hex: "34d399")], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 50, height: 50)
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Refresh Icon

struct RefreshIcon: View {
    let isLoading: Bool
    @State private var rotation: Double = 0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.secondary)
            .rotationEffect(.degrees(rotation))
            .onChange(of: isLoading) { newValue in
                if newValue {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                } else {
                    withAnimation(.default) {
                        rotation = 0
                    }
                }
            }
            .onAppear {
                if isLoading {
                    withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
            }
    }
}

// MARK: - Visual Effect Blur

struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview

#Preview {
    UsagePopoverView()
        .frame(width: 380, height: 520)
}
