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

    private func refreshShelfSize() {
        let store = (NSApp.delegate as? AppDelegate)?.shelfStore
        let bytes = store?.storedBytes ?? 0
        shelfSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        TabView {
            appearance
                .tabItem { Label("모양", systemImage: "paintbrush") }
            behaviour
                .tabItem { Label("동작", systemImage: "hand.tap") }
            features
                .onAppear(perform: refreshShelfSize)
                .tabItem { Label("기능", systemImage: "square.grid.2x2") }
            MotionLabView()
                .tabItem { Label("모션 실험실", systemImage: "waveform.path") }
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - 모양

    private var appearance: some View {
        Form {
            Section {
                Picker("노치 높이", selection: $preferences.heightMode) {
                    ForEach(NotchHeightMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if preferences.heightMode == .custom {
                    LabeledContent("높이") {
                        HStack {
                            Slider(value: $preferences.customHeight, in: 24...60, step: 1)
                            Text("\(Int(preferences.customHeight)) pt")
                                .monospacedDigit()
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }

            } footer: {
                Text("노치에 맞추면 닫힌 상태의 알약이 카메라 하우징과 완전히 겹쳐 보이지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("대기 중 표시", selection: $preferences.idleStyle) {
                    ForEach(IdleStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                Toggle("앨범 아트에서 색상 추출", isOn: $preferences.tintFromArtwork)
            }

            Section {
                Picker("표시할 디스플레이", selection: $preferences.displayTarget) {
                    ForEach(DisplayTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }

                Picker("외장 디스플레이", selection: $preferences.externalDisplayStyle) {
                    ForEach(ExternalDisplayStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
            } footer: {
                Text("맥북 내장 화면은 항상 노치에 맞춰집니다. 외장 모니터에는 카메라 하우징이 없어서, 상단 밀착은 노치 모양 그대로 메뉴 막대를 덮고, 알약은 메뉴 막대 안에 들어앉습니다.")
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
                Toggle("마우스를 올리면 열기", isOn: $preferences.openOnHover)

                if preferences.openOnHover {
                    LabeledContent("열리기까지 지연") {
                        HStack {
                            Slider(value: $preferences.hoverDelay, in: 0...0.6, step: 0.02)
                            Text(String(format: "%.2f초", preferences.hoverDelay))
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            } footer: {
                Text("끄면 노치를 클릭해야 열립니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("모션", selection: $preferences.motion) {
                    ForEach(MotionPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                Toggle("햅틱 피드백", isOn: $preferences.hapticFeedback)
            } footer: {
                Text(motionFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("볼륨·밝기 HUD를 노치에 표시", isOn: hudBinding)

                if preferences.hudEnabled {
                    if hud.isRunning {
                        Label("동작 중", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("손쉬운 사용 권한을 기다리는 중입니다. 시스템 설정에서 Dynamic을 허용하면 앱을 다시 실행하지 않아도 바로 켜집니다.")
                            Button("손쉬운 사용 설정 열기") {
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
                Text("키를 가로채 시스템 오버레이 대신 노치에 표시합니다. 그러려면 키 이벤트를 시스템보다 먼저 받아야 해서 손쉬운 사용 권한이 필요합니다. 목록에 Dynamic이 이미 있는데도 켜지지 않으면, 그 항목은 예전 서명을 가리키는 것이니 지우고 다시 추가하세요. 키보드 백라이트 키는 읽을 수 있는 값이 없어 시스템에 그대로 넘깁니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("맥을 켤 때 자동으로 실행", isOn: loginItemBinding)

                if let message = loginItemError ?? LoginItem.explanation {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if !LoginItem.isInApplicationsFolder {
                    Text("지금은 빌드 폴더에서 실행 중입니다. 자동 실행은 경로로 등록되므로, 앱을 응용 프로그램 폴더로 옮긴 뒤 다시 켜 주세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("화면 녹화에서 제외", isOn: $preferences.hideFromScreenRecording)
            } footer: {
                Text("노치는 항상 비공개 윈도우 서버 Space에 고정됩니다. 그래야 데스크탑을 넘길 때 함께 미끄러지지 않고, 전체 화면 앱 위에도 남습니다. 실제 노치는 하드웨어라 움직이지 않으니까요.")
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
                    loginItemError = "자동 실행을 설정하지 못했습니다: \(error.localizedDescription)"
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
            return "손쉬운 사용에서 ‘동작 줄이기’가 켜져 있어 모든 애니메이션이 페이드로 대체됩니다."
        }
        return "Apple의 스프링 표기(지속 시간 + 반동)를 그대로 씁니다. ‘경쾌하게’ 340ms·반동 0.18, ‘탄력 있게’ 460ms·0.28, ‘부드럽게’ 580ms·0.04. 닫힐 때는 조금 짧고 반동이 0.12 더해져서, 쉬는 크기보다 더 줄었다가 되돌아옵니다. 정확한 곡선은 ‘모션 실험실’ 탭에서 프레임 단위로 볼 수 있습니다."
    }

    // MARK: - 기능

    private var features: some View {
        Form {
            Section {
                Toggle("미디어 컨트롤 표시", isOn: $preferences.mediaEnabled)
                Toggle("비주얼라이저 표시", isOn: $preferences.visualizerEnabled)
                    .disabled(!preferences.mediaEnabled)
                Toggle("쉬는 중에도 미터 움직이기", isOn: $preferences.animateRestingMeter)
                    .disabled(!preferences.mediaEnabled || !preferences.visualizerEnabled)
                Toggle("가사 가져오기", isOn: $preferences.lyricsEnabled)
                    .disabled(!preferences.mediaEnabled)
                Picker("재생이 멈추면 숨기기", selection: $preferences.mediaIdleTimeout) {
                    Text("10초 후").tag(10.0)
                    Text("30초 후").tag(30.0)
                    Text("1분 후").tag(60.0)
                    Text("5분 후").tag(300.0)
                    Text("계속 표시").tag(0.0)
                }
                .disabled(!preferences.mediaEnabled)
            } header: {
                Text("재생 중")
            } footer: {
                Text("미터는 Core Animation으로 그려서 프레임 보간을 렌더 서버가 맡습니다. 앱은 0.33초마다 다음 목표값만 정하고, 화면이 꺼지면 완전히 멈춥니다. 유휴 CPU 0.1% 실측입니다.\n\n가사는 lrclib.net에서 가져옵니다. 곡 제목·아티스트·앨범·재생 시간이 그 서버로 전송되며, 계정이나 키는 필요 없습니다. 원하지 않으면 꺼 두세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("라이브 알림") {
                Toggle("충전·배터리 상태", isOn: $preferences.powerActivitiesEnabled)
                Toggle("다운로드·스크린샷 완료", isOn: $preferences.fileActivitiesEnabled)
                Toggle("기기 연결", isOn: $preferences.deviceActivitiesEnabled)

            }

            Section {
                Toggle("파일 선반 사용", isOn: $preferences.shelfEnabled)
                Picker("보관 기간", selection: $preferences.shelfExpiryDays) {
                    Text("1일").tag(1)
                    Text("3일").tag(3)
                    Text("7일").tag(7)
                    Text("30일").tag(30)
                    Text("계속 보관").tag(0)
                }
                .disabled(!preferences.shelfEnabled)

                Toggle("AirDrop으로 받은 파일 선반에 담기", isOn: $preferences.airDropToShelf)
                    .disabled(!preferences.shelfEnabled)

                LabeledContent("보관 중인 용량") {
                    Text(shelfSize)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("끌어다 놓은 파일은 Dynamic 전용 폴더로 복사됩니다. 원본을 옮기거나 지워도 선반은 그대로 유지됩니다. AirDrop 수신은 macOS가 처리하며, 다운로드 폴더에 도착한 파일을 노치가 알려주고 선반에 함께 담아둡니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("재생 정보 접근") {
                    Text("mediaremote-adapter 경유")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("macOS 15.4부터 MediaRemote는 Apple 자체 프로세스만 접근할 수 있습니다. Dynamic은 아직 권한이 남아 있는 시스템 perl 바이너리를 통해 재생 정보를 읽습니다. 향후 업데이트로 이 경로가 막히면 조용히 멈추는 대신 노치에 그 사실을 표시합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
