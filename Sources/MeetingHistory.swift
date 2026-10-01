import Foundation

/// 만들어 둔 회의록 하나. 팝오버 "최근 회의록"과 다시 열기에 쓴다.
struct MeetingRecord: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case inPerson, videoCall, file

        var title: String {
            switch self {
            case .inPerson:  return "대면"
            case .videoCall: return "화상"
            case .file:      return "녹음 파일"
            }
        }
    }

    let id: String
    let title: String
    let date: Date
    let kind: Kind
    /// 녹음 길이(초). 못 읽었으면 nil.
    let seconds: Double?
    /// "할 일" 몇 개인지. 목록에서 "이 회의에 할 일이 있었나"를 바로 보여 준다.
    let todoCount: Int
    /// 저장한 .md 파일 경로. 사용자가 옮기거나 지울 수 있으므로 열기 전에 있는지 본다.
    let notesPath: String
    let audioPath: String

    var notesFile: URL { URL(fileURLWithPath: notesPath) }
    var audioFile: URL { URL(fileURLWithPath: audioPath) }

    /// "어제 · 화상 · 35분 · 할 일 3개" 꼴.
    var subtitle: String {
        var parts = [Self.dateText(date), kind.title]
        if let seconds { parts.append("\(Int(seconds) / 60)분") }
        if todoCount > 0 { parts.append("할 일 \(todoCount)개") }
        return parts.joined(separator: " · ")
    }

    /// 오늘·어제는 그렇게 적고, 그 전은 날짜로 적는다. "3일 전"은 세어 봐야 알 수 있어 안 쓴다.
    private static func dateText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "a h:mm"
            return f.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "어제" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR"); f.dateFormat = "M월 d일"
        return f.string(from: date)
    }
}

enum MeetingHistoryStore {

    private static let key = "meetingHistory"
    private static let limit = 50

    static func load() -> [MeetingRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([MeetingRecord].self, from: data) else { return [] }
        // 파일을 지웠거나 옮겼으면 목록에서도 뺀다. 눌렀더니 아무것도 안 열리는 것보다 낫다.
        return list.filter { FileManager.default.fileExists(atPath: $0.notesPath) }
    }

    static func add(_ record: MeetingRecord) {
        var list = load()
        list.removeAll { $0.notesPath == record.notesPath }
        list.insert(record, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 이름을 바꾼다. **`.md` 파일 이름도 같이 바꾼다** — 목록과 파일 이름이 갈리면
    /// Finder 에서 열었을 때 어느 것이 그것인지 알 수 없다.
    /// 파일을 못 옮기면(이미 있는 이름 등) 목록 이름만 바꾸고 경로는 그대로 둔다.
    /// - Returns: 바뀐 기록. 그런 기록이 없으면 nil.
    @discardableResult
    static func rename(notesPath: String, to newTitle: String) -> MeetingRecord? {
        var list = load()
        guard let i = list.firstIndex(where: { $0.notesPath == notesPath }) else { return nil }
        let old = list[i]
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var path = old.notesPath
        let source = URL(fileURLWithPath: old.notesPath)
        // 파일 이름에 쓸 수 없는 글자를 걷어낸다. `/` 가 들어가면 엉뚱한 폴더를 가리킨다.
        let safe = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let target = source.deletingLastPathComponent().appendingPathComponent("\(safe) 회의록.md")
        if target != source, !FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.moveItem(at: source, to: target)
                path = target.path
            } catch {
                Log.write("회의록 파일 이름 바꾸기 실패 — 목록 이름만 바꿈: \(error.localizedDescription)")
            }
        }
        let renamed = MeetingRecord(id: old.id, title: trimmed, date: old.date, kind: old.kind,
                                    seconds: old.seconds, todoCount: old.todoCount,
                                    notesPath: path, audioPath: old.audioPath)
        list[i] = renamed
        save(list)
        return renamed
    }

