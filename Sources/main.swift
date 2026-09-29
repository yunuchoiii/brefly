import AppKit
import Speech
import SwiftUI
import Combine

// MARK: - 앱 진입점

let app = NSApplication.shared

// 화면 확인용: 팝오버 각 상태를 PNG로 렌더링하고 종료
if let i = CommandLine.arguments.firstIndex(of: "--render-previews"), i + 1 < CommandLine.arguments.count {
    PreviewRenderer.run(outputDir: CommandLine.arguments[i + 1])
    exit(0)
}

// 진단용: 업데이트 확인만 돌려 본다. 버전을 주면 그 버전이 설치된 것처럼 비교한다.
if let i = CommandLine.arguments.firstIndex(of: "--check-update") {
    let fake = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : UpdateChecker.currentVersion
    // 콜백이 메인 큐로 오므로 세마포어로 막으면 교착된다. 런루프를 돌리며 기다린다.
    var finished = false
    UpdateChecker.check(current: fake) { result in
        switch result {
        case .success(let r?): print("새 버전: \(r.version) (\(r.tag)) — 현재 \(fake)\n\(r.notes)")
        case .success(nil):    print("최신 버전 (현재 \(fake))")
        case .failure(let e):  print("실패: \(e.localizedDescription)")
        }
        finished = true
    }
    let deadline = Date().addingTimeInterval(30)
    while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    exit(0)
}

// 빌드용: DMG 창 배경 PNG (make-dmg.sh 가 부른다)
if let i = CommandLine.arguments.firstIndex(of: "--render-dmg-background"), i + 1 < CommandLine.arguments.count {
    PreviewRenderer.renderDMGBackground(to: CommandLine.arguments[i + 1])
    exit(0)
}

// 빌드용: 앱 아이콘 iconset PNG 를 만든다. build.sh 가 iconutil 로 .icns 로 묶는다.
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = CGFloat(base * scale)
            let image = Logo.appIcon(size: px)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: px, height: px)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
    }
    exit(0)
}

// 진단용: 녹음 없이 정리 백엔드만 돌려 본다. 키는 환경변수(GEMINI_API_KEY 등)로도 넣을 수 있다.
if let i = CommandLine.arguments.firstIndex(of: "--prompt"), i + 1 < CommandLine.arguments.count {
    // 진단용: 모델에 넘어가는 요청문(말투·질문 규칙이 붙은 모습)을 그대로 본다. 모델은 부르지 않는다.
    let hint: Intonation.Direction? = CommandLine.arguments.firstIndex(of: "--intonation").flatMap { j in
        j + 1 < CommandLine.arguments.count ? ["up": .rising, "down": .falling][CommandLine.arguments[j + 1]] : nil
    }
    let text = Glossary.apply(to: CommandLine.arguments[i + 1])
    Prompts.setIntonation(hint, raw: text)
    print(Prompts.userMessage(text, style: Prefs.style))
    exit(0)
}

// 진단용: whisper.cpp 로 소리 파일을 받아쓴다. --model 로 모델 파일을 가리킨다.
if let i = CommandLine.arguments.firstIndex(of: "--whisper"), i + 1 < CommandLine.arguments.count {
    let audio = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let model: URL = CommandLine.arguments.firstIndex(of: "--model").flatMap { j in
        j + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[j + 1]) : nil
    } ?? ModelStore.transcriptionModel
    let started = Date()
    do {
        let segments = try Whisper.transcribe(audio: audio, model: model)
        let took = Date().timeIntervalSince(started)
        let text = segments.map(\.text).joined(separator: " ")
        print("OK \(String(format: "%.1f", took))초, 구간 \(segments.count)개, 글자 \(text.count)")
        for s in segments.prefix(3) {
            print("  \(String(format: "%6.2f", s.start))~\(String(format: "%.2f", s.end))초: \(s.text.prefix(40))")
        }
        let out = "/tmp/brefly-whisper.txt"
        try? text.write(toFile: out, atomically: true, encoding: .utf8)
        print("전문: \(out)")
    } catch {
        print("FAIL \(error.localizedDescription)")
    }
    exit(0)
}

