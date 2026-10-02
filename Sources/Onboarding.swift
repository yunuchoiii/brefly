import AppKit
import SwiftUI
import AVFoundation
import Speech
import Carbon.HIToolbox

// MARK: - 첫 실행 설치 안내 (시안: Brefly Onboarding.dc.html)
//
// 권한을 한 화면에 하나씩 요청한다. macOS 권한 창은 앱이 띄우기만 할 뿐 결과를 못 바꾸고,
// 한 번 거부하면 다시 뜨지 않으며, 손쉬운 사용은 시스템 창 자체가 없어 설정 앱으로 보내야 한다.
// 그래서 권한 화면마다 요청 전 / 요청 중 / 허용됨 / 거부됨 네 상태가 있다.

final class OnboardingModel: ObservableObject {

    enum Step: Int, CaseIterable {
        case welcome, mic, speech, model, hotkey, paste, fields, done
    }

    enum Permission { case idle, requesting, granted, denied }

    @Published var step: Step = .welcome

    // 1 마이크 · 2 음성 인식
    @Published var mic: Permission = .idle
    @Published var speech: Permission = .idle
    /// 시스템 설정 > 키보드 > 받아쓰기. nil 이면 값을 못 읽은 것(체크박스로 물러난다).
    @Published var dictationEnabled: Bool? = false
    @Published var dictationChecked = false
    private var dictationTimer: Timer?

    // 8 마무리 — 로그인 시 자동 실행
    /// 마법사에서 체크해 둔 값. 화면에서 바로 등록하지 않고 finish() 에서 한 번만 반영한다.
    /// 메뉴바 앱은 떠 있지 않으면 단축키에 반응하지 못하므로 기본값은 켬이다.
    /// 정리 방식. 기본은 문장으로 다듬기라 그냥 넘어가도 된다.
    @Published var summaryOn = Prefs.style == .summary
    @Published var launchAtLogin = true
    @Published var launchAtLoginError = ""

    // 3 AI 모델
    @Published var appleStatus: AppleClient.Status
    var appleAvailable: Bool { appleStatus == .available }
    private var appleTimer: Timer?
    @Published var geminiExpanded = false
    @Published var keyDraft = ""
    @Published var keyVerifying = false
    @Published var keyVerified = false
    @Published var keyError = ""

    // 4 단축키
    @Published var hotKeyTitle = ""
    @Published var hotKeyIsModifierOnly = false
    @Published var presetIndex: Int? = 0
    @Published var recording = false
    @Published var heldModifiers = ""
    private var monitors: [Any] = []
    private var maxHeld: UInt32 = 0

    // 5 붙여넣기
    @Published var autoPaste = false
    @Published var accessibilityTrusted = false
    private var trustTimer: Timer?

    // 6 분야
    @Published var usageContexts: Set<UsageContext> = []

    /// 미리보기 렌더용. 설정을 쓰거나 시스템 권한을 건드리지 않는다.
    let previewMode: Bool
    var onFinish: (() -> Void)?

    init(previewMode: Bool = false, appleStatus: AppleClient.Status? = nil) {
        self.previewMode = previewMode
        self.appleStatus = appleStatus ?? (previewMode ? .available : AppleClient.status())
        if !previewMode {
            hotKeyTitle = Prefs.currentHotKey.title
            hotKeyIsModifierOnly = Prefs.currentHotKey.isModifierOnly
            presetIndex = Prefs.customHotKey == nil ? Prefs.hotKeyIndex : nil
            autoPaste = Prefs.autoPaste
            accessibilityTrusted = Paster.isTrusted
            usageContexts = Prefs.usageContexts
            keyVerified = !(KeychainStore.read(.gemini) ?? "").isEmpty
        } else {
            hotKeyTitle = HotKeyPreset.all[0].title
        }
    }

    // MARK: 진행

    /// "⌃⌥Space" → "⌃⌥ Space" (시안 표기)
    static func spaced(_ title: String) -> String {
        guard let i = title.firstIndex(where: { !"fn⌃⌥⇧⌘".contains($0) }), i != title.startIndex else { return title }
        return title[..<i] + " " + title[i...]
    }

    var stepIndex: Int { step.rawValue }
    var stepCount: Int { Step.allCases.count }

    /// 수정자 전용 단축키(fn⌃ 등)는 붙여넣기와 무관하게 손쉬운 사용 권한이 있어야 동작한다.
    var accessibilityRequired: Bool { autoPaste || hotKeyIsModifierOnly }

    var canGoNext: Bool {
        switch step {
        case .welcome, .fields, .done: return true
        case .mic:     return mic == .granted
        case .speech:  return speech == .granted && (dictationEnabled ?? dictationChecked)
        case .model:   return appleAvailable || keyVerified
        case .hotkey:  return !recording
        case .paste:   return !accessibilityRequired || accessibilityTrusted
        }
    }

    var canSkip: Bool {
        switch step {
        case .model:  return !appleAvailable && !keyVerified
        case .paste:  return !hotKeyIsModifierOnly && !(autoPaste && accessibilityTrusted)
        case .fields: return true
        default:      return false
        }
    }

    func next() {
        guard canGoNext, let n = Step(rawValue: step.rawValue + 1) else { return }
        go(to: n)
    }

    func skip() {
        guard canSkip, let n = Step(rawValue: step.rawValue + 1) else { return }
        if step == .paste { setAutoPaste(false) }
        go(to: n)
    }

    func back() {
        guard let p = Step(rawValue: step.rawValue - 1) else { return }
        go(to: p)
    }

    func go(to s: Step) {
        stopRecording()
        stopTrustWatcher()
        stopDictationWatcher()
        stopAppleWatcher()
        step = s
        switch s {
        case .mic:    refreshMic()
        case .model:
            refreshApple()
            if appleStatus.canBecomeAvailable { startAppleWatcher() }
        case .speech:
            refreshSpeech()
            refreshDictation()
            if dictationEnabled == false { startDictationWatcher() }
        case .paste:
            refreshTrust()
            if accessibilityRequired && !accessibilityTrusted { startTrustWatcher() }
        case .done:
            if !previewMode { Prefs.onboarded = true }
        default: break
        }
    }

