import Foundation
import AppKit

/// API 키는 ~/Library/Application Support/Brefly/keys.json (0600) 에, 나머지 설정은 UserDefaults 에.
///
/// 원래는 키체인이었다. 자체 서명 앱은 빌드마다(심지어 고정 인증서로 바꾼 뒤에도) 키체인 항목을 읽을 때
/// 암호 창이 떴고 "항상 허용"도 안 남았다 (2026-09-04). 개인 도구라 본인만 읽는 파일로 충분하다.
enum KeychainStore {

    enum Slot: String, CaseIterable {
        case anthropic = "anthropic-api-key"
        case gemini    = "gemini-api-key"
        case openai    = "openai-api-key"

        var envVar: String {
            switch self {
            case .anthropic: return "ANTHROPIC_API_KEY"
            case .gemini:    return "GEMINI_API_KEY"
            case .openai:    return "OPENAI_API_KEY"
            }
        }
    }

    /// 미리보기 렌더처럼 실제 키가 필요 없을 때 넣어 두는 가짜 값.
    static var stub: [Slot: String]?

    static let fileURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Brefly", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("keys.json")
    }()

    static var storageDescription: String { "~/Library/Application Support/Brefly/keys.json (본인만 읽기)" }

    private static let lock = NSLock()
    private static var loaded: [String: String]?

    private static func load() -> [String: String] {
        if let loaded { return loaded }
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dict = json
        }
        loaded = dict
        return dict
    }

    private static func save(_ dict: [String: String]) {
        loaded = dict
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func read(_ slot: Slot) -> String? {
        if let stub { return stub[slot] }
        // 환경변수가 있으면 우선 사용 (터미널에서 테스트할 때 편함)
        if let env = ProcessInfo.processInfo.environment[slot.envVar], !env.isEmpty {
            return env
        }
        lock.lock(); defer { lock.unlock() }
        if let v = load()[slot.rawValue], !v.isEmpty { return v }
        return nil
    }

    @discardableResult
    static func write(_ key: String, to slot: Slot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var dict = load()
        if key.isEmpty { dict.removeValue(forKey: slot.rawValue) } else { dict[slot.rawValue] = key }
        save(dict)
        return true
    }

    // 기존 호출부 호환
    static func readAPIKey() -> String? { read(.anthropic) }
    @discardableResult
    static func writeAPIKey(_ key: String) -> Bool { write(key, to: .anthropic) }
}

enum Prefs {

    private static let d = UserDefaults.standard

    /// 앱 이름이 바뀌면서 번들 ID 도 바뀌었다. Sokgi → Sokki (2026-09-04), Sokki → Brefly (2026-09-20).
    /// 예전 도메인의 설정·기록과 키 파일을 한 번만 옮겨온다. 오래된 것부터 차례로 훑어 중간 단계를 건너뛴 사용자도 챙긴다.
    /// Claude Code(CLI)를 쓰던 사람을 AUTO 로 옮기고 **한 번만** 알려 준다.
    ///
    /// `Backend(rawValue:) ?? .auto` 라서 그냥 두면 말없이 바뀐다. 결과가 달라진 이유를
    /// 모르면 앱을 탓하게 된다. 0.8.3 에서 CLI 를 걷어내며 넣었다.
    /// - Returns: 알려 줄 말. 옮길 것이 없었으면 nil.
    static func migrateAwayFromCLIIfNeeded() -> String? {
        guard d.string(forKey: "backend") == "cli" else { return nil }
        d.set(Backend.auto.rawValue, forKey: "backend")
        // 부속 설정도 같이 치운다. 남겨 두면 다음에 무엇에 쓰이는지 알 수 없다.
        for key in ["cliFallback", "cliPath", "unsupportedCLIFlags"] { d.removeObject(forKey: key) }
        return "Claude Code(터미널) 방식이 없어졌습니다. 정리를 AUTO 로 바꿨습니다. "
             + "설정 > 음성인식 · AI 에서 다시 고를 수 있습니다."
    }

