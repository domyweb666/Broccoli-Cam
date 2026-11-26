import SwiftUI
import UIKit

/// 存到「檔案」：打開系統的存檔視窗，可以選 iCloud Drive、這台手機，或其他裝了的雲端硬碟。
enum FileExport {
    /// 給存檔視窗一個好認的檔名。用硬連結，不多占空間；連不了才複製。
    static func prepare(_ source: URL, label: String? = nil) async throws -> URL {
        let name = fileName(for: source, label: label)
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory
                .appendingPathComponent("FileExport", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(name)
            do {
                try fm.linkItem(at: source, to: target)
            } catch {
                try fm.copyItem(at: source, to: target)
            }
            return target
        }.value
    }

    /// 存檔視窗關掉之後，把暫時取的檔名收掉。原檔不動。
    static func cleanUp(_ prepared: URL) {
        try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent())
    }

    /// 「花椰菜相機 字幕版 20261126-1530.mov」。冒號在「檔案」裡不能用，時間不加冒號。
    static func fileName(for source: URL, label: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let date = (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
        let parts = ["花椰菜相機", label, formatter.string(from: date)].compactMap { $0 }
        return parts.joined(separator: " ") + "." + ext
    }
}

/// 要交給存檔視窗的檔案。
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// 系統的存檔視窗。存的是複本，原檔留在 app 裡。
struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    /// true 是存好了，false 是按了取消。
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) {
            self.onFinish = onFinish
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(true)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}