    func finish() {
        if !previewMode {
            // 이미 켜져 있으면 건드리지 않는다. 껐다 켜면 시스템 설정의 승인 상태가 흔들린다.
            Prefs.style = summaryOn ? .summary : Prefs.plainStyle
            if launchAtLogin != LoginItem.isEnabled {
                launchAtLoginError = LoginItem.set(launchAtLogin) ?? ""
                if !launchAtLoginError.isEmpty {
                    Log.write("로그인 시 자동 실행 설정 실패: \(launchAtLoginError)")
                }
            }
            Prefs.onboarded = true
            NotificationCenter.default.post(name: .breflyPrefsChanged, object: nil)
        }
        onFinish?()
    }

    // MARK: 1 마이크

    func refreshMic() {
        guard !previewMode else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: markMicGranted()
        case .denied, .restricted: mic = .denied
        default: if mic != .requesting { mic = .idle }
        }
    }

    func requestMic() {
        guard !previewMode else { return }
        mic = .requesting
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                Log.write("설치 안내: 마이크 권한 \(granted)")
                if granted { self.markMicGranted() } else { self.mic = .denied }
            }
        }
    }

    private func markMicGranted() {
        guard mic != .granted else { return }
        mic = .granted
        // 허용되면 0.8초 뒤 자동으로 다음 단계
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.step == .mic, self.mic == .granted else { return }
            self.next()
        }
    }

    // MARK: 2 음성 인식

    func refreshSpeech() {
        guard !previewMode else { return }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .granted
        case .denied, .restricted: speech = .denied
        default: if speech != .requesting { speech = .idle }
        }
    }

    func requestSpeech() {
        guard !previewMode else { return }
        speech = .requesting
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                Log.write("설치 안내: 음성 인식 권한 \(status.rawValue)")
                self.speech = status == .authorized ? .granted : .denied
            }
        }
    }

    /// 받아쓰기 스위치는 앱이 못 켜지만 상태는 읽을 수 있다 (2026-09-05 실측: com.apple.assistant.support 의
    /// "Dictation Enabled"). 샌드박스가 아니라서 다른 도메인을 읽는다. 키가 없으면 nil.
    static func readDictationEnabled() -> Bool? {
        UserDefaults(suiteName: "com.apple.assistant.support")?.object(forKey: "Dictation Enabled") as? Bool
    }

    func refreshDictation() {
        guard !previewMode else { return }
        let was = dictationEnabled
        dictationEnabled = Self.readDictationEnabled()
        if was != dictationEnabled { Log.write("설치 안내: 받아쓰기 스위치 \(dictationEnabled.map { $0 ? "켜짐" : "꺼짐" } ?? "알 수 없음")") }
    }

    private func startDictationWatcher() {
        guard !previewMode, dictationTimer == nil else { return }
        dictationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshDictation()
            if self.dictationEnabled != false { self.stopDictationWatcher() }
        }
    }

    private func stopDictationWatcher() {
        dictationTimer?.invalidate()
        dictationTimer = nil
    }

    // MARK: 3 AI 모델

    func refreshApple() {
        guard !previewMode else { return }
        let now = AppleClient.status()
        if now != appleStatus {
            appleStatus = now
            Log.write("설치 안내: Apple AI 상태 \(now)")
        }
    }

    func openAppleIntelligenceSettings() {
        guard !previewMode else { return }
        SystemSettings.open(.appleIntelligence)
    }

    /// 스위치를 켜면 먼저 .downloading 이 됐다가 .available 로 바뀐다. 2초마다 다시 본다.
    private func startAppleWatcher() {
        guard !previewMode, appleTimer == nil else { return }
        appleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshApple()
            if !self.appleStatus.canBecomeAvailable { self.stopAppleWatcher() }
        }
    }

    private func stopAppleWatcher() {
        appleTimer?.invalidate()
        appleTimer = nil
    }

    func verifyKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !previewMode else { return }
        keyVerifying = true
        keyError = ""
        KeychainStore.write(key, to: .gemini)
        GeminiClient.shared.listModels { result in
            DispatchQueue.main.async {
                self.keyVerifying = false
                switch result {
                case .success:
                    self.keyVerified = true
                    Log.write("설치 안내: Gemini 키 확인됨")
                case .failure(let error):
                    self.keyVerified = false
                    self.keyError = "키를 확인하지 못했습니다. 다시 붙여 넣어 주세요. (\(error.localizedDescription))"
                    Log.write("설치 안내: Gemini 키 확인 실패 — \(error.localizedDescription)")
                }
            }
        }
    }

    var maskedKey: String {
        let saved = previewMode ? "preview-gemini-key-not-real-3kQ" : (KeychainStore.read(.gemini) ?? "")
        guard saved.count > 8 else { return saved }
        return saved.prefix(4) + "••••••••••••••••••••" + saved.suffix(3)
    }

    // MARK: 4 단축키

    func choosePreset(_ i: Int) {
        stopRecording()
        presetIndex = i
        let combo = HotKeyPreset.preset(at: i).combo
        apply(combo)
        if !previewMode {
            Prefs.hotKeyIndex = i
            Prefs.customHotKey = nil
            NotificationCenter.default.post(name: .breflyPrefsChanged, object: nil)
        }
    }

    private func setCustom(_ combo: HotKeyCombo) {
        presetIndex = nil
        apply(combo)
        if !previewMode {
            Prefs.customHotKey = combo
            NotificationCenter.default.post(name: .breflyPrefsChanged, object: nil)
        }
    }

    private func apply(_ combo: HotKeyCombo) {
        hotKeyTitle = combo.title
        hotKeyIsModifierOnly = combo.isModifierOnly
    }

    /// 설정 창의 HotKeyRecorderField 와 같은 방식. 첫 응답자로는 키를 못 받아 로컬 이벤트 모니터로 가로챈다.
    func startRecording() {
        guard !recording else { return }
        recording = true
        heldModifiers = ""
        maxHeld = 0
        NotificationCenter.default.post(name: .breflyHotKeyCaptureBegan, object: nil)

        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) { self.stopRecording(); return nil }
            let mods = HotKeyCombo.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { NSSound.beep(); return nil }
            self.setCustom(HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: mods))
            self.stopRecording()
            return nil
        }
        let flagMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let now = HotKeyCombo.modifierBits(from: event.modifierFlags)
            self.heldModifiers = HotKeyCombo(keyCode: 0, modifiers: now).modifierSymbols
            if now & self.maxHeld == self.maxHeld, now != self.maxHeld {
                self.maxHeld = now
            } else if now == 0, self.maxHeld != 0 {
                self.setCustom(HotKeyCombo(keyCode: HotKeyCombo.modifierOnlyKeyCode, modifiers: self.maxHeld))
                self.stopRecording()
                return nil
            } else if now == 0 {
                self.maxHeld = 0
            }
            return nil
        }
        monitors = [keyMonitor, flagMonitor].compactMap { $0 }
    }

    func stopRecording() {
        guard recording else { return }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        recording = false
        heldModifiers = ""
        NotificationCenter.default.post(name: .breflyHotKeyCaptureEnded, object: nil)
    }

    // MARK: 5 붙여넣기 · 손쉬운 사용

    func setAutoPaste(_ on: Bool) {
        autoPaste = on
        if !previewMode { Prefs.autoPaste = on }
        refreshTrust()
        if accessibilityRequired && !accessibilityTrusted { startTrustWatcher() } else { stopTrustWatcher() }
    }

    func refreshTrust() {
        guard !previewMode else { return }
        accessibilityTrusted = Paster.isTrusted
    }

    func openAccessibilitySettings() {
        guard !previewMode else { return }
        Paster.sendToSettings { SystemSettings.open(.accessibility) }
    }

    /// AXIsProcessTrusted 는 폴링만 된다. 2초마다 확인하다 켜지면 멈춘다.
    private func startTrustWatcher() {
        guard !previewMode, trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshTrust()
            if self.accessibilityTrusted {
                Log.write("설치 안내: 손쉬운 사용 권한 확인됨")
                self.stopTrustWatcher()
            }
        }
    }

    private func stopTrustWatcher() {
        trustTimer?.invalidate()
        trustTimer = nil
    }

    // MARK: 6 분야

    func toggleContext(_ c: UsageContext) {
        if usageContexts.contains(c) { usageContexts.remove(c) } else { usageContexts.insert(c) }
        if !previewMode { Prefs.usageContexts = usageContexts }
    }

    deinit {
        stopRecording()
        stopTrustWatcher()
        stopDictationWatcher()
        stopAppleWatcher()
    }
}

