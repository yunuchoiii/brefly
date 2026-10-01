import SwiftUI
import AppKit
import Carbon.HIToolbox

// 시안 2a "설정 창 — 일반", 2b "설정 창 — 음성인식 · AI". 창 폭 620, 왼쪽 사이드바.
// 단축키 · 고급 · 진단 탭은 시안에 없어서 기존 메뉴 항목을 같은 톤으로 옮겼다.

extension Notification.Name {
    /// 설정 창에서 값이 바뀌면 AppDelegate 가 단축키 재등록·팝오버 갱신을 한다.
    static let breflyPrefsChanged = Notification.Name("breflyPrefsChanged")
    static let breflyHotKeyCaptureBegan = Notification.Name("breflyHotKeyCaptureBegan")
    static let breflyHotKeyCaptureEnded = Notification.Name("breflyHotKeyCaptureEnded")
}

/// Prefs 를 SwiftUI 가 관찰할 수 있게 감싼다. 값을 바꾸면 곧바로 Prefs 에 쓴다.
final class SettingsModel: ObservableObject {

    enum Tab: String, CaseIterable, Identifiable {
        // ⚠️ 2026-10-02 에 다시 묶었다. 전에는 '일반'에 받아쓰기 설정이 거의 다 들어가 있고
        //    단축키만 따로 탭이 있어서, 한 기능을 고치려면 탭 두세 개를 오가야 했다.
        //    지금 기준은 **쓰는 사람이 하려는 일**이다 — 받아쓰기 / 회의록이 먼저고,
        //    둘이 같이 쓰는 것(AI 연결)과 앱 자체(일반·업데이트), 안 될 때(문제 해결)가 뒤다.
        case general, dictation, meeting, ai, trouble, updates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general:   return "일반"
            case .dictation: return "받아쓰기"
            case .meeting:   return "회의록"
            case .ai:        return "AI 연결"
            case .trouble:   return "문제 해결"
            case .updates:   return "업데이트"
            }
        }
        var symbol: String {
            switch self {
            case .general:   return "smallcircle.filled.circle"
            case .dictation: return "waveform"
            case .meeting:   return "person.2.wave.2"
            case .ai:        return "sparkles"
            case .trouble:   return "wrench.and.screwdriver"
            case .updates:   return "arrow.down.circle"
            }
        }
    }

    @Published var tab: Tab = .general

    @Published var hotKeyIndex = Prefs.hotKeyIndex            { didSet { Prefs.hotKeyIndex = hotKeyIndex; Prefs.customHotKey = nil; changed() } }
    @Published var customHotKey = Prefs.customHotKey          { didSet { Prefs.customHotKey = customHotKey; changed() } }
    var currentHotKeyTitle: String { Prefs.currentHotKey.title }
    /// 수정자 전용 단축키인데 권한이 없으면 안내가 필요하다.
    var hotKeyNeedsAccessibility: Bool { Prefs.currentHotKey.isModifierOnly && !accessibilityTrusted }
    @Published var autoStop = Prefs.autoStopOnSilence         { didSet { Prefs.autoStopOnSilence = autoStop; changed() } }
    @Published var silenceSeconds = Prefs.silenceSeconds      { didSet { Prefs.silenceSeconds = silenceSeconds; changed() } }
    @Published var appearance = Prefs.appearance              { didSet { Prefs.appearance = appearance; changed() } }
    @Published var localeID = Prefs.localeID                  { didSet { Prefs.localeID = localeID; changed() } }
    @Published var copyToClipboard = Prefs.copyToClipboard    { didSet { Prefs.copyToClipboard = copyToClipboard; changed() } }
    @Published var autoPaste = Prefs.autoPaste                { didSet { Prefs.autoPaste = autoPaste; changed() } }
    @Published var restoreClipboard = Prefs.restoreClipboard  { didSet { Prefs.restoreClipboard = restoreClipboard; changed() } }
    @Published var showErrorAlerts = Prefs.showErrorAlerts    { didSet { Prefs.showErrorAlerts = showErrorAlerts; changed() } }
    @Published var showResultPopover = Prefs.showResultPopover { didSet { Prefs.showResultPopover = showResultPopover; changed() } }
    @Published var autoCheckUpdates = Prefs.autoCheckUpdates  { didSet { Prefs.autoCheckUpdates = autoCheckUpdates; Updater.setAutomaticChecks(autoCheckUpdates); changed() } }
    @Published var showInDock = Prefs.showInDock              { didSet { Prefs.showInDock = showInDock; changed() } }
    @Published var duckMedia = Prefs.duckMediaWhileRecording  { didSet { Prefs.duckMediaWhileRecording = duckMedia; changed() } }
    @Published var recordingSounds = Prefs.recordingSounds    { didSet { Prefs.recordingSounds = recordingSounds; changed() } }
    @Published var forceServer = Prefs.forceServerRecognition { didSet { Prefs.forceServerRecognition = forceServer; changed() } }
    @Published var polishEnabled = Prefs.polishEnabled        { didSet { Prefs.polishEnabled = polishEnabled; changed() } }
    @Published var backend = Prefs.backend                    { didSet { Prefs.backend = backend; changed() } }
    @Published var tier = Prefs.tier                          { didSet { Prefs.tier = tier; changed() } }
    @Published var meetingBackend = Prefs.meetingBackend      { didSet { Prefs.meetingBackend = meetingBackend; changed() } }
    @Published var meetingDetail = Prefs.meetingDetail        { didSet { Prefs.meetingDetail = meetingDetail; changed() } }
    @Published var meetingTier = Prefs.meetingTier            { didSet { Prefs.meetingTier = meetingTier; changed() } }
    @Published var style = Prefs.style                        { didSet { Prefs.style = style; changed() } }
    @Published var geminiModel = Prefs.geminiModel            { didSet { Prefs.geminiModel = geminiModel; changed() } }
    @Published var claudeModel = Prefs.model                  { didSet { Prefs.model = claudeModel; changed() } }
    @Published var speakerNote = Prefs.speakerNote            { didSet { Prefs.speakerNote = speakerNote } }
    @Published var glossary = Prefs.glossary                  { didSet { Prefs.glossary = glossary } }
    @Published var usageContexts = Prefs.usageContexts        { didSet { Prefs.usageContexts = usageContexts } }
    /// 처음 실행 안내 배너
    @Published var showOnboarding = !Prefs.onboarded

    func toggleContext(_ c: UsageContext) {
        if usageContexts.contains(c) { usageContexts.remove(c) } else { usageContexts.insert(c) }
    }

    @Published var launchAtLogin = LoginItem.isEnabled
    @Published var launchAtLoginError = ""
    @Published var accessibilityTrusted = Paster.isTrusted

    /// 진단 동작. AppDelegate 가 채운다.
    struct Actions {
        var testPaste: () -> Void = {}
        var testBackend: () -> Void = {}
        var listGeminiModels: () -> Void = {}
        var openLog: () -> Void = {}
        var showDiagnostics: () -> Void = {}
        var openDictationSettings: () -> Void = {}
        var openAccessibility: () -> Void = {}
        var reopenOnboarding: () -> Void = {}
        var checkForUpdates: () -> Void = {}
    }
    var actions = Actions()

    private func changed() { NotificationCenter.default.post(name: .breflyPrefsChanged, object: nil) }

    /// 회의 단축키가 바뀌었을 때. 화면을 다시 그리고 앱에 다시 등록시킨다.
    func bumpHotKeys() { objectWillChange.send(); changed() }

    func refresh() {
        accessibilityTrusted = Paster.isTrusted
        launchAtLogin = LoginItem.isEnabled
    }

    /// 설치 안내처럼 설정 창 밖에서 Prefs 를 바꿨을 때. 각 didSet 이 같은 값을 되쓰므로 해가 없다.
    /// ⚠️ hotKeyIndex 의 didSet 이 Prefs.customHotKey 를 지운다. 대입 전에 먼저 읽어 두지 않으면
    /// 직접 설정한 단축키(fn⌃ 등)가 사라진다 — 0.3.0 에서 마법사로 정한 단축키가 프리셋으로 되돌아갔다.
    func reloadFromPrefs() {
        let custom = Prefs.customHotKey
        hotKeyIndex = Prefs.hotKeyIndex
        customHotKey = custom
        autoPaste = Prefs.autoPaste
        usageContexts = Prefs.usageContexts
        backend = Prefs.backend
        showOnboarding = !Prefs.onboarded
        refresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        launchAtLoginError = LoginItem.set(on) ?? ""
        launchAtLogin = LoginItem.isEnabled
    }

    var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Brefly \(v) (\(b))"
    }
}

