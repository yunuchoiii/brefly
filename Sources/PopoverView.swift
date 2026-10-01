import SwiftUI
import AppKit

// 시안 "Voice Summary App.dc.html" 의 팝오버 3종(1a 대기 / 1b 녹음 중 / 1c 요약 완료)과
// 히스토리·요약 중·오류 화면. 팝오버 폭은 시안 그대로 312pt.

let popoverWidth: CGFloat = 312

struct PopoverRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.screen {
            case .history:
                HistoryView(model: model)
            case .main:
                switch model.phase {
                case .idle:
                    IdleView(model: model)
                case .recording:
                    RecordingView(model: model)
                case .polishing:
                    PolishingView(model: model)
                case .meeting(let run):
                    MeetingProgressView(model: model, run: run)
                case .meetingRecording(let run):
                    MeetingRecordingView(model: model, run: run)
                case .done(let record, let delivery):
                    DoneView(model: model, record: record, delivery: delivery)
                case .error(let message):
                    ErrorView(model: model, message: message)
                }
            }
        }
        .frame(width: popoverWidth)
    }
}

// MARK: - 1a 대기

struct IdleView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LogoMark(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brefly").font(.system(size: 15, weight: .bold)).foregroundColor(.ink)
                    Text(model.micReady ? "대기 중 · 마이크 준비됨" : "마이크 권한이 필요해요.")
                        .font(.system(size: 12)).foregroundColor(.text2)
                }
                Spacer()
                Circle().fill(model.micReady ? Color.green : Color.coral).frame(width: 8, height: 8)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            PopoverTabBar(model: model)
            HairLine()

            Group {
                if model.tab == .dictation {
                    VStack(spacing: 0) {

                    // 회의록 탭의 칸들과 같은 짜임으로 맞춘다 — 왼쪽에 아이콘과 이름,
                    // 오른쪽 끝에 단축키와 "누르면 바로 녹음"을 뜻하는 코랄 점.
                    // 전에는 제목만 가운데 있고 단축키가 따로 떠 있어 두 탭이 따로 놀았다.
                    Button(action: model.actions.startRecording) {
                        HStack(spacing: 11) {
                            Image(systemName: "waveform").font(.system(size: 14))
                                .frame(width: 18)
                            Text("녹음").font(.system(size: 13, weight: .bold))
                            Spacer(minLength: 0)
                            KeyCap(model.hotKeyTitle, accent: true)
                            Circle().fill(Color.coral).frame(width: 8, height: 8)
                        }
                        .foregroundColor(.onPrimary)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(Color.primaryFill)
                        .cornerRadius(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("핵심 요약").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                            Text("요점만 목록 형태로 정리합니다.")
                                .font(.system(size: 11)).foregroundColor(.text3)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.summaryOn }, set: { model.actions.setSummary($0) }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            // 기본 스위치는 시스템 강조색(파랑)을 쓴다. 테마 코랄로 맞춘다.
                            .tint(.coral)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)

                    HairLine()

                    VStack(spacing: 0) {
                        HStack {
                            Text("최근 요약").font(.system(size: 12, weight: .semibold)).foregroundColor(.text2)
                            Spacer()
                            if !model.history.isEmpty {
                                Button("모두 보기") { model.screen = .history }
                                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.text3)
                            }
                        }
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

                        if model.history.isEmpty {
                            Text("아직 요약이 없어요. 녹음을 시작해 보세요.")
                                .font(.system(size: 12)).foregroundColor(.text4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 14)
                        } else {
                            ForEach(model.history.prefix(3)) { record in
                                HistoryRow(record: record,
                                           open: { model.rawExpanded = false; model.resultShownAt = nil; model.phase = .done(record, .viewing) },
                                           copy: { model.actions.copy(record) },
                                           rename: { model.actions.renameSummary(record) },
                                           remove: { model.actions.removeSummary(record) })
                            }
                            Spacer().frame(height: 6)
                        }
                    }
                    .background(Color.paperSoft)

                    }
                } else {
                    MeetingTabView(model: model)
                }
            }

            HairLine()

            HStack {
                Button("설정", action: model.actions.openSettings).buttonStyle(.plain)
                Spacer()
                Button("종료", action: model.actions.quit).buttonStyle(.plain)
            }
            .font(.system(size: 12)).foregroundColor(.text3)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color.paper)
    }
}

