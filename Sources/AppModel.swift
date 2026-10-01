import AppKit
import Combine

/// 팝오버가 그리는 상태. AppDelegate가 갱신하고 SwiftUI가 관찰한다.
final class AppModel: ObservableObject {
    /// 녹음 화면에 잠깐 띄우는 알림("회의 중에는 받아쓰기를 할 수 없습니다").
    /// ⚠️ `setState` 의 메시지는 메뉴바와 우클릭 메뉴에만 간다. **녹음 중 팝오버 두 개
    ///    어디에도 상태 줄이 없어서**, 이것이 없으면 단축키를 눌러도 아무 일도 안 일어난
    ///    것처럼 보인다 — 막았다는 사실 자체가 안 보이면 고장으로 읽힌다.
    @Published var notice: String?


    enum Delivery {
        case copied     // 클립보드 복사
        case pasted     // 커서 위치에 붙여넣음
        case viewing    // 기록에서 열어 본 것 — 토스트 없음
    }

    /// 회의를 지금 녹음하는 중에 보여 줄 것.
    struct MeetingRecordingRun {
        let startedAt: Date
        /// 시스템 소리(상대 목소리)를 잡고 있는지. 화면 기록 권한이 없으면 마이크만 남는다 —
        /// 그 상태로 화상회의를 녹음하면 내 말만 남으므로 반드시 알려야 한다.
        let capturingSystem: Bool
        /// 대면 회의로 시작했는지. 대면이면 상대 목소리를 안 잡는 것이 정상이라
        /// 경고를 띄우면 안 된다 — 잘못된 경고는 진짜 경고까지 무시하게 만든다.
        let inPerson: Bool

        var elapsedText: String {
            let t = Int(Date().timeIntervalSince(startedAt))
            return String(format: "%d:%02d", t / 60, t % 60)
        }
    }

    /// 회의록이 도는 동안 팝오버가 보여 줄 것. 메뉴바 고리와 같은 값을 쓴다.
    struct MeetingRun {
        let fileName: String
        /// 녹음 길이. 모르면 nil — 파일을 읽기 전에도 화면은 떠야 한다.
        let audioSeconds: Double?
        let startedAt: Date
        var stage: MeetingNotes.Progress.Stage = .transcribing
        var fraction: Double?

        /// 세 단계 중 몇 번째인지. 저장은 끝나는 순간이라 화면에 남지 않는다.
        var stepIndex: Int { stage == .transcribing ? 0 : 1 }

        var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

        /// 남은 시간 어림. 받아쓰기는 진행률로 재고, 요약은 몇 초라 따로 세지 않는다.
        /// ⚠️ 처음 몇 초는 진행률이 0 에 가까워 터무니없는 값이 나온다. 그때는 안 보여 준다.
        var remainingText: String? {
            guard stage == .transcribing, let fraction, fraction > 0.05 else { return nil }
            let total = elapsed / fraction
            let left = max(total - elapsed, 0)
            guard left > 3 else { return nil }
            let minutes = Int(left) / 60, seconds = Int(left) % 60
            return minutes > 0 ? "약 \(minutes)분 \(seconds)초 남음" : "약 \(seconds)초 남음"
        }

        var elapsedText: String {
            let t = Int(elapsed)
            return String(format: "%d:%02d 지남", t / 60, t % 60)
        }
    }

    enum Phase {
        case idle
        case recording
        case polishing
        /// 녹음 파일로 회의록을 만드는 중. 받아쓰기와 달리 1~2분이 걸려서 단계를 보여 줘야 한다.
        case meeting(MeetingRun)
        /// 회의를 **지금 녹음하는 중**. 파일로 만드는 것과 달리 끝이 언제일지 사용자가 정한다.
        case meetingRecording(MeetingRecordingRun)
        case done(SummaryRecord, Delivery)
        case error(String)
    }

    /// 요약 결과가 화면에 놓인 시각. 팝오버를 다시 열 때 너무 오래된 결과면 대기 화면으로 돌린다.
    /// 기록에서 꺼내 본 것에는 채우지 않는다 — 그건 사용자가 일부러 연 것이라 저절로 닫히면 안 된다.
    @Published var resultShownAt: Date?

    /// 지금 중요 표시가 켜져 있나. 녹음 화면에 드러낸다 — 켜 둔 줄 모르면 끄지도 못한다.
    @Published var highlightOn = false
    /// 이번 녹음에서 표시한 대목 수.
    @Published var highlightCount = 0

    enum Screen {
        case main
        case history
    }

    /// 팝오버 탭. 회의록은 시작하는 길이 셋이라 받아쓰기와 한 화면에 두면 지저분해진다.
    enum Tab {
        case dictation
        case meeting
    }

    @Published var phase: Phase = .idle
    @Published var screen: Screen = .main

    /// ⚠️ 마지막에 본 탭을 기억하지 않는다. 기억하면 팝오버를 열었을 때 "녹음 버튼이 어디 갔지?"가 된다.
    ///    상황이 정한다 — 회의를 녹음하거나 회의록을 만드는 중이면 회의록 탭, 아니면 늘 받아쓰기 탭.
    @Published var tab = Tab.dictation