// MARK: - 창

final class SettingsWindowController {
    private var window: NSWindow?
    let model = SettingsModel()

    func show() {
        model.refresh()
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Brefly 설정"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.titlebarAppearsTransparent = false
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 620, height: 470))
            w.center()
            window = w
        }
        window?.appearance = Prefs.appearance.nsAppearance
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applyAppearance() { window?.appearance = Prefs.appearance.nsAppearance }

    var isVisible: Bool { window?.isVisible ?? false }
}

// MARK: - 뷰

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.line).frame(width: 1)
            ScrollView {
                Group {
                    switch model.tab {
                    case .general:   GeneralPane(model: model)
                    case .dictation: DictationPane(model: model)
                    case .meeting:   MeetingPane(model: model)
                    case .ai:        AIPane(model: model)
                    case .trouble:   TroublePane(model: model)
                    case .updates:   UpdatesPane(model: model)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.paperSoft)
        }
        .frame(width: 620, height: 470)
        .onAppear { model.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsModel.Tab.allCases) { tab in
                let selected = model.tab == tab
                Button(action: { model.tab = tab }) {
                    HStack(spacing: 9) {
                        Image(systemName: tab.symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                        Text(tab.title).font(.system(size: 13, weight: selected ? .semibold : .medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(selected ? .onPrimary : .ink)
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(selected ? Color.primaryFill : Color.clear)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text(model.appVersion).font(.system(size: 11)).foregroundColor(.text4).padding(.leading, 6)
        }
        .padding(12)
        .frame(width: 176)
        .background(Color.fill)
    }
}

// MARK: 일반 — 앱이 어떻게 떠 있을지

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("화면") {
                SettingsRow(title: "화면 모드", subtitle: "팝오버와 설정 창에 적용합니다.", last: true) {
                    Segmented(options: Prefs.Appearance.allCases.map { ($0, $0.title) }, selection: $model.appearance)
                }
            }

            SettingsSection("실행") {
                SettingsRow(title: "로그인 시 Brefly 자동 실행",
                            subtitle: nil,
                            warning: model.launchAtLoginError.isEmpty ? nil : model.launchAtLoginError) {
                    InkToggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                SettingsRow(title: "Dock 에 Brefly 표시",
                            subtitle: "Dock 아이콘을 누르면 메뉴바 아이콘처럼 창이 열립니다. 끄면 메뉴바에만 남습니다.") {
                    InkToggle(isOn: $model.showInDock)
                }
                SettingsRow(title: "실패 시 시스템 알림 표시", subtitle: nil, last: true) {
                    InkToggle(isOn: $model.showErrorAlerts)
                }
            }
        }
    }
}

// MARK: 받아쓰기 — 누르고 · 말하고 · 꽂히는 것

/// ⚠️ 받아쓰기 설정은 **여기 한곳**에 모은다. 전에는 단축키가 '단축키' 탭에, 정리가 '음성인식·AI'
///    탭에, 붙여넣기가 '일반' 탭에 흩어져 있어서 한 기능을 손보려면 탭 셋을 오갔다.
struct DictationPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // ⚠️ 프리셋과 '직접 정하기'는 **한 설정**이다(`hotKeyIndex` 와 `customHotKey` 가
            //    서로를 지운다). 전에는 '직접 설정' 카드와 '자주 쓰는 조합' 카드로 갈라 놓아서
            //    두 기능처럼 보였다. 다섯 중 하나를 고르는 한 칸으로 묶는다.
            SettingsSection("받아쓰기 시작 / 종료 단축키") {
                ForEach(Array(HotKeyPreset.all.enumerated()), id: \.offset) { i, p in
                    let on = model.customHotKey == nil && model.hotKeyIndex == i
                    Button(action: { model.hotKeyIndex = i; model.customHotKey = nil }) {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(on ? .ink : .text4)
                            KeyCapLarge(p.title)
                            Spacer()
                        }
                        .padding(.horizontal, 14).frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    HairLine().padding(.leading, 14)
                }
                // 마지막 칸이 다섯 번째 선택지다. 프리셋과 같은 줄 꼴로 둬야 "이것도 그중 하나"로 읽힌다.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: model.customHotKey != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(model.customHotKey != nil ? .ink : .text4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("직접 정하기")
                                .font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                            Text("칸을 클릭하고 원하는 조합을 누릅니다. ⌃⌥D 처럼 수정자+키, 또는 fn⌃ 처럼 수정자 키만 눌렀다 떼도 됩니다.")
                                .font(.system(size: 11)).foregroundColor(.text3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                        HotKeyRecorderField(model: model)
                    }
                    if model.hotKeyNeedsAccessibility {
                        Button(action: model.actions.openAccessibility) {
                            Text("수정자 키만 쓰는 단축키는 손쉬운 사용 권한이 필요합니다 — 허용하기")
                                .font(.system(size: 11)).foregroundColor(.coral)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 26)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }

            SettingsSection("정리") {
                SettingsRow(title: "AI 로 정리하기", subtitle: "끄면 받아쓰기 원문을 그대로 붙여 넣습니다.") {
                    InkToggle(isOn: $model.polishEnabled)
                }
                SettingsRow(title: "말을 멈추면 자동 요약",
                            subtitle: model.autoStop ? "\(Int(model.silenceSeconds))초간 말이 없으면 자동으로 요약합니다."
                                                     : "끄면 단축키를 다시 누를 때만 요약합니다. 말하다 생각해도 끊기지 않습니다.",
                            last: true) {
                    HStack(spacing: 8) {
                        if model.autoStop {
                            PopupLabel(title: "\(Int(model.silenceSeconds))초",
                                       options: Prefs.silenceOptions.map { "\(Int($0))초" },
                                       selected: Prefs.silenceOptions.firstIndex(of: model.silenceSeconds)) {
                                model.silenceSeconds = Prefs.silenceOptions[$0]
                            }
                        }
                        InkToggle(isOn: $model.autoStop)
                    }
                }
            }
            SettingsSection(nil) { PolishStyleRow(model: model) }

            SettingsSection("듣기") {
                SettingsRow(title: "인식 언어", subtitle: "회의록은 한국어로 받아 적습니다.") {
                    PopupLabel(title: Prefs.locales.first { $0.id == model.localeID }?.title ?? model.localeID,
                               options: Prefs.locales.map(\.title),
                               selected: Prefs.locales.firstIndex { $0.id == model.localeID }) {
                        model.localeID = Prefs.locales[$0].id
                    }
                }
                SettingsRow(title: "음성 인식을 애플 서버에서 처리",
                            subtitle: "기본 켬. 더 정확하지만 인터넷이 필요하고 한 번에 약 1분까지 인식합니다. 끄면 인터넷 없이 이 맥에서만 인식하지만 정확도가 떨어집니다.") {
                    InkToggle(isOn: $model.forceServer)
                }
                SettingsRow(title: "녹음 중 다른 소리 줄이기",
                            subtitle: "재생 중인 음악·영상 소리를 녹음이 끝날 때까지 낮춥니다. 에어팟은 맥이 알아서 줄입니다.") {
                    InkToggle(isOn: $model.duckMedia)
                }
                SettingsRow(title: "녹음 시작·종료 알림음",
                            subtitle: "시작할 때와 끝낼 때 짧은 소리로 알려 줍니다.", last: true) {
                    InkToggle(isOn: $model.recordingSounds)
                }
            }

            SettingsSection("결과") {
                SettingsRow(title: "커서 위치에 자동 붙여넣기",
                            subtitle: model.accessibilityTrusted ? "손쉬운 사용(접근성) 권한이 있습니다." : nil,
                            warning: model.accessibilityTrusted ? nil : "손쉬운 사용(접근성) 권한이 필요합니다 — 허용하기",
                            warningAction: model.actions.openAccessibility) {
                    InkToggle(isOn: $model.autoPaste)
                }
                if model.autoPaste {
                    SettingsRow(title: "붙여넣기 후 클립보드 복원", subtitle: "자동 붙여넣기는 클립보드를 잠깐 빌려 씁니다. 켜면 붙여넣은 뒤 전에 복사해 둔 내용을 되돌려 놓고, 끄면 요약문을 클립보드에 남깁니다.") {
                        InkToggle(isOn: $model.restoreClipboard)
                    }
                }
                SettingsRow(title: "클립보드에 자동 복사", subtitle: nil) {
                    InkToggle(isOn: $model.copyToClipboard)
                }
                SettingsRow(title: "정리가 끝나면 결과 창 띄우기",
                            subtitle: "끄면 메뉴바 아이콘을 눌러야 결과를 봅니다. 복사·붙여넣기는 그대로 됩니다. 녹음 중·정리 중 화면은 항상 뜹니다.",
                            last: true) {
                    InkToggle(isOn: $model.showResultPopover)
                }
            }

            // 용어 교정은 받아쓰기와 회의록 **둘 다**에 걸린다(`Glossary.apply`). 설명에 적어 둔다.
            UsageContextSection(model: model)

            Text("단축키는 어느 앱에서나 동작합니다. 다른 앱이 같은 조합을 쓰면 등록에 실패할 수 있습니다. ⌘ 단독 조합(⌘C 등)은 겹치기 쉬우니 ⌃⌥ 를 권합니다.")
                .font(.system(size: 11)).foregroundColor(.text3)
        }
    }
}