/// 회의록 목록의 한 줄. `HistoryRow`(요약)와 같은 모양으로 맞춘다 —
/// ⚠️ 마우스를 올렸을 때 바탕이 바뀌는 것은 `@State` 가 있어야 해서 별도 뷰로 뺀다.
///    `ForEach` 안에 그대로 두면 줄마다 상태를 가질 수 없어 요약 쪽만 반응했다.
struct MeetingHistoryRow: View {
    let record: MeetingRecord
    @ObservedObject var model: AppModel
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(record.title)
                .font(.system(size: 12.5, weight: .semibold)).foregroundColor(.ink)
                .lineLimit(1)
            Text(record.subtitle)
                .font(.system(size: 11)).foregroundColor(.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 받아쓰기 쪽 `HistoryRow` 와 같은 값(가로 16, 세로 7)이라야 두 탭이 같아 보인다.
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(hover ? Color.fill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { model.actions.openMeeting(record) }
        .onHover { hover = $0 }
        // 오른쪽 클릭으로 이름을 고치고 목록에서 뺀다. 줄마다 버튼을 달면
        // 두 줄짜리 항목이 더 빽빽해진다.
        .contextMenu {
            Button("이름 바꾸기…") { model.actions.renameMeeting(record) }
            Button("Finder에서 보기") {
                NSWorkspace.shared.activateFileViewerSelecting([record.notesFile])
            }
            Divider()
            // ⚠️ 이름을 분명히 한다. "삭제" 라고만 하면 녹음까지 지운 줄 안다.
            //    녹음은 다시 만들 수 없어서 여기서는 목록에서만 뺀다.
            Button("목록에서 지우기") { model.actions.forgetMeeting(record) }
        }
    }
}

struct HistoryRow: View {
    let record: SummaryRecord
    let open: () -> Void
    let copy: () -> Void
    /// 오른쪽 클릭 메뉴. 회의록 목록과 같은 방식이다.
    var rename: (() -> Void)? = nil
    var remove: (() -> Void)? = nil
    @State private var hover = false

    var meta: String {
        "\(Format.relative(record.date)) · \(Format.duration(record.duration)) · \(Format.localeName(record.localeID))"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title).font(.system(size: 13, weight: .semibold)).foregroundColor(.ink).lineLimit(1)
                Text(meta).font(.system(size: 11)).foregroundColor(.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: copy) {
                Image(systemName: "doc.on.doc").font(.system(size: 12)).foregroundColor(.text4)
                    .frame(width: 24, height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("요약 복사")
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .contextMenu {
            if let rename { Button("이름 바꾸기…") { rename() } }
            Button("요약 복사") { copy() }
            if let remove {
                Divider()
                // ⚠️ 여기는 정말로 지운다. 요약과 원문이 이 기록 안에만 있어서 되돌릴 수 없다.
                //    회의록의 "목록에서 지우기"와 다르다 — 그쪽은 파일이 따로 남는다.
                Button("지우기") { remove() }
            }
        }
        .background(hover ? Color.fill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
    }
}

// MARK: - 1b 녹음 중

struct RecordingView: View {
    @ObservedObject var model: AppModel

    /// 시안처럼 마지막 부분만 보이게 앞을 잘라낸다.
    private var tail: String {
        let text = model.partialText
        let limit = 95
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.coral.opacity(0.22)).frame(width: 20, height: 20)
                    Circle().fill(Color.coral).frame(width: 10, height: 10)
                }
                Text("듣고 있어요").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Text(Format.timer(model.elapsed))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(.darkSub)
            }
            .padding(.horizontal, 16).padding(.top, 16)

            Waveform(levels: model.levels)
                .frame(height: 44)
                .padding(.top, 14).padding(.bottom, 12)

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }

            HStack(alignment: .bottom, spacing: 0) {
                (Text(model.partialText.isEmpty ? "말씀하세요…" : tail)
                    .foregroundColor(model.partialText.isEmpty ? .darkMuted : .darkText)
                 + Text(" ▍").foregroundColor(.darkMuted))
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 70, alignment: .topLeading)
                    .animation(nil, value: model.partialText)
            }
            .padding(12)
            .background(Color.darkCard)
            .cornerRadius(10)
            .padding(.horizontal, 16)

            HStack(spacing: 8) {
                Button(action: model.actions.finishRecording) {
                    Text("완료 — 요약하기").font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(Color.coral).cornerRadius(10)
                }
                .buttonStyle(.plain)
                Button(action: model.actions.cancelRecording) {
                    Text("취소").font(.system(size: 13, weight: .medium))
                        .foregroundColor(.darkText)
                        .frame(width: 56, height: 42)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.darkLine, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            Text(model.autoStop ? "말을 멈추고 \(Int(Prefs.silenceSeconds))초가 지나면 자동으로 요약됩니다"
                                : "\(model.hotKeyTitle) 를 다시 누르면 요약됩니다")
                .font(.system(size: 11)).foregroundColor(.darkSub)
                .padding(.bottom, 14)
        }
        .background(Color.inkFixed)
    }
}