    /// 만들어 둔 회의록 목록. 팝오버 회의록 탭이 보여 준다.
    @Published var meetingHistory: [MeetingRecord] = MeetingHistoryStore.load()

    // 녹음 중
    @Published var elapsed: TimeInterval = 0
    /// 최근 파형 레벨. [0]이 가장 새 값. 0…1.
    @Published var levels: [Float] = Array(repeating: 0, count: 11)
    /// 회의 녹음용. 받아쓰기와 따로 두는 이유는 화상일 때 두 줄(나·상대)을 함께 보여 주기 때문이다.
    @Published var meetingMicLevels: [Float] = Array(repeating: 0, count: 11)
    @Published var meetingSystemLevels: [Float] = Array(repeating: 0, count: 11)
    @Published var partialText = ""

    // 완료 화면
    @Published var rawExpanded = false

    // 오류 화면: 정리에 실패한 기록이 있으면 "다시 요약" 버튼을 보여준다
    @Published var retryRecord: SummaryRecord?

    // 환경
    @Published var history: [SummaryRecord] = HistoryStore.load()
    @Published var micReady = false
    @Published var hotKeyTitle = Prefs.currentHotKey.title
    @Published var localeID = Prefs.localeID
    @Published var autoStop = Prefs.autoStopOnSilence
    @Published var backendTitle = Prefs.backend.title
    @Published var summaryOn = Prefs.style == .summary
    /// 요약 중 화면의 진행 상황 한 줄
    @Published var polishNote = ""
    /// 결과 화면 위에 띄울 알림. 요약을 골랐는데 문장만 다듬었을 때 쓴다.
    @Published var doneNote = ""
    /// 지금 요약 중인 원문. 취소·원문 복사 버튼용.
    @Published var pendingRaw = ""

    /// 뷰가 호출하는 동작. AppDelegate가 채운다.
    struct Actions {
        var startRecording: () -> Void = {}
        var finishRecording: () -> Void = {}
        var cancelRecording: () -> Void = {}
        /// 녹음 파일을 골라 회의록을 만든다. 오른쪽 클릭 메뉴에도 같은 항목이 있지만,
        /// 사람들이 실제로 보는 것은 이 팝오버라 여기가 진짜 입구다.
        var makeMeetingNotes: () -> Void = {}
        /// 파일을 끌어다 놓았을 때. 고르기 창을 건너뛴다.
        var makeMeetingNotesFrom: (URL) -> Void = { _ in }
        /// 만들어 둔 회의록을 다시 연다.
        var openMeeting: (MeetingRecord) -> Void = { _ in }
        /// 목록에서 오른쪽 클릭 → 이름 바꾸기. 창을 띄워야 해서 앱 쪽에서 받는다.
        var renameMeeting: (MeetingRecord) -> Void = { _ in }
        /// 목록에서 오른쪽 클릭 → 목록에서 지우기. 녹음 파일은 건드리지 않는다.
        var forgetMeeting: (MeetingRecord) -> Void = { _ in }
        /// 받아쓰기 기록 오른쪽 클릭 → 이름 바꾸기 / 지우기.
        var renameSummary: (SummaryRecord) -> Void = { _ in }
        var removeSummary: (SummaryRecord) -> Void = { _ in }
        /// 녹음 중 팝오버의 하이라이트 버튼. 단축키와 같은 일을 한다.
        var toggleHighlight: () -> Void = {}
        var cancelMeetingNotes: () -> Void = {}
        /// 지금부터 회의를 녹음한다. 대면은 마이크만, 화상은 스피커 소리까지 잡는다.
        var startMeetingInPerson: () -> Void = {}
        var startMeetingVideoCall: () -> Void = {}
        var stopMeetingRecording: () -> Void = {}
        var cancelMeetingRecording: () -> Void = {}
        var openSettings: () -> Void = {}
        var quit: () -> Void = {}
        var copy: (SummaryRecord) -> Void = { _ in }
        var copyRaw: (SummaryRecord) -> Void = { _ in }
        var resummarize: (SummaryRecord) -> Void = { _ in }
        var delete: (SummaryRecord) -> Void = { _ in }
        var openLog: () -> Void = {}
        var dismissError: () -> Void = {}
        var cancelPolish: () -> Void = {}
        var copyPendingRaw: () -> Void = {}
        var setSummary: (Bool) -> Void = { _ in }
    }
    var actions = Actions()

    func pushLevel(_ level: Float) {
        levels.removeLast()
        levels.insert(level, at: 0)
    }

    func resetRecording() {
        elapsed = 0
        partialText = ""
        levels = Array(repeating: 0, count: 11)
    }

    func refreshPrefs() {
        hotKeyTitle = Prefs.currentHotKey.title
        localeID = Prefs.localeID
        autoStop = Prefs.autoStopOnSilence
        backendTitle = Prefs.backend.title
        summaryOn = Prefs.style == .summary
    }

    func upsert(_ record: SummaryRecord) {
        if let i = history.firstIndex(where: { $0.id == record.id }) {
            history[i] = record
        } else {
            history.insert(record, at: 0)
        }
        HistoryStore.save(history)
    }

    func remove(_ record: SummaryRecord) {
        history.removeAll { $0.id == record.id }
        HistoryStore.save(history)
    }
}
