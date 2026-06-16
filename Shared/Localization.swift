import Foundation

// Лёгкая локализация без .strings-файлов: на каждой строке указываем пару (ru, en).
// Язык берётся из общей настройки App Group: "auto" (по системе) | "ru" | "en".
// Работает в обоих таргетах (приложение и виджет) — настройка в общем файле.

enum AppLang {
    static let key = "app_language"   // "auto" | "ru" | "en"

    /// Текущий язык интерфейса ("ru"/"en") — ВЫЧИСЛЯЕТСЯ на лету (не кэшируется),
    /// чтобы перерисовка от смены @AppStorage сразу брала свежий язык.
    static var current: String {
        // Приложение: @AppStorage пишет в UserDefaults.standard (мгновенно).
        let u = UserDefaults.standard.string(forKey: key)
        if u == "ru" || u == "en" { return u! }
        // Виджет: своего UserDefaults для этого ключа нет (nil) → берём общий файл.
        if u == nil {
            let f = AppGroupManager.shared.loadLanguage()
            if f == "ru" || f == "en" { return f }
        }
        // "auto" или нет выбора — системный язык.
        let sys = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return sys.hasPrefix("ru") ? "ru" : "en"
    }

    static func refresh() {}   // больше не нужно: current вычисляется при каждом обращении
}

/// Возвращает строку на текущем языке. Использование: `tr("Настройки", "Settings")`.
func tr(_ ru: String, _ en: String) -> String {
    AppLang.current == "ru" ? ru : en
}
