import AVFoundation

/// 녹음은 끝났는데 회의록이 안 나온 회의를 찾는다. 앱을 켤 때 한 번 본다.
///
/// 받아쓰기·요약 중에 앱이 죽거나 꺼지면(버그, 종료, 강제 종료) 그 회의는 녹음만 숨은 폴더에 남고
/// 목록에는 아무것도 안 뜬다. 사용자는 회의록이 사라진 줄 안다. 녹음이 있으니 다시 만들 수 있다.
///
/// 끝난 회의는 `finishedMarker` 로 표시한다. 회의록이 나왔든, 말이 없어 안 만들었든, 사용자가
/// 멈췄든 **처리가 끝까지 간** 것이다. 표시가 없으면 처리 도중 끊긴 것이다.
///
/// ⚠️ 이 표시를 들이기 전의 폴더에는 표시가 없다. 그것까지 다 물으면 첫 실행에 옛 시험 녹음
///    수십 개가 쏟아진다. 그래서 이 기능을 처음 켠 시각(`Prefs` 의 `meetingRecoverySince`)
///    뒤에 시작한 녹음만 본다.
enum MeetingRecovery {

    static let finishedMarker = ".brefly-finished"

    struct Unfinished {
        let folder: URL
        let mic: URL
        let system: URL?
        let startedAt: Date
        /// 녹음 길이(초). 헤더가 깨져 있으면 고친 뒤 잰 값이다.
        let seconds: Double
    }

    private static var meetingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Brefly/meetings", isDirectory: true)
    }

    private static let sinceKey = "meetingRecoverySince"
    private static let dismissedKey = "meetingRecoveryDismissed"

    /// 처리가 끝까지 갔다고 적어 둔다. 결과가 무엇이든 부른다.
    static func markFinished(_ folder: URL) {
        let marker = folder.appendingPathComponent(finishedMarker)
        FileManager.default.createFile(atPath: marker.path, contents: Data())
    }

    /// "묻지 않기"를 누른 회의. 녹음은 지우지 않는다 — 다시 만들 수 없는 것이다.
    static func dismiss(_ folder: URL) {
        var list = UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []
        list.append(folder.lastPathComponent)
        UserDefaults.standard.set(list, forKey: dismissedKey)
    }

    /// 끊긴 회의를 최근 것부터. `excluding` 은 지금 녹음하거나 만드는 중인 폴더다.
    static func find(excluding busy: URL? = nil) -> [Unfinished] {
        let d = UserDefaults.standard
        guard let since = d.object(forKey: sinceKey) as? Date else {
            d.set(Date(), forKey: sinceKey)
            return []
        }
        let dismissed = Set(d.stringArray(forKey: dismissedKey) ?? [])
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: meetingsDirectory, includingPropertiesForKeys: nil)
        else { return [] }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        var found: [Unfinished] = []
        for folder in folders {
            let name = folder.lastPathComponent
            guard let startedAt = stamp.date(from: name), startedAt > since,
                  !dismissed.contains(name),
                  folder.standardizedFileURL != busy?.standardizedFileURL else { continue }
            let mic = folder.appendingPathComponent("mic.wav")
            guard fm.fileExists(atPath: mic.path),
                  !fm.fileExists(atPath: folder.appendingPathComponent(finishedMarker).path) else { continue }
            let files = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            // 표시를 남기기 전에 죽었어도 회의록이 있으면 끝난 것이다.
            guard !files.contains(where: { $0.hasSuffix("회의록.md") }) else { continue }

            repairHeaderIfNeeded(mic)
            let system = folder.appendingPathComponent("system.wav")
            if fm.fileExists(atPath: system.path) { repairHeaderIfNeeded(system) }
            // 화상 회의인데 시스템 소리를 못 잡았으면 머리만 있는 빈 파일이 남는다. 무음을 받아쓰면
            // whisper 가 말을 지어내므로 1초도 안 되면 없는 것으로 본다(녹음을 마칠 때와 같은 판단).
            let hasSystem = (try? AVAudioFile(forReading: system)).map { $0.length > Int64($0.fileFormat.sampleRate) } ?? false
            let seconds = (try? AVAudioFile(forReading: mic)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
            // 몇 초짜리는 잘못 누른 것이다. 물을 거리가 아니다.
            guard seconds >= 10 else { continue }
            found.append(Unfinished(folder: folder, mic: mic, system: hasSystem ? system : nil,
                                    startedAt: startedAt, seconds: seconds))
        }
        return found.sorted { $0.startedAt > $1.startedAt }
    }

    /// 녹음 중에 앱이 죽으면 WAV 머리의 길이 칸이 갱신되지 않는다. 소리는 파일에 다 있는데
    /// 머리가 "0바이트"라고 해서 아무 프로그램도 못 연다. 머리만 실제 파일 길이로 고친다.
    ///
    /// 고칠지 말지는 머리에 적힌 길이와 실제 파일 크기를 견줘 정한다. 정상 파일은 건드리지 않는다.
    @discardableResult
    static func repairHeaderIfNeeded(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 44 else { return false }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 4096), head.count >= 12,
              String(data: head[0..<4], encoding: .ascii) == "RIFF",
              String(data: head[8..<12], encoding: .ascii) == "WAVE" else { return false }

        func u32(_ at: Int) -> UInt32 {
            head[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
        }
        // 덩어리를 따라가며 'data' 를 찾는다. 'fmt ' 앞뒤로 'JUNK'·'FLLR' 이 끼어 있다.
        var offset = 12
        var dataSizeAt: Int?
        var dataStart = 0
        while offset + 8 <= head.count {
            let id = String(data: head[offset..<offset + 4], encoding: .ascii)
            if id == "data" { dataSizeAt = offset + 4; dataStart = offset + 8; break }
            offset += 8 + Int(u32(offset + 4))
        }
        guard let dataSizeAt else { return false }

        let actual = UInt64(fileSize) - UInt64(dataStart)
        let declared = UInt64(u32(dataSizeAt))
        // 1KB 넘게 어긋날 때만 고친다. 꼬리에 짧은 덩어리가 붙는 정상 파일도 있다.
        guard declared + 1024 < actual else { return false }

        func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let dataSize = UInt32(min(actual, UInt64(UInt32.max)))
        let riffSize = UInt32(min(UInt64(fileSize) - 8, UInt64(UInt32.max)))
        try? handle.seek(toOffset: 4)
        try? handle.write(contentsOf: le(riffSize))
        try? handle.seek(toOffset: UInt64(dataSizeAt))
        try? handle.write(contentsOf: le(dataSize))
        Log.write("녹음 머리 고침 — \(url.path) (\(declared) → \(dataSize)바이트)")
        return true
    }
}