    static func migrateFromPreviousNamesIfNeeded() {
        let flag = "migratedToBrefly"
        guard !d.bool(forKey: flag) else { return }
        d.set(true, forKey: flag)

        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let newKeys = support.appendingPathComponent("Brefly/keys.json")

        // 최근 것부터 본다. 먼저 찾은 쪽이 더 최신 설정이다.
        for (domain, folder) in [("com.sokki.dictation", "Sokki"), ("com.sokgi.dictation", "Sokgi")] {
            if let old = UserDefaults(suiteName: domain) {
                var count = 0
                for (key, value) in old.dictionaryRepresentation() where d.object(forKey: key) == nil {
                    // 시스템이 넣는 키(AppleLanguages 등)는 건너뛴다
                    if key.hasPrefix("Apple") || key.hasPrefix("NS") || key.hasPrefix("com.apple") { continue }
                    d.set(value, forKey: key)
                    count += 1
                }
                if count > 0 { Log.write("\(folder) 설정 \(count)개 이전") }
            }
            let oldKeys = support.appendingPathComponent("\(folder)/keys.json")
            if fm.fileExists(atPath: oldKeys.path), !fm.fileExists(atPath: newKeys.path) {
                try? fm.createDirectory(at: newKeys.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
                if (try? fm.copyItem(at: oldKeys, to: newKeys)) != nil {
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: newKeys.path)
                    Log.write("\(folder) 키 파일 이전")
                }
            }
        }
    }

    // MARK: 인식 언어

    static let locales: [(title: String, id: String)] = [
        ("한국어", "ko-KR"),
        ("English (US)", "en-US"),
        ("日本語", "ja-JP")
    ]

    static var localeID: String {
        get { d.string(forKey: "localeID") ?? "ko-KR" }
        set { d.set(newValue, forKey: "localeID") }
    }

    // MARK: 정리 스타일

    static var style: PolishStyle {
        get { PolishStyle(rawValue: d.string(forKey: "style") ?? "") ?? .standard }
        set {
            d.set(newValue.rawValue, forKey: "style")
            if newValue != .summary { d.set(newValue.rawValue, forKey: "plainStyle") }
        }
    }

    /// 요약을 켜기 전에 쓰던 정리 스타일. 팝오버의 '핵심 요약' 토글을 끄면 여기로 돌아간다.
    static var plainStyle: PolishStyle {
        PolishStyle(rawValue: d.string(forKey: "plainStyle") ?? "").flatMap { $0 == .summary ? nil : $0 } ?? .standard
    }

    // MARK: 화자 정보 · 용어 사전 (정리 프롬프트에 들어간다)

    /// 화자가 누구인지. 모델이 문맥을 잡는 데 쓴다. 예) "프론트엔드 개발자. React·React Native·Swift 를 쓴다."
    static var speakerNote: String {
        get { d.string(forKey: "speakerNote") ?? "" }
        set { d.set(newValue, forKey: "speakerNote") }
    }

    /// 사용자가 직접 추가한 용어. 한 줄에 하나. "잘못 들린 말 → 올바른 표기" 또는 그냥 단어.
    static var glossary: String {
        get { d.string(forKey: "glossary") ?? "" }
        set { d.set(newValue, forKey: "glossary") }
    }

    /// 주로 어떤 분야·상황에서 쓰는지. 체크한 것의 설명과 용어가 프롬프트에 들어간다.
    static var usageContexts: Set<UsageContext> {
        get { Set((d.stringArray(forKey: "usageContexts") ?? []).compactMap(UsageContext.init(rawValue:))) }
        set { d.set(newValue.map(\.rawValue).sorted(), forKey: "usageContexts") }
    }

    /// 처음 실행 때 분야 선택을 안내했는지
    static var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    // MARK: 백엔드

    /// 정리 단계를 무엇으로 돌릴지.
    enum Backend: String, CaseIterable {
        case auto   // Apple 온디바이스 + Gemini 동시 — 빠르고 나은 쪽
        case gemini // Google AI Studio — 무료 티어, 1~5초 (혼잡하면 503)
        case apple  // macOS 26 Apple Intelligence 온디바이스 — 무료, 오프라인
        case api    // Anthropic API — 크레딧 충전 필요, 1초 안쪽
        case openai // OpenAI API — 크레딧 충전 필요

        var title: String {
            switch self {
            case .auto:   return "AUTO (알아서 고름)"
            case .gemini: return "Gemini (구글, 무료)"
            case .apple:  return "Apple AI (이 맥에서, 오프라인)"
            case .api:    return "Claude (유료 크레딧)"
            case .openai: return "ChatGPT (유료 크레딧)"
            }
        }

        var shortTitle: String {
            switch self {
            case .auto:   return "AUTO"
            case .gemini: return "Gemini"
            case .apple:  return "Apple AI (이 맥)"
            case .api:    return "Claude"
            case .openai: return "ChatGPT"
            }
        }

        /// 빠른 모델과 좋은 모델을 따로 고를 수 있는 회사인지.
        /// AUTO 는 알아서 고르고, Apple 온디바이스와 CLI 는 고를 모델이 하나뿐이다.
        var hasTiers: Bool {
            switch self {
            case .gemini, .api, .openai: return true
            case .auto, .apple:          return false
            }
        }

