import SwiftUI

@main
struct BroccoliCamApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var library: ScriptLibrary
    @StateObject private var camera = CameraService()

    /// ScriptLibrary 要跟畫面用同一個 SettingsStore，而且讀檔時就會寫回 script，
    /// 所以兩個都在這裡先建好，不等到畫面更新時才建。
    init() {
        let settings = SettingsStore()
        let library = ScriptLibrary(settings: settings)
        _settings = StateObject(wrappedValue: settings)
        _library = StateObject(wrappedValue: library)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(camera)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum Theme {
    /// 柔和藕荷色，只作為點綴。
    static let accent = Color(red: 0.83, green: 0.65, blue: 0.72)
    static let good = Color(red: 0.45, green: 0.82, blue: 0.60)
    static let record = Color(red: 0.90, green: 0.31, blue: 0.33)
}

/// App 開啟後直接到相機；只有還沒授權時才先說明權限。
struct RootView: View {
    @EnvironmentObject private var camera: CameraService
    @EnvironmentObject private var library: ScriptLibrary
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch camera.authorization {
            case .authorized:
                RecordingView()
            case .unknown:
                PermissionView(denied: false)
            case .denied:
                PermissionView(denied: true)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                camera.refreshAuthorization()
            } else {
                // 從背景可能直接被滑掉，一離開前景就把腳本寫進檔案。
                library.flush()
            }
        }
    }
}

struct PermissionView: View {
    @EnvironmentObject private var camera: CameraService
    let denied: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "video.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accent)
                Text(denied ? "需要相機與麥克風權限" : "先開啟相機與麥克風")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text(denied
                     ? "目前沒有權限，所以無法錄影。請到「設定」打開相機與麥克風。"
                     : "花椰菜相機用前鏡頭和麥克風錄下你的口播。畫面與聲音只留在這支手機上。")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    if denied {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } else {
                        camera.requestAccess()
                    }
                } label: {
                    Text(denied ? "前往設定" : "允許相機與麥克風")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: Capsule())
                }
                .padding(.top, 8)
            }
        }
    }
}