/// 시스템 설정 앱의 특정 화면을 연다. 권한은 앱이 못 켜므로 여기로 보내는 수밖에 없다.
enum SystemSettings {
    enum Pane {
        case microphone, speechRecognition, accessibility, dictation, appleIntelligence

        var urls: [String] {
            switch self {
            case .appleIntelligence: return ["x-apple.systempreferences:com.apple.Siri-Settings.extension",
                                             "x-apple.systempreferences:com.apple.preference.speech"]
            case .microphone:        return ["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]
            case .speechRecognition: return ["x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"]
            case .accessibility:     return ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
            case .dictation:         return ["x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
                                             "x-apple.systempreferences:com.apple.preference.keyboard"]
            }
        }
    }

    /// 권한 목록이 있는 곳을 사람이 읽는 경로로. macOS 27 에서 '손쉬운 사용' 목록 이름이 '기기 제어 및 데이터 접근'으로
    /// 바뀌었다. 옛 이름으로 안내했더니 사용자가 왼쪽 목록의 '손쉬운 사용'(화면 확대 같은 기능 메뉴)을 뒤졌다.
    static var accessibilityPath: String {
        let list = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
            ? "기기 제어 및 데이터 접근" : "손쉬운 사용"
        return "시스템 설정 > 개인정보 보호 및 보안 > \(list)"
    }

    static func open(_ pane: Pane) {
        for s in pane.urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}

// MARK: - 창

/// 타이틀바 없는 창. 테두리 없는 창은 기본으로 키 창이 못 되어 텍스트 입력·단축키 녹음이 안 된다.
final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // ⌘W 로 닫을 수 있게 (닫기 버튼이 없다)
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            close(); return
        }
        super.keyDown(with: event)
    }
}

final class OnboardingWindowController {
    private var window: NSWindow?
    private(set) var model: OnboardingModel?
    var onFinish: (() -> Void)?

    static let size = NSSize(width: 560, height: 440)

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if let window, window.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let m = OnboardingModel()
        m.onFinish = { [weak self] in
            self?.window?.close()
            self?.onFinish?()
        }
        model = m

        let host = NSHostingController(rootView: OnboardingView(model: m))
        let w = OnboardingWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentViewController = host
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = Prefs.appearance.nsAppearance
        w.setContentSize(Self.size)
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        Log.write("설치 안내 열림")
    }

    func applyAppearance() { window?.appearance = Prefs.appearance.nsAppearance }
}