        /// 이 회사를 쓰려면 키가 필요한가. 필요하면 어느 칸인가.
        var keySlot: KeychainStore.Slot? {
            switch self {
            case .gemini: return .gemini
            case .api:    return .anthropic
            case .openai: return .openai
            case .auto, .apple: return nil
            }
        }
    }

    /// 무엇을 정리하는 중인가. AUTO 의 기준이 여기서 갈린다.
    enum Purpose {
        case dictation  // 받아쓰기 — 커서에 바로 들어가야 해서 속도가 먼저다
        case meeting    // 회의록 — 이미 받아쓰기에 2~5분을 썼다. 잘 뽑는 게 먼저다
    }

    /// 자동 모드에서 온디바이스가 끝난 뒤 Gemini 답을 얼마나 더 기다릴지.
    static let autoGraceSeconds: TimeInterval = 2.0

    /// 같은 회사 모델 중 어느 쪽을 쓸지. 모델 이름은 자주 바뀌고 비개발자에겐 뜻이 없어서,
    /// 고르는 자리에는 이름 대신 **빠름 / 정확**만 보여 준다.
    enum Tier: String, CaseIterable {
        case fast     // 받아쓰기용. 1~5초 안에 커서에 들어가야 한다.
        case quality  // 회의록용. 이미 받아쓰기에 2~5분을 썼으니 10초 더는 아무것도 아니다.

        var suffix: String { self == .fast ? "빠름" : "정확" }
    }

    /// 고르는 자리에 늘어놓을 항목 하나. 회사와 등급을 한 줄로 묶는다.
    struct Choice: Equatable {
        let backend: Backend
        let tier: Tier
        var title: String {
            // AUTO·Apple 은 고를 모델이 하나뿐이라 등급을 붙이지 않는다.
            backend.hasTiers ? "\(backend.shortTitle) — \(tier.suffix)" : backend.shortTitle
        }
    }

    /// 받아쓰기와 회의록이 같은 목록에서 고른다. 빠른 것과 좋은 것이 다 들어 있다.
    static let choices: [Choice] = Backend.allCases.flatMap { b in
        b.hasTiers ? Tier.allCases.map { Choice(backend: b, tier: $0) }
                   : [Choice(backend: b, tier: .fast)]
    }

    // MARK: 무엇으로 정리할까 — 받아쓰기와 회의록을 따로 고른다

    static var backend: Backend {
        get { Backend(rawValue: d.string(forKey: "backend") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "backend") }
    }

    static var tier: Tier {
        get { Tier(rawValue: d.string(forKey: "tier") ?? "") ?? .fast }
        set { d.set(newValue.rawValue, forKey: "tier") }
    }

    /// 회의록 요약은 받아쓰기와 **따로** 고른다. 받아쓰기는 빠른 게 중요하고
    /// 회의록은 잘 뽑는 게 중요해서 최적해가 다르다.
    /// 기본값은 AUTO 다. AUTO 도 가성비 순이라 **Gemini 부터** 시도하므로 0.8.2 까지의
    /// 동작(Gemini 고정)과 첫 결과가 같고, Gemini 가 다 실패했을 때만 다른 회사로 넘어간다.
    static var meetingBackend: Backend {
        get { Backend(rawValue: d.string(forKey: "meetingBackend") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "meetingBackend") }
    }

    static var meetingTier: Tier {
        get { Tier(rawValue: d.string(forKey: "meetingTier") ?? "") ?? .quality }
        set { d.set(newValue.rawValue, forKey: "meetingTier") }
    }

    static var choice: Choice { Choice(backend: backend, tier: tier) }
    static var meetingChoice: Choice { Choice(backend: meetingBackend, tier: meetingTier) }

    // MARK: Gemini

    /// 모델 이름은 자주 바뀐다. 진단 > 'Gemini 모델 목록'에서 실제 목록을 확인할 수 있다.
    /// 2026-09-04 실측: 2.5 계열은 404(퇴역). flash-lite-latest 는 503이 잦고,
    /// 3.1-flash-lite 가 3초 안팎으로 가장 안정적이라 첫 항목(기본값)으로 둔다.
    /// 22:19 재측정: -latest 별칭 둘은 응답 자체가 없고(타임아웃), 3.6-flash 2.3초 · 3.1-flash-lite 5.3초 · 3.5-flash 9.2초.
    static let geminiModels = [
        "gemini-3.1-flash-lite",
        "gemini-3.6-flash",
        "gemini-3.5-flash",
        "gemini-flash-lite-latest",
        "gemini-flash-latest"
    ]

    /// 고른 모델이 늦거나 503/429를 내면 이 순서로 겹쳐 쏜다 (고른 모델은 건너뛴다).
    static let geminiFallbacks = [
        "gemini-3.1-flash-lite",
        "gemini-3.6-flash",
        "gemini-3.5-flash"
    ]

