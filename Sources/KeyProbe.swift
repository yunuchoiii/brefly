import Foundation

/// 넣어 둔 키가 **실제로 쓸 수 있는지** 확인한다.
///
/// ⚠️ 잔액을 숫자로 알려 주는 API 는 없다. OpenAI 도 Anthropic 도 키로 잔액을 조회할 수 없고,
///    `/v1/models` 는 크레딧이 0원이어도 200 을 준다(2026-09-30 실측). 그래서 **가장 작은
///    요청을 실제로 한 번 보내고** 돌아온 오류로 상태를 가른다. 크레딧이 없으면 과금 전에
///    거부되므로 확인 비용은 0원이고, 있으면 1토큰어치라 무시할 만하다.
enum KeyProbe {

    enum Status: String, Codable {
        case unknown      // 아직 확인 안 함
        case ok           // 실제로 답이 왔다
        case noCredit     // 키는 맞는데 결제 잔액이 없다
        case badKey       // 키가 틀렸다
        case rateLimited  // 한도를 잠깐 넘었다 (무료 티어에서 흔하다)
        case failed       // 네트워크 등 — 키 탓이라고 단정하면 안 된다

        var isGood: Bool { self == .ok }

        var label: String {
            switch self {
            case .unknown:     return "아직 확인하지 않았습니다"
            case .ok:          return "쓸 수 있습니다"
            case .noCredit:    return "크레딧이 없습니다 · 충전해야 씁니다"
            case .badKey:      return "키가 올바르지 않습니다"
            case .rateLimited: return "지금 한도를 넘었습니다 · 잠시 뒤 다시"
            case .failed:      return "확인하지 못했습니다 · 인터넷을 확인해 주세요"
            }
        }
    }

    /// 마지막으로 확인한 결과. 설정 창을 열 때마다 또 부르지 않으려고 남겨 둔다.
    static func remembered(_ slot: KeychainStore.Slot) -> Status {
        Status(rawValue: UserDefaults.standard.string(forKey: "keyProbe.\(slot.rawValue)") ?? "") ?? .unknown
    }

    private static func remember(_ status: Status, _ slot: KeychainStore.Slot) {
        UserDefaults.standard.set(status.rawValue, forKey: "keyProbe.\(slot.rawValue)")
    }

    /// 크레딧을 채우러 갈 곳. 발급 페이지와 다르다 — 키는 있는데 잔액만 없는 경우가 잦다.
    static func billingURL(_ slot: KeychainStore.Slot) -> String? {
        switch slot {
        case .gemini:    return nil   // 무료 티어라 충전할 것이 없다
        case .anthropic: return "https://console.anthropic.com/settings/billing"
        case .openai:    return "https://platform.openai.com/settings/organization/billing/"
        }
    }

    // MARK: - 확인

    static func check(_ slot: KeychainStore.Slot, completion: @escaping (Status) -> Void) {
        guard let key = KeychainStore.read(slot), !key.isEmpty else {
            finish(.unknown, slot, completion); return
        }
        var req: URLRequest
        switch slot {
        case .openai:
            req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            // ⚠️ 1 토큰으로 막으면 **크레딧이 멀쩡해도 400** 이 난다(2026-09-30 실측):
            //    "Could not finish the message because max_tokens ... was reached".
            //    추론 모델은 생각하는 데 토큰을 먼저 쓴다. 넉넉히 주되 답은 짧게 시킨다 —
            //    어차피 크레딧이 없으면 과금 전에 거부되고, 있어도 몇 원 축에도 못 든다.
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": Prefs.openaiModel,
                "messages": [["role": "user", "content": "Reply with the single word: ok"]],
                "max_completion_tokens": 512,
            ])
        case .anthropic:
            req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": Prefs.model,
                "max_tokens": 16,
                "messages": [["role": "user", "content": "Reply with the single word: ok"]],
            ])
        case .gemini:
            let url = "https://generativelanguage.googleapis.com/v1beta/models/\(Prefs.geminiModel):generateContent"
            req = URLRequest(url: URL(string: url)!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "contents": [["parts": [["text": "hi"]]]],
                "generationConfig": ["maxOutputTokens": 1],
            ])
        }
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: req) { data, response, error in
            if error != nil { finish(.failed, slot, completion); return }
            guard let http = response as? HTTPURLResponse else { finish(.failed, slot, completion); return }
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            finish(status(http.statusCode, body), slot, completion)
        }.resume()
    }

    /// 응답 코드와 본문으로 상태를 가른다.
    ///
    /// ⚠️ 크레딧 부족을 코드만으로는 못 가른다 — OpenAI 는 **429**(`insufficient_quota`),
    ///    Anthropic 은 **400**(`credit balance is too low`)으로 온다(2026-09-30 실측).
    ///    그래서 본문의 말까지 본다.
    static func status(_ code: Int, _ body: String) -> Status {
        let lower = body.lowercased()
        let outOfCredit = lower.contains("insufficient_quota")
            || lower.contains("credit_balance_exhausted")
            || lower.contains("credit balance is too low")
            || lower.contains("no credits remaining")
            || lower.contains("billing")
        if (200..<300).contains(code) { return .ok }
        if outOfCredit { return .noCredit }
        // 출력 길이 때문에 잘린 것은 키 탓이 아니다. 키는 멀쩡하다는 뜻이다.
        if lower.contains("max_tokens") || lower.contains("output limit") { return .ok }
        switch code {
        case 401, 403: return .badKey
        // 키 형식이 틀려도 400 이 온다. 크레딧 말이 없으면 키 쪽으로 본다.
        case 400:      return lower.contains("api key") || lower.contains("api_key") ? .badKey : .failed
        case 429:      return .rateLimited
        default:       return .failed
        }
    }

    private static func finish(_ s: Status, _ slot: KeychainStore.Slot,
                               _ completion: @escaping (Status) -> Void) {
        remember(s, slot)
        DispatchQueue.main.async { completion(s) }
    }
}