// MARK: - 뷰

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .background(Color.paper)
        .cornerRadius(12)
    }

    private var header: some View {
        HStack(spacing: 9) {
            LogoMark(size: 18, dot: .coralDeep)
            Text("Brefly 시작하기").font(.system(size: 13, weight: .bold)).foregroundColor(.ink)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<model.stepCount, id: \.self) { i in
                    Circle()
                        .fill(i < model.stepIndex ? Color.primaryFill : (i == model.stepIndex ? Color.coral : Color.lineStrong))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(.top, 18).padding(.horizontal, 24)
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: WelcomeStep(model: model)
        case .mic:     MicStep(model: model)
        case .speech:  SpeechStep(model: model)
        case .model:   ModelStep(model: model)
        case .hotkey:  HotKeyStep(model: model)
        case .paste:   PasteStep(model: model)
        case .fields:  FieldsStep(model: model)
        case .done:    DoneStep(model: model)
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.step {
        case .done:
            EmptyView()
        case .welcome:
            HStack {
                Spacer()
                WizardButton("시작", style: .primary) { model.next() }
            }
            .padding(.top, 14).padding(.horizontal, 24).padding(.bottom, 18)
            .overlay(alignment: .top) { HairLine() }
        default:
            HStack(spacing: 14) {
                WizardButton("뒤로", style: model.recording ? .disabledOutline : .outline) { model.back() }
                Spacer()
                if model.canSkip {
                    Button(action: { model.skip() }) {
                        Text("나중에").font(.system(size: 13, weight: .semibold)).foregroundColor(.text3)
                    }.buttonStyle(.plain)
                }
                WizardButton("다음", style: model.canGoNext ? .primary : .disabled) { model.next() }
            }
            .padding(.top, 14).padding(.horizontal, 24).padding(.bottom, 18)
            .overlay(alignment: .top) { HairLine() }
        }
    }
}

// MARK: 0 환영

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 18) {
            LogoMark(size: 64)
            Text("말하면 정리해서 붙여 넣어 드립니다")
                .font(.system(size: 22, weight: .heavy)).foregroundColor(.ink)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                flowCard("단축키를 누르고") { KeyCapLarge(OnboardingModel.spaced(model.hotKeyTitle)) }
                arrow
                flowCard("편하게 말하면") { Image(systemName: "mic").font(.system(size: 22, weight: .regular)).foregroundColor(.ink).frame(height: 28) }
                arrow
                flowCard("정리해서 붙여넣기") { Image(systemName: "doc.on.clipboard").font(.system(size: 20, weight: .regular)).foregroundColor(.ink).frame(height: 28) }
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 12).padding(.horizontal, 44)
    }

    private var arrow: some View {
        Text("→").font(.system(size: 14)).foregroundColor(.text4)
    }

    private func flowCard<Icon: View>(_ caption: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 9) {
            icon()
            Text(caption).font(.system(size: 12, weight: .semibold)).foregroundColor(.text2)
        }
        .frame(width: 128).padding(.vertical, 16).padding(.horizontal, 12)
        .background(Color.fill).cornerRadius(11)
    }
}

// MARK: 1 마이크

private struct MicStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: model.mic == .denied ? 14 : 16) {
            switch model.mic {
            case .granted:
                PermissionBadge(state: .granted, icon: "mic")
                Text("허용됐습니다").font(.system(size: 21, weight: .heavy)).foregroundColor(.greenText)
                Text("마이크가 준비됐습니다.").font(.system(size: 13.5)).foregroundColor(.text2)
            case .denied:
                PermissionBadge(state: .denied, icon: "mic.slash")
                Text("마이크가 꺼져 있습니다").font(.system(size: 21, weight: .heavy)).foregroundColor(.ink)
                DeniedBox("시스템 설정 > 개인정보 보호 및 보안 > 마이크에서\nBrefly 를 켜 주세요")
                HStack(spacing: 8) {
                    WizardButton("시스템 설정 열기", style: .primary) { SystemSettings.open(.microphone) }
                    WizardButton("다시 확인", style: .outline) { model.refreshMic() }
                }
                Text("한 번 거부하면 시스템 창이 다시 뜨지 않아 설정에서 직접 켜야 합니다.")
                    .font(.system(size: 11.5)).foregroundColor(.text4)
            default:
                PermissionBadge(state: .idle, icon: "mic")
                Text("마이크를 허용해 주세요.").font(.system(size: 21, weight: .heavy)).foregroundColor(.ink)
                if model.mic == .requesting {
                    (Text("지금 뜬 시스템 창에서 ") + Text("허용").fontWeight(.bold).foregroundColor(.ink) + Text("을 눌러 주세요."))
                        .font(.system(size: 13.5)).foregroundColor(.text2)
                    RequestingButton("허용 요청 중…")
                } else {
                    Text("말한 내용을 받아 적으려면 마이크가 필요합니다.\n소리는 이 맥에서만 처리되고 저장되지 않습니다.")
                        .font(.system(size: 13.5)).foregroundColor(.text2).lineSpacing(4)
                    WizardButton("허용", style: .coral, wide: true) { model.requestMic() }
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 12).padding(.horizontal, 52)
    }
}

// MARK: 2 음성 인식 + 받아쓰기 스위치

