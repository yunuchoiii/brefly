@preconcurrency import CoreML
import Foundation
import OSLog

@available(macOS 14.0, iOS 17.0, *)
public struct OfflineDiarizerModels: Sendable {
    public let segmentationModel: MLModel
    public let fbankModel: MLModel
    public let embeddingModel: MLModel
    public let pldaRhoModel: MLModel
    public let pldaPsi: [Double]

    public let compilationDuration: TimeInterval

    private static let logger = AppLogger(category: "OfflineDiarizerModels")

    private static func loadPLDAPsi(from directory: URL) throws -> [Double] {
        let candidatePaths = [
            directory.appendingPathComponent("plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization/plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization-coreml/plda-parameters.json", isDirectory: false),
            directory.appendingPathComponent("speaker-diarization-offline/plda-parameters.json", isDirectory: false),
        ]
        guard let parametersURL = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw OfflineDiarizationError.processingFailed("PLDA parameters file not found in \(directory.path)")
        }

        let data = try Data(contentsOf: parametersURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data, options: [])
        guard
            let root = jsonObject as? [String: Any],
            let tensors = root["tensors"] as? [String: Any],
            let psiInfo = tensors["psi"] as? [String: Any],
            let base64 = psiInfo["data_base64"] as? String,
            let decoded = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters])
        else {
            throw OfflineDiarizationError.processingFailed("Failed to decode PLDA psi parameters")
        }

        let floatCount = decoded.count / MemoryLayout<Float>.size
        guard floatCount > 0 else {
            throw OfflineDiarizationError.processingFailed("PLDA psi tensor is empty")
        }

        var floats = [Float](repeating: 0, count: floatCount)
        _ = floats.withUnsafeMutableBytes { destination in
            decoded.copyBytes(to: destination)
        }

        return floats.map { Double($0) }
    }

    public init(
        segmentationModel: MLModel,
        fbankModel: MLModel,
        embeddingModel: MLModel,
        pldaRhoModel: MLModel,
        pldaPsi: [Double],
        compilationDuration: TimeInterval
    ) {
        self.segmentationModel = segmentationModel
        self.fbankModel = fbankModel
        self.embeddingModel = embeddingModel
        self.pldaRhoModel = pldaRhoModel
        self.pldaPsi = pldaPsi
        self.compilationDuration = compilationDuration
    }

    // [Brefly 수정] FluidAudio 의 `ModelHub`(내려받기·캐시)를 쓰지 않는다. 모델은 Brefly 가
    // 따로 내려받아 한 폴더에 두고(`DiarizationModels`), 여기서는 그 폴더의 컴파일된 모델을 바로 연다.
    public static func load(
        from modelsDirectory: URL,
        configuration: MLModelConfiguration? = nil
    ) async throws -> OfflineDiarizerModels {
        let logger = Self.logger
        logger.info("Loading offline diarization models from \(modelsDirectory.path)")
        let loadStart = Date()
        let inferenceComputeUnits: MLComputeUnits = configuration?.computeUnits ?? .all

        func open(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let url = modelsDirectory.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw OfflineDiarizationError.modelNotLoaded(name)
            }
            let config = MLModelConfiguration()
            config.computeUnits = units
            return try MLModel(contentsOf: url, configuration: config)
        }
        let segmentation = try open("Segmentation", inferenceComputeUnits)
        let embedding = try open("Embedding", inferenceComputeUnits)
        let plda = try open("PldaRho", inferenceComputeUnits)
        // FluidAudio 원본도 FBank 는 CPU 에 묶는다 — CPU 가 가장 빠르다.
        let fbankComputeUnits: MLComputeUnits = .cpuOnly
        let fbank = try open("FBank", fbankComputeUnits)

        let pldaPsi = try loadPLDAPsi(from: modelsDirectory)
        let compilationDuration = Date().timeIntervalSince(loadStart)
        logger.info("Offline diarization models ready (\(String(format: "%.3f", compilationDuration))s)")

        return OfflineDiarizerModels(
            segmentationModel: segmentation,
            fbankModel: fbank,
            embeddingModel: embedding,
            pldaRhoModel: plda,
            pldaPsi: pldaPsi,
            compilationDuration: compilationDuration
        )
    }
}

extension MLComputeUnits {
    fileprivate var label: String {
        switch self {
        case .cpuOnly:
            return ".cpuOnly"
        case .cpuAndGPU:
            return ".cpuAndGPU"
        case .cpuAndNeuralEngine:
            return ".cpuAndNeuralEngine"
        case .all:
            return ".all"
        @unknown default:
            return ".unknown"
        }
    }
}
