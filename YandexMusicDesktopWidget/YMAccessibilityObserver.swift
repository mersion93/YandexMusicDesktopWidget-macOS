import Foundation
import AppKit

// Подписывается на kAXTitleChangedNotification процесса ЯМ.
// Когда пользователь переключает трек, ЯМ меняет document.title →
// AX-уведомление приходит за <50 мс, что намного быстрее периодического опроса.
final class YMAccessibilityObserver {

    static let shared = YMAccessibilityObserver()

    var onChange: (() -> Void)?

    private var axObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var retainedSelf: UnsafeMutableRawPointer?

    // Дросселирование: не чаще одного вызова каждые 200 мс
    private var lastFireDate: Date = .distantPast
    private let throttle: TimeInterval = 0.2

    private init() {}
    deinit { stop() }

    func startIfNeeded(pid: pid_t) {
        guard pid != observedPID else { return }
        stop()
        observedPID = pid

        var obs: AXObserver?
        guard AXObserverCreate(pid, ymAXGlobalCallback, &obs) == .success,
              let obs else { return }

        axObserver = obs
        retainedSelf = Unmanaged.passRetained(self).toOpaque()

        let app = AXUIElementCreateApplication(pid)
        // Заголовок окна меняется при смене трека (в обычном режиме, не в «Моей волне»)
        AXObserverAddNotification(obs, app, kAXTitleChangedNotification as CFString, retainedSelf)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    }

    func stop() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            axObserver = nil
        }
        if let ptr = retainedSelf {
            Unmanaged<YMAccessibilityObserver>.fromOpaque(ptr).release()
            retainedSelf = nil
        }
        observedPID = 0
    }

    fileprivate func handleNotification() {
        let now = Date()
        guard now.timeIntervalSince(lastFireDate) >= throttle else { return }
        lastFireDate = now
        // Небольшая задержка: даём Electron обновить AX-дерево после смены заголовка
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.onChange?()
        }
    }
}

// C-callback обязателен для AXObserver; передаёт управление в экземпляр через refcon.
private let ymAXGlobalCallback: AXObserverCallback = { _, _, _, refcon in
    guard let ptr = refcon else { return }
    Unmanaged<YMAccessibilityObserver>.fromOpaque(ptr).takeUnretainedValue().handleNotification()
}