struct Waveform: View {
    let levels: [Float]
    private let bars = 21

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let distance = abs(i - bars / 2)
                let level = CGFloat(levels.indices.contains(distance) ? levels[distance] : 0)
                RoundedRectangle(cornerRadius: 2)
                    .fill(distance <= 3 ? Color.coral : Color.darkMuted)
                    .frame(width: 4, height: 6 + level * 36)
            }
        }
        .animation(.linear(duration: 0.1), value: levels)
    }
}

// MARK: - 요약 중

struct PolishingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            BreflyLoader(size: 56)
                .padding(.bottom, 2)
            Text("요약하고 있어요").font(.system(size: 14, weight: .semibold)).foregroundColor(.ink)
            Text(model.polishNote.isEmpty ? model.backendTitle : model.polishNote)
                .font(.system(size: 11)).foregroundColor(.text3)
                .multilineTextAlignment(.center).padding(.horizontal, 20)

            HStack(spacing: 8) {
                OutlineButton("원문 복사") { model.actions.copyPendingRaw() }
                OutlineButton("취소 — 원문 그대로 쓰기") { model.actions.cancelPolish() }
            }
            .padding(.horizontal, 16).padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color.paper)
    }
}

// MARK: - 1c 요약 완료

struct DoneView: View {

    /// 원문이 네 줄을 넘는지 잰다. 넘지 않으면 "펼치기" 버튼을 숨긴다.
    ///
    /// ⚠️ SwiftUI 는 `lineLimit` 때문에 글이 잘렸는지를 알려 주지 않는다. 그래서 같은
    ///    글꼴·너비로 직접 재 본다. 경계에서 한 줄쯤 어긋날 수 있는데, **잘리는데 버튼이
    ///    없는 쪽**이 더 나쁘므로 여유를 조금 두고 넉넉히 보여 주는 쪽으로 기운다.
    static func overflowsFourLines(_ text: String) -> Bool {
        let width = popoverWidth - 32          // 좌우 여백 16씩
        let font = NSFont.systemFont(ofSize: 12)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        let box = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: style])
        let lineHeight = font.ascender - font.descender + font.leading + style.lineSpacing
        return box.height > lineHeight * 4.4
    }

    @ObservedObject var model: AppModel
    let record: SummaryRecord
    let delivery: AppModel.Delivery


    /// 원문이 네 줄 안에 다 들어가는지 잰다. 들어가면 "펼치기" 버튼을 숨긴다.
    ///
    /// ⚠️ SwiftUI 는 `lineLimit` 때문에 잘렸는지를 알려 주지 않는다. 그래서 같은 글꼴·너비로
    ///    TextKit 에 직접 재 본다. 값이 조금 어긋나도 한 줄 차이라, 잘리는데 버튼이 없는 쪽만
    ///    피하면 된다 — 그래서 여유를 조금 두고 **넘칠 때만** 버튼을 보인다.
    private var rawOverflows: Bool {
        let inset: CGFloat = 16 * 2                 // 좌우 여백
        let width = popoverWidth - inset
        let font = NSFont.systemFont(ofSize: 12)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        let box = (record.raw as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs)
        let lineHeight = font.ascender - font.descender + font.leading + style.lineSpacing
        return box.height > lineHeight * 4.5
    }

    var body: some View {
        VStack(spacing: 0) {
            switch delivery {
            case .copied, .pasted:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(.green)
                    Text(delivery == .pasted ? "커서 위치에 붙여넣었어요." : "클립보드에 복사됐어요.")
                        .font(.system(size: 12, weight: .semibold)).foregroundColor(.greenText)
                    Spacer()
                    if delivery == .copied {
                        Text("⌘V 로 붙여넣기").font(.system(size: 11)).foregroundColor(.greenSub)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.greenBG)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.greenBorder, lineWidth: 1))
                .cornerRadius(8)
                .padding(.horizontal, 16).padding(.top, 16)
                if !model.doneNote.isEmpty {
                    Text(model.doneNote + " — '다시 요약'으로 한 번 더 해 볼 수 있어요.")
                        .font(.system(size: 11.5)).foregroundColor(.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.top, 8)
                }
            case .viewing:
                HStack {
                    Button(action: { model.phase = .idle }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                            Text("최근 요약")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.text3)
                    Spacer()
                    Text(Format.relative(record.date)).font(.system(size: 11)).foregroundColor(.text4)
                }
                .padding(.horizontal, 16).padding(.top, 14)
            }

            // ⚠️ 제목을 여기 두지 않는다. `HistoryStore.makeTitle` 이 **요약 첫 문장을 잘라**
            //    만든 것이라, 바로 아래 본문과 같은 말이 두 번 나왔다. 목록에서는 한 줄로
            //    가려내야 해서 제목이 필요하지만, 본문이 함께 보이는 이 화면에서는 군더더기다.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.localeName(record.localeID))
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.text2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.fill).cornerRadius(4)
                Text(Format.duration(record.duration)).font(.system(size: 11)).foregroundColor(.text3)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 16).padding(.top, 14)

            SummaryText(text: record.summary)
                .padding(.horizontal, 16).padding(.top, 10)

            // ⚠️ 여기 있던 "원문 보기" 는 아래 "전체 원문 펼치기" 와 **똑같이**
            //    `rawExpanded` 를 뒤집기만 했다. 같은 화면에 같은 일을 하는 버튼이 둘이었다.
            //    원문 바로 위에 붙은 아래쪽만 남긴다 — 무엇을 펼치는지가 거기서 더 분명하다.
            HStack(spacing: 8) {
                OutlineButton("다시 요약") { model.actions.resummarize(record) }
                Menu {
                    Button("요약 복사") { model.actions.copy(record) }
                    Button("원문 복사") { model.actions.copyRaw(record) }
                    Divider()
                    Button("기록에서 삭제") { model.actions.delete(record) }
                } label: {
                    Text("···").font(.system(size: 14, weight: .bold)).foregroundColor(.text2)
                        .frame(width: 36, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.lineStrong, lineWidth: 1))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(16)

            HairLine()

            VStack(alignment: .leading, spacing: 6) {
                Text("원문").font(.system(size: 11, weight: .semibold)).foregroundColor(.text3)
                Text(record.raw)
                    .font(.system(size: 12)).foregroundColor(.text2)
                    .lineSpacing(2)
                    .lineLimit(model.rawExpanded ? nil : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                // ⚠️ 네 줄 안에 다 들어가면 펼칠 것이 없다. 그런데도 버튼이 떠 있으면
                //    눌러도 아무 일이 안 일어나 고장으로 보인다. 잘릴 때만 보여 준다.
                if Self.overflowsFourLines(record.raw) {
                    Button(model.rawExpanded ? "접기 ↑" : "전체 원문 펼치기 ↓") {
                        withAnimation(.easeInOut(duration: 0.15)) { model.rawExpanded.toggle() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.text3)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.paperSoft)

            HairLine()

            HStack {
                Button(action: { model.phase = .idle }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("처음으로")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("새 녹음", action: model.actions.startRecording).buttonStyle(.plain)
            }
            .font(.system(size: 12)).foregroundColor(.text3)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color.paper)
    }
}

/// LLM 출력은 불릿("- ")이거나 문단이다. 둘 다 시안처럼 그린다.
struct SummaryText: View {
    let text: String

    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if let body = bulletBody(line) {
                    HStack(alignment: .top, spacing: 8) {
                        Text("·").font(.system(size: 13, weight: .bold)).foregroundColor(.text4)
                        richText(body)
                    }
                } else {
                    richText(line)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private func bulletBody(_ line: String) -> String? {
        for prefix in ["- ", "• ", "* ", "· "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            return String(line[range.upperBound...])
        }
        return nil
    }

    private func richText(_ s: String) -> Text {
        if let attributed = try? AttributedString(markdown: s) {
            return Text(attributed).font(.system(size: 13)).foregroundColor(.ink)
        }
        return Text(s).font(.system(size: 13)).foregroundColor(.ink)
    }
}

// MARK: - 히스토리

struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: { model.screen = .main }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("뒤로")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.text3)
                Spacer()
                Text("요약 기록 \(model.history.count)").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
                Spacer()
                Text("뒤로").font(.system(size: 12)).hidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            HairLine()

            if model.history.isEmpty {
                Text("아직 요약이 없어요.").font(.system(size: 12)).foregroundColor(.text4)
                    .padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.history) { record in
                            HistoryRow(record: record,
                                       open: {
                                           model.rawExpanded = false
                                           model.resultShownAt = nil
                                           model.phase = .done(record, .viewing)
                                           model.screen = .main
                                       },
                                       copy: { model.actions.copy(record) },
                                       rename: { model.actions.renameSummary(record) },
                                       remove: { model.actions.removeSummary(record) })
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(height: min(CGFloat(model.history.count) * 46 + 12, 420))
            }
        }
        .background(Color.paper)
    }
}

