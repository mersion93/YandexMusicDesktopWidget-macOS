import Foundation
import OSLog

// Яндекс Музыка не отдаёт обложку через систему, а из AX-дерева вытащить картинку
// нельзя. Поэтому ищем обложку по названию+исполнителю через бесплатный
// iTunes Search API (без авторизации) — большинство треков там есть.

enum ArtworkFetcher {
    private static let logger = Logger(subsystem: "com.yandexmusic.widget", category: "Artwork")

    // Заголовки-заглушки ЯМ для радиостанций — настоящего трека нет
    private static let radioPlaceholders: Set<String> = [
        "в стиле артиста", "моя волна", "дежавю", "яндекс музыка",
        "нет информации", "my wave", "дневник звука"
    ]

    /// Результат поиска в iTunes — обложка, артист и длительность трека.
    struct FetchResult {
        let artwork: Data?
        let artist: String?
        let duration: TimeInterval?   // trackTimeMillis / 1000, nil если не найдена
    }

    /// Ищет обложку и артиста. Пробует несколько запросов по очереди, пока не найдёт обложку:
    ///   1. «исполнитель название» в магазине RU
    ///   2. «исполнитель название» в магазине US (там самый большой каталог)
    ///   3. только «название» в магазине US
    /// Это резко повышает шанс найти обложку для нероссийских/редких треков.
    static func fetch(title: String, artist: String, completion: @escaping (FetchResult) -> Void) {
        let fallbackArtist = Constants.Media.fallbackArtist
        let isRadio        = radioPlaceholders.contains(title.lowercased())
        let noArtist       = artist.isEmpty || artist == fallbackArtist

        let cleanTitle  = title.trimmingCharacters(in: .whitespaces)
        let cleanArtist = artist.trimmingCharacters(in: .whitespaces)

        // Формируем очередь поисковых запросов (term, country)
        var attempts: [(term: String, country: String)] = []
        if isRadio {
            attempts.append((cleanArtist, "RU"))
        } else if noArtist {
            attempts.append((cleanTitle, "US"))
            attempts.append((cleanTitle, "RU"))
        } else {
            attempts.append(("\(cleanArtist) \(cleanTitle)", "RU"))
            attempts.append(("\(cleanArtist) \(cleanTitle)", "US"))
            attempts.append((cleanTitle, "US"))   // последний резерв — только название
        }
        attempts = attempts.filter { !$0.term.isEmpty }

        guard !attempts.isEmpty else {
            completion(FetchResult(artwork: nil, artist: nil, duration: nil)); return
        }

        runAttempts(attempts, index: 0, completion: completion)
    }

    /// Рекурсивно перебирает запросы; останавливается, как только получена обложка.
    private static func runAttempts(_ attempts: [(term: String, country: String)],
                                    index: Int,
                                    completion: @escaping (FetchResult) -> Void) {
        guard index < attempts.count else {
            completion(FetchResult(artwork: nil, artist: nil, duration: nil)); return
        }
        let attempt = attempts[index]
        let next = { runAttempts(attempts, index: index + 1, completion: completion) }

        guard let term = attempt.term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(term)&entity=song&limit=1&country=\(attempt.country)")
        else { next(); return }

        URLSession.shared.dataTask(with: url) { data, _, error in
            if let error = error {
                logger.debug("iTunes search ошибка: \(error.localizedDescription)")
                next(); return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let first = results.first else {
                next(); return
            }

            let foundArtist   = first["artistName"] as? String
            let foundDuration = (first["trackTimeMillis"] as? Double).map { $0 / 1000 }

            guard let artworkUrl = first["artworkUrl100"] as? String else {
                next(); return   // нет картинки в этом результате — пробуем следующий запрос
            }

            // Повышаем разрешение: 100x100 → 600x600
            let bigUrlStr = artworkUrl.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            guard let imgUrl = URL(string: bigUrlStr) else {
                completion(FetchResult(artwork: nil, artist: foundArtist, duration: foundDuration)); return
            }

            URLSession.shared.dataTask(with: imgUrl) { imgData, _, _ in
                if let imgData = imgData, !imgData.isEmpty {
                    completion(FetchResult(artwork: imgData, artist: foundArtist, duration: foundDuration))
                } else {
                    next()   // картинка не загрузилась — пробуем следующий запрос
                }
            }.resume()
        }.resume()
    }
}
