import Foundation

/// 화자 분리 모델(pyannote community-1 을 CoreML 로 바꾼 것). 회의록을 처음 쓸 때 한 번 받는다.
///
/// 앱에 넣지 않는 이유: 20.6MB 라 받아쓰기만 쓰는 사람에게 짐이다. 받아쓰기 모델(547MB)과 같은 생각이다.
///
/// ⚠️ **판을 못 박는다**(`revision`). 저장소 맨 끝을 받으면 어느 날 모델이 바뀌어도 모르고,
///    `vendor/FluidAudio` 의 코드는 그 판의 입출력에 맞춰져 있다. 파일 크기도 하나하나 맞춰 본다.
///
/// 출처: huggingface.co/FluidInference/speaker-diarization-coreml — CC-BY-4.0, 상업적 사용 허용.
/// pyannote · WeSpeaker · BUT Speech@FIT · Fluid Inference. 출처 표기는 README 와 설정 > 업데이트 탭에 있다.
/// 그 저장소의 옛 모델들(`wespeaker*`, `pyannote_segmentation`)은 라이선스 확인이 안 돼 받지 않는다.
enum DiarizationModels {

    static let repo = "FluidInference/speaker-diarization-coreml"
    static let revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"

    /// 받을 파일과 크기. 이 다섯 모델(.mlmodelc 넷 + PLDA 매개변수)만 쓴다.
    static let files: [(path: String, size: Int)] = [
        ("Embedding.mlmodelc/analytics/coremldata.bin", 243),
        ("Embedding.mlmodelc/coremldata.bin", 704),
        ("Embedding.mlmodelc/metadata.json", 2818),
        ("Embedding.mlmodelc/model.mil", 78432),
        ("Embedding.mlmodelc/weights/weight.bin", 13412288),
        ("FBank.mlmodelc/analytics/coremldata.bin", 243),
        ("FBank.mlmodelc/coremldata.bin", 853),
        ("FBank.mlmodelc/metadata.json", 3409),
        ("FBank.mlmodelc/model.mil", 15667),
        ("FBank.mlmodelc/weights/weight.bin", 1776896),
        ("PldaRho.mlmodelc/analytics/coremldata.bin", 243),
        ("PldaRho.mlmodelc/coremldata.bin", 763),
        ("PldaRho.mlmodelc/metadata.json", 2749),
        ("PldaRho.mlmodelc/model.mil", 7613),
        ("PldaRho.mlmodelc/weights/weight.bin", 200192),
        ("Segmentation.mlmodelc/analytics/coremldata.bin", 243),
        ("Segmentation.mlmodelc/coremldata.bin", 812),
        ("Segmentation.mlmodelc/metadata.json", 3410),
        ("Segmentation.mlmodelc/model.mil", 43063),
        ("Segmentation.mlmodelc/weights/weight.bin", 5959360),
        ("plda-parameters.json", 89416),
    ]

    static var directory: URL {
        ModelStore.directory.appendingPathComponent("diarization", isDirectory: true)
    }

    /// 다 받아져 있고 크기가 맞는가.
    static var isReady: Bool {
        files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.path)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            return size == file.size
        }
    }

    private static var downloading = false
    private static let lock = NSLock()

    /// 없으면 받는다. 이미 받는 중이면 아무것도 안 한다.
    ///
    /// ⚠️ 받는 동안은 **임시 폴더**에 받고 다 끝나야 제자리로 옮긴다. 중간에 끊기면 반쯤 받은
    ///    모델이 남아 다음에 CoreML 이 열다가 죽는다.
    static func ensure(completion: ((Bool) -> Void)? = nil) {
        if isReady { completion?(true); return }
        lock.lock()
        if downloading { lock.unlock(); completion?(false); return }
        downloading = true
        lock.unlock()

        Task.detached(priority: .utility) {
            let ok = await download()
            lock.withLock { downloading = false }
            completion?(ok)
        }
    }

    private static func download() async -> Bool {
        let fm = FileManager.default
        let staging = ModelStore.directory.appendingPathComponent("diarization.partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        let started = Date()
        do {
            for file in files {
                guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)") else {
                    throw URLError(.badURL)
                }
                let (tmp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                let size = (try fm.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? -1
                guard size == file.size else {
                    throw NSError(domain: "DiarizationModels", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "\(file.path) 크기가 다릅니다 (\(size) ≠ \(file.size))"])
                }
                let dest = staging.appendingPathComponent(file.path)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: tmp, to: dest)
            }
            try? fm.removeItem(at: directory)
            try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: directory)
            Log.write("화자 분리 모델 받음 — \(files.count)개, \(String(format: "%.1f", Date().timeIntervalSince(started)))초")
            return true
        } catch {
            try? fm.removeItem(at: staging)
            Log.write("화자 분리 모델 받기 실패: \(error.localizedDescription)")
            return false
        }
    }
}