// MARK: 회의록

struct MeetingPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("단축키") {
                // 대면과 화상은 권한도 동작도 달라서 따로 고른다. 하나로 묶으면 누를 때마다
                // 무엇이 시작될지 생각해야 한다. 안 쓸 거면 비워 두면 된다.
                SettingsRow(title: "대면 회의 녹음 시작 / 종료",
                            subtitle: "이 맥의 마이크로 그 자리의 말을 담습니다.") {
                    SlotHotKeyField(slot: .inPerson, model: model)
                }
                SettingsRow(title: "화상 회의 녹음 시작 / 종료",
                            subtitle: "내 목소리와 스피커로 나오는 소리를 함께 담습니다. 화면 기록 권한이 필요합니다.") {
                    SlotHotKeyField(slot: .videoCall, model: model)
                }
                // ⚠️ 짧게 둔다. "끄는 걸 잊으면 알려 준다"는 실제로 잊었을 때 그 자리에서
                //    알림창이 뜨므로 여기 미리 적을 필요가 없다.
                SettingsRow(title: "하이라이트",
                            subtitle: "녹음 중 누르면 그 자리부터 표시가 시작되고, 다시 누르면 끝납니다. 표시한 말은 회의록에 꼭 들어갑니다.",
                            last: true) {
                    SlotHotKeyField(slot: .highlight, model: model)
                }
            }

            SettingsSection("정리") {
                SettingsRow(title: "회의록 요약 정도", subtitle: model.meetingDetail.hint, last: true) {
                    HStack(spacing: 10) {
                        DotSlider(index: Binding(
                            get: { model.meetingDetail.rawValue - 1 },
                            set: { model.meetingDetail = Prefs.MeetingDetail(rawValue: $0 + 1) ?? .normal }
                        ), count: Prefs.MeetingDetail.allCases.count)
                        // 점만 두면 어느 쪽이 자세한 쪽인지 알 수 없다. 고른 단계 이름을 옆에 붙인다.
                        Text(model.meetingDetail.title)
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.ink)
                            .frame(width: 58, alignment: .leading)
                    }
                }
            }

            Text("어떤 AI 가 회의록을 쓸지는 'AI 연결' 에서 고릅니다. 녹음은 이 컴퓨터 안에서 글자로 바꾸고, 정리할 때만 그 글을 AI 에 보냅니다.")
                .font(.system(size: 11)).foregroundColor(.text3)
        }
    }
}


struct APIKeyRow: View {
    let slot: KeychainStore.Slot
    @State private var editing = false
    @State private var draft = ""
    @State private var saved: String = ""
    @State private var showHelp = false

    private var issueURL: String {
        switch slot {
        case .gemini:    return "https://aistudio.google.com/apikey"
        case .anthropic: return "https://console.anthropic.com/settings/keys"
        case .openai:    return "https://platform.openai.com/api-keys"
        }
    }

    private var slotTitle: String {
        switch slot {
        case .gemini:    return "Gemini"
        case .anthropic: return "Claude"
        case .openai:    return "ChatGPT"
        }
    }

