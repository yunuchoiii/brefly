import AppKit
import SwiftUI

/// `Brefly --render-previews <dir>` 로 실행하면 팝오버 각 상태와 아이콘을 PNG로 저장하고 끝난다.
/// 실제 NSHostingView로 그리므로 팝오버에 뜨는 화면과 같은 코드 경로다. 화면 확인·시안 대조용.
enum PreviewRenderer {

    static func run(outputDir: String) {
        KeychainStore.stub = [.gemini: "preview-gemini-key-not-real-0000", .anthropic: ""]   // 구글 키 형식(AIza…)을 피한다 — GitHub 시크릿 스캐너가 가짜 값을 잡았다
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = Date()
        // 첫 기록은 README 캡처로 쓰인다. 앱이 실제로 내는 결과만 넣는다 — 전에 시안의 가짜 제목·불릿을 넣었다가
        // 사용자가 "요약을 전혀 안 하는데 사기 아니냐"고 했다. 아래는 이 원문을 '핵심 요약' 스타일·Haiku 로
        // 돌린 출력 그대로다(2026-09-25). 제목도 앱과 같은 코드로 뽑는다.
        let doneSummary = "- 온보딩 첫 화면: 설명 제거, 마이크 버튼 누르도록 유도\n- 단축키 안내: 처음 한 번만 표시\n- 다음 주까지 시안 2개 준비, 금요일 리뷰"
        let samples = [
            SummaryRecord(title: HistoryStore.makeTitle(from: doneSummary),
                          summary: doneSummary,
                          raw: "그래서 온보딩 첫 화면은 지금처럼 설명을 길게 쓰지 말고, 사용자가 바로 마이크 버튼을 누르게 유도하는 게 좋을 것 같고요, 아 그리고 아까 말했던 단축키 안내도 매번 보여줄 필요는 없고 처음 한 번만… 아 맞다, 다음 주까지 시안 두 개 준비해서 금요일에 리뷰하죠.",
                          date: now.addingTimeInterval(-14 * 60), duration: 160, localeID: "ko-KR", polished: true),
            SummaryRecord(title: "아이디어 메모 — 신규 온보딩 개선안",
                          summary: "신규 온보딩 개선안입니다.", raw: "신규 온보딩 개선안 어쩌구",
                          date: Calendar.current.date(bySettingHour: 11, minute: 2, second: 0, of: now)!,
                          duration: 72, localeID: "ko-KR", polished: true),
            SummaryRecord(title: "Weekly sync recap — follow-ups",
                          summary: "Follow-ups from weekly sync.", raw: "so the weekly sync follow ups are",
                          date: now.addingTimeInterval(-26 * 3600), duration: 245, localeID: "en-US", polished: true)
        ]

        let model = AppModel()
        model.history = samples
        model.micReady = true
        model.hotKeyTitle = "⌥ Space"
        model.backendTitle = Prefs.Backend.gemini.title

        func snap(_ name: String) {
            let image = render(PopoverRoot(model: model))
            write(image, to: dir.appendingPathComponent("\(name).png"))
        }

        model.phase = .idle
        snap("1a-idle")

        model.phase = .recording
        model.elapsed = 47
        model.levels = [0.95, 0.8, 0.62, 0.5, 0.4, 0.33, 0.28, 0.22, 0.16, 0.12, 0.08]
        model.partialText = samples[0].raw.prefix(150) + " 그리고 아까 말했던 단축키 안내도"
        snap("1b-recording")
        model.notice = "회의 녹음은 받아쓰기를 마친 뒤 시작할 수 있어요."
        snap("1b-recording-blocked")
        model.notice = nil

        model.phase = .done(samples[0], .copied)
        model.rawExpanded = false
        snap("1c-done")
        model.rawExpanded = true
        snap("1c-done-expanded")

        // 요약을 못 하고 온디바이스로 문장만 다듬었을 때
        var fallback = samples[0]
        fallback.summary = "다음 스프린트는 로그인 개선을 먼저 하구요. 결제가 더 급하니까 결제 먼저 하죠. 디자인은 목요일까지 받기로 했습니다."
        fallback.title = HistoryStore.makeTitle(from: fallback.summary)
        model.doneNote = "요약할 AI 모델이 응답하지 않아 이 맥에서 문장만 다듬었어요"
        model.phase = .done(fallback, .copied)
        model.rawExpanded = false
        snap("1c-done-fallback")
        model.doneNote = ""

        model.phase = .done(samples[0], .viewing)
        model.rawExpanded = false
        snap("1c-viewing")

        model.phase = .polishing
        model.pendingRaw = samples[0].raw
        model.polishNote = "gemini-3.1-flash-lite 응답이 늦어 gemini-3.6-flash 에도 요청 중…"
        snap("polishing")

        // 회의록 처리 중. 받아쓰기(1단계)와 요약(2단계)을 각각 본다 — 단계마다 표시가 달라진다.
        model.phase = .meeting(AppModel.MeetingRun(
            fileName: "주간 기획 회의.m4a", audioSeconds: 2112,
            startedAt: Date().addingTimeInterval(-34), stage: .transcribing, fraction: 0.42))
        snap("1d-meeting-transcribing")

        model.phase = .meeting(AppModel.MeetingRun(
            fileName: "주간 기획 회의.m4a", audioSeconds: 2112,
            startedAt: Date().addingTimeInterval(-96), stage: .summarizing, fraction: nil))
        snap("1d-meeting-summarizing")

        // 회의록 탭. 시작 방법 셋과 최근 목록이 보여야 한다.
        model.meetingHistory = [
            // 제목은 회의록 `한 줄 요약` 에서 뽑아 40자에서 자른다. 목록에서 잘리는 모습을 봐야 한다.
            MeetingRecord(id: "a", title: "출시 일정 확정과 설치 안내 정리",
                          date: Date().addingTimeInterval(-86400), kind: .videoCall,
                          seconds: 2112, todoCount: 3, notesPath: "/tmp/a.md", audioPath: "/tmp/a.m4a"),
            MeetingRecord(id: "b", title: "고객 인터뷰 — 3차",
                          date: Date().addingTimeInterval(-86400 * 5), kind: .file,
                          seconds: 3120, todoCount: 0, notesPath: "/tmp/b.md", audioPath: "/tmp/b.m4a"),
        ]
        // ⚠️ 앞 단계에서 phase 가 남아 있으면 그 화면이 이긴다. 대기로 돌려놓고 찍는다.
        model.phase = .idle
        model.tab = .meeting
        snap("1f-meeting-tab")
        // "녹음본에서 추출" 칸은 모드마다 회색이 달라진다. 어두운 쪽도 찍어야 대비를 본다 —
        // 전에 밝은 회색 칩이 어두운 배경에서 안 보인 적이 있다.
        write(render(PopoverRoot(model: model), dark: true),
              to: dir.appendingPathComponent("dark-1f-meeting-tab.png"))
        model.tab = .dictation

        // 회의를 지금 녹음하는 중. 시스템 소리를 못 잡는 경우도 같이 본다 —
        // 그때는 화상회의에서 내 말만 남으므로 경고가 보여야 한다.
        model.micName = "MacBook Pro 마이크"
        model.phase = .meetingRecording(AppModel.MeetingRecordingRun(
            startedAt: Date().addingTimeInterval(-372), capturingSystem: true, inPerson: false))
        snap("1e-meeting-recording-video")
        // 화면 기록 권한이 없어 상대 목소리를 못 잡는 모습. 모르고 회의를 다 녹음하면 되돌릴 수 없다.
        model.phase = .meetingRecording(AppModel.MeetingRecordingRun(
            startedAt: Date().addingTimeInterval(-372), capturingSystem: false, inPerson: false))
        snap("1e-meeting-recording-no-system")
        model.phase = .meetingRecording(AppModel.MeetingRecordingRun(
            startedAt: Date().addingTimeInterval(-372), capturingSystem: false, inPerson: true))
        snap("1e-meeting-recording-in-person")
        // 회의 중 받아쓰기 단축키를 눌렀을 때. 막았다는 것이 **화면에** 보여야 한다 —
        // 메뉴바 글자만으로는 눌러도 아무 일 없는 것으로 읽힌다.
        model.notice = "회의를 녹음하는 동안에는 받아쓰기를 쓸 수 없어요."
        snap("1e-meeting-recording-blocked")
        model.notice = nil
        // 하이라이트 두 곳을 남긴 모습과, 지금 켜 둔 모습. 시안 2a 의 나머지 두 상태다.
        model.highlightCount = 2
        snap("1e-meeting-recording-marks")
        model.highlightOn = true
        model.highlightStartedAt = Date().addingTimeInterval(-7)
        snap("1e-meeting-recording-highlighting")
        model.highlightOn = false
        model.highlightStartedAt = nil
        model.highlightCount = 0

        model.retryRecord = samples[0]
        model.phase = .error("정리에 실패해서 원문을 그대로 복사했어요\n\n"
            + APIErrorText.describe(service: "Gemini", code: 503,
                                    body: #"{"error":{"code":503,"message":"This model is currently experiencing high demand. Spikes in demand are usually temporary. Please try again later.","status":"UNAVAILABLE"}}"#))
        snap("error")
        model.retryRecord = nil

        model.phase = .idle
        model.screen = .history
        snap("history")

        model.screen = .main
        model.history = []
        snap("1a-idle-empty")

        // 회의록 결과 창. 팝오버가 아니라 일반 창이라 크기를 못 박아 그린다.
        let sampleNotes = """
        ## 제목
        출시 일정 확정과 설치 안내 정리

        ## 한 줄 요약
        출시 일정을 그대로 두고, 설치 안내는 단계를 늘리지 않는 쪽으로 정리하기로 했다.

        ## 결정된 것
        - 다음 달 14일 출시 일정 유지
        - 설치 안내에 새 단계를 추가하지 않음

        ## 할 일
        - 처리 중 화면 시안 확정
        - 내려받기 안내 문구 검토

        ## 논의한 것
        - 처리 중에 창을 닫으면 멈춘 것처럼 보인다는 의견
        """
        let sampleSegments: [Whisper.Segment] = [
            .init(text: "자, 그럼 시작하겠습니다. 오늘은 두 가지만 보면 될 것 같아요.", start: 0, end: 4.2),
            .init(text: "출시는 그대로 가는 거죠? 회의록 기능까지 포함해서요.", start: 42, end: 46.5),
            .init(text: "네, 그건 확정이고요. 문제는 처리 중 화면입니다.", start: 75, end: 79.1),
            .init(text: "창을 닫으면 아무것도 안 보여서 멈춘 줄 아시더라고요.", start: 123, end: 127.4),
        ]
        // 화상 회의라 화자가 붙는다. 붙은 모습을 시안에서 보고 넘어가야 한다.
        let labelled = sampleSegments.enumerated().map { i, s in
            Whisper.Segment(text: s.text, start: s.start, end: s.end, speaker: i % 2 == 0 ? "상대" : "나")
        }
        let sampleDoc = MeetingDocument(
            // 제목은 이제 날짜가 아니라 `한 줄 요약` 첫 문장이다. 시안도 실제로 뽑아 쓴다.
            title: MeetingHistoryStore.titleFromNotes(sampleNotes) ?? "주간 기획 회의", audio: URL(fileURLWithPath: "/Users/me/문서/회의/주간 기획 회의.m4a"),
            notesFile: URL(fileURLWithPath: "/Users/me/문서/회의/주간 기획 회의 회의록.md"),
            // 앱은 `## 제목` 을 떼고 저장한다(제목은 창 머리에 있다). 시안도 같아야 한다.
            recordedAt: Date(), duration: 2112,
            notes: MeetingHistoryStore.stripTitleSection(sampleNotes), segments: labelled,
            transcript: labelled.map { "\($0.speaker ?? ""): \($0.text)" }.joined(separator: "\n"),
            speakersKnown: true,
            usedModel: ("ChatGPT", "gpt-5.5"),
            highlightCount: 3)
        // 요약만 실패한 모습. 이 화면이 없으면 사용자는 다 잃은 줄 안다.
        var failedDoc = sampleDoc
        failedDoc.summaryFailed = "요약에 실패했습니다 (503). This model is currently experiencing high demand."
        failedDoc.notes = MeetingNotes.transcriptOnlyNotes(sampleDoc.transcript,
                                                          error: MeetingNotes.Failure.badResponse(503, ""))
        write(render(MeetingResultView(document: failedDoc).frame(width: 820, height: 600)),
              to: dir.appendingPathComponent("3b-meeting-summary-failed.png"))
        write(render(MeetingResultView(document: sampleDoc).frame(width: 820, height: 600)),
              to: dir.appendingPathComponent("3-meeting-result.png"))
        write(render(MeetingResultView(document: sampleDoc).frame(width: 820, height: 600), dark: true),
              to: dir.appendingPathComponent("dark-3-meeting-result.png"))

        let settings = SettingsModel()
        settings.usageContexts = [.devFrontend, .devMobile]
        settings.showOnboarding = true
        for tab in SettingsModel.Tab.allCases {
            settings.tab = tab
            write(render(SettingsView(model: settings)), to: dir.appendingPathComponent("2-settings-\(tab.rawValue).png"))
        }

        // 다크 모드
        model.screen = .main
        model.history = samples
        model.phase = .idle
        write(render(PopoverRoot(model: model), dark: true), to: dir.appendingPathComponent("dark-1a-idle.png"))
        model.phase = .done(samples[0], .copied)
        write(render(PopoverRoot(model: model), dark: true), to: dir.appendingPathComponent("dark-1c-done.png"))
        settings.tab = .general
        write(render(SettingsView(model: settings), dark: true), to: dir.appendingPathComponent("dark-2-settings-general.png"))

        settings.showOnboarding = false
        write(render(PersonalPane(model: settings).padding(20).frame(width: 620).background(Color.paperSoft)),
              to: dir.appendingPathComponent("2-settings-personal-full.png"))
        write(render(GeneralPane(model: settings).padding(20).frame(width: 620).background(Color.paperSoft)),
              to: dir.appendingPathComponent("2-settings-general-full.png"))
        write(render(AdvancedPane(model: settings).padding(20).frame(width: 620).background(Color.paperSoft)),
              to: dir.appendingPathComponent("2-settings-advanced-full.png"))
        // 단축키 탭도 회의록 묶음이 붙어 한 화면을 넘는다.
        write(render(HotKeyPane(model: settings).padding(20).frame(width: 620).background(Color.paperSoft)),
              to: dir.appendingPathComponent("2-settings-hotkey-full.png"))
        // 정리 스타일이 라디오 목록이 되면서 인식 탭이 한 화면을 넘는다. 전체를 봐야 확인이 된다.
        write(render(RecognitionPane(model: settings).padding(20).frame(width: 620).background(Color.paperSoft)),
              to: dir.appendingPathComponent("2-settings-recognition-full.png"))

        // 설치 안내 (시안 Brefly Onboarding.dc.html 의 아트보드 이름을 그대로 쓴다)
        func wizard(_ name: String, dark: Bool = false, apple: AppleClient.Status = .available, _ setup: (OnboardingModel) -> Void) {
            let m = OnboardingModel(previewMode: true, appleStatus: apple)
            setup(m)
            write(render(OnboardingView(model: m), dark: dark), to: dir.appendingPathComponent("3-onboarding-\(name).png"))
        }
        wizard("W0-welcome") { _ in }
        wizard("W1-mic-idle") { $0.step = .mic }
        wizard("W1-mic-requesting") { $0.step = .mic; $0.mic = .requesting }
        wizard("W1-mic-granted") { $0.step = .mic; $0.mic = .granted }
        wizard("W1-mic-denied") { $0.step = .mic; $0.mic = .denied }
        wizard("W2-speech-idle") { $0.step = .speech }
        wizard("W2-speech-granted-dictation-off") { $0.step = .speech; $0.speech = .granted }
        wizard("W2-speech-granted-dictation-unknown") { $0.step = .speech; $0.speech = .granted; $0.dictationEnabled = nil }
        wizard("W2-speech-done") { $0.step = .speech; $0.speech = .granted; $0.dictationEnabled = true }
        wizard("W3-model-A") { $0.step = .model }
        wizard("W3-model-B-empty", apple: .unsupportedOS) { $0.step = .model }
        wizard("W3-model-B-verified", apple: .unsupportedOS) { $0.step = .model; $0.keyVerified = true }
        wizard("W3-model-C-not-enabled", apple: .notEnabled) { $0.step = .model }
        wizard("W3-model-C-downloading", apple: .downloading) { $0.step = .model }
        wizard("W3-model-C-key-verified", apple: .notEnabled) { $0.step = .model; $0.keyVerified = true }
        wizard("W4-hotkey-default") { $0.step = .hotkey }
        wizard("W4-hotkey-recording") { $0.step = .hotkey; $0.recording = true }
        wizard("W4-hotkey-modifier-only") { $0.step = .hotkey; $0.presetIndex = nil; $0.hotKeyTitle = "fn⌃"; $0.hotKeyIsModifierOnly = true }
        wizard("W5-paste-default") { $0.step = .paste }
        wizard("W5-paste-waiting") { $0.step = .paste; $0.autoPaste = true }
        wizard("W5-paste-granted") { $0.step = .paste; $0.autoPaste = true; $0.accessibilityTrusted = true }
        wizard("W6-fields") { $0.step = .fields; $0.usageContexts = [.meeting, .devFrontend] }
        wizard("W7-done") { $0.step = .done }
        wizard("W0-welcome-dark", dark: true) { _ in }
        wizard("W1-mic-idle-dark", dark: true) { $0.step = .mic }

        let strip = HStack(spacing: 24) {
            ForEach([10.0, 30.0, 44.0, 60.0, 70.0, 85.0], id: \.self) { f in
                VStack(spacing: 6) {
                    BreflyLoader(size: 56, fixedFrame: f)
                    Text("\(Int(f))f").font(.system(size: 10)).foregroundColor(.text3)
                }
            }
        }.padding(20).background(Color.paper)
        write(render(strip), to: dir.appendingPathComponent("loader-frames.png"))

        write(Logo.appIcon(size: 256), to: dir.appendingPathComponent("app-icon.png"))
        write(Logo.mark(size: 72, wave: Theme.ink, dot: Theme.coral), to: dir.appendingPathComponent("logo-mark.png"))
        let menubar = Logo.menuBarIcon()
        menubar.isTemplate = false
        write(menubar, to: dir.appendingPathComponent("menubar-icon.png"))

        print("미리보기 저장: \(dir.path)")
    }

    /// DMG 창 배경(660×400pt, 2x). make-dmg.sh 가 Finder 아이콘을 (165,190)·(495,190) 에 놓는다 — 화살표 위치와 맞춘다.
    static func renderDMGBackground(to path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(render(DMGBackground()), to: url)
        print("DMG 배경 저장: \(url.path)")
    }

    private static func render<V: View>(_ view: V, scale: CGFloat = 2, dark: Bool = false) -> NSImage {
        let host = NSHostingView(rootView: view)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("저장 실패: \(url.lastPathComponent)"); return
        }
        try? png.write(to: url)
        print("  \(url.lastPathComponent)  \(Int(image.size.width))×\(Int(image.size.height))")
    }
}


/// DMG 를 열었을 때 보이는 안내 배경. 왼쪽 자리에 Brefly, 오른쪽 자리에 Applications 아이콘이 놓인다.
struct DMGBackground: View {
    static let size = CGSize(width: 660, height: 400)
    static let leftCenter = CGPoint(x: 165, y: 190)
    static let rightCenter = CGPoint(x: 495, y: 190)

