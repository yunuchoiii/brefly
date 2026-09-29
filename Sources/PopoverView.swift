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
                    Text(model.micReady ? "대기 중 · 마이크 준비됨" : "마이크 권한이 필요해요")
                        .font(.system(size: 12)).foregroundColor(.text2)
                }
                Spacer()
                Circle().fill(model.micReady ? Color.green : Color.coral).frame(width: 8, height: 8)
            }
            .padding(.horizontal, 16).padding(.top, 16)

            Button(action: model.actions.startRecording) {
                HStack(spacing: 8) {
                    Circle().fill(Color.coral).frame(width: 8, height: 8)
                    Text("녹음 시작").font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.onPrimary)
                .frame(maxWidth: .infinity).frame(height: 42)
                // 제목은 가운데 그대로 두고 단축키만 오른쪽에 붙인다. HStack 에 넣으면 제목이 왼쪽으로 밀린다.
                .overlay(alignment: .trailing) {
                    KeyCap(model.hotKeyTitle, accent: true).padding(.trailing, 12)
                }
                .background(Color.primaryFill)
                .cornerRadius(10)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)

            HStack(spacing: 10) {
                Text("핵심 요약").font(.system(size: 13, weight: .semibold)).foregroundColor(.ink)
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
                                   open: { model.rawExpanded = false; model.phase = .done(record, .viewing) },
                                   copy: { model.actions.copy(record) })
                    }
                    Spacer().frame(height: 6)
                }
            }
            .background(Color.paperSoft)

            HairLine()

            HStack(spacing: 14) {
                Button("설정", action: model.actions.openSettings).buttonStyle(.plain)
                Button("회의록", action: model.actions.makeMeetingNotes).buttonStyle(.plain)
                Spacer()
                Button("종료", action: model.actions.quit).buttonStyle(.plain)
            }
            .font(.system(size: 12)).foregroundColor(.text3)
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color.paper)
    }
}

struct HistoryRow: View {
    let record: SummaryRecord
    let open: () -> Void
    let copy: () -> Void
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
            }
            .buttonStyle(.plain)
            .help("요약 복사")
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
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
    @ObservedObject var model: AppModel
    let record: SummaryRecord
    let delivery: AppModel.Delivery

    var body: some View {
        VStack(spacing: 0) {
            switch delivery {
            case .copied, .pasted:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundColor(.green)
                    Text(delivery == .pasted ? "커서 위치에 붙여넣었어요" : "클립보드에 복사됐어요")
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
                    Text(model.doneNote + " — '다시 요약'으로 한 번 더 해 볼 수 있어요")
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
                    }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.text3)
                    Spacer()
                    Text(Format.relative(record.date)).font(.system(size: 11)).foregroundColor(.text4)
                }
                .padding(.horizontal, 16).padding(.top, 14)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.title).font(.system(size: 14, weight: .bold)).foregroundColor(.ink).lineLimit(2)
                Spacer(minLength: 4)
                Text(Format.localeName(record.localeID))
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.text2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.fill).cornerRadius(4)
                Text(Format.duration(record.duration)).font(.system(size: 11)).foregroundColor(.text3)
            }
            .padding(.horizontal, 16).padding(.top, 14)

            SummaryText(text: record.summary)
                .padding(.horizontal, 16).padding(.top, 10)

            HStack(spacing: 8) {
                OutlineButton(model.rawExpanded ? "원문 접기" : "원문 보기") {
                    withAnimation(.easeInOut(duration: 0.15)) { model.rawExpanded.toggle() }
                }
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
                Button(model.rawExpanded ? "접기 ↑" : "전체 원문 펼치기 ↓") {
                    withAnimation(.easeInOut(duration: 0.15)) { model.rawExpanded.toggle() }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.text3)
                .padding(.top, 2)
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
                                           model.phase = .done(record, .viewing)
                                           model.screen = .main
                                       },
                                       copy: { model.actions.copy(record) })
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
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.ink)
                .frame(maxWidth: .infinity).frame(height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.lineStrong, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