    /// 비개발자용 발급 안내. ? 버튼을 누르면 말풍선으로 뜬다.
    private var helpSteps: [String] {
        if slot == .openai {
            // ⚠️ 마지막 줄을 꼭 넣는다. 구독료를 내고 있으면 API 도 포함이라고 생각하기 쉽다.
            return ["아래 '발급 페이지 열기'를 누르면 OpenAI 플랫폼이 열립니다. 로그인하세요.",
                    "'Create new secret key' 를 눌러 키를 만듭니다. sk-… 로 시작합니다.",
                    "키는 그때 한 번만 보여 주니 바로 복사하세요.",
                    "ChatGPT 구독과 요금이 따로 나갑니다. 결제 수단을 등록해야 쓸 수 있고, 쓴 만큼 청구됩니다."]
        }
        return slot == .gemini
        ? ["아래 '발급 페이지 열기'를 누르면 Google AI Studio 가 열립니다. 구글 계정으로 로그인하세요.",
           "파란 'API 키 만들기(Create API key)' 버튼을 누릅니다. 프로젝트를 고르라고 하면 아무거나 골라도 됩니다.",
           "AIza… 로 시작하는 긴 문자열이 나옵니다. 복사 버튼을 누르세요.",
           "여기 '입력' 버튼을 누르고 붙여넣은 뒤 저장하면 끝. 무료이고 카드 등록도 필요 없습니다."]
        : ["아래 '발급 페이지 열기'를 누르면 Anthropic 콘솔이 열립니다. 로그인하세요.",
           "'Create Key' 를 눌러 이름을 정하고 키를 만듭니다. sk-ant-… 로 시작합니다.",
           "키는 그때 한 번만 보여 주니 바로 복사하세요.",
           "Billing 에서 크레딧을 조금 충전해야 동작합니다. 한 번 요약에 5원 안팎입니다."]
    }

    /// 키를 안 넣었을 때 보여 줄 안내. 회사마다 발급처와 비용이 다르다.
    private var dotColor: Color {
        if saved.isEmpty { return .coral }
        switch probe {
        case .ok:                     return .green
        case .noCredit, .badKey:      return .coral
        case .unknown, .rateLimited, .failed: return .text4
        }
    }

    /// 키가 없으면 발급 안내, 있으면 **실제로 쓸 수 있는지**를 보여 준다.
    /// 키를 넣어 둬도 크레딧이 0원이면 아무것도 안 되는데, 그걸 모르면 앱을 탓하게 된다.
    private var statusText: String {
        guard !saved.isEmpty else { return emptyHint }
        switch probe {
        case .unknown: return "키 있음 · '확인' 을 누르면 실제로 쓸 수 있는지 알아봅니다"
        case .ok:      return "쓸 수 있습니다 · " + KeychainStore.storageDescription
        default:       return probe.label
        }
    }

    private func runProbe() {
        guard !saved.isEmpty else { probe = .unknown; return }
        probing = true
        KeyProbe.check(slot) { status in probe = status; probing = false }
    }

    private var emptyHint: String {
        switch slot {
        case .gemini:    return "aistudio.google.com/apikey 에서 무료 발급\n카드 등록 불필요"
        case .anthropic: return "console.anthropic.com 에서 발급\n크레딧 충전 필요"
        // ⚠️ 구독과 별개라는 것을 여기서도 말한다. 제일 자주 오해하는 부분이다.
        case .openai:    return "platform.openai.com/api-keys 에서 발급\nChatGPT 구독과 요금이 따로 나갑니다"
        }
    }

    private var placeholder: String {
        switch slot {
        case .gemini:    return "AIza..."
        case .anthropic: return "sk-ant-..."
        case .openai:    return "sk-..."
        }
    }

    /// 마지막으로 확인한 결과. 창을 열 때마다 또 부르지 않는다 — 확인은 실제 요청이다.
    @State private var probe = KeyProbe.Status.unknown
    @State private var probing = false

    private var masked: String {
        guard !saved.isEmpty else { return "키 없음" }
        let head = saved.prefix(7), tail = saved.suffix(4)
        return "\(head)••••••••••••\(tail)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 키 칸이 여러 개 뜨므로 이름표가 없으면 어느 게 어느 것인지 알 수 없다.
            Text(slotTitle).font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
            HStack(spacing: 10) {
                if editing {
                    SecureField(placeholder, text: $draft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    SmallButton("저장", filled: true) {
                        KeychainStore.write(draft.trimmingCharacters(in: .whitespacesAndNewlines), to: slot)
                        saved = KeychainStore.read(slot) ?? ""
                        editing = false
                        // 넣자마자 확인해 준다. "저장했는데 왜 안 되지" 를 없애는 게 핵심이다.
                        runProbe()
                    }
                    SmallButton("취소") { editing = false }
                } else {
                    Text(masked)
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(saved.isEmpty ? .text4 : .text2)
                        .padding(.horizontal, 12).frame(height: 30).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.fill).cornerRadius(7)
                    SmallButton(saved.isEmpty ? "입력" : "변경", filled: true) { draft = ""; editing = true }
                }
                Button(action: { showHelp.toggle() }) {
                    Image(systemName: "questionmark.circle").font(.system(size: 15)).foregroundColor(.text3)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("키 받는 방법")
                .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(slot == .gemini ? "Gemini API 키 받는 법 (무료)" : "\(slotTitle) API 키 받는 법")
                            .font(.system(size: 13, weight: .bold))
                        ForEach(Array(helpSteps.enumerated()), id: \.offset) { i, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(i + 1)").font(.system(size: 11, weight: .bold))
                                    .frame(width: 18, height: 18).background(Color.primary.opacity(0.08)).cornerRadius(9)
                                Text(step).font(.system(size: 12)).lineSpacing(2)
                            }
                        }
                        HStack {
                            Spacer()
                            Button("발급 페이지 열기") {
                                if let u = URL(string: issueURL) { NSWorkspace.shared.open(u) }
                            }
                        }
                    }
                    .padding(16).frame(width: 340)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 6, height: 6)
                Text(statusText)
                    .font(.system(size: 11)).foregroundColor(.text3)
                    .fixedSize(horizontal: false, vertical: true)
                // 칸마다 안내 글 길이가 달라서 링크가 들쭉날쭉했다. 오른쪽 끝에 고정한다.
                Spacer(minLength: 8)
                // ⚠️ 링크 두 개를 나란히 두면 글자만 붙어 있어 하나로 읽힌다. 사이에 선을 긋는다.
                if !saved.isEmpty {
                    Button(probing ? "확인 중…" : "확인") { runProbe() }
                        .buttonStyle(.link).font(.system(size: 11)).fixedSize()
                        .disabled(probing)
                    Rectangle().fill(Color.lineStrong).frame(width: 1, height: 11)
                }
                // 크레딧이 없을 때는 발급이 아니라 **충전**으로 보내야 한다. 키는 이미 있다.
                if probe == .noCredit, let billing = KeyProbe.billingURL(slot) {
                    Button("크레딧 충전") { if let u = URL(string: billing) { NSWorkspace.shared.open(u) } }
                        .buttonStyle(.link).font(.system(size: 11)).fixedSize()
                } else {
                    Button("발급 페이지 열기") {
                        if let u = URL(string: issueURL) { NSWorkspace.shared.open(u) }
                    }.buttonStyle(.link).font(.system(size: 11)).fixedSize()
                }
            }
        }
        .padding(14)
        // 창을 열 때는 **기억해 둔 결과만** 보여 준다. 열 때마다 부르면 실제 요청이 나간다.
        .onAppear { saved = KeychainStore.read(slot) ?? ""; probe = KeyProbe.remembered(slot) }
        .onChange(of: slot) { s in
            saved = KeychainStore.read(s) ?? ""; editing = false; probe = KeyProbe.remembered(s)
        }
    }
}