private struct SpeechStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StepTitle("말을 글자로 바꾸는 기능을 켭니다")

            // 음성 인식 권한
            if model.speech == .granted {
                GreenBox("음성 인식 허용됐습니다")
            } else if model.speech == .denied {
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform.slash").font(.system(size: 20)).foregroundColor(.coralDeep).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("음성 인식이 꺼져 있습니다").font(.system(size: 13.5, weight: .bold)).foregroundColor(.ink)
                            Text("시스템 설정 > 개인정보 보호 및 보안 > 음성 인식에서 Brefly 를 켜 주세요.")
                                .font(.system(size: 12)).foregroundColor(.text2)
                        }
                        Spacer()
                        WizardButton("설정 열기", style: .primary, small: true) { SystemSettings.open(.speechRecognition) }
                        WizardButton("다시 확인", style: .outline, small: true) { model.refreshSpeech() }
                    }
                }
            } else {
                Card {
                    HStack(spacing: 12) {
                        LogoMark(size: 26, dot: .ink)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("음성 인식 허용").font(.system(size: 13.5, weight: .bold)).foregroundColor(.ink)
                            Text(model.speech == .requesting ? "지금 뜬 시스템 창에서 허용을 눌러 주세요." : "말한 내용을 글자로 바꾸는 데 필요합니다.")
                                .font(.system(size: 12)).foregroundColor(.text2)
                        }
                        Spacer()
                        if model.speech == .requesting {
                            RequestingButton("요청 중…", small: true)
                        } else {
                            WizardButton("허용", style: .coral, small: true) { model.requestSpeech() }
                        }
                    }
                }
            }

            // 맥의 받아쓰기 스위치 — 앱이 켤 수는 없지만 상태는 읽는다. 못 읽으면 체크박스로.
            if model.dictationEnabled == true || (model.dictationEnabled == nil && model.dictationChecked) {
                GreenBox(model.dictationEnabled == true ? "받아쓰기가 켜져 있습니다" : "받아쓰기를 켰습니다")
            } else {
                Card(soft: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: "keyboard").font(.system(size: 18)).foregroundColor(.ink).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("맥의 받아쓰기 스위치").font(.system(size: 13.5, weight: .bold)).foregroundColor(.ink)
                                Text(model.dictationEnabled == nil
                                     ? "시스템 설정 > 키보드 > 받아쓰기가 꺼져 있으면 인식이 되지 않습니다. 켜져 있는지 확인하고 아래를 체크해 주세요."
                                     : "시스템 설정 > 키보드 > 받아쓰기가 꺼져 있어 인식이 되지 않습니다. 켜고 돌아오면 자동으로 확인됩니다.")
                                    .font(.system(size: 12)).foregroundColor(.text2).lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            WizardButton("받아쓰기 설정 열기", style: .outline, small: true) { SystemSettings.open(.dictation) }
                        }
                        if model.dictationEnabled == nil {
                            Button(action: { model.dictationChecked.toggle() }) {
                                HStack(spacing: 9) {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(Color.lineStrong, lineWidth: 1.5)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.paper))
                                        .frame(width: 17, height: 17)
                                    Text("받아쓰기를 켰습니다").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 36)
                        } else {
                            HStack(spacing: 8) {
                                Spinner(size: 11)
                                Text("2초마다 확인 중").font(.system(size: 11.5)).foregroundColor(.text4)
                            }
                            .padding(.leading, 36)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 20).padding(.horizontal, 36)
    }
}

// MARK: 3 AI 모델

private struct ModelStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if model.appleAvailable {
                StepTitle("받아 적은 글을 정리할 AI 를 고릅니다")
                Card(selected: true) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 20)).foregroundColor(.ink).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("이 맥의 Apple AI").font(.system(size: 13.5, weight: .bold)).foregroundColor(.ink)
                            Text("인터넷 없이 이 맥 안에서 바로 정리합니다 · 무료").font(.system(size: 12)).foregroundColor(.text2)
                        }
                        Spacer()
                        CheckCircle(color: .coral, size: 19)
                    }
                }
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { model.geminiExpanded.toggle() } }) {
                    HStack(spacing: 10) {
                        Text("Gemini 도 함께 쓰기 (무료 키)").font(.system(size: 13, weight: .semibold)).foregroundColor(.text2)
                        Spacer()
                        Image(systemName: model.geminiExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(.text4)
                    }
                    .padding(.vertical, 13).padding(.horizontal, 16)
                    .background(Color.paperSoft)
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.line, lineWidth: 1))
                    .cornerRadius(11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if model.geminiExpanded { keyField }
            } else if model.appleStatus.canBecomeAvailable {
                // C: 켤 수 있는데 꺼져 있거나 내려받는 중 — 가장 쉬운 길을 먼저 보여 준다
                StepTitle("받아 적은 글을 정리할 AI 를 고릅니다")
                Card(selected: true) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 20)).foregroundColor(.ink).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.appleStatus == .downloading ? "Apple Intelligence 모델을 내려받는 중입니다" : "Apple Intelligence 를 켜면 키 없이 됩니다")
                                .font(.system(size: 13.5, weight: .bold)).foregroundColor(.ink)
                            Text(model.appleStatus == .downloading
                                 ? "끝나면 이 맥 안에서 바로 정리합니다 · 무료 · 인터넷 불필요"
                                 : "시스템 설정 > Apple Intelligence & Siri 에서 켜고 돌아오면 자동으로 확인됩니다 · 무료")
                                .font(.system(size: 12)).foregroundColor(.text2).lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if model.appleStatus == .downloading {
                            Spinner(size: 14)
                        } else {
                            WizardButton("설정 열기", style: .primary, small: true) { model.openAppleIntelligenceSettings() }
                        }
                    }
                }
                HStack(spacing: 8) {
                    Spinner(size: 11)
                    Text("2초마다 확인 중").font(.system(size: 11.5)).foregroundColor(.text4)
                    Spacer()
                }
                .padding(.leading, 4)
                HStack(spacing: 10) {
                    HairLine()
                    Text("또는 Gemini 무료 키").font(.system(size: 12, weight: .bold)).foregroundColor(.text3).fixedSize()
                    HairLine()
                }
                .padding(.vertical, 2)
                keyField
                if model.keyVerified {
                    GreenBox("\(Prefs.geminiModel) 로 연결됐습니다 · 요약을 정리할 준비가 됐어요")
                } else {
                    // ⚠️ 여기만 밑줄 친 회색 글자였다. 좌우가 전부 회색 설명이라 그 사이에서
                    //    **누를 것으로 안 보였다.** 아래 갈래(`helpBox`)는 검은 버튼인데 짝이 안 맞았다.
                    //    같은 버튼으로 맞춘다.
                    HStack(spacing: 10) {
                        WizardButton("발급 페이지 열기", style: .primary, small: true) {
                            if let u = URL(string: "https://aistudio.google.com/apikey") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        Text("카드 등록 없이 무료입니다").font(.system(size: 12)).foregroundColor(.text4)
                        Spacer(minLength: 8)
                        Text("나중에 하면 원문만 복사됩니다.").font(.system(size: 12)).foregroundColor(.text4)
                    }
                }
            } else {
                StepTitle("정리에 쓸 Gemini 무료 키를 넣어 주세요.")
                keyField
                if model.keyVerified {
                    GreenBox("\(Prefs.geminiModel) 로 연결됐습니다 · 요약을 정리할 준비가 됐어요")
                } else {
                    helpBox
                    Text("나중에 하면 정리 없이 원문만 복사됩니다.").font(.system(size: 12)).foregroundColor(.text4)
                }
            }
                // 정리 방식은 쓸 AI 가 정해졌을 때만 묻는다. 아직 못 고른 화면은 이미 빽빽해서
                // 여기서 더 올리면 560×440 안에 안 들어간다.
                if model.appleAvailable || model.keyVerified {
                    PolishChoice(model: model)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 18).padding(.horizontal, 36)
    }

    @ViewBuilder private var keyField: some View {
        if model.keyVerified {
            HStack(spacing: 8) {
                Text(model.maskedKey)
                    .font(.system(size: 13, design: .monospaced)).foregroundColor(.ink)
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.paper)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.green, lineWidth: 1.5))
                    .cornerRadius(9)
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("키 확인됨").font(.system(size: 12.5, weight: .bold)).foregroundColor(.greenText)
                }
                .padding(.horizontal, 6)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("AIza… 키를 붙여 넣어 주세요.", text: $model.keyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.vertical, 10).padding(.horizontal, 14)
                        .background(Color.paperSoft)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.lineStrong, lineWidth: 1))
                        .cornerRadius(9)
                        .onSubmit { model.verifyKey() }
                    if model.keyVerifying {
                        RequestingButton("확인 중…", small: true)
                    } else {
                        WizardButton("확인", style: .outline, small: true) { model.verifyKey() }
                    }
                }
                if !model.keyError.isEmpty {
                    Text(model.keyError).font(.system(size: 11.5)).foregroundColor(.coralDeep)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var helpBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("키 받는 방법 — 카드 등록 없이 무료입니다").font(.system(size: 12, weight: .bold)).foregroundColor(.text2)
            NumberedRow(1) { Text("aistudio.google.com/apikey 에 접속합니다.") }
            NumberedRow(2) { Text("\"키 만들기\"를 누릅니다.") }
            NumberedRow(3) { Text("만들어진 키를 복사해 위 칸에 붙여 넣습니다.") }
            WizardButton("발급 페이지 열기", style: .primary, small: true) {
                if let u = URL(string: "https://aistudio.google.com/apikey") { NSWorkspace.shared.open(u) }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 13).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fill).cornerRadius(11)
    }
}

