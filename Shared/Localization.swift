import Foundation

// Лёгкая локализация без .strings-файлов: на каждой строке указываем пару (ru, en).
// Язык берётся из общей настройки App Group: "auto" (по системе) | "ru" | "en".
// Работает в обоих таргетах (приложение и виджет) — настройка в общем файле.

enum AppLang {
    static let key = "app_language"   // "auto" | "ru" | "en"

    /// Текущий язык интерфейса ("ru"/"en"), кэшируется в памяти.
    static private(set) var current: String = resolve()

    static func resolve() -> String {
        // Приложение: UserDefaults.standard (его пишет @AppStorage пикера — для
        // мгновенного переключения). Виджет: общий файл App Group (у него свой
        // UserDefaults). Иначе — системный язык.
        if let s = UserDefaults.standard.string(forKey: key), s == "ru" || s == "en" { return s }
        let f = AppGroupManager.shared.loadLanguage()
        if f == "ru" || f == "en" { return f }
        let sys = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return sys.hasPrefix("ru") ? "ru" : "en"
    }

    /// Перечитать после смены настройки.
    static func refresh() { current = resolve() }
}

/// Возвращает строку на текущем языке. Использование: `tr("Настройки", "Settings")`.
func tr(_ ru: String, _ en: String) -> String {
    AppLang.current == "ru" ? ru : en
}