    static var geminiModel: String {
        get { d.string(forKey: "geminiModel") ?? geminiModels[0] }
        set { d.set(newValue, forKey: "geminiModel") }
    }



    // MARK: 모델

    /// 받아쓰기 정리는 가벼운 작업이라 Haiku로 충분하다. 첫 항목이 기본값.
    static let models = ["claude-haiku-4-5-20251001", "claude-sonnet-5", "claude-opus-5"]

    static var model: String {
        get { d.string(forKey: "model") ?? models[0] }
        set { d.set(newValue, forKey: "model") }
    }

    // MARK: ChatGPT

    /// ⚠️ 모델 이름은 자주 바뀌고 없어진다. 여기 적힌 이름이 이미 퇴역했을 수 있으므로
    ///    **첫 이름이 404 면 다음 이름으로 넘어간다**(`MeetingNotes.attempt`, `GPTClient`).
    ///    실제로 쓸 수 있는 목록은 `--probe-keys` 옆 진단으로 키에 직접 물어볼 수 있다.
    static let openaiModels = ["gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.4", "gpt-5.5", "gpt-6.1-sol"]

    static var openaiModel: String {
        get { d.string(forKey: "openaiModel") ?? openaiModels[0] }
        set { d.set(newValue, forKey: "openaiModel") }
    }

    // MARK: 빠름 / 정확

    /// 회사·등급으로 실제 모델 이름을 고른다. 첫 항목이 그 등급의 기본값이고,
    /// 404·503 이면 뒤 항목으로 넘어간다.
    /// 2026-09-30 실측으로 정한 표다.
    ///
    /// **빠름** — 같은 한 문장을 세 번씩 다듬어 잰 평균:
    ///
    ///     gpt-5.4-mini 0.85초 · gpt-5.4-nano 0.93초 · gpt-5.4 1.18초
    ///
    /// **정확** — 48분 회의 원문(11,149토큰)을 실제로 요약시켜 잰 값:
    ///
    ///     gpt-5.5       31.6초  출력 3,365토큰(그중 생각 2,048)
    ///     claude-sonnet-5 51.2초  출력 4,753토큰
    ///     claude-haiku    9.3초   출력   886토큰 — 빠르지만 얕다
    ///
    ///  셋 다 지어낸 말 없이 이름·날짜·이유까지 살렸고, haiku 만 눈에 띄게 짧았다.
    static func modelNames(_ backend: Backend, _ tier: Tier) -> [String] {
        switch (backend, tier) {
        case (.gemini, .fast):    return ["gemini-3.1-flash-lite", "gemini-3.6-flash", "gemini-3.5-flash"]
        case (.gemini, .quality): return ["gemini-3.6-flash", "gemini-3.5-flash", "gemini-3.1-flash-lite"]
        case (.api, .fast):       return ["claude-haiku-4-5-20251001", "claude-sonnet-5"]
        case (.api, .quality):    return ["claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001"]
        case (.openai, .fast):    return ["gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.4"]
        case (.openai, .quality): return ["gpt-5.5", "gpt-6.1-sol", "gpt-5.4"]
        default:                  return []
        }
    }

    /// AUTO 가 고르는 순서. **목적에 따라 기준이 다르다.**
    ///
    /// - 받아쓰기: 빠른 것 먼저. 커서에 들어가기까지 1~5초 안에 끝나야 한다.
    ///   (Apple 온디바이스와 Gemini 를 동시에 쏘는 기존 동작은 `ClaudeClient` 가 그대로 한다.)
    /// - 회의록: **가성비 순**. 셋 다 지어낸 말 없이 잘 뽑았으므로, 같은 값이면 싼 쪽이 낫다.
    ///   ⚠️ Apple 온디바이스는 아예 넣지 않는다. 3B 모델은 긴 글에서 결정 사항을 뒤집는다
    ///     (CLAUDE.md "요약은 클라우드가 본체다").
    ///
    /// 회의록 순서의 근거 — 같은 48분 원문(16,450자)으로 잰 값이다(2026-09-30).
    ///
    ///     Gemini          무료 티어 — 0원
    ///     gpt-5.5         입력 11,149 · 출력 3,365
    ///     claude-sonnet-5 입력 19,034 · 출력 7,739 (그중 생각 6,374)
    ///
    /// 같은 글인데 Anthropic 이 **입력을 1.7배**로 센다(한국어를 쪼개는 방식이 다르다).
    /// 생각 토큰도 출력 요금이라 sonnet 은 출력이 gpt-5.5 의 2.3배다. 품질 차이는 그만큼 안 났다.
    /// 가장 좋은 것을 원하면 AUTO 가 아니라 직접 고르면 된다 — 그러라고 따로 고르게 해 뒀다.
    ///
    /// 키가 없는 회사는 건너뛴다 — 고를 수 없는 것을 시도해 봐야 실패만 늘어난다.
    static func autoCandidates(for purpose: Purpose) -> [Choice] {
        let order: [Choice] = purpose == .dictation
            ? [Choice(backend: .gemini, tier: .fast),
               Choice(backend: .openai, tier: .fast),
               Choice(backend: .api,    tier: .fast)]
            : [Choice(backend: .gemini, tier: .quality),
               Choice(backend: .openai, tier: .quality),
               Choice(backend: .api,    tier: .quality)]
        return order.filter { c in
            guard let slot = c.backend.keySlot else { return true }
            return KeychainStore.read(slot)?.isEmpty == false
        }
    }

