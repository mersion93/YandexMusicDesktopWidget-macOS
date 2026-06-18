import Foundation

/// Единый кэш обложек: id трека Яндекс Музыки → готовые JPEG-данные (~700px).
///
/// На `NSCache`, а не на обычном словаре: он потокобезопасен и сам вытесняет старое
/// под давлением памяти — не нужно вручную чистить и держать счётчик. Каждая обложка
/// скачивается и даунскейлится ОДИН раз; повторный показ того же трека берётся отсюда.
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let cache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 60   // ~60 последних обложек хватает; дальше вытесняем LRU
    }

    func data(for id: String) -> Data? {
        cache.object(forKey: id as NSString) as Data?
    }

    func store(_ data: Data, for id: String) {
        cache.setObject(data as NSData, forKey: id as NSString)
    }
}
