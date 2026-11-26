import AVFoundation

/// 要用哪支麥克風。存進設定的是字串：auto、builtin，或 port:<uid>\n<名字>（指定某一支，沒接上時照自動挑）。
enum MicChoice: Hashable {
    case automatic
    case builtIn
    case port(uid: String, name: String)

    init(storage: String) {
        if storage == "builtin" {
            self = .builtIn
        } else if storage.hasPrefix("port:") {
            let body = storage.dropFirst("port:".count)
            let parts = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let uid = parts.first.map(String.init) ?? ""
            let name = parts.count > 1 ? String(parts[1]) : uid
            self = uid.isEmpty ? .automatic : .port(uid: uid, name: name)
        } else {
            self = .automatic
        }
    }

    var storage: String {
        switch self {
        case .automatic: return "auto"
        case .builtIn: return "builtin"
        case .port(let uid, let name): return "port:\(uid)\n\(name)"
        }
    }
}

/// 外接麥是雙聲道時怎麼錄。
enum MicChannelMode: String, CaseIterable, Identifiable {
    /// 左右混成一軌，兩邊耳朵聽到的一樣。一支發射器時最保險。
    case mono
    /// 左右分開，兩支發射器各佔一邊（DJI 接收器的立體聲模式）。
    case stereo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mono: return "合成單聲道"
        case .stereo: return "立體聲（左右分開）"
        }
    }
}

/// 麥克風的種類：決定自動模式誰優先、畫面上怎麼講。
enum MicKind: Equatable {
    case builtIn
    case usb
    case wired
    case bluetooth
    case other
    case none

    init(_ port: AVAudioSession.Port) {
        switch port {
        case .builtInMic: self = .builtIn
        case .usbAudio: self = .usb
        case .headsetMic, .lineIn: self = .wired
        case .bluetoothHFP: self = .bluetooth
        default: self = .other
        }
    }

    var label: String {
        switch self {
        case .builtIn: return "手機麥克風"
        case .usb: return "USB 麥克風"
        case .wired: return "有線麥克風"
        case .bluetooth: return "藍牙麥克風"
        case .other: return "外接麥克風"
        case .none: return "沒有麥克風"
        }
    }

    /// 自動模式的順序，小的先用：USB（DJI 接收器、音訊介面）> 有線 > 其他 > 藍牙 > 手機。
    var priority: Int {
        switch self {
        case .usb: return 0
        case .wired: return 1
        case .other: return 2
        case .bluetooth: return 3
        case .builtIn: return 4
        case .none: return 9
        }
    }

    var isExternal: Bool { self != .builtIn && self != .none }
}

/// 接著的一支麥克風。
struct MicPort: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: MicKind
}

/// 現在實際的收音狀況，給主畫面、設定頁、除錯層看。
struct MicRoute: Equatable {
    var name = "—"
    var kind: MicKind = .none
    /// 系統這條路線給幾聲道。
    var inputChannels = 0
    var sampleRate: Double = 0
    /// 照現在的設定，下一段會錄成雙聲道。
    var recordsStereo = false
    /// 接著、可以選的麥克風。
    var available: [MicPort] = []
    /// AirPods 高品質收音有打開。
    var bluetoothHQ = false
    /// 錄影中才接上、等這段錄完才換過去的那支。
    var waitingFor: String?

    /// 藍牙走電話用的通道（HFP），音質只有電話等級。
    var isPhoneQuality: Bool { kind == .bluetooth && !bluetoothHQ }

    /// 主畫面那一小行。手機麥克風不寫，外接的才寫。
    var badge: String? {
        guard kind.isExternal else { return nil }
        if isPhoneQuality { return "藍牙・音質較差" }
        return recordsStereo ? "\(name)・立體聲" : name
    }

    /// 給人看的一句。
    var summary: String {
        guard kind != .none else { return "沒有麥克風" }
        let rate = sampleRate > 0 ? String(format: "%.0f kHz", sampleRate / 1000) : "—"
        var text = "\(name)（\(kind.label)，\(inputChannels) 聲道，\(rate)）"
        if recordsStereo { text += "，錄成立體聲" }
        return text
    }
}

/// 管 AVAudioSession：錄影用的類別、要不要開藍牙麥克風、挑哪支麥克風、要幾聲道。
/// 相機的 session 不自動設定音訊（要自己挑外接麥、要雙聲道，自動設定做不到），全部在這裡做。
/// 只在 CameraService 的 sessionQueue 呼叫。
final class AudioRouter {
    struct Preferences: Equatable {
        var choice: MicChoice = .automatic
        /// 藍牙麥克風（DJI Mic Mini／Mic 3 直連、AirPods）。
        var allowsBluetooth = true
        var channelMode: MicChannelMode = .mono
        /// iOS 26 的 AirPods 高品質收音。
        var bluetoothHQ = false
    }

    var preferences = Preferences()
    var onLog: ((String) -> Void)?