// MARK: - 오류

struct ErrorView: View {
    @ObservedObject var model: AppModel
    let message: String

    private var headline: String { message.split(separator: "\n").first.map(String.init) ?? message }
    private var detail: String {
        message.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundColor(.coral)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.system(size: 12, weight: .semibold)).foregroundColor(.coralDeep)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundColor(.text2).lineSpacing(2)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.coral.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.coral.opacity(0.35), lineWidth: 1))
            .cornerRadius(8)
            .padding(16)

            HStack(spacing: 8) {
                if let record = model.retryRecord {
                    Button(action: { model.actions.resummarize(record) }) {
                        Text("다시 요약").font(.system(size: 12, weight: .semibold)).foregroundColor(.onPrimary)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .background(Color.primaryFill).cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
                OutlineButton("확인") { model.actions.dismissError() }
                OutlineButton("로그 열기") { model.actions.openLog() }
                OutlineButton("설정…") { model.actions.openSettings() }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .background(Color.paper)
    }
}

// MARK: - 공용 조각

struct HairLine: View {
    var body: some View { Rectangle().fill(Color.line).frame(height: 1) }
}

struct KeyCap: View {
    let label: String
    /// 녹음 시작 버튼 안에 놓이는 형태. 테두리 없이 밝은 회색 칩에 코랄 글자를 쓴다.
    ///
    /// ⚠️ 칩 배경을 한 색으로 고정하면 안 된다. 버튼이 모드에 따라 검정(ink 0x16181d)과
    /// 흰색(darkTextMain 0xf2f3f5)으로 뒤집히므로, 칩도 그 반대편이 아니라
    /// **버튼색에서 한 단계 떨어진 값**이어야 형태가 남는다.
    /// 라이트는 검은 버튼 위 어두운 회색(darkLine), 다크는 흰 버튼 위 밝은 회색(lineStrong).
    /// 한때 fill(0xf2f3f5)로 고정했다가 다크 버튼색과 값이 같아 칩이 통째로 사라진 적이 있다.
    let accent: Bool
    init(_ label: String, accent: Bool = false) { self.label = label; self.accent = accent }
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(accent ? .coral : .text2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(accent ? Color(nsColor: Theme.dyn(Theme.darkLine, Theme.lineStrong)) : Color.fill)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(accent ? Color.clear : Color.lineStrong, lineWidth: 1)
            )
            .cornerRadius(5)
    }
}

