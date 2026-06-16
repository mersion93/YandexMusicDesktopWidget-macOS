import Foundation
import AppKit
import WebKit
import OSLog

// Клиент неофициального API Яндекс Музыки (api.music.yandex.net).
// Используется для получения настоящей обложки трека, реального статуса лайка
// и надёжной постановки/снятия лайка — то, что недоступно через Accessibility.

final class YandexMusicAPI {
    static let shared = YandexMusicAPI()

    private let logger = Logger(subsystem: "com.yandexmusic.widget", category: "YandexAPI")
    private let base = "https://api.music.yandex.net"

    // OAuth client_id официального приложения Яндекс Музыки (implicit grant).
    static let clientID = "23cabbbdc6cd418abb4b39c32c41195d"
    static var authURL: URL {
        URL(string: "https://oauth.yandex.ru/authorize?response_type=token&client_id=\(clientID)")!
    }

    private init() {}

    // MARK: - Токен / авторизация (хранение в файле App Group — надёжно)

    var token: String? {
        get { AppGroupManager.shared.loadYandexToken() }
        set { AppGroupManager.shared.saveYandexToken(newValue) }
    }
    var uid: String? {
        get { AppGroupManager.shared.loadYandexUID() }
        set { AppGroupManager.shared.saveYandexUID(newValue) }
    }
    var isAuthorized: Bool { (token?.isEmpty == false) }

    func logout() {
        token = nil; uid = nil
        likedCache.removeAll()
    }

    /// Сохраняет токен и подтягивает uid аккаунта.
    func applyToken(_ t: String, completion: @escaping (Bool) -> Void) {
        token = t
        fetchAccount { ok in
            if ok { self.refreshLikes() }
            DispatchQueue.main.async { completion(ok) }
        }
    }

    /// Вызывать при запуске: если токен уже есть — обновить uid и список лайков.
    func refreshOnLaunch() {
        guard isAuthorized else { return }
        if uid == nil {
            fetchAccount { ok in if ok { self.refreshLikes() } }
        } else {
            refreshLikes()
        }
    }

    // MARK: - Низкоуровневый запрос

    private func request(_ path: String, method: String = "GET",
                         query: [URLQueryItem] = [], formBody: [String: String]? = nil,
                         completion: @escaping ([String: Any]?) -> Void) {
        guard let token else { completion(nil); return }
        guard var comps = URLComponents(string: base + path) else { completion(nil); return }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { completion(nil); return }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Yandex-Music-API", forHTTPHeaderField: "X-Yandex-Music-Client")
        if let formBody {
            let s = formBody.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
                            .joined(separator: "&")
            req.httpBody = s.data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            if let error { self?.logger.debug("API ошибка \(path): \(error.localizedDescription)") }
            // Истёк/недействителен токен → разлогиниваем, чтобы UI предложил войти заново.
            if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                DispatchQueue.main.async { self?.logout(); completion(nil) }
                return
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            // ВСЕ коллбэки — на главном потоке (исключает гонки доступа к likedCache/currentTrack).
            DispatchQueue.main.async { completion(json) }
        }.resume()
    }

    // MARK: - Аккаунт

    func fetchAccount(completion: @escaping (Bool) -> Void) {
        request("/account/status") { json in
            guard let result = json?["result"] as? [String: Any],
                  let account = result["account"] as? [String: Any],
                  let uid = account["uid"] else { completion(false); return }
            self.uid = "\(uid)"
            self.logger.info("Авторизован, uid=\(self.uid ?? "?")")
            completion(true)
        }
    }

    // MARK: - Поиск трека

    struct APITrack {
        let id: String
        let title: String
        let artist: String
        let coverURL: URL?
        let duration: TimeInterval   // секунды, 0 если неизвестно
    }

