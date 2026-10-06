# FluidAudio — 오프라인 화자 분리 (일부만 가져옴)

- 출처: https://github.com/FluidInference/FluidAudio , 커밋 `04e363c`
- 라이선스: Apache License 2.0 (`LICENSE`)
- 저작권: © Fluid Inference

pyannote **community-1** 파이프라인(분할 → 화자 특징 → PLDA → VBx 군집)을 CoreML 로 돌리는
`Sources/FluidAudio/Diarizer/Offline/` 와, 그것이 기대는 최소한의 파일만 가져왔다.
SwiftPM 패키지 전체를 붙이지 않은 이유는 Brefly 가 `swiftc` 하나로 빌드하기 때문이다(`build.sh`).

## 가져온 것

| 여기 | 원본 |
| --- | --- |
| `Offline/**` | `Sources/FluidAudio/Diarizer/Offline/**` |
| `Core/DiarizerTypes.swift` | `Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift` |
| `Shared/AppLogger.swift`, `AudioSampleSource.swift`, `ANEMemoryOptimizer.swift`, `ANEMemoryUtils.swift` | `Sources/FluidAudio/Shared/` |
| `Shared/HungarianAssignment.swift` | `Sources/FluidAudio/Diarizer/HungarianAssignment.swift` |
| `Shared/BlasIndex.swift` | `Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/Decoder/BlasIndex.swift` |
| `FastClusterWrapper/**` | `Sources/FastClusterWrapper/**` (C++ — 아래 fastcluster) |

## 고친 것 (Apache-2.0 4조 b항에 따라 밝힌다)

`[Brefly 수정]` 주석으로 표시했다.

- `Offline/Core/OfflineDiarizerModels.swift` — `ModelHub`(내려받기·캐시) 대신 Brefly 가 받아 둔 폴더의
  컴파일된 모델을 `MLModel(contentsOf:)` 로 바로 연다. `defaultModelsDirectory()` 를 뺐다.
- `Offline/Core/OfflineDiarizerManager.swift` — `prepareModels` 의 내려받기·캐시 지우기·다시 받기 경로를 빼고
  `directory` 를 꼭 받게 했다. 파일 URL 로 처리하는 `process(_:)`(디스크 스트리밍 팩토리)와 `purgeDiarizerRepo` 를 뺐다.
  모델을 알아서 받지 않고, 없으면 `modelNotLoaded` 를 던진다.
- `Shared/BlasIndex.swift` — ASR 쪽 오류 형식(`ASRError`) 대신 `OfflineDiarizationError` 를 던진다.
  원본대로 두면 ASR 코드 전체가 딸려 왔다.

## fastcluster

`FastClusterWrapper/fastcluster_internal.hpp` 는 fastcluster 의 일부다.
© 2011 Daniel Müllner (1.1.23 까지), © Google Inc. (1.1.24 부터). BSD 2-Clause — `FastClusterWrapper/LICENSE-fastcluster`.

## 모델

모델 파일은 여기 없다. 처음 쓸 때 `huggingface.co/FluidInference/speaker-diarization-coreml` 에서 받는다
(`Sources/DiarizationModels.swift`). 그 모델의 라이선스·출처 표기는 저장소 `README.md` 에 있다.