struct OutlineButton: View {
    let title: String
    /// 팝오버 버튼은 가로를 꽉 채우지만, 창 머리의 버튼은 글자만큼만 차지해야 한다.
    let wide: Bool
    let action: () -> Void
    init(_ title: String, wide: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.wide = wide; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
                .frame(maxWidth: wide ? .infinity : nil)
                .padding(.horizontal, wide ? 0 : 14)
                .frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 회의록이 도는 동안의 팝오버. 시안 2-1 의 (나)에 해당한다.
///
/// 메뉴바 고리만으로는 단계 이름·남은 시간·취소를 담을 수 없다. 그래서 시작할 때 이 화면을
/// 한 번 띄워 주고, 닫으면 메뉴바 고리가 이어받는다.
struct MeetingProgressView: View {
    @ObservedObject var model: AppModel
    let run: AppModel.MeetingRun
    /// 지남/남음 표시를 1초마다 다시 그린다. 숫자가 멈춰 있으면 그것대로 멈춘 줄 안다.
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private struct Step {
        let title: String
        /// 없으면 제목만 놓는다. 제목이 이미 뜻을 다 말하는 단계가 있다.
        let detail: String?
    }

    private let steps = [
        Step(title: "받아쓰기", detail: "이 컴퓨터 내부적으로 처리합니다."),
        Step(title: "요약하기", detail: "받아 적은 글을 AI가 요약합니다."),
        Step(title: "저장하고 복사하기", detail: nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("회의록 만드는 중").font(.system(size: 15, weight: .bold)).foregroundColor(.ink)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.text3)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 9) {
                        mark(for: index)
                            .frame(width: 15, height: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.title)
                                .font(.system(size: 12.5, weight: index == run.stepIndex ? .semibold : .regular))
                                .foregroundColor(index <= run.stepIndex ? .ink : .text3)
                            if let detail = step.detail {
                                Text(detail).font(.system(size: 10.5)).foregroundColor(.text3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 12)

            HStack(spacing: 6) {
                if let remaining = run.remainingText {
                    Text(remaining).font(.system(size: 11, weight: .semibold)).foregroundColor(.ink)
                    Text("·").font(.system(size: 11)).foregroundColor(.text4)
                }
                Text(run.elapsedText).font(.system(size: 11)).foregroundColor(.text3)
                Spacer()
                Button("취소") { model.actions.cancelMeetingNotes() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold)).foregroundColor(.coral)
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
            .id(tick)   // 1초마다 숫자를 다시 그린다

            HairLine()

            Text("이 창을 닫아도 계속됩니다 · 메뉴바에서 진행률이 보입니다.")
                .font(.system(size: 10.5)).foregroundColor(.text3)
                .padding(.horizontal, 16).padding(.vertical, 9)
        }
        .onReceive(timer) { tick = $0 }
    }

    private var subtitle: String {
        guard let seconds = run.audioSeconds else { return run.fileName }
        let m = Int(seconds) / 60, s = Int(seconds) % 60
        return "\(run.fileName) · \(m)분 \(s)초"
    }

    /// 끝난 단계는 체크, 지금 단계는 코랄 점, 아직인 단계는 빈 동그라미.
    @ViewBuilder
    private func mark(for index: Int) -> some View {
        if index < run.stepIndex {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(.coral)
        } else if index == run.stepIndex {
            ZStack {
                Circle().stroke(Color.coral.opacity(0.3), lineWidth: 2)
                Circle().trim(from: 0, to: CGFloat(run.fraction ?? 0.25))
                    .stroke(Color.coral, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
        } else {
            Circle().stroke(Color.radioOff.opacity(0.45), lineWidth: 1.5).frame(width: 13, height: 13)
        }
    }
}

/// 회의를 지금 녹음하는 중. 받아쓰기 녹음과 같은 어두운 화면을 쓴다 — 같은 일(듣는 중)이라
/// 같아 보여야 한다. 다른 점은 몇십 분씩 간다는 것이다.
struct MeetingRecordingView: View {
    @ObservedObject var model: AppModel
    let run: AppModel.MeetingRecordingRun
    @State private var tick = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.coral.opacity(0.22)).frame(width: 20, height: 20)
                    Circle().fill(Color.coral).frame(width: 10, height: 10)
                }
                Text(run.inPerson ? "대면 회의 녹음 중" : "화상 회의 녹음 중")
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                Spacer()
                Text(run.elapsedText)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(.darkSub)
                    .id(tick)
            }
            .padding(.horizontal, 16).padding(.top, 16)

            // ⚠️ 켜 둔 줄 모르면 끄지도 못한다. 그리고 **쓸 수 있다는 것 자체를** 여기서 알린다 —
            //    녹음 중이 이 기능을 쓰는 유일한 순간이라, 설정에만 적어 두면 아무도 모른다.
            highlightLine
                .padding(.horizontal, 16).padding(.top, 8)

            // 소리가 들어오고 있는지 눈으로 본다. 끝나고서야 아는 것이 제일 나쁘다.
            //
            // ⚠️ 화상이어도 **한 줄로 합쳐 보여 준다.** 전에는 "내 목소리"와 "상대방"을 나눠
            //    그렸는데, 내가 입을 다물고 있어도 상대가 말하면 "내 목소리" 막대가 같이 뛰었다.
            //    스피커로 나간 상대 목소리가 마이크로 되돌아 들어오기 때문이다(에코).
            //    소리 단계에서 떼는 건 이미 실패했고(`EchoFilter` 주석: 목소리까지 26배 감쇠),
            //    레벨만 빼는 꼼수는 두 사람이 같이 말할 때 내 쪽을 지운다. 막대가 할 일은
            //    "수음이 되고 있나"를 보여 주는 것뿐이니, 갈라서 틀리게 그리느니 합친다.
            //    (받아쓰기에서 나/상대를 가르는 것은 그대로다 — 그쪽은 글자 단계라 에코를 뗀다.)
            Waveform(levels: combinedLevels)
                .frame(height: 44)
                .padding(.top, 14).padding(.bottom, 14)

            if let notice = model.notice {
                Text(notice)
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }

            if !run.inPerson, !run.capturingSystem {
                // 모르고 회의를 다 녹음한 뒤에 알면 되돌릴 수 없다.
                Text("상대 목소리를 못 잡고 있습니다 · 화면 기록 권한이 필요합니다.")
                    .font(.system(size: 11)).foregroundColor(.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }

            HStack(spacing: 8) {
                Button(action: model.actions.stopMeetingRecording) {
                    Text("끝내고 회의록 만들기")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).frame(height: 42)
                        .background(Color.coral).cornerRadius(10)
                }
                .buttonStyle(.plain)
                // 잘못 시작했을 때 빠져나갈 길. 받아쓰기에도 있는데 여기만 없으면 갇힌다.
                Button(action: model.actions.cancelMeetingRecording) {
                    Text("취소")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.darkText)
                        .frame(width: 66).frame(height: 42)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.darkLine, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            Text("이 창을 닫아도 녹음은 계속됩니다.")
                .font(.system(size: 11)).foregroundColor(.darkMuted)
                .padding(.top, 10).padding(.bottom, 14)
        }
        .onReceive(timer) { tick = $0 }
    }