    /// 목록에서만 뺀다. **녹음과 `.md` 파일은 건드리지 않는다** —
    /// 녹음은 다시 만들 수 없는 것이라 목록에서 지운다고 같이 지우면 안 된다.
    static func forget(notesPath: String) {
        save(load().filter { $0.notesPath != notesPath })
    }

    private static func save(_ list: [MeetingRecord]) {
        if let data = try? JSONEncoder().encode(Array(list.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 다시 요약해서 "할 일" 개수가 달라졌을 때. 목록에 옛 숫자가 남으면 안 된다.
    static func updateTodos(notesPath: String, count: Int) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.notesPath == notesPath }) else { return }
        let old = list[i]
        list[i] = MeetingRecord(id: old.id, title: old.title, date: old.date, kind: old.kind,
                                seconds: old.seconds, todoCount: count,
                                notesPath: old.notesPath, audioPath: old.audioPath)
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// 받아쓴 구간은 목록에 담기엔 너무 크다(35분이면 1300개쯤). 파일로 따로 둔다.
    /// 사용자 폴더에 부스러기를 남기지 않으려고 앱 폴더에 넣는다.
    private static var segmentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Brefly/transcripts", isDirectory: true)
    }

    static func saveSegments(_ segments: [Whisper.Segment], id: String) {
        try? FileManager.default.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        let rows = segments.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        try? data.write(to: segmentsDirectory.appendingPathComponent("\(id).json"))
    }

    static func segments(id: String) -> [Whisper.Segment] {
        guard let data = try? Data(contentsOf: segmentsDirectory.appendingPathComponent("\(id).json")),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let text = row["text"] as? String,
                  let start = row["start"] as? Double,
                  let end = row["end"] as? Double else { return nil }
            return Whisper.Segment(text: text, start: start, end: end)
        }
    }

    /// 회의록 본문에서 제목을 뽑는다. `## 한 줄 요약` 아래 첫 문장이다.
    ///
    /// 모델을 한 번 더 부르지 않는다 — 요약이 이미 "회의가 무엇을 다뤘고 무엇이 정해졌는지
    /// 한 문장"을 쓰게 돼 있다. 받아쓰기 쪽 `HistoryStore.makeTitle` 과 같은 생각이다.
    ///
    /// ⚠️ 못 뽑으면 nil 을 돌려준다. 부르는 쪽이 날짜-시각으로 물러선다 —
    ///    엉뚱한 제목보다 날짜가 낫다.
    static func titleFromNotes(_ notes: String) -> String? {
        var inSummary = false
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                // 다른 항목으로 넘어갔으면 한 줄 요약이 비어 있던 것이다.
                if inSummary { return nil }
                inSummary = line.contains("한 줄 요약")
                continue
            }
            guard inSummary, !line.isEmpty else { continue }
            line = line.replacingOccurrences(of: "**", with: "")
            if line.hasPrefix("- ") { line = String(line.dropFirst(2)) }
            // 한 문장만 쓴다. 두 문장이면 제목이 길어 목록에서 잘린다.
            if let dot = line.range(of: "다. ") {
                line = String(line[..<dot.upperBound]).trimmingCharacters(in: .whitespaces)
            }
            // 파일 이름에 못 쓰는 글자를 미리 치운다. `rename` 도 같은 일을 한다.
            line = line.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: CharacterSet(charactersIn: " .·"))
            guard line.count >= 4 else { return nil }
            return line.count > 40 ? line.prefix(40).trimmingCharacters(in: .whitespaces) + "…" : line
        }
        return nil
    }

    /// 회의록 본문에서 "할 일"이 몇 개인지 센다. 그 항목 아래 불릿만 센다 —
    /// 전체 불릿을 세면 "논의한 것"까지 들어가 숫자가 뜻을 잃는다.
    static func countTodos(in notes: String) -> Int {
        var counting = false
        var count = 0
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                counting = line.contains("할 일")
                continue
            }
            if counting, line.hasPrefix("- ") { count += 1 }
        }
        return count
    }
}
