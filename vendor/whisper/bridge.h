// Swift 가 whisper.cpp 의 C API 를 바로 부르게 해 주는 다리.
// WhisperKit 같은 Swift 패키지를 쓰면 SwiftPM 이 필요해 빌드를 갈아엎어야 하는데,
// whisper.cpp 는 순수 C 라 헤더 하나만 읽히면 된다.
#include "ggml-backend.h"
#include "whisper.h"
