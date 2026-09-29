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