// 진단용: 마이크와 시스템 소리를 함께 회의 녹음한다. 두 갈래가 제대로 갈려 들어오는지 본다.
if let i = CommandLine.arguments.firstIndex(of: "--record-meeting"), i + 1 < CommandLine.arguments.count {
    let seconds = Double(CommandLine.arguments[i + 1]) ?? 10
    let done = DispatchSemaphore(value: 0)
    Task {
        let recorder = MeetingRecorder()
        do {
            let session = try await recorder.start()
            if let e = recorder.systemAudioError { print("주의: 시스템 소리 없음 — \(e.localizedDescription)") }
            print("\(seconds)초 동안 녹음합니다 — \(session.directory.path)")
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await recorder.stop()
            func size(_ url: URL) -> String {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                return "\((bytes ?? 0) / 1024)KB"
            }
            print("마이크  \(recorder.micBuffers)조각  \(size(session.mic))")
            print("시스템  \(recorder.systemBuffers)조각  \(size(session.system))")
            print(recorder.micBuffers > 0 ? "OK \(session.directory.path)" : "FAIL 마이크가 하나도 안 들어왔습니다")
        } catch {
            print("FAIL \(error.localizedDescription)")
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + seconds + 60)
    exit(0)
}

// 진단용: 스피커로 나가는 소리를 잡아 WAV 로 남긴다. 화상회의 상대방 목소리가 실제로 들어오는지 본다.
if let i = CommandLine.arguments.firstIndex(of: "--capture-system-audio"), i + 2 < CommandLine.arguments.count {
    let seconds = Double(CommandLine.arguments[i + 1]) ?? 10
    let out = URL(fileURLWithPath: CommandLine.arguments[i + 2])
    let done = DispatchSemaphore(value: 0)
    Task {
        let recorder = SystemAudioRecorder()
        var file: AVAudioFile?
        recorder.onBuffer = { buffer in
            if file == nil {
                file = try? AVAudioFile(forWriting: out, settings: buffer.format.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            try? file?.write(from: buffer)
        }
        do {
            try await recorder.start()
            print("\(seconds)초 동안 잡습니다 — 지금 소리를 내 보세요")
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await recorder.stop()
            print("버퍼 \(recorder.buffers)개, 최대 진폭 \(String(format: "%.4f", recorder.peak))")
            if recorder.buffers == 0 {
                print("FAIL 소리가 하나도 안 들어왔습니다 — 화면 기록 권한을 확인하세요")
            } else if recorder.peak < 0.0001 {
                print("FAIL 무음만 들어왔습니다 — 권한은 났지만 소리가 안 잡힙니다")
            } else {
                print("OK \(out.path)")
            }
        } catch {
            print("FAIL \(error.localizedDescription)")
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + seconds + 60)
    exit(0)
}

// 진단용: 소리 파일만 받아쓴다. --from 초 --for 초 로 구간을, --on-device 로 온디바이스 인식을 고른다.
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"), i + 1 < CommandLine.arguments.count {
    func number(_ flag: String, _ fallback: Double) -> Double {
        guard let j = CommandLine.arguments.firstIndex(of: flag), j + 1 < CommandLine.arguments.count,
              let v = Double(CommandLine.arguments[j + 1]) else { return fallback }
        return v
    }
    let done = DispatchSemaphore(value: 0)
    Transcriber.run(CommandLine.arguments[i + 1],
                    from: number("--from", 0),
                    seconds: number("--for", 0),
                    onDevice: CommandLine.arguments.contains("--on-device")) { result in
        switch result {
        case .success(let r):
            print("OK (\(String(format: "%.1f", r.seconds))초) 글자 \(r.text.count)")
            print("구간 \(r.segments)개, 시각이 0이 아닌 것 \(r.timed)개, 마지막 시각 \(String(format: "%.2f", r.lastTimestamp))초")
            let out = "/tmp/brefly-transcribe.txt"
            try? r.text.write(toFile: out, atomically: true, encoding: .utf8)
            print("전문: \(out)")
        case .failure(let e):
            print("FAIL \(e.localizedDescription)")
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 1800)
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--polish"), i + 1 < CommandLine.arguments.count {
    let done = DispatchSemaphore(value: 0)
    let started = Date()
    // 진단용: --intonation up|down 으로 녹음 끝 억양을 흉내 낸다.
    let hint: Intonation.Direction? = CommandLine.arguments.firstIndex(of: "--intonation").flatMap { j in
        j + 1 < CommandLine.arguments.count ? ["up": .rising, "down": .falling][CommandLine.arguments[j + 1]] : nil
    }
    Polisher.run(CommandLine.arguments[i + 1], intonation: hint) { result in
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        switch result {
        case .success(let text):
            print("OK (\(secs)s) [\(Prefs.backend.rawValue)]\n\(text)")
            if let note = Polisher.fallbackNote { print("NOTE: \(note)") }
        case .failure(let error): print("FAIL (\(secs)s)\n\(error.localizedDescription)")
        }
        done.signal()
    }
    _ = done.wait(timeout: .now() + 120)
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Prefs.showInDock ? .regular : .accessory)   // 설정에 따라 Dock 에 보이거나 메뉴바 전용
app.run()

// MARK: - 상태

enum AppState {
    case idle, recording, polishing, error

    var icon: String {
        switch self {
        case .idle:      return "🎙"
        case .recording: return "🔴"
        case .polishing: return "✨"
        case .error:     return "⚠️"
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    private var statusItem: NSStatusItem!
    private let recorder = SpeechRecorder()
    private var state: AppState = .idle
    private var lastMessage = "준비됨"
    private var lastResult = ""
    private var partialText = ""

    // 팝오버(시안 1a/1b/1c)
    private let model = AppModel()
    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let host = NSHostingController(rootView: PopoverRoot(model: model))
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        return p
    }()

    /// 팝오버 배경(꼬리 포함). NSPopover 는 기본 회색 비주얼 이펙트라 흰 화면과 꼬리 색이 달라 보인다.
    private let popoverBackground: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.paper.cgColor
        return v
    }()
    /// 팝오버 밖을 클릭하면 닫는다. 앱이 활성화되지 않은 상태에선 .transient 만으로는 안 닫힌다.
    private var outsideClickMonitor: Any?
    private var phaseObserver: AnyCancellable?

    let settings = SettingsWindowController()
    /// 첫 실행 설치 안내. 권한을 한 화면에 하나씩 요청한다 (시안 Brefly Onboarding.dc.html).
    let onboarding = OnboardingWindowController()

    /// 요약 요청 세대. 취소하면 올려서 늦게 오는 결과를 버린다.
    private var polishGeneration = 0
    private var pendingRaw = ""
    private var pendingDuration: TimeInterval = 0
    private var pendingReplacing: SummaryRecord?

    /// 손쉬운 사용 권한 감시가 이미 돌고 있는지. 타이머가 여러 개 겹치면 안내가 여러 번 뜬다.
    private var trustWatcherRunning = false

    // 녹음 중 Esc 로 취소. 전역 감시는 다른 앱 위에서도 잡고, 로컬 감시는 팝오버가 키 창일 때 잡는다.
    private var escMonitors: [Any] = []

    /// 녹음을 시작하기 직전에 쓰고 있던 앱. 붙여넣기는 여기로 돌아가야 한다.
    /// 팝오버가 뜨면 Brefly 가 활성 앱이 되므로, 그 전에 잡아 두지 않으면 알 길이 없다.
    private var appBeforeRecording: NSRunningApplication?


    // 녹음 타이머 · 침묵 감지
    private var recordingStartedAt: Date?
    private var recordingTimer: Timer?
    private var lastSpeechAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== Brefly 시작 === 로그: \(Log.url.path)")
        Prefs.migrateFromPreviousNamesIfNeeded()

        NSApp.applicationIconImage = Logo.appIcon()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Logo.menuBarIcon()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        installMainMenu()
        wireModelActions()
        wireSettingsActions()
        Polisher.onStatus = { [weak self] text in self?.model.polishNote = text }
        updateStatusTitle()
        popover.delegate = self

        phaseObserver = model.$phase.receive(on: DispatchQueue.main).sink { [weak self] phase in
            self?.updatePopoverBackground(for: phase)
            self?.applyPopoverStickiness(for: phase)
        }
        NotificationCenter.default.addObserver(forName: .breflyPrefsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.prefsChanged()
        }
        // 단축키를 녹음하는 동안엔 전역 핫키를 풀어 둔다. 같은 조합을 누르면 녹음이 켜져 버린다.
        NotificationCenter.default.addObserver(forName: .breflyHotKeyCaptureBegan, object: nil, queue: .main) { _ in
            HotKey.unregister()
            ModifierHotKey.unregister()
        }
        NotificationCenter.default.addObserver(forName: .breflyHotKeyCaptureEnded, object: nil, queue: .main) { [weak self] _ in
            self?.registerHotKey()
            self?.model.refreshPrefs()
        }

        registerHotKey()
        Log.write("실행 경로: \(Bundle.main.bundlePath)")
        Log.write("자동 붙여넣기: \(Prefs.autoPaste), 접근성 권한: \(Paster.isTrusted)")

        onboarding.onFinish = { [weak self] in
            guard let self else { return }
            self.requestRecorderPermissions()
            self.settings.model.reloadFromPrefs()
            self.model.refreshPrefs()
            Log.write("설치 안내 완료")
        }

        if !Prefs.onboarded {
            // 처음 실행: 마이크·음성 인식 권한 창을 한꺼번에 띄우지 않는다. 설치 안내가 한 단계씩 요청한다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.onboarding.show() }
            return
        }

        requestRecorderPermissions()

        // 새 버전 확인은 실행 직후 소란스럽지 않게 조금 뒤에. 이후 주기는 Sparkle 이 관리한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { Updater.start() }

        // 기본값은 클립보드 복사이므로 권한을 요구하지 않는다.
        // 자동 붙여넣기를 켠 사용자에게만 안내한다.
        if Prefs.autoPaste && !Paster.isTrusted {
            // 실행 직후엔 이미 켜 둔 권한도 false 로 보인다. 알림창을 바로 띄우지 말고 15초 기다렸다가,
            // 그래도 없으면 안내한다. 그 사이 권한이 확인되면 아무 일도 없었던 것처럼 넘어간다.
            // 여기서 권한 요청 창을 바로 띄우면 15초 뒤 안내창과 겹친다. 안내창 하나로만 알린다.
            startTrustWatcher(noticeAfter: 15, notice: { [weak self] in self?.showAccessibilityNotice() })
        }
    }

    /// 이미 허용된 권한은 창 없이 바로 돌아온다. 처음 실행에선 설치 안내가 끝난 뒤에 부른다.
    private func requestRecorderPermissions() {
        SpeechRecorder.requestPermissions { [weak self] result in
            switch result {
            case .success:
                self?.model.micReady = true
            case .failure(let error):
                self?.model.micReady = false
                self?.fail(error.localizedDescription)
            }
        }
    }

    /// 권한이 켜지는 순간을 감지해 메뉴를 갱신한다. AXIsProcessTrusted는 폴링만 가능하다.
    /// - noticeAfter: 이 시간(초)이 지나도 권한이 없으면 그때 안내한다. nil 이면 조용히 기다리기만 한다.
    private func startTrustWatcher(noticeAfter: Int? = nil, notice: (() -> Void)? = nil) {
        guard !trustWatcherRunning else { return }
        trustWatcherRunning = true
        var elapsed = 0
        var notified = false
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            elapsed += 2
            if Paster.isTrusted {
                Log.write("접근성 권한이 허용되었습니다.")
                timer.invalidate()
                self.trustWatcherRunning = false
                self.setState(.idle, message: "접근성 권한 확인됨")
                if Prefs.currentHotKey.isModifierOnly { self.registerHotKey() }
                self.settings.model.refresh()
                return
            }
            if let noticeAfter, !notified, elapsed >= noticeAfter {
                notified = true
                if let notice {
                    notice()
                } else {
                    self.fail("단축키 \(Prefs.currentHotKey.title) 는 손쉬운 사용 권한이 있어야 동작합니다.\n\n\(SystemSettings.accessibilityPath)에서 Brefly 를 켜 주세요. 권한이 켜지면 자동으로 다시 등록합니다.")
                }
            }
            if elapsed > 300 {
                timer.invalidate()
                self.trustWatcherRunning = false
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioDucker.restore()
        HotKey.unregister()
        ModifierHotKey.unregister()
        recorder.cancel()
    }

    // MARK: 단축키

    private func registerHotKey() {
        let combo = Prefs.currentHotKey
        let action: () -> Void = { [weak self] in
            Log.write("단축키 눌림")
            self?.toggle()
        }
        HotKey.unregister()
        ModifierHotKey.unregister()

        if combo.isModifierOnly {
            let ok = ModifierHotKey.register(combo, action: action)
            Log.write("수정자 단축키 \(combo.title) 등록: \(ok)")
            if !ok {
                // 사용자가 이미 권한을 켜 뒀어도 앱이 막 뜬 직후엔 false 로 보인다(번들 ID 가 바뀐 첫 실행에서 14초 걸렸다).
                // 곧바로 오류를 띄우지 말고 감시만 걸어 둔다. 끝내 안 풀리면 startTrustWatcher 가 그때 안내한다.
                startTrustWatcher(noticeAfter: 15)
            }
            return
        }

        let ok = HotKey.register(keyCode: combo.keyCode, modifiers: combo.modifiers & 0xFFFF, action: action)
        Log.write("단축키 \(combo.title) 등록: \(ok)")
        if !ok {
            fail("단축키 \(combo.title) 등록 실패 — 다른 앱이 이미 쓰고 있을 수 있어요.")
        }
    }

    // MARK: 녹음 토글

    @objc private func toggle() {
        recorder.isRunning ? stopAndPolish() : startRecording()
    }

    private func startRecording() {
        do {
            // 팝오버를 띄우기 전에 잡아야 한다. 띄운 뒤엔 Brefly 자신이 최전면이라 늦는다.
            let front = NSWorkspace.shared.frontmostApplication
            appBeforeRecording = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
            Log.write("붙여넣기 대상 기억: \(appBeforeRecording?.localizedName ?? "없음")")
            partialText = ""
            model.resetRecording()
            model.retryRecord = nil
            model.screen = .main
            model.rawExpanded = false
            lastSpeechAt = nil
            AudioDucker.prepare()
            try recorder.start(localeID: Prefs.localeID, onPartial: { [weak self] text in
                guard let self else { return }
                if text != self.partialText { self.lastSpeechAt = Date() }
                self.partialText = text
                self.model.partialText = text
            }, onLevel: { [weak self] level in
                self?.model.pushLevel(level)
            })
            recordingStartedAt = Date()
            installEscMonitor()
            playCue(.start)   // 볼륨을 낮추기 전에
            if Prefs.duckMediaWhileRecording { AudioDucker.duck() }
            startRecordingTimer()
            model.phase = .recording
            setState(.recording, message: "듣는 중…")
            showPopover()
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// 0.25초마다 경과 시간을 올리고, 켜져 있으면 침묵 3초를 감지해 자동으로 끝낸다.
    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStartedAt else { return }
            self.model.elapsed = Date().timeIntervalSince(started)
            self.renderRecordingTitle()

            if Prefs.autoStopOnSilence,
               self.recorder.isRunning,
               !self.partialText.isEmpty,
               let last = self.lastSpeechAt,
               Date().timeIntervalSince(last) >= Prefs.silenceSeconds {
                Log.write("침묵 \(Int(Prefs.silenceSeconds))초 — 자동 요약")
                self.stopAndPolish()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    enum Cue { case start, stop }

    /// 녹음 시작·종료 알림음 "띠딩". 시작은 올라가는 두 음, 종료는 내려가는 두 음(Chime 이 합성).
    private func playCue(_ cue: Cue) {
        guard Prefs.recordingSounds else { return }
        Chime.play(cue == .start ? .start : .stop)
    }

    /// Esc(keyCode 53)를 누르면 녹음을 취소한다. 전역 감시는 이벤트를 삼키지 못하므로 앞 앱에도 Esc 가 전달된다.
    private func installEscMonitor() {
        removeEscMonitor()
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self, event.keyCode == 53, self.recorder.isRunning else { return }
            Log.write("Esc — 녹음 취소")
            self.cancelRecording()
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if event.keyCode == 53 { handler(event); return nil }
            return event
        }) { escMonitors.append(l) }
    }

    private func removeEscMonitor() {
        for m in escMonitors { NSEvent.removeMonitor(m) }
        escMonitors = []
    }

    private func cancelRecording() {
        removeEscMonitor()
        stopRecordingTimer()
        recorder.cancel()
        AudioDucker.restore()
        recordingStartedAt = nil
        model.phase = .idle
        setState(.idle, message: "취소됨")
        popover.performClose(nil)
        Log.write("녹음 취소")
    }

    private func stopAndPolish() {
        removeEscMonitor()
        stopRecordingTimer()
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil
        model.phase = .polishing
        setState(.polishing, message: "정리 중…")

        AudioDucker.restore()
        playCue(.stop)    // 볼륨을 되돌린 뒤에
        recorder.stop { [weak self] transcript, recError in
            guard let self else { return }
            let raw = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("받아쓰기 원문(\(raw.count)자): \(raw)")

            guard !raw.isEmpty else {
                self.handleEmptyTranscript(recError)
                return
            }
            self.polish(raw: raw, duration: duration, replacing: nil)
        }
    }

    /// 원문을 정리해서 전달한다. replacing 이 있으면 그 기록을 새 요약으로 덮어쓴다("다시 요약").
    private func polish(raw: String, duration: TimeInterval, replacing old: SummaryRecord?) {
        polishGeneration += 1
        let generation = polishGeneration
        pendingRaw = raw
        pendingDuration = duration
        pendingReplacing = old
        model.pendingRaw = raw
        model.polishNote = ""

        func record(_ text: String, polished: Bool) -> SummaryRecord {
            var r = old ?? SummaryRecord(title: "", summary: "", raw: raw, date: Date(),
                                         duration: duration, localeID: Prefs.localeID, polished: polished)
            r.summary = text
            r.title = HistoryStore.makeTitle(from: text)
            r.polished = polished
            if old != nil { r.date = Date() }
            return r
        }

        guard Prefs.polishEnabled else {
            deliver(record(raw, polished: false), message: "원문 붙여넣기 완료")
            return
        }

        let startedAt = Date()
        // 억양은 방금 녹음한 소리에서만 잰다. "다시 요약"은 예전 기록이라 없다.
        let intonation = old == nil ? recorder.lastIntonation?.direction : nil
        Polisher.run(raw, intonation: intonation) { result in
            DispatchQueue.main.async {
                guard generation == self.polishGeneration else {
                    Log.write("취소된 요약 결과 무시")
                    return
                }
                let secs = String(format: "%.1f", Date().timeIntervalSince(startedAt))
                switch result {
                case .success(let text):
                    Log.write("Claude 정리 완료(\(text.count)자, \(secs)초)")
                    self.model.doneNote = Polisher.fallbackNote ?? ""
                    self.deliver(record(text, polished: true), message: Polisher.fallbackNote ?? "완료 (\(secs)초)")
                case .failure(let error):
                    // 정리에 실패해도 말한 내용은 버리지 않는다.
                    Log.write("Claude 실패: \(error.localizedDescription)")
                    self.model.doneNote = ""
                    let fallback = record(raw, polished: false)
                    self.deliver(fallback, message: "Claude 정리 실패, 원문 붙여넣음")
                    self.model.retryRecord = fallback
                    self.fail("정리에 실패해서 원문을 그대로 복사했어요\n\n\(error.localizedDescription)")
                }
            }
        }
    }

    private func handleEmptyTranscript(_ recError: Error?) {
        // 아무 말도 안 한 건 오류가 아니다. 인식기는 침묵을 "No speech detected"(kAFAssistantErrorDomain 1110)로
        // 돌려주는데, 이걸 실패로 다루면 오류 창이 뜨고 온디바이스에선 서버 인식으로 영구 전환까지 됐다.
        // 마이크 버퍼가 하나도 안 왔을 때만 진짜 문제로 본다.
        let lowered = (recError?.localizedDescription ?? "").lowercased()
        let noSpeech = recError == nil || lowered.contains("no speech") || (recError as NSError?)?.code == 1110
        if noSpeech && recorder.bufferCount > 0 {
            finishQuietly("말한 내용이 없어요")
            return
        }

        if let recError {
            let detail = recError.localizedDescription

            // macOS 받아쓰기 자체가 꺼져 있는 경우. 서버 인식으로 바꿔도 소용없다.
            if lowered.contains("dictation") || lowered.contains("siri") {
                showDictationDisabledNotice(detail)
                return
            }

            // 온디바이스 모델이 준비 안 된 경우 — 다음 시도는 서버 인식으로.
            if recorder.usingOnDevice {
                Prefs.forceServerRecognition = true
                fail("""
                    온디바이스 음성 인식이 실패했습니다. 다음 시도부터 애플 서버 인식으로 전환합니다. \
                    한 번 더 말해 보세요.

                    원인: \(detail)
                    """)
            } else {
                fail("음성 인식 실패: \(detail)")
            }
        } else {
            fail("""
                인식된 말이 없습니다. 확인해 볼 것:
                • 시스템 설정 > 사운드 > 입력에서 마이크 입력 레벨이 움직이는지
                • 시스템 설정 > 키보드 > 받아쓰기가 켜져 있는지
                • 인식 언어(현재 \(Prefs.localeID))가 실제 말한 언어와 맞는지
                """)
        }
    }

    /// 빈 녹음처럼 알릴 게 없을 때. 오류 화면 없이 대기로 돌아가고 팝오버는 닫는다.
    private func finishQuietly(_ message: String) {
        Log.write("빈 녹음 — \(message) (버퍼 \(recorder.bufferCount)개)")
        partialText = ""
        model.phase = .idle
        setState(.idle, message: message)
        if popover.isShown { popover.performClose(nil) }
    }

    private func deliver(_ record: SummaryRecord, message: String) {
        let text = record.summary
        lastResult = text
        partialText = ""
        model.upsert(record)
        model.rawExpanded = false

        guard Prefs.autoPaste, Paster.isTrusted else {
            if Prefs.copyToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                Log.write("클립보드에 복사 (\(text.count)자)")
            } else {
                Log.write("클립보드 복사 꺼짐 — 기록에만 저장")
            }
            NSSound(named: "Tink")?.play()
            model.phase = .done(record, Prefs.copyToClipboard ? .copied : .viewing)
            setState(.idle, message: Prefs.copyToClipboard ? "\(message) — ⌘V로 붙여넣으세요" : message)
            showResultOrClose()
            return
        }

        // 팝오버가 떠 있으면 Brefly 가 활성 앱이다. 원래 앱으로 초점을 확실히 돌려준 뒤에 붙여넣는다.
        // 고정 시간만 기다리면 초점이 아직 안 돌아온 채로 Cmd+V 를 쏘게 되고, 그러면 아무 데도 안 붙는다.
        let wasActive = NSApp.isActive
        let popoverWasShown = popover.isShown
        Log.write("붙여넣기 준비: Brefly 활성=\(wasActive), 팝오버 열림=\(popoverWasShown), 대상=\(appBeforeRecording?.localizedName ?? "없음"), 현재 최전면=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")

        // ⚠️ 팝오버 닫기를 NSApp.isActive 안에 두면 안 된다.
        // 상태 항목 팝오버는 앱이 "활성"이 아니어도 키 창이 될 수 있고, 그러면 키보드 입력을
        // 팝오버가 받아 삼킨다. 실측: 붙일 때마다 활성=false 라 팝오버를 한 번도 안 닫았고,
        // 그래서 Cmd+V 가 대상 앱에 닿지 않았다. 열려 있으면 활성 여부와 무관하게 먼저 닫는다.
        if popoverWasShown { popover.performClose(nil) }
        if wasActive {
            // 순서가 중요하다. activate() 를 먼저 부르면 뒤이은 hide() 가 초점을 또 옮겨 버린다.
            NSApp.hide(nil)
            appBeforeRecording?.activate()
        }
        let startedAt = Date()
        waitForFocusReturn { returned in
            let waited = Date().timeIntervalSince(startedAt)
            // 최전면이 바뀌었다고 해서 그 앱 안의 입력칸이 곧바로 키보드 초점을 되찾는 건 아니다.
            // 창 전환이 끝나고도 first responder 복원이 한 박자 늦어서, 여유를 두고 쏜다.
            // 팝오버를 닫았으면 키 창이 원래 앱으로 넘어갈 틈이 필요하다.
            let settle: TimeInterval = (wasActive || popoverWasShown) ? 0.35 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                Log.write("붙여넣기: 초점 복귀 \(returned ? "성공" : "실패") — 대기 \(String(format: "%.2f", waited))초 + 여유 \(settle)초")
                self.finishDelivery(text, record: record, message: message, focusReturned: returned)
            }
        }
    }

    /// 원래 쓰던 앱이 다시 최전면이 될 때까지 기다린다. 0.03초마다 확인하고 최대 1초까지만.
    /// 기억해 둔 앱이 없으면(예: 단축키를 눌렀을 때 Brefly 가 이미 앞이었음) 짧게만 쉬고 넘어간다.
    private func waitForFocusReturn(_ done: @escaping (Bool) -> Void) {
        guard NSApp.isActive || appBeforeRecording != nil else { done(true); return }
        guard let target = appBeforeRecording else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { done(!NSApp.isActive) }
            return
        }
        let deadline = Date().addingTimeInterval(1.0)
        func check() {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                done(true)
            } else if Date() >= deadline {
                Log.write("붙여넣기: \(target.localizedName ?? "이전 앱") 으로 초점이 1초 안에 안 돌아옴")
                done(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { check() }
            }
        }
        check()
    }

    /// 초점이 돌아왔으면 붙여넣고, 아니면 클립보드에만 남긴다. 어느 쪽인지 팝오버에도 그대로 알린다.
    private func finishDelivery(_ text: String, record: SummaryRecord, message: String, focusReturned: Bool) {
        var pasted = false
        if focusReturned && !Paster.secureInputOn {
            pasted = Paster.paste(text, restoreClipboard: Prefs.restoreClipboard)
        }
        if !pasted {
            // 붙여넣지 못했으면 최소한 클립보드에는 남겨 둔다. 그래야 ⌘V 로 직접 붙일 수 있다.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let why = Paster.secureInputOn ? "보안 입력 모드가 켜져 있음"
                    : (focusReturned ? "키 이벤트를 만들지 못함" : "초점이 안 돌아옴")
            Log.write("붙여넣기 실패(\(why)) — 클립보드에만 복사 (\(text.count)자)")
        } else {
            let now = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            Log.write("커서 위치에 붙여넣음 (\(text.count)자) — 대상 \(appBeforeRecording?.localizedName ?? "없음"), 붙일 때 최전면 \(now)")
        }
        model.phase = .done(record, pasted ? .pasted : .copied)
        setState(.idle, message: pasted ? message : "\(message) — ⌘V로 붙여넣으세요")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.showResultOrClose() }
    }

    /// 정리가 끝난 뒤. 설정이 꺼져 있으면 정리 중 화면을 닫고 조용히 끝낸다 — 결과는 메뉴바 아이콘을 누르면 본다.
    private func showResultOrClose() {
        if Prefs.showResultPopover {
            showPopover()
        } else if popover.isShown {
            popover.performClose(nil)
        }
    }

    // MARK: Dock · 메인 메뉴

    /// Dock 아이콘을 누르면 메뉴바 아이콘을 누른 것처럼 팝오버를 띄운다.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return false
    }

    /// Dock 에 보이는 동안(.regular) 앱이 활성화되면 메뉴바에 앱 메뉴가 나온다. 비어 있으면 어색하고,
    /// 편집 메뉴가 없으면 설정 창 텍스트 필드에서 ⌘C·⌘V 가 안 먹는다.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "설정…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Brefly 종료", action: #selector(quitApp), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// 설정의 "Dock 에 표시" 를 실행 중에 바꿨을 때. 정책이 같으면 건드리지 않는다(바꾸면 앱이 잠깐 깜빡인다).
    private func applyDockVisibility() {
        let wanted: NSApplication.ActivationPolicy = Prefs.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        Log.write("Dock 표시: \(Prefs.showInDock)")
        // 설정 창이 열려 있는 상태에서 정책을 바꾸면 창이 뒤로 밀린다. 다시 앞으로 가져온다.
        if settings.isVisible { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: 팝오버

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettingsMenu()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.refreshPrefs()
        // 시스템 모드는 메뉴바가 아니라 앱의 현재 모드를 따르게 명시한다 (메뉴바는 배경화면에 따라 다크일 수 있다)
        popover.appearance = Prefs.appearance.nsAppearance
            ?? NSAppearance(named: Prefs.appearance.isDark ? .darkAqua : .aqua)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// 팝오버 프레임 뷰(꼬리 포함)에 단색 배경을 깐다.
    /// 재질(비주얼 이펙트) 아래에 깔면 반투명 재질이 섞여 꼬리와 박스 색이 미묘하게 달라진다.
    /// 그래서 콘텐츠 뷰 바로 아래, 재질 위에 둔다.
    private func installPopoverBackground() {
        guard let window = popover.contentViewController?.view.window,
              let contentView = window.contentView,
              let frameView = contentView.superview else { return }
        if popoverBackground.superview !== frameView {
            popoverBackground.removeFromSuperview()
            popoverBackground.frame = frameView.bounds
            popoverBackground.autoresizingMask = [.width, .height]
            frameView.addSubview(popoverBackground, positioned: .below, relativeTo: contentView)
        }
        updatePopoverBackground(for: model.phase)
    }

    private func updatePopoverBackground(for phase: AppModel.Phase) {
        if case .recording = phase {
            popoverBackground.layer?.backgroundColor = Theme.ink.cgColor
        } else {
            popoverBackground.layer?.backgroundColor = Theme.paperColor(dark: Prefs.appearance.isDark).cgColor
        }
    }

    func popoverDidShow(_ notification: Notification) {
        installPopoverBackground()
        applyPopoverStickiness(for: model.phase)
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    /// 녹음 중·정리 중에는 팝오버를 붙박이로 둔다. 다른 데를 눌러도, 데스크탑을 옮겨도, 전체 화면 앱 위에서도 남는다.
    /// 그 밖의 상태(대기·완료·오류)는 평소 팝오버처럼 밖을 누르면 닫힌다.
    private func applyPopoverStickiness(for phase: AppModel.Phase) {
        let sticky: Bool
        switch phase {
        case .recording, .polishing: sticky = true
        default: sticky = false
        }
        popover.behavior = sticky ? .applicationDefined : .transient
        if let window = popover.contentViewController?.view.window {
            window.collectionBehavior = sticky ? [.canJoinAllSpaces, .fullScreenAuxiliary] : []
        }
        guard popover.isShown else { return }
        if sticky {
            removeOutsideClickMonitor()
        } else if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
    }

    /// 설정 창에서 값이 바뀌었을 때.
    private func prefsChanged() {
        if Prefs.currentHotKey.title != model.hotKeyTitle { registerHotKey() }
        applyDockVisibility()
        if Prefs.autoPaste && !Paster.isTrusted {
            startTrustWatcher()   // 설정을 바꿀 때마다 권한 요청 창을 띄우지 않는다
        }
        model.refreshPrefs()
        settings.model.refresh()
        settings.applyAppearance()
        onboarding.applyAppearance()
        if popover.isShown {
            popover.appearance = Prefs.appearance.nsAppearance
                ?? NSAppearance(named: Prefs.appearance.isDark ? .darkAqua : .aqua)
            updatePopoverBackground(for: model.phase)
        }
    }

    private func wireSettingsActions() {
        settings.model.actions.testPaste = { [weak self] in self?.testPaste() }
        settings.model.actions.testBackend = { [weak self] in self?.testClaude() }
        settings.model.actions.listGeminiModels = { [weak self] in self?.listGeminiModels() }
        settings.model.actions.checkCLI = { [weak self] in self?.checkCLI() }
        settings.model.actions.resetCLIFlags = { [weak self] in self?.resetCLIFlags() }
        settings.model.actions.openLog = { [weak self] in self?.openLog() }
        settings.model.actions.showDiagnostics = { [weak self] in self?.showDiagnostics() }
        settings.model.actions.openDictationSettings = { [weak self] in self?.openDictationSettings() }
        settings.model.actions.openAccessibility = { [weak self] in self?.openAccessibility() }
        settings.model.actions.reopenOnboarding = { [weak self] in self?.onboarding.show() }
        settings.model.actions.checkForUpdates = { Updater.checkManually() }
    }

    /// 상태 아이콘 우클릭 · 팝오버의 "설정…" 에서 기존 설정 메뉴를 띄운다.
    private func showSettingsMenu() {
        rebuildMenu()
        guard let menu = settingsMenu else { return }
        if popover.isShown {
            popover.performClose(nil)
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } else {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        }
    }

    private func wireModelActions() {
        model.actions.startRecording = { [weak self] in self?.startRecording() }
        model.actions.finishRecording = { [weak self] in
            guard let self, self.recorder.isRunning else { return }
            self.stopAndPolish()
        }
        model.actions.cancelRecording = { [weak self] in self?.cancelRecording() }
        model.actions.openSettings = { [weak self] in
            self?.popover.performClose(nil)
            self?.settings.show()
        }
        model.actions.quit = { NSApp.terminate(nil) }
        // 설정 창 모델을 거쳐 바꿔야 설정 창의 '정리 스타일'도 같이 바뀌고 prefsChanged 가 돈다.
        model.actions.setSummary = { [weak self] on in
            self?.settings.model.style = on ? .summary : Prefs.plainStyle
        }
        model.actions.openLog = { [weak self] in self?.openLog() }
        model.actions.cancelPolish = { [weak self] in
            guard let self, case .polishing = self.model.phase else { return }
            self.polishGeneration += 1
            Log.write("요약 취소 — 원문 그대로 전달")
            var r = self.pendingReplacing ?? SummaryRecord(title: "", summary: "", raw: self.pendingRaw, date: Date(),
                                                            duration: self.pendingDuration, localeID: Prefs.localeID, polished: false)
            r.summary = self.pendingRaw
            r.title = HistoryStore.makeTitle(from: self.pendingRaw)
            r.polished = false
            self.deliver(r, message: "요약 취소 — 원문 사용")
        }
        model.actions.copyPendingRaw = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.pendingRaw, forType: .string)
            NSSound(named: "Tink")?.play()
            self.model.polishNote = "원문을 클립보드에 복사했어요 — 요약은 계속 진행 중"
        }
        model.actions.dismissError = { [weak self] in
            self?.model.retryRecord = nil
            self?.model.phase = .idle
            self?.setState(.idle, message: "준비됨")
        }
        model.actions.copy = { [weak self] record in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.summary, forType: .string)
            NSSound(named: "Tink")?.play()
            self?.setState(self?.state ?? .idle, message: "요약을 복사했습니다.")
        }
        model.actions.copyRaw = { record in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.raw, forType: .string)
            NSSound(named: "Tink")?.play()
        }
        model.actions.resummarize = { [weak self] record in
            guard let self else { return }
            self.model.retryRecord = nil
            self.model.phase = .polishing
            self.setState(.polishing, message: "다시 정리 중…")
            self.polish(raw: record.raw, duration: record.duration, replacing: record)
        }
        model.actions.delete = { [weak self] record in
            guard let self else { return }
            self.model.remove(record)
            if case .done(let current, _) = self.model.phase, current.id == record.id {
                self.model.phase = .idle
            }
        }
    }

    // MARK: 상태 표시

    private func setState(_ newState: AppState, message: String) {
        DispatchQueue.main.async {
            self.state = newState
            self.lastMessage = message
            self.updateStatusTitle()
            self.rebuildMenu()
        }
    }

    /// 로그에 남기고, 메뉴 상태 줄에 쓰고, (설정에 따라) 알림창까지 띄운다.
    private func fail(_ message: String) {
        Log.write("실패: \(message)")
        setState(.error, message: message.split(separator: "\n").first.map(String.init) ?? message)
        DispatchQueue.main.async {
            if self.recorder.isRunning { return }   // 녹음 화면을 덮지 않는다
            self.stopRecordingTimer()
            self.model.phase = .error(message)
            self.showPopover()
        }
        guard Prefs.showErrorAlerts else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Brefly"
            alert.informativeText = message
            alert.addButton(withTitle: "확인")
            alert.addButton(withTitle: "로그 열기")
            if alert.runModal() == .alertSecondButtonReturn { self.openLog() }
        }
    }

    /// 메뉴바: 대기는 파형 아이콘만, 녹음 중엔 코랄 점 + 타이머, 정리 중엔 앰버 점.
    private func updateStatusTitle() {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            switch self.state {
            case .idle:
                button.attributedTitle = NSAttributedString(string: "")
            case .recording:
                self.renderRecordingTitle()
            case .polishing:
                button.attributedTitle = NSAttributedString(
                    string: " ●", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold),
                                               .foregroundColor: Theme.amber,
                                               .baselineOffset: 1])
            case .error:
                button.attributedTitle = NSAttributedString(
                    string: " !", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                               .foregroundColor: Theme.coral])
            }
        }
    }

    private func renderRecordingTitle() {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString(
            string: " ●", attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold),
                                       .foregroundColor: Theme.coral,
                                       .baselineOffset: 1])
        title.append(NSAttributedString(
            string: " \(Format.timer(model.elapsed))",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]))
        button.attributedTitle = title
    }

    // MARK: 설정 메뉴 (상태 아이콘 우클릭 · 팝오버 "설정…")

    private var settingsMenu: NSMenu?

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let preset = HotKeyPreset.preset(at: Prefs.hotKeyIndex)
        let toggleTitle = recorder.isRunning ? "받아쓰기 중지" : "받아쓰기 시작"
        let toggleItem = NSMenuItem(title: "\(toggleTitle)  (\(preset.title))",
                                    action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let statusLine = NSMenuItem(title: lastMessage, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let settingsItem = NSMenuItem(title: "설정 창 열기…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if !lastResult.isEmpty {
            let copyItem = NSMenuItem(title: "마지막 결과 다시 복사", action: #selector(copyLast), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        menu.addItem(.separator())

        addRadioSubmenu(to: menu, title: "인식 언어",
                        items: Prefs.locales.map(\.title),
                        selected: Prefs.locales.firstIndex { $0.id == Prefs.localeID } ?? 0,
                        action: #selector(pickLocale(_:)))

        addRadioSubmenu(to: menu, title: "정리 스타일",
                        items: PolishStyle.allCases.map(\.title),
                        selected: PolishStyle.allCases.firstIndex(of: Prefs.style) ?? 0,
                        action: #selector(pickStyle(_:)))

        addRadioSubmenu(to: menu, title: "단축키",
                        items: HotKeyPreset.all.map(\.title),
                        selected: Prefs.hotKeyIndex,
                        action: #selector(pickHotKey(_:)))

        addRadioSubmenu(to: menu, title: "AI 모델",
                        items: Prefs.Backend.allCases.map(\.title),
                        selected: Prefs.Backend.allCases.firstIndex(of: Prefs.backend) ?? 0,
                        action: #selector(pickBackend(_:)))

        switch Prefs.backend {
        case .gemini, .auto:
            addRadioSubmenu(to: menu, title: "Gemini 모델",
                            items: Prefs.geminiModels,
                            selected: Prefs.geminiModels.firstIndex(of: Prefs.geminiModel) ?? 0,
                            action: #selector(pickGeminiModel(_:)))
        case .apple:
            break
        case .api, .cli:
            addRadioSubmenu(to: menu, title: "Claude 모델",
                            items: Prefs.models,
                            selected: Prefs.models.firstIndex(of: Prefs.model) ?? 0,
                            action: #selector(pickModel(_:)))
        }

        menu.addItem(.separator())

        addCheckItem(to: menu, title: "AI로 정리하기",
                     on: Prefs.polishEnabled, action: #selector(togglePolish))
        addCheckItem(to: menu, title: "커서 위치에 자동 붙여넣기 (접근성 권한 필요)",
                     on: Prefs.autoPaste, action: #selector(toggleAutoPaste))
        if Prefs.autoPaste {
            addCheckItem(to: menu, title: "붙여넣기 후 클립보드 복원",
                         on: Prefs.restoreClipboard, action: #selector(toggleRestore))
        }
        addCheckItem(to: menu, title: "말을 멈추고 3초 뒤 자동 요약",
                     on: Prefs.autoStopOnSilence, action: #selector(toggleAutoStop))
        addCheckItem(to: menu, title: "실패 시 시스템 알림창도 띄우기",
                     on: Prefs.showErrorAlerts, action: #selector(toggleAlerts))
        addCheckItem(to: menu, title: "음성 인식을 애플 서버에서 처리",
                     on: Prefs.forceServerRecognition, action: #selector(toggleServerRecognition))

        switch Prefs.backend {
        case .gemini, .auto:
            let g = NSMenuItem(title: "Gemini API 키 설정…", action: #selector(setGeminiKey), keyEquivalent: "")
            g.target = self
            menu.addItem(g)
            if KeychainStore.read(.gemini)?.isEmpty != false {
                let hint = NSMenuItem(title: "   ↳ aistudio.google.com/apikey 에서 무료 발급", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
        case .apple:
            let note = NSMenuItem(title: "   ↳ \(AppleClient.availability().note)", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        case .api, .cli:
            let keyItem = NSMenuItem(title: "Claude API 키 설정…", action: #selector(setAPIKey), keyEquivalent: "")
            keyItem.target = self
            menu.addItem(keyItem)
        }

        menu.addItem(.separator())

        // 진단
        let diagMenu = NSMenu()
        for (title, sel) in [("붙여넣기 테스트", #selector(testPaste)),
                             ("AI 모델 연결 테스트", #selector(testClaude)),
                             ("Gemini 모델 목록", #selector(listGeminiModels)),
                             ("Claude Code CLI 확인", #selector(checkCLI)),
                             ("CLI 경로 직접 지정…", #selector(setCLIPath)),
                             ("받아쓰기 설정 열기", #selector(openDictationSettings)),
                             ("CLI 플래그 캐시 초기화", #selector(resetCLIFlags)),
                             ("로그 열기", #selector(openLog)),
                             ("현재 상태 진단", #selector(showDiagnostics))] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            diagMenu.addItem(item)
        }
        let diagRoot = NSMenuItem(title: "진단", action: nil, keyEquivalent: "")
        diagRoot.submenu = diagMenu
        menu.addItem(diagRoot)

        if Prefs.autoPaste && !Paster.isTrusted {
            let axItem = NSMenuItem(title: "⚠️ 접근성 권한 허용하기…", action: #selector(openAccessibility), keyEquivalent: "")
            axItem.target = self
            menu.addItem(axItem)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "종료", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        settingsMenu = menu
        model.refreshPrefs()
    }

    private func addRadioSubmenu(to menu: NSMenu, title: String,
                                 items: [String], selected: Int, action: Selector) {
        let sub = NSMenu()
        for (i, label) in items.enumerated() {
            let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = (i == selected) ? .on : .off
            sub.addItem(item)
        }
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.submenu = sub
        menu.addItem(root)
    }

    private func addCheckItem(to menu: NSMenu, title: String, on: Bool, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    // MARK: 설정 액션

    @objc private func pickLocale(_ sender: NSMenuItem) {
        Prefs.localeID = Prefs.locales[sender.tag].id
        setState(state, message: "인식 언어: \(Prefs.locales[sender.tag].title)")
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        Prefs.style = PolishStyle.allCases[sender.tag]
        setState(state, message: "정리 스타일: \(Prefs.style.title)")
    }

    @objc private func pickHotKey(_ sender: NSMenuItem) {
        Prefs.hotKeyIndex = sender.tag
        registerHotKey()
        setState(state, message: "단축키: \(HotKeyPreset.preset(at: sender.tag).title)")
    }

    @objc private func pickBackend(_ sender: NSMenuItem) {
        Prefs.backend = Prefs.Backend.allCases[sender.tag]
        setState(state, message: "AI 모델: \(Prefs.backend.title)")
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        Prefs.model = Prefs.models[sender.tag]
        setState(state, message: "모델: \(Prefs.model)")
    }

    @objc private func pickGeminiModel(_ sender: NSMenuItem) {
        Prefs.geminiModel = Prefs.geminiModels[sender.tag]
        setState(state, message: "Gemini 모델: \(Prefs.geminiModel)")
    }

    @objc private func setGeminiKey() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Gemini API 키"
        alert.informativeText = """
            aistudio.google.com/apikey 에서 무료로 발급받을 수 있습니다. 카드 등록 필요 없습니다.
            Flash-Lite 기준 분당 15회 / 하루 1,000회까지 무료입니다.

            키는 \\(KeychainStore.storageDescription) 에 저장됩니다.
            """
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "발급 페이지 열기")
        alert.addButton(withTitle: "취소")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.placeholderString = "AIza..."
        field.stringValue = KeychainStore.read(.gemini) ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let ok = KeychainStore.write(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                         to: .gemini)
            setState(.idle, message: ok ? "Gemini 키를 저장했습니다." : "키체인 저장에 실패했습니다.")
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://aistudio.google.com/apikey") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    @objc private func listGeminiModels() {
        setState(state, message: "Gemini 모델 목록 조회 중…")
        GeminiClient.shared.listModels { result in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                switch result {
                case .success(let names):
                    Log.write("Gemini 모델 \(names.count)개")
                    alert.messageText = "사용 가능한 Gemini 모델 (\(names.count)개)"
                    alert.informativeText = names.joined(separator: "\n")
                    alert.addButton(withTitle: "복사")
                    alert.addButton(withTitle: "닫기")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(names.joined(separator: "\n"), forType: .string)
                    }
                case .failure(let error):
                    self.fail("Gemini 모델 목록 조회 실패\n\n\(error.localizedDescription)")
                }
                self.setState(.idle, message: "준비됨")
            }
        }
    }

    @objc private func togglePolish() {
        Prefs.polishEnabled.toggle()
        setState(state, message: Prefs.polishEnabled ? "Claude 정리 켬" : "Claude 정리 끔 (원문 그대로)")
    }

    @objc private func toggleAutoPaste() {
        Prefs.autoPaste.toggle()
        Log.write("자동 붙여넣기: \(Prefs.autoPaste)")

        guard Prefs.autoPaste else {
            setState(.idle, message: "클립보드 복사만 합니다 — ⌘V로 붙여넣으세요")
            return
        }
        if Paster.isTrusted {
            setState(.idle, message: "커서 위치에 자동 붙여넣습니다")
        } else {
            startTrustWatcher()
            setState(.idle, message: "접근성 권한을 허용해 주세요")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                self.showAccessibilityNotice()
            }
        }
    }

    @objc private func toggleRestore() {
        Prefs.restoreClipboard.toggle()
        rebuildMenu()
    }

    @objc private func toggleAlerts() {
        Prefs.showErrorAlerts.toggle()
        rebuildMenu()
    }

    @objc private func toggleAutoStop() {
        Prefs.autoStopOnSilence.toggle()
        setState(state, message: Prefs.autoStopOnSilence ? "침묵 3초 뒤 자동 요약" : "단축키로만 요약")
    }

    @objc private func toggleServerRecognition() {
        Prefs.forceServerRecognition.toggle()
        setState(state, message: Prefs.forceServerRecognition ? "애플 서버 인식 사용" : "온디바이스 인식 우선")
    }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastResult, forType: .string)
        setState(state, message: "클립보드에 복사했습니다.")
    }

    @objc private func setAPIKey() {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Claude API 키"
        alert.informativeText = "console.anthropic.com 에서 발급한 키를 붙여 넣으세요. 키는 \\(KeychainStore.storageDescription) 에 저장됩니다."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-..."
        field.stringValue = KeychainStore.readAPIKey() ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let ok = KeychainStore.writeAPIKey(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            setState(.idle, message: ok ? "API 키를 저장했습니다." : "키체인 저장에 실패했습니다.")
        }
    }

    // MARK: 진단 액션

    @objc private func testPaste() {
        guard Prefs.autoPaste else {
            fail("자동 붙여넣기가 꺼져 있습니다. 지금은 결과가 클립보드에만 복사됩니다.\n메뉴에서 '커서 위치에 자동 붙여넣기'를 켜면 이 테스트를 쓸 수 있습니다.")
            return
        }
        guard Paster.isTrusted else {
            fail("접근성 권한이 없어 자동 붙여넣기를 할 수 없습니다.\n\(SystemSettings.accessibilityPath)에서 Brefly를 켜세요.")
            return
        }
        setState(.idle, message: "3초 뒤 붙여넣습니다 — 텍스트 필드를 클릭하세요.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Paster.paste("Brefly 붙여넣기 테스트", restoreClipboard: Prefs.restoreClipboard)
        }
    }

    @objc private func testClaude() {
        setState(.polishing, message: "Claude 연결 확인 중…")
        Polisher.run("어 그 테스트 입니다 음 잘 되나요") { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    self.setState(.idle, message: "Claude 정상: \(text)")
                    NSApp.activate(ignoringOtherApps: true)
                    let a = NSAlert()
                    a.messageText = "연결 정상 — \(Prefs.backend.title)"
                    a.informativeText = "보낸 원문: 어 그 테스트 입니다 음 잘 되나요\n정리 결과: \(text)"
                    a.runModal()
                case .failure(let e):
                    self.fail("AI 모델 연결 실패 (\(Prefs.backend.title))\n\n\(e.localizedDescription)")
                }
            }
        }
    }

    @objc private func checkCLI() {
        setState(state, message: "CLI 확인 중…")
        CLIClient.shared.status { info in
            DispatchQueue.main.async {
                Log.write("CLI 상태\n\(info)")
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Claude Code CLI"
                alert.informativeText = info
                alert.addButton(withTitle: "복사")
                alert.addButton(withTitle: "닫기")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info, forType: .string)
                }
                self.setState(.idle, message: "준비됨")
            }
        }
    }

    @objc private func setCLIPath() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "claude 실행 파일 경로"
        alert.informativeText = "터미널에서 `which claude`로 확인한 경로를 넣으세요. 비워 두면 자동으로 찾습니다."
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.placeholderString = CLIClient.resolveExecutable() ?? "/Users/이름/.local/bin/claude"
        field.stringValue = Prefs.cliPath ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        if alert.runModal() == .alertFirstButtonReturn {
            let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Prefs.cliPath = path.isEmpty ? nil : path
            setState(.idle, message: "CLI 경로: \(CLIClient.resolveExecutable() ?? "못 찾음")")
        }
    }

    @objc private func resetCLIFlags() {
        Prefs.unsupportedCLIFlags = []
        setState(.idle, message: "CLI 플래그 캐시를 지웠습니다. 다음 호출에서 다시 탐색합니다.")
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.url)
    }

    @objc private func showDiagnostics() {
        let rec = SFSpeechRecognizer(locale: Locale(identifier: Prefs.localeID))
        let info = """
            인식 언어: \(Prefs.localeID)
            recognizer 사용 가능: \(rec?.isAvailable.description ?? "생성 실패")
            온디바이스 지원: \(rec?.supportsOnDeviceRecognition.description ?? "-")
            애플 서버 인식: \(Prefs.forceServerRecognition)
            음성 인식 권한: \(SFSpeechRecognizer.authorizationStatus().rawValue) (3 = 허용)
            마이크 권한: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = 허용)
            접근성 권한: \(Paster.isTrusted)
            AI 모델: \(Prefs.backend.title)
            Gemini 키 저장됨: \(KeychainStore.read(.gemini)?.isEmpty == false)
            Gemini 모델: \(Prefs.geminiModel)
            Anthropic 키 저장됨: \(KeychainStore.read(.anthropic)?.isEmpty == false)
            claude CLI 경로: \(CLIClient.resolveExecutable() ?? "못 찾음")
            Claude 모델: \(Prefs.model)
            로그: \(Log.url.path)
            """
        Log.write("진단\n\(info)")

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Brefly 진단"
        alert.informativeText = info
        alert.addButton(withTitle: "복사")
        alert.addButton(withTitle: "닫기")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info, forType: .string)
        }
    }

    /// macOS 받아쓰기가 꺼져 있으면 어떤 인식 방식도 동작하지 않는다.
    private func showDictationDisabledNotice(_ detail: String) {
        Log.write("받아쓰기 비활성 상태: \(detail)")
        setState(.error, message: "macOS 받아쓰기가 꺼져 있습니다.")

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "macOS 받아쓰기를 켜 주세요"
            alert.informativeText = """
                Brefly는 애플 음성 인식 엔진을 씁니다. 시스템의 받아쓰기 기능이 꺼져 있으면 \
                온디바이스든 서버든 인식이 되지 않습니다.

                시스템 설정 > 키보드 > 받아쓰기를 켜고,
                받아쓰기 언어에 한국어가 있는지 확인하세요.

                켠 뒤에는 다시 설정할 것 없이 바로 단축키를 누르면 됩니다.

                (원본 오류: \(detail))
                """
            alert.addButton(withTitle: "키보드 설정 열기")
            alert.addButton(withTitle: "닫기")
            if alert.runModal() == .alertFirstButtonReturn {
                self.openDictationSettings()
            }
        }
    }

    @objc private func openDictationSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard"
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func openAccessibility() {
        Paster.sendToSettings { SystemSettings.open(.accessibility) }
    }

    private func showAccessibilityNotice() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "접근성 권한이 필요합니다"
        alert.informativeText = """
            커서 위치에 텍스트를 자동으로 붙여 넣으려면 접근성 권한이 필요합니다.

            \(SystemSettings.accessibilityPath)에서 Brefly를 켜 주세요.
            이미 켜져 있는데도 이 창이 뜨면, Brefly 를 목록에서 '−'로 지우고 다시 추가해 주세요. 앱을 새로 설치하면
            macOS 가 다른 앱으로 볼 때가 있습니다.

            목록에 Brefly가 안 보이면 '+' 버튼을 누르고 ⌘⇧G로 아래 경로를 붙여넣어 직접 추가하세요:
            \(Bundle.main.bundlePath)

            권한 없이도 결과는 클립보드에 복사되니 ⌘V로 붙여넣을 수 있습니다.
            """
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "앱 경로 복사")
        alert.addButton(withTitle: "나중에")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibility()
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Bundle.main.bundlePath, forType: .string)
            setState(state, message: "앱 경로를 클립보드에 복사했습니다.")
        default:
            break
        }
    }

    @objc private func openSettingsWindow() {
        settings.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