    private var session: AVAudioSession { AVAudioSession.sharedInstance() }

    /// 這支手機的系統有沒有 AirPods 高品質收音。
    static var supportsBluetoothHQ: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// 把音訊設成錄影用。開相機前、從播放頁回來、中斷結束時呼叫。已經是這樣就不重設。
    func activate() {
        let options = categoryOptions()
        do {
            if session.category != .playAndRecord || session.mode != .videoRecording || session.categoryOptions != options {
                try session.setCategory(.playAndRecord, mode: .videoRecording, options: options)
                onLog?("音訊設成錄影用\(preferences.allowsBluetooth ? "（可用藍牙麥）" : "")")
            }
            try session.setActive(true)
        } catch {
            onLog?("音訊設定失敗：\(error.localizedDescription)")
        }
    }

    private func categoryOptions() -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        if preferences.allowsBluetooth {
            options.insert(Self.hfpOption)
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), preferences.bluetoothHQ {
            options.insert(.bluetoothHighQualityRecording)
        }
        #endif
        return options
    }

    private static var hfpOption: AVAudioSession.CategoryOptions {
        // 新版 SDK 改名叫 allowBluetoothHFP（舊系統一樣能用），舊 SDK 只有舊名字。
        #if compiler(>=6.2)
        return .allowBluetoothHFP
        #else
        return .allowBluetooth
        #endif
    }

    /// AirPods 高品質收音現在有沒有開著。
    var bluetoothHQActive: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return session.categoryOptions.contains(.bluetoothHighQualityRecording)
        }
        #endif
        return false
    }

    /// 照設定挑麥克風、設聲道數。
    /// 錄影中不換：換了聲音會斷一下、音量也會跳，回傳想換過去的那支名字，等錄完再叫一次。
    @discardableResult
    func applyChoice(recording: Bool) -> String? {
        let inputs = session.availableInputs ?? []
        guard let target = pick(inputs) else { return nil }
        if recording {
            let current = session.currentRoute.inputs.first
            return current?.uid == target.uid ? nil : target.portName
        }
        if session.preferredInput?.uid != target.uid {
            do {
                try session.setPreferredInput(target)
                onLog?("改用麥克風：\(target.portName)")
            } catch {
                onLog?("換麥克風失敗：\(error.localizedDescription)")
            }
        }
        applyChannels()
        return nil
    }

    /// USB、有線麥能給兩聲道就要兩聲道：立體聲要錄左右，合成單聲道也要兩邊都收到才混得起來。
    private func applyChannels() {
        let kind = session.currentRoute.inputs.first.map { MicKind($0.portType) } ?? .none
        let wanted: Int = (kind == .usb || kind == .wired || kind == .other) && session.maximumInputNumberOfChannels >= 2 ? 2 : 1
        guard session.preferredInputNumberOfChannels != wanted else { return }
        do {
            try session.setPreferredInputNumberOfChannels(wanted)
            onLog?("收音聲道設成 \(wanted)")
        } catch {
            onLog?("設聲道數失敗：\(error.localizedDescription)")
        }
    }

    private func pick(_ inputs: [AVAudioSessionPortDescription]) -> AVAudioSessionPortDescription? {
        switch preferences.choice {
        case .builtIn:
            if let builtIn = inputs.first(where: { $0.portType == .builtInMic }) { return builtIn }
        case .port(let uid, _):
            if let chosen = inputs.first(where: { $0.uid == uid }) { return chosen }
        case .automatic:
            break
        }
        let usable = inputs.filter { preferences.allowsBluetooth || MicKind($0.portType) != .bluetooth }
        return usable.min { MicKind($0.portType).priority < MicKind($1.portType).priority }
    }

    /// 這次錄影要錄幾聲道。
    func recordingChannels() -> Int {
        preferences.channelMode == .stereo && session.inputNumberOfChannels >= 2 ? 2 : 1
    }

    /// 現在用的麥克風名字，錄影中拿來比對有沒有被換掉。
    var currentInputName: String? {
        session.currentRoute.inputs.first?.portName
    }

    var currentKind: MicKind {
        session.currentRoute.inputs.first.map { MicKind($0.portType) } ?? .none
    }

    func snapshot(waitingFor: String?) -> MicRoute {
        let current = session.currentRoute.inputs.first
        var route = MicRoute()
        route.name = current?.portName ?? "沒有麥克風"
        route.kind = current.map { MicKind($0.portType) } ?? .none
        route.inputChannels = current == nil ? 0 : session.inputNumberOfChannels
        route.sampleRate = session.sampleRate
        route.recordsStereo = recordingChannels() == 2
        route.available = (session.availableInputs ?? []).map {
            MicPort(id: $0.uid, name: $0.portName, kind: MicKind($0.portType))
        }
        route.bluetoothHQ = bluetoothHQActive
        route.waitingFor = waitingFor
        return route
    }
}