// MARK: AI 연결 — 어떤 AI 로, 무슨 키로

/// 받아쓰기와 회의록이 **같이 쓰는** 것만 모은다. 모델을 매일 바꾸는 사람은 없어서
/// 각 기능 탭에 두면 그 탭이 개발자 도구처럼 보인다.
struct AIPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 받아쓰기와 회의록을 따로 고른다. 받아쓰기는 커서에 바로 들어가야 해서 속도가
            // 먼저고, 회의록은 이미 받아쓰기에 2~5분을 썼으니 잘 뽑는 게 먼저다.
            // ⚠️ 둘을 나란히 둬야 "따로 고를 수 있다"가 설명 없이 보인다.
            SettingsSection("무엇으로 정리할지") {
                SettingsRow(title: "받아쓰기 정리", subtitle: backendHint) {
                    choicePicker(Prefs.Choice(backend: model.backend, tier: model.tier)) {
                        model.backend = $0.backend; model.tier = $0.tier
                    }
                }
                SettingsRow(title: "회의록 요약", subtitle: meetingHint, last: true) {
                    choicePicker(Prefs.Choice(backend: model.meetingBackend, tier: model.meetingTier)) {
                        model.meetingBackend = $0.backend; model.meetingTier = $0.tier
                    }
                }
            }

            if model.backend != .apple {
                SettingsSection("API 키") {
                    // 받아쓰기와 회의록이 서로 다른 회사를 쓸 수 있으니 필요한 키를 전부 보여 준다.
                    // '자동으로 선택'은 키가 있는 것 중에 고르므로 셋 다 보여 준다 — 넣어 둘수록 잘 고른다.
                    ForEach(neededKeySlots, id: \.self) { APIKeyRow(slot: $0) }
                }
            }

            SettingsSection("세부 설정") {
                SettingsRow(title: "세부 모델", subtitle: modelHint,
                            last: model.backend == .apple) {
                    if model.backend == .apple {
                        Text("이 맥의 Apple Intelligence 모델을 씁니다.").font(.system(size: 12)).foregroundColor(.text3)
                    } else if model.backend == .gemini || model.backend == .auto {
                        PopupLabel(title: model.geminiModel, options: Prefs.geminiModels,
                                   selected: Prefs.geminiModels.firstIndex(of: model.geminiModel)) {
                            model.geminiModel = Prefs.geminiModels[$0]
                        }
                    } else {
                        PopupLabel(title: model.claudeModel, options: Prefs.models,
                                   selected: Prefs.models.firstIndex(of: model.claudeModel)) {
                            model.claudeModel = Prefs.models[$0]
                        }
                    }
                }
                if model.backend != .apple {
                    ActionRow("쓸 수 있는 모델 다시 불러오기",
                              "지금 키로 쓸 수 있는 Gemini 모델을 조회합니다.",
                              action: model.actions.listGeminiModels, last: true)
                }
            }
        }
    }

    /// 빠른 것과 좋은 것을 한 목록에 늘어놓는다. 모델 이름은 비개발자에게 뜻이 없어서
    /// "Gemini — 빠름" 처럼 회사와 등급만 보여 준다.
    private func choicePicker(_ current: Prefs.Choice,
                              onPick: @escaping (Prefs.Choice) -> Void) -> some View {
        PopupLabel(title: current.title,
                   options: Prefs.choices.map(\.title),
                   selected: Prefs.choices.firstIndex(of: current) ?? 0) {
            onPick(Prefs.choices[$0])
        }
    }

    private var meetingHint: String {
        switch model.meetingBackend {
        case .auto:   return "무료인 Gemini 부터 씁니다. 안 되면 ChatGPT, Claude 순입니다. 이 맥의 Apple AI 는 긴 회의에 쓰지 않습니다."
        case .apple:  return "긴 회의는 이 맥의 모델이 내용을 뒤집을 수 있습니다. 클라우드 모델을 권합니다."
        default:      return "받아쓰기와 따로 고릅니다. 회의록은 시간이 조금 더 걸려도 잘 정리하는 쪽이 낫습니다."
        }
    }

    /// 지금 설정으로 필요한 키 칸들. 둘 중 하나라도 '자동으로 선택'이면 셋 다 보여 준다.
    private var neededKeySlots: [KeychainStore.Slot] {
        let all: [KeychainStore.Slot] = [.gemini, .anthropic, .openai]
        if model.backend == .auto || model.meetingBackend == .auto { return all }
        let used = Set([model.backend.keySlot, model.meetingBackend.keySlot].compactMap { $0 })
        return all.filter { used.contains($0) }
    }

    private var backendHint: String {
        switch model.backend {
        case .auto:   return AppleClient.availability().ok
                             ? "추천. 이 맥의 Apple AI 와 Gemini 를 함께 써서 빠르고 나은 답을 고릅니다."
                             : "이 맥의 Apple AI 를 쓸 수 없어 Gemini 만 사용합니다."
        case .gemini: return "구글 AI 입니다. 무료 키로 쓸 수 있고 1~5초 걸리며, 혼잡할 땐 실패하기도 합니다."
        case .apple:  return AppleClient.availability().note
        case .api:    return "Anthropic 의 Claude 입니다. 유료 크레딧이 필요하고 1초 안팎 걸립니다."
        case .openai: return "OpenAI 의 ChatGPT 입니다. 유료 크레딧이 필요합니다. ChatGPT 구독과는 요금이 따로 나갑니다."
        }
    }

    private var modelHint: String {
        switch model.backend {
        case .gemini, .auto: return "Gemini 안에서 먼저 쓸 모델입니다. 늦으면 다른 모델도 같이 씁니다."
        case .apple:  return "인터넷을 쓰지 않습니다."
        default:      return "정리는 가벼운 일이라 Haiku 로 충분합니다."
        }
    }
}

// MARK: 문제 해결 — 안 될 때만 여는 곳