    /// Ищет трек в каталоге ЯМ по «исполнитель название», возвращает id + обложку.
    func searchTrack(title: String, artist: String, completion: @escaping (APITrack?) -> Void) {
        let text = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { completion(nil); return }
        request("/search", query: [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "page", value: "0"),
            URLQueryItem(name: "nocorrect", value: "false")
        ]) { json in
            guard let result = json?["result"] as? [String: Any],
                  let tracks = result["tracks"] as? [String: Any],
                  let items = tracks["results"] as? [[String: Any]],
                  let first = items.first else { completion(nil); return }
            completion(self.parseTrack(first))
        }
    }

    private func parseTrack(_ d: [String: Any]) -> APITrack? {
        guard let idAny = d["id"] else { return nil }
        let id = "\(idAny)"
        let title = (d["title"] as? String) ?? ""
        let artists = (d["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        var coverURL: URL?
        if let cover = d["coverUri"] as? String {
            let full = "https://" + cover.replacingOccurrences(of: "%%", with: "400x400")
            coverURL = URL(string: full)
        }
        var duration: TimeInterval = 0
        if let ms = d["durationMs"] as? Double { duration = ms / 1000 }
        else if let ms = d["durationMs"] as? Int { duration = Double(ms) / 1000 }
        return APITrack(id: id, title: title, artist: artists.joined(separator: ", "),
                        coverURL: coverURL, duration: duration)
    }

    /// Загружает данные обложки по URL.
    func fetchCover(_ url: URL, completion: @escaping (Data?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in completion(data) }.resume()
    }

    /// Обложка высокого разрешения (1000×1000) для трека — со СТРОГОЙ проверкой
    /// совпадения названия, чтобы не подставить чужую картинку. nil — если не уверены.
    func highResCover(title: String, artist: String, completion: @escaping (Data?) -> Void) {
        searchTrack(title: title, artist: artist) { [weak self] t in
            guard let self, let t,
                  t.title.lowercased() == title.lowercased(),   // строгое совпадение названия
                  let url0 = t.coverURL else { completion(nil); return }
            let big = url0.absoluteString.replacingOccurrences(of: "400x400", with: "1000x1000")
            guard let url = URL(string: big) else { completion(nil); return }
            self.fetchCover(url) { completion($0) }
        }
    }

    // MARK: - Лайки

    private var likedCache: Set<String> = []

    func refreshLikes(completion: (() -> Void)? = nil) {
        guard let uid else { completion?(); return }
        request("/users/\(uid)/likes/tracks") { json in
            if let result = json?["result"] as? [String: Any],
               let library = result["library"] as? [String: Any],
               let tracks = library["tracks"] as? [[String: Any]] {
                self.likedCache = Set(tracks.compactMap { t in (t["id"]).map { "\($0)" } })
                self.logger.info("Лайков загружено: \(self.likedCache.count)")
            }
            completion?()
        }
    }

    func isLiked(trackId: String) -> Bool { likedCache.contains(trackId) }

    /// Ставит/снимает лайк через API. liked=true — добавить в «Мне нравится».
    func setLike(trackId: String, liked: Bool, completion: ((Bool) -> Void)? = nil) {
        guard let uid else { completion?(false); return }
        let action = liked ? "add-multiple" : "remove"
        request("/users/\(uid)/likes/tracks/\(action)", method: "POST",
                formBody: ["track-ids": trackId]) { json in
            let ok = json?["result"] != nil
            if ok {
                if liked { self.likedCache.insert(trackId) } else { self.likedCache.remove(trackId) }
            }
            completion?(ok)
        }
    }
}

// MARK: - Окно входа (WKWebView OAuth)

final class YandexAuthController: NSObject, WKNavigationDelegate {
    static let shared = YandexAuthController()

    private var window: NSWindow?
    private var onToken: ((String?) -> Void)?

    func present(onToken: @escaping (String?) -> Void) {
        self.onToken = onToken

        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: config)
        web.navigationDelegate = self
        // Десктопный User-Agent — Яндекс не любит встроенные мобильные webview
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        web.load(URLRequest(url: YandexMusicAPI.authURL))

        let w = NSWindow(contentRect: web.frame,
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Вход в Яндекс"
        w.contentView = web
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let token = Self.extractToken(from: url) {
            decisionHandler(.cancel)
            finish(token)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url, let token = Self.extractToken(from: url) { finish(token) }
    }

    private static func extractToken(from url: URL) -> String? {
        // Токен приходит во фрагменте: ...#access_token=XXX&token_type=bearer&...
        guard let frag = url.fragment else { return nil }
        for part in frag.split(separator: "&") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, kv[0] == "access_token", !kv[1].isEmpty { return kv[1] }
        }
        return nil
    }

    private func finish(_ token: String) {
        let cb = onToken
        onToken = nil
        window?.close()
        window = nil
        cb?(token)
    }
}
