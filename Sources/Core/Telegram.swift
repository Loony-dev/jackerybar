// Sends notifications to Telegram through your own bot (Bot API, plain HTTPS).

import Foundation

enum Telegram {
    static func send(_ cfg: TelegramConfig, text: String, done: ((String?) -> Void)? = nil) {
        guard !cfg.token.isEmpty, !cfg.chatId.isEmpty,
              let url = URL(string: "https://api.telegram.org/bot\(cfg.token)/sendMessage") else { done?(L("Немає токена або chat id", "No token or chat id")); return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["chat_id": cfg.chatId, "text": text, "disable_web_page_preview": true])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let msg = ok ? nil : (data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["description"] as? String
                                   ?? err?.localizedDescription ?? L("Помилка Telegram", "Telegram error"))
            DispatchQueue.main.async { done?(msg) }
        }.resume()
    }

    /// The chat of the last message sent to the bot (write anything to the bot first).
    static func findChat(token: String, done: @escaping (Result<(id: String, name: String), Error>) -> Void) {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/getUpdates") else { return }
        URLSession.shared.dataTask(with: url) { data, _, err in
            var result: Result<(id: String, name: String), Error> = .failure(err ?? NSError(domain: "Telegram", code: 1,
                userInfo: [NSLocalizedDescriptionKey: L("Напиши боту будь-яке повідомлення й спробуй ще раз", "Send the bot any message and try again")]))
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if obj["ok"] as? Bool == false {
                    result = .failure(NSError(domain: "Telegram", code: 2, userInfo: [NSLocalizedDescriptionKey: obj["description"] as? String ?? L("Невірний токен", "Wrong token")]))
                } else if let updates = obj["result"] as? [[String: Any]],
                          let chat = updates.reversed().compactMap({ (($0["message"] ?? $0["my_chat_member"]) as? [String: Any])?["chat"] as? [String: Any] }).first,
                          let id = chat["id"] {
                    let name = (chat["title"] ?? chat["username"] ?? chat["first_name"]) as? String ?? ""
                    result = .success(("\(id)", name))
                }
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}
