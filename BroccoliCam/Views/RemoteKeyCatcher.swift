import SwiftUI
import UIKit
import GameController

/// 隱形的 view，專門接藍牙踏板、翻頁器、實體鍵盤的按鍵。
/// 不是文字輸入，所以不會叫出螢幕鍵盤。佔 1×1，不吃觸控。
struct RemoteKeyCatcher: UIViewRepresentable {
    let isActive: Bool
    let onKey: (RemoteKey) -> Void

    init(isActive: Bool, onKey: @escaping (RemoteKey) -> Void) {
        self.isActive = isActive
        self.onKey = onKey
    }

    func makeUIView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView(frame: .zero)
        view.onKey = onKey
        return view
    }

    func updateUIView(_ view: KeyCatcherView, context: Context) {
        view.onKey = onKey
        view.setActive(isActive)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: KeyCatcherView, context: Context) -> CGSize? {
        CGSize(width: 1, height: 1)
    }

    static func dismantleUIView(_ view: KeyCatcherView, coordinator: ()) {
        view.onKey = nil
        view.setActive(false)
    }
}

final class KeyCatcherView: UIView {
    var onKey: ((RemoteKey) -> Void)?

    private var isActive = false
    private var watchdog: Timer?

    /// 從 pressesBegan 收到、還沒放開的鍵。
    private var held = Set<Int>()
    /// 每個鍵上次送出的時間。
    private var lastFired: [Int: CFTimeInterval] = [:]
    /// GameController 回報正在按著的鍵，以及按下的時間。按著不放時系統會一直重送快速鍵，用這個擋掉。
    private var heldSince: [Int: CFTimeInterval] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = false
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(somethingChanged),
                           name: UIWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(somethingChanged),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardConnected),
                           name: .GCKeyboardDidConnect, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("只用程式建立")
    }

    // 只接按鍵，不接觸控。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }

    // MARK: - 搶 first responder

    override var canBecomeFirstResponder: Bool {
        isActive
    }

    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        held = []
        heldSince = [:]
        if on {
            startWatchdog()
            // 不在 SwiftUI 更新畫面的當下搶。
            DispatchQueue.main.async { [weak self] in
                self?.claim()
            }
        } else {
            stopWatchdog()
            // 同樣不在 SwiftUI 更新畫面的當下放，不然會報版面循環。
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isActive, self.isFirstResponder else { return }
                _ = self.resignFirstResponder()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopWatchdog()
        } else if isActive {
            startWatchdog()
            DispatchQueue.main.async { [weak self] in
                self?.claim()
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        held = []
        heldSince = [:]
        return super.resignFirstResponder()
    }

    /// 現在可以接就接過來。上面還蓋著彈出視窗就不搶，人家可能在打字。
    private func claim() {
        guard isActive, !isFirstResponder, let window, window.isKeyWindow else { return }
        if let owner = owningController, owner.presentedViewController != nil { return }
        if becomeFirstResponder() {
            listenToKeyboard()
        }
    }

    private var owningController: UIViewController? {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// 彈出視窗、提示關掉時不一定有通知，定時看一眼還是不是自己。
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.6, target: self, selector: #selector(somethingChanged),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    @objc private func somethingChanged() {
        claim()
    }

    @objc private func keyboardConnected() {
        // 通知不保證在主執行緒。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isFirstResponder {
                self.listenToKeyboard()
            } else {
                self.claim()
            }
        }
    }

    /// 只拿來知道哪個鍵還按著，按鍵本身不從這裡送。
    private func listenToKeyboard() {
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            let code = keyCode.rawValue
            let now = CACurrentMediaTime()
            DispatchQueue.main.async {
                self?.keyboardChanged(code: code, pressed: pressed, at: now)
            }
        }
    }

    private func keyboardChanged(code: Int, pressed: Bool, at time: CFTimeInterval) {
        if pressed {
            if heldSince[code] == nil { heldSince[code] = time }
        } else {
            heldSince[code] = nil
        }
    }

    // MARK: - 按鍵

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, accepts(key) {
                let code = key.keyCode.rawValue
                held.insert(code)
                fire(code, fromCommand: false)
            } else {
                rest.insert(press)
            }
        }
        if !rest.isEmpty {
            super.pressesBegan(rest, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = release(presses)
        if !rest.isEmpty {
            super.pressesEnded(rest, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = release(presses)
        if !rest.isEmpty {
            super.pressesCancelled(rest, with: event)
        }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = presses.filter { press in
            guard let key = press.key else { return true }
            return !held.contains(key.keyCode.rawValue)
        }
        if !rest.isEmpty {
            super.pressesChanged(rest, with: event)
        }
    }

    /// 放開的鍵裡，按下時是自己接的就收掉，其他的交回去。
    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, held.remove(key.keyCode.rawValue) != nil {
                continue
            }
            rest.insert(press)
        }
        return rest
    }

    private func accepts(_ key: UIKey) -> Bool {
        guard isActive else { return false }
        let modifiers = key.modifierFlags.intersection([.command, .control, .alternate])
        return modifiers.isEmpty && !RemoteKey(code: key.keyCode.rawValue).isModifier
    }

    /// 同一下可能從 pressesBegan 和快速鍵兩條路進來，只送一次；按著不放的重送也擋掉。
    private func fire(_ code: Int, fromCommand: Bool) {
        let now = CACurrentMediaTime()
        if fromCommand && held.contains(code) { return }
        if let fired = lastFired[code] {
            if now - fired < 0.12 {
                lastFired[code] = now
                return
            }
            // 上次送出之後一直沒放開。
            if fromCommand, let since = heldSince[code], fired >= since - 0.1 { return }
        }
        lastFired[code] = now
        onKey?(RemoteKey(code: code))
    }

    // MARK: - 快速鍵

    /// 這幾個鍵會被系統拿去移動焦點，要搶在系統之前。
    private static let priorityKeys: [(input: String, key: RemoteKey)] = [
        (UIKeyCommand.inputUpArrow, .up),
        (UIKeyCommand.inputDownArrow, .down),
        (UIKeyCommand.inputLeftArrow, .left),
        (UIKeyCommand.inputRightArrow, .right),
        (UIKeyCommand.inputPageUp, .pageUp),
        (UIKeyCommand.inputPageDown, .pageDown),
        (" ", .space),
        ("\r", .returnKey),
        ("\t", .tab)
    ]

    private lazy var commands: [UIKeyCommand] = KeyCatcherView.priorityKeys.map { item in
        let command = UIKeyCommand(input: item.input, modifierFlags: [],
                                   action: #selector(KeyCatcherView.commandFired(_:)))
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    override var keyCommands: [UIKeyCommand]? {
        isActive ? commands : nil
    }

    @objc private func commandFired(_ command: UIKeyCommand) {
        guard isActive, let item = Self.priorityKeys.first(where: { $0.input == command.input }) else { return }
        fire(item.key.code, fromCommand: true)
    }
}