    /// 중요 표시 줄. 네 가지 모습 — 켜짐 / 표시한 것 있음 / 단축키는 있음 / 단축키도 없음.
    /// 단축키를 안 정했으면 어디서 정하는지 알려 준다.
    @ViewBuilder
    private var highlightLine: some View {
        let key = Prefs.extraHotKey(.highlight)
        // ⚠️ 단축키만 두면 단축키를 안 정한 사람은 이 기능을 아예 못 쓴다. 누를 수 있는
        //    버튼을 함께 둔다 — 팝오버가 열려 있는 동안엔 이게 더 빠르기도 하다.
        return HStack(spacing: 8) {
            Button(action: model.actions.toggleHighlight) {
                HStack(spacing: 5) {
                    Image(systemName: model.highlightOn ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.highlightOn ? "하이라이트 끝내기" : "하이라이트")
                        .font(.system(size: 11, weight: .semibold))
                    if let key, !model.highlightOn { KeyCap(key.title, accent: true) }
                }
                .foregroundColor(model.highlightOn ? .onPrimary : .darkText)
                .padding(.horizontal, 10).frame(height: 26)
                .background(model.highlightOn ? Color.coral : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(model.highlightOn ? Color.clear : Color.darkLine, lineWidth: 1))
                .cornerRadius(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("녹음 중 중요한 대목을 표시합니다")

            // 지금 어떤 상태인지. 켜져 있는 줄 모르면 끄지도 못한다.
            Group {
                if model.highlightOn {
                    Text("표시하는 중…").font(.system(size: 11, weight: .semibold)).foregroundColor(.coral)
                } else if model.highlightCount > 0 {
                    Text("\(model.highlightCount)곳 표시함").font(.system(size: 11)).foregroundColor(.darkMuted)
                } else if key == nil {
                    Text("설정 > 단축키에서 단축키도 정할 수 있습니다")
                        .font(.system(size: 11)).foregroundColor(.darkMuted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 두 갈래 중 큰 쪽. 마이크만 쓰는 대면이거나 시스템 소리를 못 잡는 중이면 그냥 마이크다.
    private var combinedLevels: [Float] {
        guard !run.inPerson, run.capturingSystem else { return model.meetingMicLevels }
        return zip(model.meetingMicLevels, model.meetingSystemLevels).map { max($0, $1) }
    }
}

/// 팝오버 탭. 시안은 밑줄이 아니라 **분절 컨트롤**이다 — 바탕 위에 고른 쪽만 흰 칸이 얹힌다.
struct PopoverTabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            tab("받아쓰기", .dictation)
            tab("회의록", .meeting)
        }
        .padding(2)
        .background(Color.line)
        .cornerRadius(9)
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func tab(_ title: String, _ value: AppModel.Tab) -> some View {
        let on = model.tab == value
        return Button(action: { model.tab = value }) {
            Text(title)
                .font(.system(size: 12.5, weight: on ? .bold : .semibold))
                .foregroundColor(on ? .ink : .text2)
                .frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(on ? Color.paper : Color.clear)
                .cornerRadius(7)
                .shadow(color: on ? Color.black.opacity(0.12) : .clear, radius: 1, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 회의록 탭. 시작하는 길이 셋이고, 시안은 색을 한 단계씩 낮춰 무게를 가른다 —
/// 대면이 가장 진하고, 파일은 가장 옅으면서 점선이다(창을 여는 동작이라).
struct MeetingTabView: View {
    @ObservedObject var model: AppModel
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                // 바로 시작하는 둘은 나란히 둔다. 성격이 같은 짝이라 위아래로 쌓으면 목록처럼 보인다.
                HStack(spacing: 8) {
                    liveCard(icon: "person.2", title: "대면 회의", fill: .meetingRow1,
                             hotKey: .inPerson,
                             action: model.actions.startMeetingInPerson)
                    // ⚠️ 대면과 같은 색을 쓴다. 전에는 한 단계 흐린 `meetingRow2` 였는데,
                    //    둘은 나란히 놓인 대등한 선택지라 색이 다르면 화상이 덜 중요해 보인다.
                    liveCard(icon: "video", title: "화상 회의", fill: .meetingRow1,
                             hotKey: .videoCall,
                             action: model.actions.startMeetingVideoCall)
                }
                // 파일은 지금 녹음하는 것이 아니라 **창을 여는** 동작이라 실시간 둘과 갈라 놓는다.
                // 색을 한 단계 물린 회색으로 둔다 — 흰 칸이면 팝오버 바탕에 묻힌다.
                // ⚠️ 끌어다 놓기는 안 된다. 팝오버 밖을 누르는 순간 닫혀서 파일을 끌어올 수가 없다.
                //    할 수 없는 일을 적어 두면 해 보다 안 돼서 앱을 탓하게 된다.
                row(icon: "doc.text",
                    title: "녹음본에서 추출", detail: nil,
                    fill: .meetingRowFile, onFill: false, dot: false,
                    action: model.actions.makeMeetingNotes)

                HStack(spacing: 5) {
                    Image(systemName: "lock").font(.system(size: 9.5)).foregroundColor(.text2)
                    Text("녹음은 이 컴퓨터 내부에만 저장됩니다.")
                        .font(.system(size: 11)).foregroundColor(.text2)
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
            // 위 구분선에 카드가 붙어 있었다. 받아쓰기 탭의 첫 버튼과 같은 14 로 띄운다.
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            HairLine()

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    // 받아쓰기 탭의 "최근 요약"과 같은 글꼴·색으로 맞춘다. 두 탭을 오가면
                    // 굵기와 색이 다른 것이 바로 보인다.
                    Text("최근 회의록").font(.system(size: 12, weight: .semibold)).foregroundColor(.text2)
                    Spacer()
                    // 시안은 두 개만 보여 준다. 더 있으면 펼쳐서 본다 —
                    // 목록 화면을 따로 만들 만큼 쌓이는 물건이 아니다.
                    if model.meetingHistory.count > 2 {
                        Button(showAll ? "접기" : "모두 보기") { showAll.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundColor(.text3)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 4)

                if model.meetingHistory.isEmpty {
                    Text("아직 만든 회의록이 없어요.")
                        .font(.system(size: 12)).foregroundColor(.text4)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                } else {
                    ForEach(showAll ? model.meetingHistory : Array(model.meetingHistory.prefix(2))) { record in
                        MeetingHistoryRow(record: record, model: model)
                    }
                }
            }
            // ⚠️ 가로 여백을 이 덩어리에 주면 안 된다. 줄이 안쪽으로 들어가서 마우스를 올렸을 때
            //    바탕이 팝오버 끝까지 차지 않는다. 받아쓰기 쪽(`HistoryRow`)처럼 여백을
            //    **줄 안쪽**에 준다.
            .padding(.top, 10).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.paperSoft)
        }
    }

    /// - Parameter detail: 없으면 한 줄로 그린다. 시안에서 대면·화상은 설명이 없다 —
    ///   무엇인지 제목만으로 알 수 있고, 설명을 붙이면 세 줄이 다 빽빽해진다.
    /// - Parameter onFill: 어두운 칸 위에 얹는지. 흰 칸이면 글자와 아이콘을 본래 색으로 쓴다.
    /// 바로 녹음이 시작되는 칸. 좁아서 아이콘과 제목을 위아래로 쌓는다.
    private func liveCard(icon: String, title: String, fill: Color,
                          hotKey: HotKey.Slot? = nil,
                          action: @escaping () -> Void) -> some View {
        let key = hotKey.flatMap { Prefs.extraHotKey($0) }
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                // ⚠️ 아이콘 칸 높이를 못 박는다. SF Symbol 은 글리프마다 높이가 달라서
                //    (2026-09-30 실측: person.2 19pt vs video 16pt) 그대로 두면 나란히 놓인
                //    두 칸의 높이가 3pt 어긋난다. 레이아웃은 같은데 아이콘 탓이다.
                Image(systemName: icon).font(.system(size: 16)).foregroundColor(.onMeetingRow)
                    .frame(height: 20, alignment: .center)
                HStack(spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(.onMeetingRow)
                    // 단축키를 정해 뒀으면 카드에 적어 둔다. 정하고도 잊어버리면 없는 것과 같다.
                    // ⚠️ 받아쓰기 버튼과 같은 `KeyCap` 을 쓴다. 따로 만들었더니 같은 팝오버 안에서
                    //    단축키 표시가 두 가지 모양이 됐다.
                    if let key { KeyCap(key.title, accent: true) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(fill)
            // 누르면 바로 녹음이 시작된다는 표시.
            .overlay(alignment: .topTrailing) {
                Circle().fill(Color.coral).frame(width: 8, height: 8).padding(10)
            }
            .cornerRadius(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(icon: String,
                     title: String, detail: String?, fill: Color, onFill: Bool,
                     dot: Bool, action: @escaping () -> Void) -> some View {
        let titleColor: Color = onFill ? .onMeetingRow : .ink
        let detailColor: Color = onFill ? .onMeetingRowSub : .text3
        return Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 14)).foregroundColor(titleColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(titleColor)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundColor(detailColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                // 누르면 바로 녹음이 시작되는 줄에만 붙인다. 파일은 창을 여는 동작이다.
                if dot { Circle().fill(Color.coral).frame(width: 8, height: 8) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            // ⚠️ 테두리를 두르지 않는다. 바탕색만으로 칸이 충분히 드러나고,
            //    테두리까지 있으면 위의 실시간 두 칸보다 오히려 더 튄다.
            .background(fill)
            .cornerRadius(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