// MARK: 4 단축키

private struct HotKeyStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle("녹음을 시작할 단축키를 고릅니다")
            if !model.hotKeyIsModifierOnly {
                Text("어느 앱에서든 이 키를 누르면 바로 녹음이 시작됩니다.").font(.system(size: 13)).foregroundColor(.text2)
            }
            HStack(spacing: 8) {
                ForEach(Array(HotKeyPreset.all.enumerated()), id: \.offset) { i, p in
                    let on = model.presetIndex == i && !model.recording
                    Button(action: { model.choosePreset(i) }) {
                        Text(OnboardingModel.spaced(p.title))
                            .font(.system(size: 13, weight: on ? .bold : .semibold))
                            .foregroundColor(model.recording ? .text4 : (on ? .coralDeep : .ink))
                            .padding(.vertical, 9).padding(.horizontal, 16)
                            .background(on ? Color.coral.opacity(0.08) : Color.paper)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(on ? Color.coral : Color.lineStrong, lineWidth: on ? 1.5 : 1))
                            .cornerRadius(9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.recording)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("직접 정하기").font(.system(size: 12, weight: .bold)).foregroundColor(.text3)
                recorder
                if model.hotKeyIsModifierOnly {
                    HStack(alignment: .top, spacing: 8) {
                        Text("ⓘ").font(.system(size: 12.5, weight: .heavy)).foregroundColor(.coral)
                        Text("이 단축키는 손쉬운 사용 권한이 필요합니다. 다음 단계에서 켭니다.")
                            .font(.system(size: 12.5)).foregroundColor(.ink).lineSpacing(2)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.fill).cornerRadius(9)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 20).padding(.horizontal, 36)
        .onDisappear { model.stopRecording() }
    }

    @ViewBuilder private var recorder: some View {
        if model.recording {
            HStack(spacing: 8) {
                BlinkDot()
                Text(model.heldModifiers.isEmpty ? "원하는 조합을 누르세요…" : model.heldModifiers + "…")
                    .font(.system(size: 13.5, weight: .bold)).foregroundColor(.coralDeep)
            }
            .padding(.vertical, 13).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.coral.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.coral, lineWidth: 1.5))
            .cornerRadius(10)
        } else if model.presetIndex == nil {
            HStack(spacing: 8) {
                Text(OnboardingModel.spaced(model.hotKeyTitle)).font(.system(size: 13.5, weight: .bold)).foregroundColor(.ink)
                Spacer()
                Button(action: { model.startRecording() }) {
                    Text("다시 정하기").font(.system(size: 12, weight: .semibold)).foregroundColor(.text4)
                }.buttonStyle(.plain)
            }
            .padding(.vertical, 13).padding(.horizontal, 16)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primaryFill, lineWidth: 1.5))
            .cornerRadius(10)
        } else {
            Button(action: { model.startRecording() }) {
                Text("눌러서 원하는 키 조합을 입력합니다.")
                    .font(.system(size: 13)).foregroundColor(.text4)
                    .padding(.vertical, 13).padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundColor(.lineStrong))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: 5 붙여넣기 방식 · 손쉬운 사용

private struct PasteStep: View {
    @ObservedObject var model: OnboardingModel

    private var waiting: Bool { model.accessibilityRequired && !model.accessibilityTrusted }

    var body: some View {
        VStack(alignment: .leading, spacing: waiting ? 10 : 12) {
            if model.hotKeyIsModifierOnly {
                StepTitle("손쉬운 사용 권한이 필요합니다")
                Text("고른 단축키(\(model.hotKeyTitle))는 이 권한이 있어야 다른 앱 위에서 동작합니다.")
                    .font(.system(size: 13)).foregroundColor(.text2)
            } else {
                StepTitle("정리한 글을 어떻게 전달할까요?")
            }

            radio(selected: !model.autoPaste, title: "클립보드에 복사만",
                  subtitle: "⌘V 로 원하는 곳에 붙여 넣습니다 · 별도 허용 필요 없음", compact: waiting) { model.setAutoPaste(false) }
            radio(selected: model.autoPaste, title: "커서 위치에 자동으로 붙여넣기",
                  subtitle: model.autoPaste && waiting ? "손쉬운 사용 허용이 필요합니다"
                          : "말이 끝나면 지금 쓰던 곳에 바로 들어갑니다." + (model.accessibilityTrusted ? "" : " · 손쉬운 사용 허용 필요"),
                  compact: waiting) { model.setAutoPaste(true) }

            if waiting {
                VStack(alignment: .leading, spacing: 9) {
                    NumberedRow(1) { WizardButton("시스템 설정 열기", style: .primary, small: true) { model.openAccessibilitySettings() } }
                    NumberedRow(2) { Text("목록에서 Brefly 스위치를 켭니다.") }
                    NumberedRow(3) {
                        HStack(spacing: 8) {
                            Text("돌아오면 자동으로 확인됩니다.")
                            Spinner(size: 11)
                            Text("2초마다 확인 중").font(.system(size: 11.5)).foregroundColor(.text4)
                        }
                    }
                }
                .padding(.vertical, 13).padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.fill).cornerRadius(11)
            } else if model.accessibilityRequired && model.accessibilityTrusted {
                GreenBox(model.autoPaste ? "손쉬운 사용이 허용됐습니다 · 자동 붙여넣기 준비 완료" : "손쉬운 사용이 허용됐습니다 · 단축키 준비 완료")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, waiting ? 18 : 20).padding(.horizontal, 36)
    }

    private func radio(selected: Bool, title: String, subtitle: String, compact: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    if selected {
                        Circle().fill(Color.coral).frame(width: 19, height: 19)
                        Circle().fill(Color.white).frame(width: 7, height: 7)
                    } else {
                        Circle().stroke(Color.lineStrong, lineWidth: 1.5).frame(width: 17, height: 17)
                    }
                }
                .frame(width: 19, height: 19).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .bold)).foregroundColor(.ink)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.text2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, compact ? 12 : 15).padding(.horizontal, 16)
            .background(selected ? Color.paper : Color.paperSoft)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? Color.coral : Color.line, lineWidth: selected ? 1.5 : 1))
            .cornerRadius(11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: 6 분야

private struct FieldsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepTitle("주로 어떤 이야기를 하시나요?")
            Text("고른 분야에 맞춰 용어를 더 정확하게 알아듣습니다. 여러 개 골라도 됩니다.")
                .font(.system(size: 13)).foregroundColor(.text2)
            FlowLayout(spacing: 8) {
                ForEach(UsageContext.allCases) { c in
                    let on = model.usageContexts.contains(c)
                    Button(action: { model.toggleContext(c) }) {
                        Text(c.title)
                            .font(.system(size: 13, weight: on ? .bold : .semibold))
                            .foregroundColor(on ? .onPrimary : .ink)
                            .padding(.vertical, 9).padding(.horizontal, 16)
                            .background(on ? Color.primaryFill : Color.paper)
                            .overlay(Capsule().stroke(on ? Color.primaryFill : Color.lineStrong, lineWidth: on ? 1.5 : 1))
                            .clipShape(Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 20).padding(.horizontal, 36)
    }
}

// MARK: 7 완료

private struct DoneStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.greenBG).frame(width: 76, height: 76)
                CheckCircle(color: .green, size: 38)
            }
            Text("준비됐습니다").font(.system(size: 22, weight: .heavy)).foregroundColor(.ink)
            HStack(spacing: 7) {
                ForEach(Array(Self.caps(model.hotKeyTitle).enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(.system(size: 18, weight: .heavy)).foregroundColor(.ink)
                        .padding(.vertical, 12).padding(.horizontal, cap.count > 1 ? 26 : 18)
                        .background(Color.paperSoft)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(Color.lineStrong, lineWidth: 1)
                        )
                        .overlay(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 10).stroke(Color.lineStrong, lineWidth: 3)
                                .mask(Rectangle().padding(.top, 20))
                        }
                        .cornerRadius(10)
                }
            }
            Text("지금 눌러서 한 번 말해 보세요.").font(.system(size: 13.5)).foregroundColor(.text2)
            // 회의록은 설정할 것이 없어서 단계로 만들 이유가 없다. 끝 화면은 이탈 걱정이 없는 자리다(시안).
            VStack(alignment: .leading, spacing: 5) {
                Text("녹음 파일로 회의록도 만듭니다")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(.ink)
                Text("메뉴바 아이콘을 누르고 아래쪽 ‘회의록 만들기…’")
                    .font(.system(size: 11.5)).foregroundColor(.text2)
                // 회의 내용이라 "어디로 가는지"가 제일 큰 걱정이다. 숨기지 않고 둘 다 적는다.
                Text("녹음은 이 맥 밖으로 나가지 않습니다 · 요약할 때만 받아 적은 글을 AI 모델로 보냅니다.")
                    .font(.system(size: 11)).foregroundColor(.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.paperSoft)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line, lineWidth: 1))
            .cornerRadius(10)

            Button(action: { model.launchAtLogin.toggle() }) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(model.launchAtLogin ? Color.clear : Color.lineStrong, lineWidth: 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(model.launchAtLogin ? Color.ink : Color.paper)
                        )
                        .frame(width: 17, height: 17)
                        .overlay {
                            if model.launchAtLogin {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .heavy)).foregroundColor(.paper)
                            }
                        }
                    Text("로그인할 때 자동으로 시작").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            WizardButton("닫기", style: .primary, wide: true) { model.finish() }
        }
        .padding(.vertical, 12).padding(.horizontal, 60)
    }

    /// "⌃⌥Space" → ["⌃", "⌥", "Space"], "fn⌃" → ["fn", "⌃"]
    static func caps(_ title: String) -> [String] {
        var out: [String] = []
        var rest = Substring(title)
        while !rest.isEmpty {
            if rest.hasPrefix("fn") { out.append("fn"); rest = rest.dropFirst(2); continue }
            let c = rest.first!
            if "⌃⌥⇧⌘".contains(c) { out.append(String(c)); rest = rest.dropFirst(); continue }
            out.append(String(rest)); break
        }
        return out
    }
}