/// 평소엔 안 쓰는 것만 모은다. 진단을 맨 위에 둬서 "무엇이 빠졌는지" 부터 보게 하고,
/// 그 아래에 빠진 것을 채우는 버튼을 둔다.
struct TroublePane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("지금 상태") {
                ActionRow("현재 상태 진단", "권한 4종, 인식 언어, 키 유무를 한 화면에 보여 줍니다.",
                          action: model.actions.showDiagnostics, last: true)
            }

            SettingsSection("권한") {
                ActionRow("손쉬운 사용 권한 열기",
                          "받아쓴 글을 커서 위치에 자동으로 넣으려면 필요합니다.",
                          action: model.actions.openAccessibility)
                ActionRow("받아쓰기 설정 열기",
                          "시스템 설정 > 키보드 > 받아쓰기가 꺼져 있으면 말을 글자로 바꾸지 못합니다.",
                          action: model.actions.openDictationSettings, last: true)
            }

            SettingsSection("시험해 보기") {
                ActionRow("붙여넣기 테스트", "3초 뒤 커서 위치에 텍스트를 넣습니다. 자동 붙여넣기가 켜져 있어야 합니다.",
                          action: model.actions.testPaste)
                ActionRow("AI 모델 연결 테스트", "짧은 문장을 실제로 정리해 봅니다.",
                          action: model.actions.testBackend, last: true)
            }

            SettingsSection("그 밖에") {
                ActionRow("처음 설정 안내 다시 보기", "권한·AI 모델·단축키를 처음처럼 한 단계씩 다시 설정합니다.",
                          action: model.actions.reopenOnboarding)
                ActionRow("로그 열기", Log.url.path, action: model.actions.openLog, last: true)
            }
        }
    }
}

// MARK: 업데이트 — 버전 · 바뀐 점 · 후원

/// ⚠️ 버전을 **맨 위에 크게** 둔다. 전에는 "업데이트 확인" 줄의 부제 안에
///    "지금 버전은 0.8.3 입니다" 로 묻혀 있어서, 설정에서 버전을 찾기가 어려웠다.
///    이 자리가 '정보' 탭이 할 일을 대신한다 — 그것 때문에 탭을 하나 더 만들지 않는다.
struct UpdatesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(nil) {
                HStack(spacing: 12) {
                    LogoMark(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        // `appVersion` 에 이미 "Brefly" 가 들어 있다. 앞에 또 붙이면 두 번 나온다.
                        Text(model.appVersion)
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.ink)
                        Text("새 버전이 있으면 바뀐 점과 설치 버튼을 보여 줍니다.")
                            .font(.system(size: 11)).foregroundColor(.text3)
                    }
                    Spacer()
                    SmallButton("업데이트 확인", action: model.actions.checkForUpdates)
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
            }

            SettingsSection("자동 확인") {
                SettingsRow(title: "실행할 때 자동으로 확인",
                            subtitle: "하루에 한 번 확인하고, 새 버전이 있을 때만 알려 줍니다. \"나중에\"를 누른 버전은 다시 묻지 않습니다.",
                            last: true) {
                    InkToggle(isOn: $model.autoCheckUpdates)
                }
            }

            SettingsSection("바뀐 점") {
                ActionRow("지금까지 바뀐 점 보기", "나온 버전과 바뀐 점을 GitHub 릴리스 페이지에서 봅니다.",
                          buttonTitle: "보기", action: {
                    if let url = URL(string: "https://github.com/yunuchoiii/brefly/releases") { NSWorkspace.shared.open(url) }
                })
                SettingsRow(title: "손으로 설치해야 한다면",
                            subtitle: "다운로드한 DMG 를 열어 Brefly 를 Applications 폴더에 끌어 넣으면 덮어써지고, 설정과 권한은 그대로 유지됩니다.",
                            last: true) { EmptyView() }
            }

            SettingsSection("후원") {
                ActionRow("커피 한 잔으로 응원하기", "Brefly 는 무료입니다. 도움이 됐다면 GitHub Sponsors 로 응원해 주세요.",
                          buttonTitle: "열기", action: {
                    if let url = URL(string: "https://github.com/sponsors/yunuchoiii") { NSWorkspace.shared.open(url) }
                }, last: true)
            }
        }
    }
}


// MARK: - 조각

/// 눈금이 박힌 슬라이더. 단계가 몇 개뿐이고 각 칸에 이름이 있을 때 쓴다 —
/// 드롭다운과 달리 **어느 쪽이 더 센 쪽인지**가 한눈에 보인다.
///
/// 눈금을 눌러도 되고 끌어도 된다. 끝에서 더 끌어도 범위를 벗어나지 않는다.
struct DotSlider: View {
    @Binding var index: Int
    let count: Int
    var width: CGFloat = 108

    private let knob: CGFloat = 14
    private let tick: CGFloat = 6
    private var step: CGFloat { (width - knob) / CGFloat(max(count - 1, 1)) }
    private func center(_ i: Int) -> CGFloat { knob / 2 + step * CGFloat(i) }

    var body: some View {
        ZStack(alignment: .leading) {
            // ⚠️ 선은 **첫 점에서 끝 점까지**만 깐다. `width` 전체에 깔면 손잡이 반지름만큼
            //    (7pt) 양쪽에 점 없는 선이 삐져나온다 — 눈금이 다섯인데 선은 그보다 길어서
            //    "왜 끝에 선만 있지?" 로 보인다(2026-10-02).
            Capsule().fill(Color.lineStrong)
                .frame(width: center(count - 1) - center(0), height: 2)
                .offset(x: center(0))
            Capsule().fill(Color.coral)
                .frame(width: center(index) - center(0), height: 2)
                .offset(x: center(0))
            // ⚠️ 손잡이를 **점보다 먼저** 그리고 속을 비운다. 꽉 찬 손잡이를 점 위에 얹으면
            //    고른 자리의 점이 가려져 양 끝에서 점이 네 개로 보인다. 고리로 두면 다섯 개가
            //    늘 보이고, 고른 자리는 "점에 테두리가 둘린 것"으로 읽힌다.
            Circle()
                .fill(Color.paper)
                .overlay(Circle().stroke(Color.coral, lineWidth: 2))
                .frame(width: knob, height: knob)
                .offset(x: center(index) - knob / 2)
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i <= index ? Color.coral : Color.lineStrong)
                    .frame(width: tick, height: tick)
                    .offset(x: center(i) - tick / 2)
            }
        }
        .frame(width: width, height: knob)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: index)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let raw = ((value.location.x - knob / 2) / step).rounded()
            let next = min(max(Int(raw), 0), count - 1)
            if next != index { index = next }
        })
        .accessibilityElement()
        .accessibilityValue("\(index + 1) / \(count)")
    }
}

struct SettingsSection<Content: View>: View {
    let title: String?
    let content: Content
    init(_ title: String?, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.text3)
            }
            VStack(spacing: 0) { content }
                .background(Color.paper)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.lineStrong, lineWidth: 1))
                .cornerRadius(10)
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String?
    var warning: String? = nil
    var warningAction: (() -> Void)? = nil
    var last: Bool = false
    let accessory: Accessory

    init(title: String, subtitle: String?, warning: String? = nil, warningAction: (() -> Void)? = nil,
         last: Bool = false, @ViewBuilder accessory: () -> Accessory) {
        self.title = title; self.subtitle = subtitle; self.warning = warning
        self.warningAction = warningAction; self.last = last; self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11)).foregroundColor(.text3)
                    }
                    if let warning {
                        Button(action: { warningAction?() }) {
                            Text(warning).font(.system(size: 11)).foregroundColor(.coralDeep)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            if !last { HairLine().padding(.leading, 14) }
        }
    }
}

