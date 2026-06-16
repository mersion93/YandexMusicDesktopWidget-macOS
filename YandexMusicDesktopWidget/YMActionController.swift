import Foundation
import AppKit
import ApplicationServices
import OSLog

// Лайк/дизлайк в Яндекс Музыке нельзя отправить медиа-клавишей — нужно нажать
// настоящую кнопку в интерфейсе через Accessibility API. Разрешение Accessibility
// есть только у основного приложения, поэтому весь код здесь, а виджет шлёт
// запросы через App Group (PendingAction).

struct YMActionController {
    static let shared = YMActionController()

    private let logger = Logger(subsystem: "com.yandexmusic.widget", category: "YMAction")

    private init() {}

    // MARK: - Public

    /// Нажимает кнопку «Мне нравится». Возвращает true при успехе.
    @discardableResult
    func performLike(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility не разрешён — лайк невозможен")
            return false
        }
        let ok = findAndPress(pid: pid, kind: .like)
        logger.info("Лайк: \(ok ? "успешно" : "кнопка не найдена")")
        return ok
    }

    /// Нажимает кнопку «Не нравится». Возвращает true при успехе.
    @discardableResult
    func performDislike(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else {
            logger.warning("Accessibility не разрешён — дизлайк невозможен")
            return false
        }
        let ok = findAndPress(pid: pid, kind: .dislike)
        logger.info("Дизлайк: \(ok ? "успешно" : "кнопка не найдена")")
        return ok
    }

    /// Определяет текущую оценку трека по состоянию кнопок (best-effort).
    /// Сначала сканируем только панель плеера (быстро) — кнопки лайка/дизлайка там.
    /// Полный обход дерева — только если в плеере кнопок не нашлось.
    func currentLikeState(pid: pid_t) -> LikeState {
        guard AXIsProcessTrusted() else { return .none }
        var buttons: [(el: AXUIElement, label: String)] = []
        if let bar = YMTrackReader.playerBar(pid: pid) {
            collectButtons(el: bar, depth: 0, maxDepth: 8, into: &buttons)
        }
        if buttons.isEmpty {
            let app = AXUIElementCreateApplication(pid)
            collectButtons(el: app, depth: 0, maxDepth: 25, into: &buttons)
        }

        for (el, label) in buttons {
            let l = label.lowercased()
            // «Убрать» + «нрав» → трек уже лайкнут
            if l.contains("нрав"), l.contains("убрать") || l.contains("убери") {
                return .liked
            }
            // Кнопка лайка в «нажатом» состоянии (AXValue == 1)
            if isLikeLabel(l), isPressed(el) { return .liked }
            if isDislikeLabel(l), isPressed(el) { return .disliked }
        }
        return .none
    }

    /// Переключает «Повтор». Возвращает true при успехе.
    @discardableResult
    func performRepeat(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return findAndPress(pid: pid, kind: .repeatMode)
    }

    /// Переключает «В случайном порядке». Возвращает true при успехе.
    @discardableResult
    func performShuffle(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        return findAndPress(pid: pid, kind: .shuffle)
    }

    // MARK: - Matching

    private enum Kind { case like, dislike, repeatMode, shuffle }

    private func findAndPress(pid: pid_t, kind: Kind) -> Bool {
        var buttons: [(el: AXUIElement, label: String)] = []
        if let bar = YMTrackReader.playerBar(pid: pid) {
            collectButtons(el: bar, depth: 0, maxDepth: 8, into: &buttons)
        }
        if buttons.isEmpty {
            let app = AXUIElementCreateApplication(pid)
            collectButtons(el: app, depth: 0, maxDepth: 25, into: &buttons)
        }

        let candidates = buttons.filter { item in
            let l = item.label.lowercased()
            switch kind {
            case .like:       return isLikeLabel(l)
            case .dislike:    return isDislikeLabel(l)
            case .repeatMode: return l.contains("повтор") || l.contains("repeat")
            case .shuffle:    return l.contains("случайн") || l.contains("перемеш")
                                  || l.contains("shuffle")
            }
        }

        logger.debug("\(kind == .like ? "like" : "dislike") кандидатов: \(candidates.count)")

        for item in candidates {
            if AXUIElementPerformAction(item.el, kAXPressAction as CFString) == .success {
                return true
            }
        }
        return false
    }

    private func isLikeLabel(_ l: String) -> Bool {
        // «Мне нравится» / «Нравится» / «Like» — но не дизлайк
        let isDislike = isDislikeLabel(l)
        if isDislike { return false }
        return l.contains("нрав") || (l.contains("like") && !l.contains("dislike"))
            || l.contains("в коллекцию") || l.contains("в избранное")
    }

    private func isDislikeLabel(_ l: String) -> Bool {
        return l.contains("не нрав") || l.contains("не понрав")
            || l.contains("дизлайк") || l.contains("dislike")
            || l.contains("заблокировать") || l.contains("заблокир")
            || l.contains("не интересно") || l.contains("ban")
    }

    private func isPressed(_ el: AXUIElement) -> Bool {
        var valRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef) == .success
        else { return false }
        if let n = valRef as? Int { return n != 0 }
        if let b = valRef as? Bool { return b }
        return false
    }

    // MARK: - Traversal

    private func collectButtons(el: AXUIElement, depth: Int, maxDepth: Int,
                                into buttons: inout [(el: AXUIElement, label: String)]) {
        guard depth < maxDepth else { return }

        var roleRef: AnyObject?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        if role == "AXButton" || role == "AXCheckBox" || role == "AXRadioButton" {
            let label = buttonLabel(el)
            if !label.isEmpty {
                buttons.append((el, label))
            }
        }

        var childRef: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childRef) == .success,
              let children = childRef as? [AXUIElement] else { return }
        for child in children {
            collectButtons(el: child, depth: depth + 1, maxDepth: maxDepth, into: &buttons)
        }
    }

    private func buttonLabel(_ el: AXUIElement) -> String {
        var parts: [String] = []
        for attr in [kAXDescriptionAttribute, kAXTitleAttribute,
                     kAXHelpAttribute, kAXRoleDescriptionAttribute] {
            var ref: AnyObject?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success,
               let s = ref as? String, !s.isEmpty {
                parts.append(s)
            }
        }
        return parts.joined(separator: " ")
    }
}
