import AppKit
import SwiftUI

/// 만들어진 회의록 한 편. 창이 보여 줄 것을 한 덩어리로 들고 다닌다.
struct MeetingDocument {
    var title: String
    let audio: URL
    /// 저장한 .md 파일. "Finder 에서 보기"와 고친 내용 저장이 여기로 간다.
    var notesFile: URL
    let recordedAt: Date
    let duration: Double?
    var notes: String
    let segments: [Whisper.Segment]
    /// 받아 적은 원문. "다시 요약"이 이걸 다시 모델에 넘긴다 — 받아쓰기를 다시 돌리지 않는다.
    var transcript: String = ""
    /// 화자를 아는 녹음인지(화상 회의). 다시 요약할 때 프롬프트가 달라진다.
    var speakersKnown: Bool = false
    /// 요약이 실패한 채로 저장됐으면 그 까닭. 있으면 창 위에 띠와 '다시 요약'이 뜬다.
    var summaryFailed: String? = nil
    /// 어느 AI 가 뽑았는지. AUTO 는 회사를 오가므로 결과만 보고는 알 수 없다.
    var usedModel: (label: String, name: String)? = nil
    /// 녹음 중에 사용자가 찍은 중요 대목 수.
    var highlightCount: Int = 0

    var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f.string(from: recordedAt)
    }

    var durationText: String? {
        guard let duration else { return nil }
        let m = Int(duration) / 60, s = Int(duration) % 60
        return "\(m)분 \(s)초"
    }

    /// 녹음이 어느 폴더에 있는지. 전체 경로는 길어서 마지막 두 칸만 보여 준다.
    var locationText: String {
        let parts = audio.deletingLastPathComponent().pathComponents.suffix(2)
        return parts.joined(separator: " › ")
    }
}

/// 회의록 결과 창. 팝오버가 아니라 일반 창이다 — 회의록은 팝오버에 담기엔 너무 길다.
final class MeetingWindow: NSObject, NSWindowDelegate {
    static let shared = MeetingWindow()
    private var window: NSWindow?

    /// 이름이 바뀌었을 때 창 제목 막대를 따라가게 한다.
    func retitle(_ title: String) { window?.title = title }

    /// 이름이 바뀌었을 때 부를 것. 팝오버 목록을 다시 읽게 한다.
    var onRenamed: (() -> Void)?

