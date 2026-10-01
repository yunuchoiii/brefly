import AppKit
import AVFoundation
import Speech

/// 사용자가 개발자에게 문제를 알리는 길.
///
/// **아무것도 자동으로 보내지 않는다.** 메일 앱을 열어 줄 뿐이고, 보내기는 사용자가 누른다.
/// 회의 내용을 다루는 앱이라 "앱이 알아서 서버로 쏜다"는 구조를 쓰지 않는다 —
/// 무엇이 나가는지 본인이 보고 지울 수 있어야 한다.
enum Feedback {

    /// 받을 곳. 바꿀 일이 생기면 여기만 고친다.
    static let address = "chltjdnjs529@gmail.com"

    /// 어디가 막혔는지 알아내는 데 필요한 **사실만** 모은다.
    ///
    /// ⚠️ 여기에는 말한 내용이 **한 글자도** 들어가지 않는다. 로그에서 "최근 오류 줄"을 몇 개
    ///    끌어다 붙일까 했는데 그만뒀다 — 오류 줄에도 받아쓴 말과 회의록 파일 경로(= 회의 제목)가
    ///    섞인다. 내용이 필요하면 사용자가 체크해서 로그를 직접 붙이게 한다.
    static func diagnostics() -> String {
        let rec = SFSpeechRecognizer(locale: Locale(identifier: Prefs.localeID))
        let os = ProcessInfo.processInfo.operatingSystemVersion
        func yn(_ on: Bool) -> String { on ? "있음" : "없음" }
        return """
            [Brefly 진단 정보]
            앱: \(appVersion())
            macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(machine())

            권한
            - 마이크: \(permission(AVCaptureDevice.authorizationStatus(for: .audio).rawValue))
            - 음성 인식: \(permission(SFSpeechRecognizer.authorizationStatus().rawValue))
            - 손쉬운 사용: \(yn(Paster.isTrusted))

            인식
            - 언어: \(Prefs.localeID)
            - 애플 서버 인식: \(Prefs.forceServerRecognition ? "켬" : "끔")
            - recognizer 사용 가능: \(rec?.isAvailable.description ?? "생성 실패")
            - 받아쓰기 모델 내려받음: \(yn(ModelStore.hasTranscriptionModel))

            정리
            - 받아쓰기: \(Prefs.Choice(backend: Prefs.backend, tier: Prefs.tier).title)
            - 회의록: \(Prefs.Choice(backend: Prefs.meetingBackend, tier: Prefs.meetingTier).title)
            - 회의록 요약 정도: \(Prefs.meetingDetail.title)
            - Gemini 모델: \(Prefs.geminiModel)

            키 (값은 보내지 않습니다)
            - Gemini: \(yn(KeychainStore.read(.gemini)?.isEmpty == false))
            - Claude: \(yn(KeychainStore.read(.anthropic)?.isEmpty == false))
            - ChatGPT: \(yn(KeychainStore.read(.openai)?.isEmpty == false))
            """
    }

    static func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    private static func permission(_ raw: Int) -> String {
        raw == 3 ? "허용" : "허용 안 됨(\(raw))"
    }

    /// 맥 모델 식별자(MacBookPro18,3). 기종마다 다른 문제가 있어서 쓸모가 있다.
    private static func machine() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        return String(cString: chars)
    }

    /// 로그 꼬리. 줄 수를 못 박는다 — 통째로 붙이면 몇 달 치가 따라간다.
    static func logTail(lines: Int = 150) -> String {
        guard let text = try? String(contentsOf: Log.url, encoding: .utf8) else {
            return "(로그를 읽지 못했습니다)"
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }

    /// 메일 앱을 연다. 본문이 길면 열리지 않거나 잘리는 일이 있어서, 긴 쪽은 클립보드로 넘긴다.
    ///
    /// ⚠️ `mailto:` 본문 길이 한계는 보장된 값이 아니다. 넉넉히 잡아 2,000자를 넘으면
    ///    클립보드로 보내고 붙여넣게 한다 — 메일이 안 열리는 것보다 한 번 붙여넣는 게 낫다.
    static func compose(summary: String, body: String) -> Bool {
        let subject = "Brefly \(appVersion()) — \(summary.isEmpty ? "문제 알림" : String(summary.prefix(60)))"
        let viaClipboard = body.count > 2000
        let mailBody = viaClipboard
            ? "아래에 붙여넣기(⌘V) 해 주세요. 보내기 전에 내용을 확인하실 수 있습니다.\n\n"
            : body
        if viaClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = address
        parts.queryItems = [URLQueryItem(name: "subject", value: subject),
                            URLQueryItem(name: "body", value: mailBody)]
        guard let url = parts.url else { return false }
        NSWorkspace.shared.open(url)
        return viaClipboard
    }
}
