import Foundation

/// 요약 한 건. 팝오버의 "최근 요약"과 히스토리 화면에 쓴다.
struct SummaryRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var summary: String
    var raw: String
    var date: Date
    var duration: TimeInterval
    var localeID: String
    /// false면 정리 없이 원문을 그대로 넘긴 것.
    var polished: Bool
}

enum HistoryStore {

    private static let key = "history"
    private static let limit = 50

    static func load() -> [SummaryRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([SummaryRecord].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [SummaryRecord]) {
        let trimmed = Array(list.prefix(limit))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// 목록에서 이름을 바꾼다. 요약은 글자만 있으므로 파일을 옮길 일이 없다 —
    /// 회의록(`MeetingHistoryStore.rename`)은 `.md` 파일도 같이 옮겨야 해서 다르다.
    static func rename(id: UUID, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        list[i].title = trimmed
        save(list)
    }

    /// 기록 하나를 지운다. 요약과 원문이 이 안에만 있으므로 **되돌릴 수 없다.**
    static func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    /// 요약 첫 문장에서 제목을 뽑는다. LLM을 한 번 더 부르지 않는다.
    static func makeTitle(from summary: String) -> String {
        // 요약 스타일은 "주제: 내용" 불릿이 많다. 첫 불릿을 제목으로 쓰면 바로 아래 첫 불릿과 똑같이 두 번 보여서
        // 주제들을 이어 제목으로 쓴다 ("온보딩 첫 화면 · 단축키 안내").
        let topics = summary.split(separator: "\n").compactMap { line -> String? in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard l.hasPrefix("- "), let colon = l.range(of: ": ") else { return nil }
            let topic = l[l.index(l.startIndex, offsetBy: 2)..<colon.lowerBound].replacingOccurrences(of: "**", with: "")
            return (1...16).contains(topic.count) ? topic : nil
        }
        if topics.count >= 2 {
            let joined = topics.joined(separator: " · ")
            return joined.count > 34 ? joined.prefix(34).trimmingCharacters(in: .whitespaces) + "…" : joined
        }

        let firstLine = summary
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""

        // 불릿·번호 접두어 제거
        var line = firstLine
        for prefix in ["- ", "• ", "* ", "· "] where line.hasPrefix(prefix) {
            line.removeFirst(prefix.count)
        }
        if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
            line.removeSubrange(range)
        }
        // 마크다운 굵게 표시 제거
        line = line.replacingOccurrences(of: "**", with: "")

        let maxLength = 34
        if line.count > maxLength {
            let cut = line.prefix(maxLength).trimmingCharacters(in: .whitespaces)
            return cut + "…"
        }
        // 문장 끝 마침표는 제목에서 뺀다
        if line.hasSuffix(".") { line.removeLast() }
        return line.isEmpty ? "제목 없음" : line
    }
}

// MARK: - 표시용 포맷

enum Format {

    private static let ko = Locale(identifier: "ko_KR")

    private static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = ko
        f.dateFormat = "a h:mm"
        return f
    }()

    private static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = ko
        f.dateFormat = "M월 d일"
        return f
    }()

    /// "방금", "14분 전", "오전 11:02", "어제", "8월 30일"
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let secs = now.timeIntervalSince(date)
        if secs < 60 { return "방금" }
        if secs < 3600 { return "\(Int(secs / 60))분 전" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return timeOfDay.string(from: date) }
        if cal.isDateInYesterday(date) { return "어제" }
        return monthDay.string(from: date)
    }

    /// "47초", "2분 40초", "1시간 2분"
    static func duration(_ secs: TimeInterval) -> String {
        let total = Int(secs.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)시간 \(m)분" }
        if m > 0 { return "\(m)분 \(String(format: "%02d", s))초" }
        return "\(s)초"
    }

    /// "0:47"
    static func timer(_ secs: TimeInterval) -> String {
        let total = Int(secs)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "ko-KR" → "한국어", "en-US" → "English"
    static func localeName(_ id: String) -> String {
        if let match = Prefs.locales.first(where: { $0.id == id }) {
            // "English (US)" → "English"
            return match.title.components(separatedBy: " (").first ?? match.title
        }
        return id
    }
}
