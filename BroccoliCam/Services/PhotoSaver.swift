import Foundation
import Photos

enum PhotoSaveError: LocalizedError {
    case denied
    case unknown

    var errorDescription: String? {
        switch self {
        case .denied: return "沒有照片圖庫的權限。請到「設定」開啟「加入照片」權限。"
        case .unknown: return "儲存失敗，請再試一次。"
        }
    }
}

enum PhotoSaver {
    /// 只要求「加入照片」權限。completion 在主執行緒回呼。
    static func save(videoAt url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(PhotoSaveError.denied)) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { ok, error in
                DispatchQueue.main.async {
                    if ok {
                        completion(.success(()))
                    } else {
                        completion(.failure(error ?? PhotoSaveError.unknown))
                    }
                }
            })
        }
    }
}
