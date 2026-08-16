import AppKit
import SwiftUI

/// A plain AppKit window rather than SwiftUI's `Settings` scene, because an
/// accessory app with no scenes has nothing for that scene to attach to.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let lifetime = Lifetime()

    static var isOpen: Bool { window != nil }

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let created = NSWindow(contentViewController: hosting)
        created.title = "Dynamic"
        created.styleMask = [.titled, .closable, .miniaturizable]
        created.isReleasedWhenClosed = false
        // Torn down on close, not kept around.
        //
        // A settings window is opened once in a while and then closed for good,
        // but holding it keeps the whole SwiftUI tree behind four tabs — the
        // Motion Lab's sampled curves included — alive for the rest of the
        // session. That is most of this app's resident memory, permanently, for
        // a window nobody is looking at. Rebuilding it costs a few frames.
        created.delegate = lifetime
        created.setContentSize(NSSize(width: 520, height: 560))
        created.center()
        // Centring alone puts the title bar under the notch panel, which sits
        // above every other window and would hide the tab bar.
        if let screen = created.screen ?? NSScreen.main {
            let maximumTop = screen.visibleFrame.maxY - 140
            if created.frame.maxY > maximumTop {
                created.setFrameOrigin(
                    NSPoint(x: created.frame.origin.x, y: maximumTop - created.frame.height)
                )
            }
        }

        window = created
        NSApp.activate(ignoringOtherApps: true)
        created.makeKeyAndOrderFront(nil)
    }

    /// `isReleasedWhenClosed` stays false — AppKit releasing a window out from
    /// under ARC is its own hazard — so releasing means dropping our reference.
    private final class Lifetime: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let closing = notification.object as? NSWindow,
                      closing === SettingsWindow.window
                else { return }
                closing.contentViewController = nil
                SettingsWindow.window = nil
            }
        }
    }
}

struct SettingsView: View {
    @State private var preferences = Preferences.shared
    @State private var hud = HUDController.shared
    @State private var launchesAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?
    /// Read once when the tab appears rather than on every redraw: it walks the
    /// shelf directory, and a settings form re-renders on every keystroke.
    @State private var shelfSize = "…"
    @State private var updates = UpdateCheck()
    @State private var language = AppLanguage.current