    // MARK: 단축키

    static var hotKeyIndex: Int {
        get { d.integer(forKey: "hotKeyIndex") }
        set { d.set(newValue, forKey: "hotKeyIndex") }
    }

    /// 설정 창에서 직접 녹음한 단축키. 있으면 프리셋보다 우선한다.
    static var customHotKey: HotKeyCombo? {
        get {
            guard d.object(forKey: "customHotKeyCode") != nil else { return nil }
            return HotKeyCombo(keyCode: UInt32(d.integer(forKey: "customHotKeyCode")),
                               modifiers: UInt32(d.integer(forKey: "customHotKeyMods")))
        }
        set {
            if let c = newValue {
                d.set(Int(c.keyCode), forKey: "customHotKeyCode")
                d.set(Int(c.modifiers), forKey: "customHotKeyMods")
            } else {
                d.removeObject(forKey: "customHotKeyCode")
                d.removeObject(forKey: "customHotKeyMods")
            }
        }
    }

    /// 실제로 등록할 단축키.
    static var currentHotKey: HotKeyCombo {
        customHotKey ?? HotKeyPreset.preset(at: hotKeyIndex).combo
    }

    // MARK: 회의 단축키

    /// 받아쓰기 말고 나머지 단축키. 저마다 따로 고른다 — 대면과 화상은 권한도 동작도 달라서
    /// 하나로 묶으면 무엇이 시작될지 누를 때마다 생각해야 한다.
    /// 비워 두면 그 단축키는 등록하지 않는다. 기본값이 비어 있다 — 쓰지도 않는 조합을
    /// 미리 잡아 두면 다른 앱과 부딪힌다.
    static func extraHotKey(_ slot: HotKey.Slot) -> HotKeyCombo? {
        let code = "hotkey.\(slot.rawValue).code", mods = "hotkey.\(slot.rawValue).mods"
        guard d.object(forKey: code) != nil else { return nil }
        return HotKeyCombo(keyCode: UInt32(d.integer(forKey: code)),
                           modifiers: UInt32(d.integer(forKey: mods)))
    }

    static func setExtraHotKey(_ combo: HotKeyCombo?, for slot: HotKey.Slot) {
        let code = "hotkey.\(slot.rawValue).code", mods = "hotkey.\(slot.rawValue).mods"
        if let combo {
            d.set(Int(combo.keyCode), forKey: code)
            d.set(Int(combo.modifiers), forKey: mods)
        } else {
            d.removeObject(forKey: code)
            d.removeObject(forKey: mods)
        }
    }

    // MARK: 기타