/// 정리 스타일 고르기. 드롭다운이면 다섯 가지가 접혀 있어 '핵심 요약'이 있는 줄도 모르고 지나친다.
/// 펼쳐 두면 어떤 선택지가 있는지 한눈에 보인다.
struct PolishStyleRow: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("정리 스타일").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                    Text("요약 결과의 말투와 형식을 정합니다.")
                        .font(.system(size: 11)).foregroundColor(.text3)
                }
                VStack(spacing: 6) {
                    ForEach(PolishStyle.allCases, id: \.self) { style in
                        let on = model.style == style
                        Button(action: { model.style = style }) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 13)).foregroundColor(on ? .coral : .radioOff)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.title)
                                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                                        .foregroundColor(.ink)
                                    // 제목만 있으면 "격식체"가 무엇인지 알 수 없다.
                                    Text(style.detail)
                                        .font(.system(size: 11)).foregroundColor(.text3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(on ? Color.fill : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(on ? Color.coral.opacity(0.5) : Color.radioOff.opacity(0.45), lineWidth: 1))
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            HairLine().padding(.leading, 14)
        }
    }
}

struct ActionRow: View {
    let title: String
    let subtitle: String
    let action: () -> Void
    /// 버튼에 쓸 말. 대부분은 "실행"이 맞지만, 확인·보기처럼 행동이 분명한 곳은 그 말을 쓴다.
    var buttonTitle = "실행"
    var last = false
    init(_ title: String, _ subtitle: String, buttonTitle: String = "실행",
         action: @escaping () -> Void, last: Bool = false) {
        self.title = title; self.subtitle = subtitle
        self.buttonTitle = buttonTitle; self.action = action; self.last = last
    }
    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, last: last) {
            SmallButton(buttonTitle, action: action)
        }
    }
}

struct InkToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() } }) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Color.primaryFill : Color.lineStrong).frame(width: 38, height: 22)
                Circle().fill(isOn ? Color.onPrimary : Color.white).frame(width: 18, height: 18).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 드롭다운. SwiftUI Menu 는 macOS 에서 라벨 꾸밈을 무시해 NSMenu 를 직접 띄운다.
struct PopupLabel: View {
    let title: String
    let options: [String]
    let selected: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        Button(action: popUp) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundColor(.ink).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(.text3)
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color.fill)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.lineStrong, lineWidth: 1))
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func popUp() {
        let menu = NSMenu()
        for (i, label) in options.enumerated() {
            let item = NSMenuItem(title: label, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.tag = i
            item.state = (i == selected) ? .on : .off
            item.target = MenuTarget.shared
            item.representedObject = MenuChoice(onSelect)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private final class MenuChoice { let run: (Int) -> Void; init(_ run: @escaping (Int) -> Void) { self.run = run } }
private final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func pick(_ sender: NSMenuItem) { (sender.representedObject as? MenuChoice)?.run(sender.tag) }
}

struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                let on = opt.0 == selection
                Button(action: { selection = opt.0 }) {
                    Text(opt.1).font(.system(size: 12, weight: .semibold))
                        .foregroundColor(on ? .onPrimary : .text2)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 10).frame(height: 24)
                        .background(on ? Color.primaryFill : Color.clear)
                        .cornerRadius(6)
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.fill).cornerRadius(8)
        .fixedSize()
    }
}

struct KeyCapLarge: View {
    let label: String
    init(_ label: String) { self.label = label }
    var body: some View {
        Text(label).font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color.fill)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.lineStrong, lineWidth: 1))
            .cornerRadius(7)
    }
}

struct SmallButton: View {
    let title: String
    var filled = false
    let action: () -> Void
    init(_ title: String, filled: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.filled = filled; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundColor(filled ? .onPrimary : .ink)
                .padding(.horizontal, 12).frame(height: 28)
                .background(filled ? Color.primaryFill : Color.paper)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(filled ? Color.clear : Color.lineStrong, lineWidth: 1))
                .cornerRadius(7)
        }.buttonStyle(.plain)
    }
}


// MARK: - 단축키 녹음기

/// 클릭하면 녹음 상태가 되고, 앱에 들어오는 다음 keyDown 을 단축키로 저장한다. Esc 로 취소.
/// 첫 응답자 방식은 SwiftUI 호스팅 창에서 키를 못 받아서, 로컬 이벤트 모니터로 가로챈다.
/// 받아쓰기 말고 나머지 단축키(대면·화상·하이라이트)를 고르는 칸.
/// ⚠️ 받아쓰기용 `HotKeyRecorderField` 와 따로 둔다 — 그쪽은 프리셋과 "직접 설정" 표시가
///    얽혀 있고, 이쪽은 **비워 둘 수 있어야** 한다(안 쓰는 단축키를 잡아 두면 다른 앱과 부딪힌다).
struct SlotHotKeyField: View {
    let slot: HotKey.Slot
    @ObservedObject var model: SettingsModel
    @State private var recording = false
    @State private var held = ""
    @State private var monitors: [Any] = []
    @State private var maxHeld: UInt32 = 0

    private var combo: HotKeyCombo? { Prefs.extraHotKey(slot) }

    private var label: String {
        if recording { return held.isEmpty ? "키 조합을 누르세요…" : held + "…" }
        return combo?.title ?? "없음"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { if !recording { start() } }) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(recording ? .coralDeep : (combo == nil ? .text4 : .ink))
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(recording ? Color.coral.opacity(0.08) : Color.fill)
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(recording ? Color.coral : Color.lineStrong, lineWidth: 1))
                    .cornerRadius(7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recording ? "Esc 로 취소 · 수정자 키만 눌렀다 떼도 저장됩니다." : "클릭해서 바꾸기")
            if combo != nil, !recording {
                Button("지우기") { Prefs.setExtraHotKey(nil, for: slot); model.bumpHotKeys() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .fixedSize()
        .onDisappear { stop() }
    }

    private func save(_ c: HotKeyCombo) {
        // ⚠️ 겹치면 저장하지 않는다. 덮어쓰면 다른 단축키가 말없이 죽고,
        //    그대로 두면 둘 중 하나가 영영 안 눌린다.
        if let owner = Prefs.hotKeyOwner(c, excluding: slot) {
            stop()
            let alert = NSAlert()
            alert.messageText = "\(c.title) 는 이미 쓰고 있습니다"
            alert.informativeText = "'\(owner)' 에 정해 둔 조합입니다. 같은 조합을 둘에 두면 "
                + "하나는 눌리지 않습니다. 다른 조합을 골라 주세요."
            alert.addButton(withTitle: "알겠습니다")
            alert.runModal()
            return
        }
        Prefs.setExtraHotKey(c, for: slot)
        model.bumpHotKeys()
        stop()
    }

    private func start() {
        recording = true; held = ""; maxHeld = 0
        NotificationCenter.default.post(name: .breflyHotKeyCaptureBegan, object: nil)
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let mods = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }
            save(HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
            return nil
        }
        let flagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let now = HotKeyCombo.modifierBits(from: event.modifierFlags)
            held = HotKeyCombo(keyCode: 0, modifiers: now).modifierSymbols
            if now & maxHeld == maxHeld, now != maxHeld {
                maxHeld = now
            } else if now == 0, maxHeld != 0 {
                save(HotKeyCombo(keyCode: HotKeyCombo.modifierOnlyKeyCode, modifiers: maxHeld))
                return nil
            } else if now == 0 {
                maxHeld = 0
            }
            return nil
        }
        monitors = [keyMonitor, flagMonitor].compactMap { $0 }
    }

    private func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        recording = false
        NotificationCenter.default.post(name: .breflyHotKeyCaptureEnded, object: nil)
    }
}

