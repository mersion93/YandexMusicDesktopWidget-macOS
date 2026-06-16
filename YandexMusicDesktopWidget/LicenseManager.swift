import Foundation
import Combine

// Управляет пробным периодом и статусом покупки.
// Сейчас без реальной оплаты — кнопка покупки заглушка; интеграцию (Gumroad/StoreKit)
// подключим позже, заменив purchase()/applyLicenseKey().

final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    /// Длительность пробного периода (дней).
    static let trialDays = 14

    private let trialStartKey = "trial_start_date"
    private let purchasedKey  = "is_purchased"
    private let licenseKey    = "license_key"

    @Published private(set) var isPurchased: Bool
    @Published private(set) var trialStart: Date

    private init() {
        let d = UserDefaults.standard
        isPurchased = d.bool(forKey: purchasedKey)
        if let ts = d.object(forKey: trialStartKey) as? Date {
            trialStart = ts
        } else {
            // Первый запуск — стартуем пробный период.
            let now = Date()
            d.set(now, forKey: trialStartKey)
            trialStart = now
        }
    }

    // MARK: - Статус

    var daysLeft: Int {
        let elapsed = Calendar.current.dateComponents([.day], from: trialStart, to: Date()).day ?? 0
        return max(0, Self.trialDays - elapsed)
    }
    var isTrialActive: Bool { daysLeft > 0 }
    /// Есть ли доступ к Pro-возможностям (куплено или активен триал).
    var hasAccess: Bool { isPurchased || isTrialActive }

    var statusText: String {
        if isPurchased { return "Полная версия" }
        if isTrialActive { return "Пробный период: \(daysLeft) дн. осталось" }
        return "Пробный период истёк"
    }

    // MARK: - Покупка (заглушки — реальную оплату подключим позже)

    /// Применить лицензионный ключ (формат проверим при подключении сервиса оплаты).
    func applyLicenseKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }
        UserDefaults.standard.set(trimmed, forKey: licenseKey)
        UserDefaults.standard.set(true, forKey: purchasedKey)
        isPurchased = true
        return true
    }

    /// Сброс покупки (для теста).
    func resetPurchase() {
        UserDefaults.standard.set(false, forKey: purchasedKey)
        UserDefaults.standard.removeObject(forKey: licenseKey)
        isPurchased = false
    }

    /// URL страницы покупки (заменим на реальную при подключении оплаты).
    static let purchaseURL = URL(string: "https://yandexmusicwidget.example.com/buy")!
}
