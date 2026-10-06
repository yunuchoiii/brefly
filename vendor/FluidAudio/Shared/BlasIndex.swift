import Accelerate

typealias BlasIndex = Int32

@inline(__always)
func makeBlasIndex(_ value: Int, label: String) throws -> BlasIndex {
    guard let cast = BlasIndex(exactly: value) else {
        // [Brefly 수정] 원본은 ASR 쪽 오류 형식(ASRError)을 던져서 ASR 코드를 통째로 끌고 왔다.
        //  화자 분리 쪽 오류 형식으로 바꾼다.
        throw OfflineDiarizationError.processingFailed("\(label) exceeds supported range")
    }
    return cast
}