// MARK: - 조각

private struct StepTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 20, weight: .heavy)).foregroundColor(.ink)
    }
}

private struct WizardButton: View {
    enum Style { case primary, coral, outline, disabled, disabledOutline }
    let title: String
    let style: Style
    var small = false
    var wide = false
    let action: () -> Void

    init(_ title: String, style: Style, small: Bool = false, wide: Bool = false, action: @escaping () -> Void) {
        self.title = title; self.style = style; self.small = small; self.wide = wide; self.action = action
    }

    private var isDisabled: Bool { style == .disabled || style == .disabledOutline }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: small ? 12.5 : 13, weight: style == .outline || style == .disabledOutline ? .semibold : .bold))
                .foregroundColor(foreground)
                .padding(.vertical, small ? 8 : (style == .outline || style == .disabledOutline ? 9 : 10))
                .padding(.horizontal, wide ? 36 : (small ? 14 : (style == .outline || style == .disabledOutline ? 18 : 28)))
                .background(background)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(style == .outline || style == .disabledOutline ? Color.lineStrong : Color.clear, lineWidth: 1))
                .cornerRadius(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private var foreground: Color {
        switch style {
        case .primary: return .onPrimary
        case .coral:   return .white
        case .outline: return .ink
        case .disabled, .disabledOutline: return .text4
        }
    }

    private var background: Color {
        switch style {
        case .primary:  return .primaryFill
        case .coral:    return .coral
        case .outline:  return .paper
        case .disabled: return .fill
        case .disabledOutline: return .paper
        }
    }
}