    /// Claude 정리를 끄면 받아쓰기 원문을 그대로 붙여 넣는다.
    static var polishEnabled: Bool {
        get { d.object(forKey: "polishEnabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "polishEnabled") }
    }

    /// 커서 위치에 자동으로 붙여넣을지. 끄면 클립보드에만 넣는다(권한 불필요).
    /// 애드혹 서명 앱은 재빌드마다 접근성 권한이 풀리므로 기본값은 끔.
    static var autoPaste: Bool {
        get { d.object(forKey: "autoPaste") as? Bool ?? false }
        set { d.set(newValue, forKey: "autoPaste") }
    }

    /// 결과를 클립보드에 넣을지. 끄면 기록에만 남는다(자동 붙여넣기가 켜져 있으면 그쪽이 우선).
    static var copyToClipboard: Bool {
        get { d.object(forKey: "copyToClipboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "copyToClipboard") }
    }

    static var restoreClipboard: Bool {
        get { d.object(forKey: "restoreClipboard") as? Bool ?? true }
        set { d.set(newValue, forKey: "restoreClipboard") }
    }

    /// Dock 에 실행 중인 앱으로 보일지. 끄면 메뉴바 아이콘만 남는다. Dock 아이콘을 누르면 팝오버가 뜬다.
    static var showInDock: Bool {
        get { d.object(forKey: "showInDock") as? Bool ?? true }
        set { d.set(newValue, forKey: "showInDock") }
    }

    // MARK: 업데이트 확인

    /// 실행할 때 하루 한 번 GitHub 릴리스를 확인한다.
    static var autoCheckUpdates: Bool {
        get { d.object(forKey: "autoCheckUpdates") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoCheckUpdates") }
    }

    static var lastUpdateCheck: Date? {
        get { d.object(forKey: "lastUpdateCheck") as? Date }
        set { d.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// "나중에"를 누른 버전. 같은 버전은 자동 확인에서 다시 묻지 않는다.
    static var skippedUpdateVersion: String? {
        get { d.string(forKey: "skippedUpdateVersion") }
        set { d.set(newValue, forKey: "skippedUpdateVersion") }
    }

    /// 정리가 끝났을 때 결과 팝오버를 자동으로 띄울지. 계속 떠 있으면 거슬린다는 피드백(2026-09-09)으로 기본은 끔.
    /// 녹음 중·정리 중 화면은 이 설정과 무관하게 뜬다.
    static var showResultPopover: Bool {
        get { d.object(forKey: "showResultPopover") as? Bool ?? false }
        set { d.set(newValue, forKey: "showResultPopover") }
    }

    /// 녹음 시작·종료 때 "띠딩" 알림음. 시작은 올라가는 두 음, 종료는 내려가는 두 음 (정리 뒤 복사는 Tink).
    static var recordingSounds: Bool {
        get { d.object(forKey: "recordingSounds") as? Bool ?? true }
        set { d.set(newValue, forKey: "recordingSounds") }
    }

    /// 녹음 중에 재생 중인 다른 소리를 낮춘다. 에어팟은 macOS 가 알아서 하므로 내장 스피커 등에만 적용.
    static var duckMediaWhileRecording: Bool {
        get { d.object(forKey: "duckMediaWhileRecording") as? Bool ?? true }
        set { d.set(newValue, forKey: "duckMediaWhileRecording") }
    }

    /// 실패했을 때 시스템 알림창까지 띄운다. 팝오버가 오류를 보여주므로 기본은 끔.
    static var showErrorAlerts: Bool {
        get { d.object(forKey: "showErrorAlerts") as? Bool ?? false }
        set { d.set(newValue, forKey: "showErrorAlerts") }
    }

    /// 말을 멈추고 N초가 지나면 자동으로 녹음을 끝내고 요약한다. 생각하다 끊기는 게 싫다는 피드백으로 기본은 끔.
    static var autoStopOnSilence: Bool {
        get { d.object(forKey: "autoStopOnSilence") as? Bool ?? false }
        set { d.set(newValue, forKey: "autoStopOnSilence") }
    }

    static let silenceOptions: [TimeInterval] = [2, 3, 5, 8, 12]

    static var silenceSeconds: TimeInterval {
        get { let v = d.double(forKey: "silenceSeconds"); return v > 0 ? v : 5 }
        set { d.set(newValue, forKey: "silenceSeconds") }
    }

    /// 화면 모드: 시스템 / 라이트 / 다크
    enum Appearance: String, CaseIterable {
        case system, light, dark
        var title: String {
            switch self {
            case .system: return "시스템"
            case .light:  return "라이트"
            case .dark:   return "다크"
            }
        }
        /// nil 이면 시스템을 따른다.
        var nsAppearance: NSAppearance? {
            switch self {
            case .system: return nil
            case .light:  return NSAppearance(named: .aqua)
            case .dark:   return NSAppearance(named: .darkAqua)
            }
        }
        var isDark: Bool {
            switch self {
            case .dark: return true
            case .light: return false
            case .system:
                return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
        }
    }

    static var appearance: Appearance {
        get { Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "appearance") }
    }

    /// 애플 서버 인식을 쓸지. 기본 켬(2026-09-13): 온디바이스는 눈에 띄게 덜 정확하고 멈춤 뒤 구간을 리셋한다.
    /// 직접 끄면 인터넷 없이 이 맥에서만 인식한다(한 번에 1분 제한 없음).
    static var forceServerRecognition: Bool {
        get { d.object(forKey: "forceServerRecognition") as? Bool ?? true }
        set { d.set(newValue, forKey: "forceServerRecognition") }
    }
}


/// 앱을 쓰는 분야·상황. 체크한 항목의 `context` 는 프롬프트의 화자 설명에, `glossary` 는 용어 사전에 합쳐진다.
enum UsageContext: String, CaseIterable, Identifiable {
    case devFrontend, devBackend, devMobile, design, product, marketing, meeting, messenger, email, study, personal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devFrontend: return "프론트엔드 개발"
        case .devBackend:  return "백엔드·인프라 개발"
        case .devMobile:   return "iOS·Android 앱 개발"
        case .design:      return "디자인·UX"
        case .product:     return "기획·PM"
        case .marketing:   return "마케팅·영업"
        case .meeting:     return "회의·업무 메모"
        case .messenger:   return "메신저 (Slack·카톡)"
        case .email:       return "이메일·보고"
        case .study:       return "공부·강의 노트"
        case .personal:    return "일상·개인 메모"
        }
    }

    var symbol: String {
        switch self {
        case .devFrontend: return "chevron.left.forwardslash.chevron.right"
        case .devBackend:  return "server.rack"
        case .devMobile:   return "iphone"
        case .design:      return "paintbrush"
        case .product:     return "list.clipboard"
        case .marketing:   return "megaphone"
        case .meeting:     return "person.2"
        case .messenger:   return "bubble.left.and.bubble.right"
        case .email:       return "envelope"
        case .study:       return "book"
        case .personal:    return "note.text"
        }
    }

    /// 화자 설명에 붙는 한 문장
    var context: String {
        switch self {
        case .devFrontend: return "프론트엔드 개발자다. React·TypeScript·웹 용어를 자주 쓴다."
        case .devBackend:  return "백엔드·인프라 일을 한다. 서버·DB·배포 용어를 자주 쓴다."
        case .devMobile:   return "iOS·Android 앱을 만든다. Swift·Kotlin·React Native 용어를 자주 쓴다."
        case .design:      return "디자인·UX 일을 한다. Figma·컴포넌트·시안 이야기를 자주 한다."
        case .product:     return "기획·PM 일을 한다. 요구사항·일정·우선순위 이야기를 자주 한다."
        case .marketing:   return "마케팅·영업 일을 한다. 캠페인·전환·고객 이야기를 자주 한다."
        case .meeting:     return "회의 내용과 업무 메모를 남기는 데 쓴다. 결정 사항·담당자·마감이 중요하다."
        case .messenger:   return "메신저에 보낼 말을 정리하는 데 쓴다. 말투를 딱딱하게 바꾸지 않는다."
        case .email:       return "이메일이나 보고에 쓸 글을 정리하는 데 쓴다."
        case .study:       return "공부·강의 내용을 노트로 남기는 데 쓴다. 개념과 용어를 정확히 적는다."
        case .personal:    return "일상 메모·일기·할 일을 적는 데 쓴다."
        }
    }

    /// "들린 말 → 표기" 용어. 한 줄에 하나.
    var glossary: String {
        switch self {
        case .devFrontend: return """
            리듬이, 리드 미 → README
            레포, 랩 포, 래포 → 레포(repo)
            리 액트 → React
            타입스크립트 → TypeScript
            넥스트 → Next.js
            프론트 앤드, 프론트느 → 프론트엔드
            깃 헙, 깃 허브 → GitHub
            풀 리퀘스트, 피알 → PR
            파악 오버, 파보, 밥 오버, 팝 오버, 팝업 오버 → 팝오버
            툴 팁 → 툴팁
            드롭 다운 → 드롭다운
            커밋, 브랜치, 머지, 클론, 푸시, 빌드, 배포, 리팩터링, 컴포넌트, 훅, 상태 관리, 모달, 토글, 사이드바, 스크롤
            """
        case .devBackend: return """
            리듬이, 리드 미 → README
            레포, 랩 포 → 레포(repo)
            100 and, 백 앤드 → 백엔드
            에이피아이 → API
            디비 → DB
            도커 → Docker
            쿠버네티스 → Kubernetes
            깃 헙 → GitHub
            배포, 서버, 인프라, 마이그레이션, 캐시, 큐, 스케줄러
            """
        case .devMobile: return """
            스위프트 → Swift
            스위프트 유아이 → SwiftUI
            코틀린 → Kotlin
            리 액트 네이티브 → React Native
            엑스코드 → Xcode
            앱스토어 → App Store
            테스트 플라이트 → TestFlight
            시뮬레이터, 빌드, 배포, 권한, 푸시 알림
            """
        case .design: return """
            피그마 → Figma
            파악 오버, 파보, 밥 오버, 팝 오버 → 팝오버
            툴 팁 → 툴팁
            시안, 와이어프레임, 프로토타입, 컴포넌트, 디자인 시스템, 토큰, 여백, 정렬, 모달, 토글, 아이콘
            유엑스 → UX
            유아이 → UI
            """
        case .product: return """
            피엠 → PM
            스프린트, 백로그, 요구사항, 우선순위, 로드맵, 마일스톤, 일정, 리스크
            케이피아이 → KPI
            오케이알 → OKR
            """
        case .marketing: return """
            캠페인, 전환율, 리드, 퍼널, 랜딩 페이지, 광고비, 고객, 제안서, 견적
            씨티에이 → CTA
            로아스 → ROAS
            """
        case .meeting: return """
            액션 아이템, 담당자, 마감, 결정 사항, 안건, 후속 조치, 다음 회의
            """
        case .messenger: return ""
        case .email: return """
            수신, 참조, 첨부, 회신, 요청 드립니다, 확인 부탁드립니다
            """
        case .study: return """
            개념, 정의, 예시, 정리, 복습, 챕터, 과제
            """
        case .personal: return ""
        }
    }
}


/// 용어 사전의 "들린 말 → 표기" 줄을 원문에 그대로 적용한다.
/// 모델(특히 온디바이스)이 사전을 절반만 따르길래, 확실한 것은 코드가 먼저 바꿔 둔다.
enum Glossary {

    struct Rule { let variants: [String]; let replacement: String }

    static func rules() -> [Rule] {
        var lines: [String] = []
        for c in UsageContext.allCases where Prefs.usageContexts.contains(c) {
            lines += c.glossary.split(separator: "\n").map(String.init)
        }
        lines += Prefs.glossary.split(separator: "\n").map(String.init)

        var result: [Rule] = []
        for line in lines {
            let parts = line.components(separatedBy: "→")
            guard parts.count == 2 else { continue }
            let variants = parts[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var right = parts[1].trimmingCharacters(in: .whitespaces)
            // "레포(repo)" → "레포": 괄호 안은 모델용 설명이라 치환 결과에는 넣지 않는다
            if let paren = right.range(of: "(") { right = String(right[..<paren.lowerBound]).trimmingCharacters(in: .whitespaces) }
            guard !variants.isEmpty, !right.isEmpty else { continue }
            result.append(Rule(variants: variants, replacement: right))
        }
        return result
    }

    /// 음성 인식에 미리 알려 줄 단어들(SFSpeechRecognitionRequest.contextualStrings). 올바른 표기와 단독 단어만 모은다.
    /// "파악 오버"처럼 엉뚱하게 들리는 것보다 "팝오버"로 바로 인식되는 편이 낫다.
    static func vocabulary() -> [String] {
        var lines: [String] = []
        for c in UsageContext.allCases where Prefs.usageContexts.contains(c) {
            lines += c.glossary.split(separator: "\n").map(String.init)
        }
        lines += Prefs.glossary.split(separator: "\n").map(String.init)

        var words: [String] = []
        for line in lines {
            let parts = line.components(separatedBy: "→")
            if parts.count == 2 {
                var right = parts[1].trimmingCharacters(in: .whitespaces)
                if let paren = right.range(of: "(") { right = String(right[..<paren.lowerBound]).trimmingCharacters(in: .whitespaces) }
                if !right.isEmpty { words.append(right) }
            } else {
                words += line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        }
        var seen = Set<String>()
        return Array(words.filter { seen.insert($0).inserted }.prefix(150))
    }

    /// 모델이 원문의 영어 단어를 비슷하게 들리는 용어 목록 단어로 바꾼 걸 되돌린다. 사용자가 flash-lite 를 말해
    /// "Flashlight"로 받아쓰였는데 모델이 목록의 "TestFlight"로 바꿨다(2026-09-25). 규칙을 두 번 좁혀도 무시했다.
    /// 원문의 영어 단어가 딱 하나 사라지고 원문에 없던 목록 단어가 딱 하나 생겼을 때만 바꾼다.
    static func restoreSwappedWord(_ output: String, raw: String) -> String {
        func latinWords(_ s: String) -> Set<String> {
            Set(s.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }).map(String.init).filter { $0.count >= 3 })
        }
        let targets = Set(rules().map(\.replacement))
        let missing = latinWords(raw).filter { output.range(of: $0, options: .caseInsensitive) == nil }
        let introduced = latinWords(output).filter { word in
            raw.range(of: word, options: .caseInsensitive) == nil && targets.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
        }
        guard missing.count == 1, introduced.count == 1, let from = introduced.first, let to = missing.first else { return output }
        Log.write("용어 되돌림: 모델이 \(to) 를 \(from) 로 바꿨다")
        return output.replacingOccurrences(of: from, with: to)
    }

    /// 긴 변형부터 바꿔서 "리 액트 네이티브"가 "React 네이티브"로 반쯤 바뀌는 일을 막는다.
    static func apply(to text: String) -> String {
        var out = text
        let pairs = rules().flatMap { r in r.variants.map { ($0, r.replacement) } }
            .sorted { $0.0.count > $1.0.count }
        for (from, to) in pairs where from != to {
            out = out.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        return out
    }
}
