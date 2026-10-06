import Foundation

/// 대면 회의·녹음 파일에서 **목소리로** 누가 말했는지 가른다. 받아쓴 구간에 `화자 1`, `화자 2` 를 붙인다.
///
/// 화상 회의는 이걸 안 쓴다 — 마이크(나)와 시스템 소리(상대)로 트랙이 이미 갈려 있다.
///
/// **2명 이상일 때만 붙인다.** 1명으로 나오면 nil 을 돌려주고 회의록은 지금처럼 화자 없이 간다.
/// 혼자 말한 녹음에 "화자 1:" 만 줄줄이 붙으면 읽을 것만 늘고 정보는 없다.
///
/// ⚠️ 실패해도 회의록을 막지 않는다. 모델이 없거나(아직 안 받음, macOS 13) 계산이 죽으면 nil 이다.
///    받아쓰기는 비싸고 화자는 덤이다 — 덤 때문에 본체를 잃으면 안 된다(`CLAUDE.md` 의 "요약에 매달지 말 것").
///
/// 실측(2026-10-06, M 시리즈): AMI 회의 DER 9.1%, 화자 수 6/6. 두 사람이 번갈아 말한
/// 녹음(2026-10-06-130703)은 16줄 모두 맞았다.
enum Diarizer {

    /// 화자 하나로 셀 최소 말 길이. 이보다 짧으면 군집이 잘못 쪼갠 조각으로 보고 이웃 화자에 붙인다.
    /// 기침·맞장구 한두 번이 "화자 3" 이 되는 걸 막는다.
    static let minSpeakerSeconds = 3.0

    /// - Returns: 화자가 붙은 구간. 2명 미만이거나 못 돌렸으면 nil.
    static func label(_ segments: [Whisper.Segment], audio: URL) -> [Whisper.Segment]? {
        guard !segments.isEmpty else { return nil }
        guard #available(macOS 14.0, *) else { return nil }
        // 보통은 앱을 켤 때 받아 둔다. 그래도 없으면 여기서 받는다 — 21MB 라 몇 초면 된다.
        // 인터넷이 없으면 1분 기다리고 화자 없이 간다. 받아쓴 것은 그대로 쓴다.
        if !DiarizationModels.isReady {
            Log.write("화자 분리 모델이 없어 지금 받는다")
            DiarizationModels.ensure()
            let deadline = Date().addingTimeInterval(60)
            while !DiarizationModels.isReady && Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
            guard DiarizationModels.isReady else {
                Log.write("화자 분리 건너뜀 — 모델을 받지 못했다")
                return nil
            }
        }
        let started = Date()
        guard let turns = run(audio: audio) else { return nil }
        var talk: [String: Double] = [:]
        for t in turns { talk[t.speaker, default: 0] += t.end - t.start }
        Log.write("화자 분리 말차례 \(turns.count)개 — "
                  + talk.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: "%.1f", $0.value))초" }.joined(separator: ", "))
        let labelled = assign(segments, turns: turns)
        let count = Set(labelled?.compactMap(\.speaker) ?? []).count
        Log.write("화자 분리 — \(count)명 (\(String(format: "%.1f", Date().timeIntervalSince(started)))초)"
                  + (labelled == nil ? ", 2명 미만이라 붙이지 않는다" : ""))
        return labelled
    }

    /// 모델이 낸 말차례. 시각은 초.
    struct Turn { let speaker: String; let start: Double; let end: Double }

    @available(macOS 14.0, *)
    private static func run(audio: URL) -> [Turn]? {
        let samples: [Float]
        do { samples = try Whisper.monoSamples(audio) } catch {
            Log.write("화자 분리 실패 — 소리를 못 읽었다: \(error.localizedDescription)")
            return nil
        }
        // 동기 호출로 감싼다. 회의록 파이프라인이 이미 백그라운드 큐에서 한 줄로 돈다.
        var turns: [Turn]?
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
                try await manager.prepareModels(directory: DiarizationModels.directory)
                let result = try await manager.process(audio: samples)
                turns = result.segments.map {
                    Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
                }
            } catch {
                Log.write("화자 분리 실패: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
        return turns
    }

    /// 받아쓴 구간마다 가장 많이 겹치는 화자를 붙인다. 번호는 **처음 말한 순서**로 매긴다.
    static func assign(_ segments: [Whisper.Segment], turns: [Turn]) -> [Whisper.Segment]? {
        // 너무 적게 말한 화자는 뺀다. 그 구간은 남은 화자 중 가장 가까운 쪽으로 간다.
        var talk: [String: Double] = [:]
        for t in turns { talk[t.speaker, default: 0] += t.end - t.start }
        let kept = turns.filter { (talk[$0.speaker] ?? 0) >= minSpeakerSeconds }
        guard Set(kept.map(\.speaker)).count >= 2 else { return nil }

        var raw: [String] = []
        for s in segments {
            var overlap: [String: Double] = [:]
            for t in kept {
                let o = min(s.end, t.end) - max(s.start, t.start)
                if o > 0 { overlap[t.speaker, default: 0] += o }
            }
            if let best = overlap.max(by: { $0.value < $1.value })?.key {
                raw.append(best)
            } else {
                // 겹치는 말차례가 없다(받아쓰기와 화자 모델이 말소리 구간을 다르게 봤다). 가장 가까운 쪽.
                let mid = (s.start + s.end) / 2
                let nearest = kept.min { distance(mid, $0) < distance(mid, $1) }!
                raw.append(nearest.speaker)
            }
        }
        // 받아쓴 글 기준으로도 2명이 안 되면 붙이지 않는다. 말차례는 둘이어도 글은 한 사람 것일 수 있다.
        guard Set(raw).count >= 2 else { return nil }

        var number: [String: Int] = [:]
        for id in raw where number[id] == nil { number[id] = number.count + 1 }
        return zip(segments, raw).map { s, id in
            Whisper.Segment(text: s.text, start: s.start, end: s.end, speaker: "화자 \(number[id]!)")
        }
    }

    private static func distance(_ time: Double, _ turn: Turn) -> Double {
        time < turn.start ? turn.start - time : (time > turn.end ? time - turn.end : 0)
    }

    /// 모델에 넘길 글. 같은 사람이 잇달아 말한 구간은 한 줄로 묶는다.
    static func transcript(_ labelled: [Whisper.Segment]) -> String {
        var lines: [(speaker: String, text: String)] = []
        for s in labelled {
            let speaker = s.speaker ?? ""
            let text = s.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let last = lines.last, last.speaker == speaker {
                lines[lines.count - 1].text += " " + text
            } else {
                lines.append((speaker, text))
            }
        }
        return lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}