    var body: some View {
        ZStack {
            Color(nsColor: Theme.paperSoft)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    LogoMark(size: 22, wave: .inkFixed, dot: .coral)
                    Text("Brefly").font(.system(size: 17, weight: .bold)).foregroundColor(.inkFixed)
                }
                Text("Brefly 를 Applications 폴더로 끌어 넣으세요")
                    .font(.system(size: 15, weight: .semibold)).foregroundColor(Color(nsColor: Theme.text2))
            }
            .position(x: Self.size.width / 2, y: 62)

            // 두 아이콘 사이 화살표 (아이콘 128pt 기준 양쪽 여백을 둔다)
            Path { p in
                let y = Self.leftCenter.y
                p.move(to: CGPoint(x: Self.leftCenter.x + 96, y: y))
                p.addLine(to: CGPoint(x: Self.rightCenter.x - 96, y: y))
            }
            .stroke(Color(nsColor: Theme.lineStrong), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            Path { p in
                let tip = CGPoint(x: Self.rightCenter.x - 96, y: Self.leftCenter.y)
                p.move(to: CGPoint(x: tip.x - 16, y: tip.y - 14))
                p.addLine(to: tip)
                p.addLine(to: CGPoint(x: tip.x - 16, y: tip.y + 14))
            }
            .stroke(Color(nsColor: Theme.lineStrong), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
