import Foundation

/// 藍牙踏板、翻頁器、實體鍵盤可以做的事。
enum RemoteAction: String, CaseIterable, Codable, Identifiable {
    case next
    case previous
    case playPause
    case toggleVoice
    case toggleJumpMode
    case record

    var id: String { rawValue }

    var label: String {
        switch self {
        case .next: return "往下"
        case .previous: return "往上"
        case .playPause: return "暫停／繼續"
        case .toggleVoice: return "開關語音跟隨"
        case .toggleJumpMode: return "切換逐段／逐行"
        case .record: return "開始／停止錄影"
        }
    }
}

/// 一個實體按鍵。用鍵盤的 HID usage 編號認，和輸入法、大小寫無關。
struct RemoteKey: Codable, Hashable {
    let code: Int

    static let returnKey = RemoteKey(code: 0x28)
    static let tab = RemoteKey(code: 0x2B)
    static let space = RemoteKey(code: 0x2C)
    static let period = RemoteKey(code: 0x37)
    static let pageUp = RemoteKey(code: 0x4B)
    static let pageDown = RemoteKey(code: 0x4E)
    static let right = RemoteKey(code: 0x4F)
    static let left = RemoteKey(code: 0x50)
    static let down = RemoteKey(code: 0x51)
    static let up = RemoteKey(code: 0x52)
    static let letterC = RemoteKey(code: 0x06)
    static let letterM = RemoteKey(code: 0x10)

    /// Ctrl、Shift、Alt、Cmd 本身，不拿來當按鍵。
    var isModifier: Bool {
        (0xE0...0xE7).contains(code) || code == 0x39
    }

    /// 給人看的名字。
    var label: String {
        switch code {
        case 0x04...0x1D:
            return Self.character(from: "A", offset: code - 0x04)
        case 0x1E...0x26:
            return "\(code - 0x1E + 1)"
        case 0x27:
            return "0"
        case 0x3A...0x45:
            return "F\(code - 0x3A + 1)"
        case 0x59...0x61:
            return "小鍵盤 \(code - 0x59 + 1)"
        case 0x62:
            return "小鍵盤 0"
        default:
            return Self.names[code] ?? "按鍵 \(code)"
        }
    }

    private static func character(from first: Unicode.Scalar, offset: Int) -> String {
        guard let scalar = Unicode.Scalar(first.value + UInt32(offset)) else { return "" }
        return String(Character(scalar))
    }

    private static let names: [Int: String] = [
        0x28: "Enter",
        0x29: "Esc",
        0x2A: "退格鍵",
        0x2B: "Tab",
        0x2C: "空白鍵",
        0x2D: "-",
        0x2E: "=",
        0x2F: "[",
        0x30: "]",
        0x31: "\\",
        0x33: ";",
        0x34: "'",
        0x35: "`",
        0x36: "逗號",
        0x37: "句號",
        0x38: "/",
        0x49: "Insert",
        0x4A: "Home",
        0x4B: "PageUp",
        0x4C: "Delete",
        0x4D: "End",
        0x4E: "PageDown",
        0x4F: "→",
        0x50: "←",
        0x51: "↓",
        0x52: "↑",
        0x58: "小鍵盤 Enter",
        0x63: "小鍵盤句號"
    ]
}

/// 哪個鍵做哪件事。一個鍵只能對一個動作，一個動作可以有好幾個鍵。
struct RemoteBindings: Codable, Equatable {
    private var map: [RemoteAction: [RemoteKey]]

    static let standard = RemoteBindings(map: [
        .next: [.down, .right, .pageDown],
        .previous: [.up, .left, .pageUp],
        .playPause: [.space, .returnKey, .period],
        .toggleVoice: [.letterC],
        .toggleJumpMode: [.letterM],
        .record: []
    ])

    private init(map: [RemoteAction: [RemoteKey]]) {
        self.map = map
    }

    func keys(for action: RemoteAction) -> [RemoteKey] {
        map[action] ?? []
    }

    func action(for key: RemoteKey) -> RemoteAction? {
        RemoteAction.allCases.first { keys(for: $0).contains(key) }
    }

    /// 這個鍵改成做這件事，原本做的事就不再對應它。
    mutating func assign(_ key: RemoteKey, to action: RemoteAction) {
        guard self.action(for: key) != action else { return }
        remove(key)
        map[action] = keys(for: action) + [key]
    }

    mutating func remove(_ key: RemoteKey) {
        for action in RemoteAction.allCases {
            map[action] = keys(for: action).filter { $0 != key }
        }
    }

    // MARK: - 存檔

    /// 存成「動作名稱：按鍵」。讀的時候不認得的動作跳過，少掉的動作補預設，壞掉就整組預設。
    init(from decoder: Decoder) throws {
        let saved = (try? [String: [RemoteKey]](from: decoder)) ?? [:]
        var result: [RemoteAction: [RemoteKey]] = [:]
        var used = Set<RemoteKey>()
        for action in RemoteAction.allCases {
            guard let keys = saved[action.rawValue] else { continue }
            result[action] = keys.filter { used.insert($0).inserted }
        }
        for action in RemoteAction.allCases where result[action] == nil {
            // 別的動作已經用掉的鍵不搶。
            result[action] = Self.standard.keys(for: action).filter { used.insert($0).inserted }
        }
        map = result
    }

    func encode(to encoder: Encoder) throws {
        var saved: [String: [RemoteKey]] = [:]
        // 空的也要寫，才分得出「使用者清掉了」和「舊版沒有這個動作」。
        for action in RemoteAction.allCases {
            saved[action.rawValue] = keys(for: action)
        }
        try saved.encode(to: encoder)
    }
}
