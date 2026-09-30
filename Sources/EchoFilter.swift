import Foundation

/// 마이크 트랙에 섞여 들어온 **상대 목소리**를 글자 단계에서 걷어낸다.
///
/// 노트북 스피커로 회의하면 상대 목소리가 마이크로 되돌아 들어온다. 그대로 두면 회의록에
/// 상대의 말이 두 번씩 적힌다. 혼자 있는 방에서 스피커로 하는 것이 보통이라 이어폰을
/// 전제할 수도 없다.
///
/// ⚠️ 소리 단계에서 막으려다 실패했다. `setVoiceProcessingEnabled(true)` 는 에코와 함께
///    목소리까지 26배 깎았다(2026-09-29 실측). 그래서 글자 단계에서 푼다 —
///    마이크에 섞인 에코는 **같은 시각 시스템 트랙에 있는 것과 같은 말**이므로,
///    시간으로 맞춰 겹치는 것을 빼면 된다. 하드웨어를 안 타는 것이 이 방식의 값어치다.
enum EchoFilter {

    /// 겹친다고 보는 시간 여유. 두 트랙은 같은 순간을 받아쓰지만 구간 경계가 딱 맞지는 않는다.
    private static let slack: Double = 4.0
    /// 같은 말로 보는 기준. 받아쓰기가 조금씩 다르게 들으므로 완전히 같기를 기대하면 안 된다.
    private static let sameEnough: Double = 0.62

    /// 마이크 구간 중 **시스템 쪽에도 같은 말이 같은 때 있는 것**을 뺀다.
    ///
    /// ⚠️ 전에는 "8자 미만은 절대 안 지운다"는 걸림돌을 뒀다. "네", "맞아요" 같은 맞장구를
    ///    지키려던 것인데, 2026-09-29 48분 화상회의에서 참담하게 실패했다. 스피커 에코는
    ///    소리가 작고 뭉개져서 whisper 가 **낱말 단위로** 끊는다 — 마이크 구간 1,937개 중
    ///    **60%가 8자 미만**이었다. 그래서 1,937개 중 110개(5.7%)만 걸러졌고, 회의 전체가
    ///    "나"가 말한 것으로 적혔다. 맞장구 하나를 지키려다 상대의 48분을 내 말로 만들었다.
    ///    걸림돌을 걷어내고, 대신 **같은 때 스피커에도 실제로 있던 말**만 뺀다.
    static func removeEcho(mic: [Whisper.Segment], system: [Whisper.Segment]) -> [Whisper.Segment] {
        guard !system.isEmpty else { return mic }
        return mic.filter { segment in
            let nearby = system.filter { $0.start < segment.end + slack && $0.end > segment.start - slack }
            guard !nearby.isEmpty else { return true }
            let mine = normalize(segment.text)
            guard !mine.isEmpty else { return false }
            // 같은 때 스피커로 나간 말 안에 통째로 들어 있으면 에코다. 낱말 조각이 이 길로 걸린다.
            let spoken = nearby.map { normalize($0.text) }.joined()
            if spoken.contains(mine) { return false }
            return !nearby.contains { similarity(mine, normalize($0.text)) >= sameEnough }
        }
    }

    /// 두 트랙을 시간순으로 엮어 누가 말했는지 붙인 **구간**을 돌려준다. 화면(원문 탭)이 쓴다.
    static func labelled(mic: [Whisper.Segment], system: [Whisper.Segment]) -> [Whisper.Segment] {
        let mine = removeEcho(mic: mic, system: system).map {
            Whisper.Segment(text: $0.text, start: $0.start, end: $0.end,
                            speaker: system.isEmpty ? nil : "나")
        }
        let theirs = system.map {
            Whisper.Segment(text: $0.text, start: $0.start, end: $0.end, speaker: "상대")
        }
        return (mine + theirs).sorted { $0.start < $1.start }
    }

    /// 두 트랙을 시간순으로 엮어 누가 말했는지 붙인 **글**. 모델에 넘길 원문이다.
    /// 화상회의에서는 이 갈래가 곧 화자 구분이다 — 모델을 돌려야 얻을 정보를 채널이 이미 준다.
    static func merge(mic: [Whisper.Segment], system: [Whisper.Segment]) -> String {
        guard !system.isEmpty else { return mic.map(\.text).joined(separator: " ") }
        return labelled(mic: mic, system: system)
            .map { "\($0.speaker ?? "나"): \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - 견주기

    /// 띄어쓰기·문장부호를 걷어낸다. 받아쓰기는 같은 말도 띄어쓰기를 다르게 적는다.
    private static func normalize(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 두 글자열이 얼마나 같은지 0~1. 글자 두 개씩 묶어 견준다 —
    /// 낱말로 자르면 받아쓰기가 붙여 쓴 것과 띄어 쓴 것이 아예 다른 말이 된다.
    private static func similarity(_ a: String, _ b: String) -> Double {
        guard a.count > 1, b.count > 1 else { return a == b ? 1 : 0 }
        // 한쪽이 다른 쪽을 품으면 같은 말로 본다. 에코는 앞뒤가 잘려 들어오는 일이 잦다.
        if a.contains(b) || b.contains(a) {
            return Double(min(a.count, b.count)) / Double(max(a.count, b.count)) >= 0.7 ? 1 : 0
        }
        let pairsA = Set(bigrams(a)), pairsB = Set(bigrams(b))
        guard !pairsA.isEmpty, !pairsB.isEmpty else { return 0 }
        let shared = pairsA.intersection(pairsB).count
        return Double(shared) / Double(min(pairsA.count, pairsB.count))
    }

    private static func bigrams(_ text: String) -> [String] {
        let chars = Array(text)
        guard chars.count > 1 else { return [] }
        return (0..<(chars.count - 1)).map { String(chars[$0...$0 + 1]) }
    }
}