    func show(_ document: MeetingDocument) {
        let view = MeetingResultView(document: document, onRenamed: onRenamed)
        if let window {
            // ⚠️ 제목도 같이 바꾼다. 창을 다시 쓰면서 내용만 갈았더니 **창 제목 막대에는
            //    먼저 열었던 회의록 이름이 그대로 남아** 있었다.
            window.title = document.title
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = document.title
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 680, height: 460)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 화면

struct MeetingResultView: View {
    @State var document: MeetingDocument
    @State private var tab = Tab.notes
    @State private var editing = false
    @State private var draft = ""
    @State private var toast: String?
    @State private var retrying = false
    /// 모델이 마지막으로 낸 글. 사용자가 고쳤는지 가리는 기준이다.
    /// 이름이 바뀌면 팝오버 목록도 따라 바뀌어야 한다.
    var onRenamed: (() -> Void)? = nil
    @State private var titleHover = false
    @State private var lastSummary = ""
    /// 다시 요약하기 직전의 글. 새 요약이 더 나쁠 수도 있어서 한 번은 되돌릴 수 있게 둔다.
    @State private var undoTarget: String?

    enum Tab { case notes, transcript }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let failure = document.summaryFailed { HairLine(); retryBanner(failure) }
            HairLine()
            tabs
            HairLine()
            Group {
                switch tab {
                case .notes:      notesTab
                case .transcript: transcriptTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.paperSoft)
            if let toast {
                HairLine()
                HStack(spacing: 10) {
                    Text(toast).font(.system(size: 11.5)).foregroundColor(.text3)
                    Spacer(minLength: 0)
                    if let previous = undoTarget {
                        Button("되돌리기") {
                            document.notes = previous
                            lastSummary = previous
                            try? previous.write(to: document.notesFile, atomically: true, encoding: .utf8)
                            MeetingHistoryStore.updateTodos(notesPath: document.notesFile.path,
                                                            count: MeetingHistoryStore.countTodos(in: previous))
                            undoTarget = nil
                            flash("이전 요약으로 되돌렸습니다.")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.coral)
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
        .background(Color.paper)
        .onAppear { if lastSummary.isEmpty { lastSummary = document.notes } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                // 이름은 탭과 무관하므로 머리말에 둔다. 연필을 붙여 **고칠 수 있다는 것**을
                // 드러낸다 — 버튼을 따로 두면 무엇의 이름인지 한 번 더 생각해야 한다.
                Button(action: renameDocument) {
                    HStack(spacing: 8) {
                        Text(document.title).font(.system(size: 17, weight: .bold)).foregroundColor(.ink)
                        // ⚠️ 연필만 두면 획이 가늘어 글자 옆에서 묻힌다.
                        //    테두리를 둘러 누를 것임을 드러낸다.
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(titleHover ? .ink : .text3)
                            .frame(width: 22, height: 22)
                            .background(titleHover ? Color.fill : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(titleHover ? Color.lineStrong : Color.line, lineWidth: 1))
                            .cornerRadius(6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { titleHover = $0 }
                .help("이름 바꾸기")
                Text([document.dateText, document.durationText].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundColor(.text3)
            }
            Spacer()
            OutlineButton("Finder에서 보기", wide: false) {
                NSWorkspace.shared.activateFileViewerSelecting([document.notesFile])
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    /// 요약만 실패했을 때 뜨는 띠. 받아 적은 것은 이미 안전하다는 걸 먼저 말하고,
    /// 몇 초면 되는 재시도를 바로 옆에 둔다.
    private func retryBanner(_ failure: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundColor(.coral)
            VStack(alignment: .leading, spacing: 2) {
                Text("요약만 실패했습니다. 받아 적은 원문은 그대로 있습니다.")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
                Text(failure).font(.system(size: 11)).foregroundColor(.text3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            OutlineButton(retrying ? "요약하는 중…" : "다시 요약", wide: false) { retrySummary() }
                .disabled(retrying)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.coral.opacity(0.06))
    }

    /// 회의록 이름을 바꾼다. 목록과 `.md` 파일 이름이 함께 바뀐다.
    /// 목록에서 오른쪽 클릭해도 되지만, 열어서 읽다가 "이거 이름 바꿔야겠다" 싶은 때가 더 잦다.
    private func renameDocument() {
        let alert = NSAlert()
        alert.messageText = "회의록 이름 바꾸기"
        alert.informativeText = "목록과 .md 파일 이름이 함께 바뀝니다."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = document.title
        alert.accessoryView = field
        alert.addButton(withTitle: "바꾸기")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != document.title else { return }
        guard let moved = MeetingHistoryStore.rename(notesPath: document.notesFile.path, to: name) else {
            flash("이름을 바꾸지 못했습니다.")
            return
        }
        document.title = moved.title
        document.notesFile = moved.notesFile
        MeetingWindow.shared.retitle(moved.title)
        onRenamed?()
        flash("이름을 바꿨습니다.")
    }

    /// 고쳐 둔 글이 있으면 먼저 묻는다. 모델 결과로 덮어쓰면 사용자가 쓴 것이 사라진다.
    private func askRetry() {
        guard document.notes != lastSummary else { retrySummary(); return }
        let alert = NSAlert()
        alert.messageText = "다시 요약할까요?"
        alert.informativeText = "지금 회의록을 모델이 새로 쓴 것으로 바꿉니다. "
            + "고쳐 두신 내용은 사라집니다. 받아 적은 원문은 그대로입니다."
        alert.addButton(withTitle: "다시 요약")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        retrySummary()
    }

    /// 받아쓰기는 건드리지 않는다. 요약만 다시 부른다 — 48분 녹음이라도 몇 초다.
    private func retrySummary() {
        guard !retrying, !document.transcript.isEmpty else { return }
        retrying = true
        MeetingNotes.summarizeOnly(document.transcript, speakersKnown: document.speakersKnown) { result in
            DispatchQueue.main.async {
                retrying = false
                switch result {
                case .success(let notes):
                    let previous = document.notes
                    document.notes = notes
                    document.summaryFailed = nil
                    lastSummary = notes
                    document.usedModel = MeetingNotes.lastUsedModel
                    try? notes.write(to: document.notesFile, atomically: true, encoding: .utf8)
                    // 목록의 "할 일 n개"가 옛 숫자로 남으면 안 된다.
                    MeetingHistoryStore.updateTodos(notesPath: document.notesFile.path,
                                                    count: MeetingHistoryStore.countTodos(in: notes))
                    undoTarget = previous
                    flash("요약을 다시 만들었습니다. 마음에 안 들면 되돌릴 수 있습니다.")
                case .failure(let error):
                    document.summaryFailed = error.localizedDescription
                    flash("또 실패했습니다. 원문은 그대로 있습니다.")
                }
            }
        }
    }

    /// ⚠️ 바깥에 여백을 주지 않는다. 탭 두 개가 창을 정확히 반씩 나눠 갖게 두면
    ///    좌우 여백이 저절로 같아진다. 전에는 `padding(.horizontal, 20)` 을 줬는데,
    ///    밑줄 `Rectangle` 이 가로로 탐욕스러워 탭이 이미 반씩 차지하고 있던 터라
    ///    왼쪽 끝과 오른쪽 끝의 여백이 어긋나 보였다.
    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton("회의록", .notes)
            tabButton("받아쓴 원문", .transcript)
        }
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        let on = tab == value
        return Button(action: { tab = value }) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? .ink : .text3)
                    // ⚠️ 눌리는 영역은 **버튼 안**에서만 넓힐 수 있다. 위 여백을 바깥
                    //    `padding(.top,)` 으로 주면 글자 위쪽이 눌리지 않는다.
                    //    위아래를 같은 값으로 버튼 안에 넣는다.
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                Rectangle().fill(on ? Color.coral : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 회의록 탭

    private var notesTab: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                if editing {
                    // 고칠 때는 원본 마크다운을 그대로 보여 준다. 꾸며 놓은 걸 고치게 하면
                    // 무엇이 저장될지 알 수 없다.
                    TextEditor(text: $draft)
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(minHeight: 420)
                        .padding(20)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(MarkdownBlock.parse(document.notes, droppingTitle: document.title).enumerated()), id: \.offset) { _, block in
                            block.view
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    // ⚠️ SwiftUI 의 `Text` 는 기본이 **선택 불가**다. 팝오버 쪽에는 걸어 뒀는데
                    //    이 창만 빠져서, 회의록을 읽다가 한 대목만 긁어 갈 수가 없었다.
                    //    복사 버튼은 전체만 준다.
                    .textSelection(.enabled)
                }
            }
            HairLine().frame(width: 1).frame(maxHeight: .infinity)
            sidebar.frame(width: 232)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 회의록에만 걸리는 동작 셋. 탭 위에 있으면 원문 탭을 보면서도 회의록을
                // 고치는 것처럼 읽힌다. 사이드바가 좁아 가로로 늘어놓으면 글자가 잘리므로 쌓는다.
                VStack(spacing: 6) {
                    // 실패했을 때만이 아니라 **마음에 안 들 때도** 다시 뽑을 수 있어야 한다.
                    // 고치는 중에는 숨긴다 — 쓰던 글을 모델 결과로 덮어쓰면 그게 사고다.
                    if !editing, !document.transcript.isEmpty, document.summaryFailed == nil {
                        OutlineButton(retrying ? "요약하는 중…" : "다시 요약") { askRetry() }
                            .disabled(retrying)
                    }
                    OutlineButton(editing ? "저장" : "직접 수정") { toggleEditing() }
                    OutlineButton("복사") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(document.notes, forType: .string)
                        flash("회의록을 클립보드에 복사했습니다.")
                    }
                }
                // 어느 AI 가 뽑았는지 보여 준다. AUTO 가 회사를 오가게 되면서
                // 결과만 보고는 알 수 없어졌다 — 품질이 다르면 원인을 여기서 찾는다.
                if let used = document.usedModel {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("요약 정보").font(.system(size: 11, weight: .bold)).foregroundColor(.text3)
                        infoRow("AI", used.label)
                        infoRow("모델", used.name)
                        if document.highlightCount > 0 {
                            infoRow("중요 표시", "\(document.highlightCount)곳")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("녹음 정보").font(.system(size: 11, weight: .bold)).foregroundColor(.text3)
                    infoRow("날짜", document.dateText)
                    if let duration = document.durationText { infoRow("길이", duration) }
                    infoRow("위치", document.locationText)
                }
                // ⚠️ 화자 구분이 들어올 자리. 지금은 비워 두되 틀을 잡아 둔다 —
                //    나중에 "참석자" 목록이 같은 자리에 들어가므로 화면을 갈아엎지 않는다.
                VStack(alignment: .leading, spacing: 6) {
                    Text("참석자").font(.system(size: 11, weight: .bold)).foregroundColor(.text3)
                    if document.speakersKnown {
                        // 화상 회의는 트랙이 갈려 있어 내 쪽과 상대 쪽은 안다. 상대가 몇 명인지는 모른다.
                        infoRow("나", "이 맥의 마이크")
                        infoRow("상대", "스피커로 나온 소리")
                        Text("상대가 여러 명이면 모두 '상대'로 묶입니다.")
                            .font(.system(size: 11)).foregroundColor(.text4)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("누가 말했는지는 아직 구분하지 않습니다. 다음 버전에서 화자를 나누고 이름을 붙일 수 있습니다.")
                            .font(.system(size: 11)).foregroundColor(.text4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.coral.opacity(0.35),
                                              style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 11.5)).foregroundColor(.text3).frame(width: 52, alignment: .leading)
            Text(value).font(.system(size: 11.5)).foregroundColor(.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: 받아쓴 원문 탭

    private var transcriptTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(document.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: 12) {
                        Text(timeText(segment.start))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.text3)
                            .frame(width: 44, alignment: .leading)
                        // 화상 회의는 트랙이 갈려 있어 누가 말했는지 안다. 대면은 비워 둔다.
                        if let speaker = segment.speaker {
                            Text(speaker)
                                .font(.system(size: 11, weight: .semibold)).foregroundColor(.ink)
                                .padding(.horizontal, 7).padding(.vertical, 1)
                                .background(speaker == "나" ? Color.paperSoft : Color.paper)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.line, lineWidth: 1))
                                .cornerRadius(5)
                                .frame(width: 42, alignment: .leading)
                        }
                        Text(segment.text).font(.system(size: 12.5)).foregroundColor(.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .textSelection(.enabled)
        }
    }

    private func timeText(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    // MARK: 동작

    private func toggleEditing() {
        if editing {
            document.notes = draft
            // 고친 내용은 곧바로 파일에 넣는다. "저장" 을 또 찾게 하면 안 고친 채로 닫는다.
            try? draft.write(to: document.notesFile, atomically: true, encoding: .utf8)
            flash("고친 내용을 .md 파일에 저장했습니다.")
            editing = false
        } else {
            draft = document.notes
            editing = true
        }
    }

    private func flash(_ message: String) {
        toast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if toast == message { toast = nil }
        }
    }
}

// MARK: - 아주 작은 마크다운

/// 회의록은 `## 제목` 과 `- 항목` 만 쓴다. 그것만 알아보면 된다 —
/// 마크다운 라이브러리를 들이면 벤더링할 것이 또 늘어난다.
enum MarkdownBlock {
    case heading(String)
    case bullet(String)
    case paragraph(String)

    /// ⚠️ 저장한 `.md` 는 첫 줄이 `# <회의록 이름>` 이다(`finishMeetingNotes`). 창에는 이미
    ///    머리말에 이름이 있어서, 그대로 그리면 같은 이름이 두 번 나온다. 첫 제목 한 줄만 뗀다.
    static func parse(_ text: String, droppingTitle title: String? = nil) -> [MarkdownBlock] {
        var text = text
        if let title {
            let first = "# " + title
            if text.hasPrefix(first) {
                text = String(text.dropFirst(first.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return parseBlocks(text)
    }

    private static func parseBlocks(_ text: String) -> [MarkdownBlock] {
        text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if line.hasPrefix("# ") { return .heading(String(line.dropFirst(2))) }
            if line.hasPrefix("- ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    @ViewBuilder
    var view: some View {
        switch self {
        case .heading(let text):
            Text(text).font(.system(size: 13, weight: .bold)).foregroundColor(.ink)
                .padding(.top, 6)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 8) {
                Text("•").font(.system(size: 12.5)).foregroundColor(.coral)
                Text(stripEmphasis(text)).font(.system(size: 12.5)).foregroundColor(.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(let text):
            Text(stripEmphasis(text)).font(.system(size: 12.5)).foregroundColor(.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 모델이 가끔 `**굵게**` 를 섞어 보낸다. 별표를 그대로 두면 읽기 나쁘다.
    private func stripEmphasis(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "")
    }
}
