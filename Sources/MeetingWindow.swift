import AppKit
import SwiftUI

/// 만들어진 회의록 한 편. 창이 보여 줄 것을 한 덩어리로 들고 다닌다.
struct MeetingDocument {
    let title: String
    let audio: URL
    /// 저장한 .md 파일. "Finder 에서 보기"와 고친 내용 저장이 여기로 간다.
    let notesFile: URL
    let recordedAt: Date
    let duration: Double?
    var notes: String
    let segments: [Whisper.Segment]

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

    func show(_ document: MeetingDocument) {
        let view = MeetingResultView(document: document)
        if let window {
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

    enum Tab { case notes, transcript }

    var body: some View {
        VStack(spacing: 0) {
            header
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
                Text(toast).font(.system(size: 11.5)).foregroundColor(.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 8)
            }
        }
        .background(Color.paper)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).font(.system(size: 17, weight: .bold)).foregroundColor(.ink)
                Text([document.dateText, document.durationText].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11.5)).foregroundColor(.text3)
            }
            Spacer()
            HStack(spacing: 8) {
                OutlineButton(editing ? "저장" : "고치기", wide: false) { toggleEditing() }
                OutlineButton("Finder에서 보기", wide: false) {
                    NSWorkspace.shared.activateFileViewerSelecting([document.notesFile])
                }
                OutlineButton("복사", wide: false) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document.notes, forType: .string)
                    flash("클립보드에 복사됨")
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var tabs: some View {
        HStack(spacing: 18) {
            tabButton("회의록", .notes)
            tabButton("받아쓴 원문", .transcript)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private func tabButton(_ title: String, _ value: Tab) -> some View {
        let on = tab == value
        return Button(action: { tab = value }) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                    .foregroundColor(on ? .ink : .text3)
                Rectangle().fill(on ? Color.coral : Color.clear).frame(height: 2)
            }
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
                        ForEach(Array(MarkdownBlock.parse(document.notes).enumerated()), id: \.offset) { _, block in
                            block.view
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
            HairLine().frame(width: 1).frame(maxHeight: .infinity)
            sidebar.frame(width: 232)
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                    Text("누가 말했는지는 아직 구분하지 않습니다. 다음 버전에서 화자를 나누고 이름을 붙일 수 있습니다.")
                        .font(.system(size: 11)).foregroundColor(.text4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.coral.opacity(0.35),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(.system(size: 11.5)).foregroundColor(.text3).frame(width: 34, alignment: .leading)
            Text(value).font(.system(size: 11.5)).foregroundColor(.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 받아쓴 원문 탭

    private var transcriptTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(document.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: 12) {
                        // ⚠️ 시간 칸을 넉넉히 잡는다. 화자 구분이 들어오면 여기에 이름이 들어간다.
                        Text(timeText(segment.start))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(.text3)
                            .frame(width: 74, alignment: .leading)
                        Text(segment.text).font(.system(size: 12.5)).foregroundColor(.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
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
            flash("고친 내용을 .md 파일에 저장했습니다")
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

    static func parse(_ text: String) -> [MarkdownBlock] {
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