private struct RequestingButton: View {
    let title: String
    var small = false
    init(_ title: String, small: Bool = false) { self.title = title; self.small = small }
    var body: some View {
        HStack(spacing: 9) {
            Spinner(size: 12)
            Text(title).font(.system(size: small ? 12.5 : 13.5, weight: .bold)).foregroundColor(.text4)
        }
        .padding(.vertical, small ? 8 : 10).padding(.horizontal, small ? 14 : 30)
        .background(Color.fill).cornerRadius(8)
    }
}

/// 회전하는 링. ProgressView 는 크기·색을 못 맞춘다.
private struct Spinner: View {
    var size: CGFloat = 12
    @State private var spinning = false
    var body: some View {
        Circle()
            .trim(from: 0.25, to: 1)
            .stroke(Color.text2, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

private struct BlinkDot: View {
    @State private var on = true
    var body: some View {
        Circle().fill(Color.coral).frame(width: 8, height: 8)
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: on)
            .onAppear { on = false }
    }
}

private struct PermissionBadge: View {
    let state: OnboardingModel.Permission
    let icon: String
    var body: some View {
        ZStack {
            Circle().fill(state == .granted ? Color.greenBG : Color.fill).frame(width: 72, height: 72)
            if state == .granted {
                CheckCircle(color: .green, size: 32)
            } else {
                Image(systemName: icon).font(.system(size: 30, weight: .regular))
                    .foregroundColor(state == .denied ? .coralDeep : .ink)
            }
        }
    }
}

private struct CheckCircle: View {
    let color: Color
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: "checkmark").font(.system(size: size * 0.5, weight: .bold)).foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct GreenBox: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 10) {
            CheckCircle(color: .green, size: 18)
            Text(text).font(.system(size: 13, weight: .bold)).foregroundColor(.greenText)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13).padding(.horizontal, 16)
        .background(Color.greenBG)
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.greenBorder, lineWidth: 1))
        .cornerRadius(11)
    }
}

private struct DeniedBox: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold)).foregroundColor(.coralDeep).lineSpacing(4)
            .padding(.vertical, 11).padding(.horizontal, 16)
            .background(Color.coral.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.coral.opacity(0.3), lineWidth: 1))
            .cornerRadius(10)
    }
}

private struct Card<Content: View>: View {
    var soft = false
    var selected = false
    let content: Content
    init(soft: Bool = false, selected: Bool = false, @ViewBuilder content: () -> Content) {
        self.soft = soft; self.selected = selected; self.content = content()
    }
    var body: some View {
        content
            .padding(.vertical, selected ? 15 : 14).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(soft ? Color.paperSoft : Color.paper)
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? Color.coral : Color.line, lineWidth: selected ? 1.5 : 1))
            .cornerRadius(11)
    }
}

private struct NumberedRow<Content: View>: View {
    let n: Int
    let content: Content
    init(_ n: Int, @ViewBuilder content: () -> Content) { self.n = n; self.content = content() }
    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundColor(.onPrimary)
                .frame(width: 18, height: 18).background(Circle().fill(Color.primaryFill))
            content.font(.system(size: 12.5)).foregroundColor(.ink)
        }
    }
}

/// 칩을 줄바꿈해 흘려 놓는다. macOS 13 의 Layout 프로토콜.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 480
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// 정리 방식 고르기. 설명 없이 선택지 둘로 알려 준다 — 기본값이 있어 그냥 넘어가도 된다(시안 W3).
private struct PolishChoice: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("정리 방식").font(.system(size: 12, weight: .bold)).foregroundColor(.text2)
            HStack(spacing: 8) {
                option(title: "문장으로 다듬기", detail: "말한 그대로 읽기 좋게 고칩니다.", on: !model.summaryOn) {
                    model.summaryOn = false
                }
                option(title: "핵심 요약", detail: "요점만 뽑아 목록 형태로 만듭니다.", on: model.summaryOn) {
                    model.summaryOn = true
                }
            }
            Text("메뉴바 팝오버의 “핵심 요약” 스위치로 언제든 바꿀 수 있습니다.")
                .font(.system(size: 11)).foregroundColor(.text3)
        }
    }

    private func option(title: String, detail: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .bold)).foregroundColor(.ink)
                Text(detail).font(.system(size: 11)).foregroundColor(.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(on ? Color.fill : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(on ? Color.coral : Color.lineStrong, lineWidth: on ? 1.5 : 1))
            .cornerRadius(9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