struct HotKeyRecorderField: View {
    @ObservedObject var model: SettingsModel
    @State private var recording = false
    @State private var heldModifiers = ""
    @State private var monitors: [Any] = []
    @State private var maxHeld: UInt32 = 0

    private var label: String {
        if recording { return heldModifiers.isEmpty ? "키 조합을 누르세요…" : heldModifiers + "…" }
        return model.currentHotKeyTitle
    }

    var body: some View {
        Button(action: { if !recording { start() } }) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(recording ? .coralDeep : .ink)
                if !recording, model.customHotKey != nil {
                    Text("직접 설정").font(.system(size: 10)).foregroundColor(.text3)
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(recording ? Color.coral.opacity(0.08) : Color.fill)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(recording ? Color.coral : Color.lineStrong, lineWidth: 1))
            .cornerRadius(7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(recording ? "Esc 로 취소 · 수정자 키만 눌렀다 떼도 저장됩니다." : "클릭해서 바꾸기")
        .onDisappear { stop() }
    }

    /// 받아쓰기 단축키도 회의 단축키와 겹칠 수 있다. 같은 확인을 거친다.
    private func saveDictation(_ c: HotKeyCombo) {
        if let owner = Prefs.hotKeyOwner(c, excluding: .dictation) {
            stop()
            let alert = NSAlert()
            alert.messageText = "\(c.title) 는 이미 쓰고 있습니다"
            alert.informativeText = "'\(owner)' 에 정해 둔 조합입니다. 같은 조합을 둘에 두면 "
                + "하나는 눌리지 않습니다. 다른 조합을 골라 주세요."
            alert.addButton(withTitle: "알겠습니다")
            alert.runModal()
            return
        }
        model.customHotKey = c
        stop()
    }

    private func start() {
        recording = true
        heldModifiers = ""
        maxHeld = 0
        NotificationCenter.default.post(name: .breflyHotKeyCaptureBegan, object: nil)

        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            let mods = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else {
                NSSound.beep()
                return nil
            }
            saveDictation(HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
            return nil
        }
        let flagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let now = HotKeyCombo.modifierBits(from: event.modifierFlags)
            heldModifiers = HotKeyCombo(keyCode: 0, modifiers: now).modifierSymbols
            if now & maxHeld == maxHeld, now != maxHeld {
                maxHeld = now              // 더 누르는 중
            } else if now == 0, maxHeld != 0 {
                // 전부 뗐고 그 사이 다른 키가 없었다 → 수정자 전용 단축키
                saveDictation(HotKeyCombo(keyCode: HotKeyCombo.modifierOnlyKeyCode, modifiers: maxHeld))
                return nil
            } else if now == 0 {
                maxHeld = 0
            }
            return nil
        }
        monitors = [keyMonitor, flagMonitor].compactMap { $0 }
    }

    private func stop() {
        guard recording else { return }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        recording = false
        heldModifiers = ""
        NotificationCenter.default.post(name: .breflyHotKeyCaptureEnded, object: nil)
    }
}


// MARK: - 사용 분야·상황

/// 체크한 분야의 설명과 용어가 정리 프롬프트에 들어간다. 프롬프트에 특정 직군 용어를 박아 두지 않기 위한 장치.
struct UsageContextSection: View {
    @ObservedObject var model: SettingsModel
    @State private var showExtras = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        SettingsSection("주로 어디에 쓰나요?") {
            VStack(alignment: .leading, spacing: 12) {
                if model.showOnboarding {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles").foregroundColor(.coral)
                        Text("처음이시군요. 주로 쓰는 분야와 상황을 골라 주세요. 골라 둔 분야의 용어(예: 개발이면 README·레포·React)를 받아쓰기가 잘못 들어도 바로잡습니다. 여러 개 골라도 됩니다.")
                            .font(.system(size: 12)).foregroundColor(.ink).lineSpacing(2)
                    }
                    .padding(12)
                    .background(Color.coral.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.coral.opacity(0.35), lineWidth: 1))
                    .cornerRadius(8)
                } else {
                    // ⚠️ 설명이 처음 쓰는 사람에게만 떴다. 나머지는 칩만 보고 무엇에 쓰는지 몰랐다.
                    //    ⚠️ 이 설정은 **회의록에도 걸린다**(`Glossary.apply`). 받아쓰기 탭에 있어서
                    //       받아쓰기 전용으로 읽히므로 여기 적어 둔다.
                    Text("골라 둔 분야의 용어를 잘못 들어도 바로잡습니다. 회의록에도 적용됩니다.")
                        .font(.system(size: 11)).foregroundColor(.text3)
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(UsageContext.allCases) { c in
                        let on = model.usageContexts.contains(c)
                        Button(action: { model.toggleContext(c) }) {
                            HStack(spacing: 8) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13)).foregroundColor(on ? .ink : .text4)
                                Image(systemName: c.symbol).font(.system(size: 11)).foregroundColor(.text2).frame(width: 14)
                                Text(c.title).font(.system(size: 12, weight: on ? .semibold : .regular)).foregroundColor(.ink)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 34)
                            .background(on ? Color.fill : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.lineStrong : Color.line, lineWidth: 1))
                            .cornerRadius(8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                if model.showOnboarding {
                    HStack {
                        Spacer()
                        SmallButton("이대로 시작", filled: true) {
                            Prefs.onboarded = true
                            model.showOnboarding = false
                        }
                    }
                }

                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showExtras.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: showExtras ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        Text("직접 추가 — 내 소개, 자주 쓰는 용어")
                    }
                    .font(.system(size: 12)).foregroundColor(.text2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showExtras {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("내 소개 (선택)").font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
                        Text("예) 시큐어로그에서 SCSM 이라는 사내 솔루션을 만듭니다.")
                            .font(.system(size: 11)).foregroundColor(.text3)
                        TextEditor(text: $model.speakerNote)
                            .font(.system(size: 12)).frame(height: 48)
                            .padding(6).background(Color.fill).cornerRadius(7)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.lineStrong, lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("추가 용어 (선택)").font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
                        Text("한 줄에 하나씩 적습니다. \"잘못 들린 말 → 올바른 표기\" 또는 단어만 적어도 됩니다. 예) 에스씨에스엠 → SCSM")
                            .font(.system(size: 11)).foregroundColor(.text3)
                        TextEditor(text: $model.glossary)
                            .font(.system(size: 12, design: .monospaced)).frame(height: 90)
                            .padding(6).background(Color.fill).cornerRadius(7)
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.lineStrong, lineWidth: 1))
                    }
                }
            }
            .padding(14)
        }
    }
}