    private func refreshShelfSize() {
        let store = (NSApp.delegate as? AppDelegate)?.shelfStore
        let bytes = store?.storedBytes ?? 0
        shelfSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            appearance
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            behaviour
                .tabItem { Label("Behaviour", systemImage: "hand.tap") }
            features
                .onAppear(perform: refreshShelfSize)
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }
            #if DEV_TOOLS
            MotionLabView()
                .tabItem { Label("Motion Lab", systemImage: "waveform.path") }
            #endif
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text(updates.installedVersion)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        updateStatus
                    }
                }

                Button("Check for Updates") {
                    Task { await updates.check() }
                }
                .disabled(updates.state == .checking)

                if case .available(let version) = updates.state {
                    Button("Download \(version)") {
                        NSWorkspace.shared.open(UpdateCheck.releasesPage)
                    }
                }
            } header: {
                Text("Dynamic")
            } footer: {
                Text("Updates are published as GitHub releases. Dynamic only tells you one exists and opens the page — it never replaces itself, which keeps an auto-updater's worth of attack surface out of the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .onChange(of: language) { _, selected in
                    AppLanguage.select(selected)
                }
            } footer: {
                Text("macOS reads this before the app's text is loaded, so it applies the next time Dynamic starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Website") {
                    Link("lunibee.kr", destination: UpdateCheck.website)
                }
                LabeledContent("Source and releases") {
                    Link("GitHub", destination: UpdateCheck.sourcePage)
                }
            } footer: {
                Text("Dynamic is open source under the MIT licence, and bundles mediaremote-adapter under BSD 3-Clause. It comes with no warranty — see the notes on playback access in Features.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch updates.state {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label("Up to date", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .font(.caption)
        case .available(let version):
            Label("\(version) available", systemImage: "arrow.down.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.tint)
                .font(.caption)
        case .failed:
            Label("Could not check", systemImage: "exclamationmark.triangle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    // MARK: - 모양

    private var appearance: some View {
        Form {
            Section {
                Picker("Notch height", selection: $preferences.heightMode) {
                    ForEach(NotchHeightMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if preferences.heightMode == .custom {
                    LabeledContent("Height") {
                        HStack {
                            Slider(value: $preferences.customHeight, in: 24...60, step: 1)
                            Text("\(Int(preferences.customHeight)) pt")
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }

            } footer: {
                Text("Matching the notch hides the resting pill behind the camera housing exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("When idle, show", selection: $preferences.idleStyle) {
                    ForEach(IdleStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("Take the accent colour from the artwork", isOn: $preferences.tintFromArtwork)
            }

            Section {
                Picker("Show on", selection: $preferences.displayTarget) {
                    ForEach(DisplayTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }

                Picker("On external displays", selection: $preferences.externalDisplayStyle) {
                    ForEach(ExternalDisplayStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            } footer: {
                Text("The built-in display always matches the notch. An external monitor has no camera housing, so flush keeps the notch shape and covers the menu bar, while the pill sits inside the menu bar instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 동작

    private var behaviour: some View {
        Form {
            Section {
                Toggle("Open on hover", isOn: $preferences.openOnHover)

                if preferences.openOnHover {
                    LabeledContent("Delay before opening") {
                        HStack {
                            Slider(value: $preferences.hoverDelay, in: 0...0.6, step: 0.02)
                            Text(String(format: String(localized: "%.2fs"), preferences.hoverDelay))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            } footer: {
                Text("With this off, the notch opens on a click instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Motion", selection: $preferences.motion) {
                    ForEach(MotionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Toggle("Haptic feedback", isOn: $preferences.hapticFeedback)
            } footer: {
                Text(motionFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show the volume and brightness HUD in the notch", isOn: hudBinding)

                if preferences.hudEnabled {
                    if hud.isRunning {
                        Label("Working", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Waiting for Accessibility permission. Allow Dynamic in System Settings and this turns itself on — no relaunch needed.")
                            Button("Open Accessibility settings") {
                                NSWorkspace.shared.open(URL(
                                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                                )!)
                            }
                            .controlSize(.small)
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Intercepts the keys and draws them in the notch instead of the system overlay. That means seeing the key events before the system does, which is what needs Accessibility permission. If Dynamic is already in the list but this stays off, that entry points at an older signature — remove it and add it again. Keyboard backlight keys have no readable value, so they are passed straight through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: loginItemBinding)

                if let message = loginItemError ?? LoginItem.explanation {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !LoginItem.isInApplicationsFolder {
                    Text("This copy is running from a build folder. Opening at login registers a path, so move the app to your Applications folder and turn this on again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Exclude from screen recordings", isOn: $preferences.hideFromScreenRecording)
            } footer: {
                Text("The notch is always pinned to a private window server Space. That is what keeps it from sliding away when you switch desktops, and what keeps it above full-screen apps — a real notch is hardware, and hardware does not move.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Writes straight through to `SMAppService` and reads the result back, so
    /// the toggle can never claim a state launchd did not accept.
    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { launchesAtLogin },
            set: { wanted in
                do {
                    try LoginItem.setEnabled(wanted)
                    loginItemError = nil
                } catch {
                    loginItemError = String(localized: "Could not set up opening at login: \(error.localizedDescription)")
                }
                launchesAtLogin = LoginItem.isEnabled
            }
        )
    }

    private var delegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    /// Turning this on may need permission the app does not have yet, so the
    /// write goes through the delegate, which prompts and re-arms the tap.
    private var hudBinding: Binding<Bool> {
        Binding(
            get: { preferences.hudEnabled },
            set: { wanted in
                preferences.hudEnabled = wanted
                delegate?.refreshHUD()
            }
        )
    }

    private var motionFooter: String {
        if Motion.prefersReducedMotion {
            return String(localized: "Reduce Motion is on in Accessibility, so every animation is replaced by a fade.")
        }
        return String(localized: "Uses Apple’s own spring notation — duration plus bounce. Like the Island is 340ms at 0.18, Bouncy is 460ms at 0.28, Gentle is 580ms at 0.04. Closing is a little shorter with 0.12 more bounce, so it undershoots the resting size and settles back. The exact curves are in the Motion Lab tab, frame by frame.")
    }

    // MARK: - 기능

    private var features: some View {
        Form {
            Section {
                Toggle("Show media controls", isOn: $preferences.mediaEnabled)
                Toggle("Show the visualiser", isOn: $preferences.visualizerEnabled)
                    .disabled(!preferences.mediaEnabled)
                Toggle("Keep the meter moving while resting", isOn: $preferences.animateRestingMeter)
                    .disabled(!preferences.mediaEnabled || !preferences.visualizerEnabled)
                Toggle("Fetch lyrics", isOn: $preferences.lyricsEnabled)
                    .disabled(!preferences.mediaEnabled)
                Picker("Hide after playback stops", selection: $preferences.mediaIdleTimeout) {
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("Never").tag(0.0)
                }
                .disabled(!preferences.mediaEnabled)
            } header: {
                Text("Now Playing")
            } footer: {
                Text("The meter is drawn with Core Animation, so the render server interpolates the frames. The app only picks the next target every 0.33s, and stops entirely when the display sleeps. Measured idle CPU: 0.05%.\n\nLyrics come from lrclib.net. The track title, artist, album and duration are sent to that server; no account or key is involved. Turn this off if you would rather not.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Live activities") {
                Toggle("Power and battery", isOn: $preferences.powerActivitiesEnabled)
                Toggle("Downloads and screenshots", isOn: $preferences.fileActivitiesEnabled)
                Toggle("Device connections", isOn: $preferences.deviceActivitiesEnabled)

            }

            Section {
                Toggle("Use the file shelf", isOn: $preferences.shelfEnabled)
                Picker("Keep files for", selection: $preferences.shelfExpiryDays) {
                    Text("1 day").tag(1)
                    Text("3 days").tag(3)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("Forever").tag(0)
                }
                .disabled(!preferences.shelfEnabled)

                Toggle("Put AirDrop arrivals on the shelf", isOn: $preferences.airDropToShelf)
                    .disabled(!preferences.shelfEnabled)

                LabeledContent("Stored") {
                    Text(shelfSize)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Dropped files are copied into a folder of Dynamic’s own, so moving or deleting the original leaves the shelf alone. AirDrop itself is handled by macOS; the notch notices what lands in your Downloads folder, announces it, and keeps a copy on the shelf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Playback access") {
                    Text("via mediaremote-adapter")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Since macOS 15.4, MediaRemote is reachable only by Apple’s own processes. Dynamic reads playback information through the system perl binary, which is still entitled. If a future update closes that path, the notch says so rather than going quiet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
