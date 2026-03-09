import Foundation

// Shared keys and options used by both UI and persistence layers.
let defaultReadingModeKey = "defaultReadingModeRawValue"
let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "gif", "tiff", "heic", "avif"]
let readerDidCloseNotification = Notification.Name("readerDidCloseNotification")

enum DefaultReadingModeOption: String, CaseIterable, Identifiable {
    case automatic = "Автоматически"
    case vertical = "Вертикально"
    case leftToRight = "Слева → направо"
    case rightToLeft = "Справа ← налево"

    var id: String { rawValue }

    var readingMode: ReadingMode? {
        switch self {
        case .automatic: return nil
        case .vertical: return .vertical
        case .leftToRight: return .leftToRight
        case .rightToLeft: return .rightToLeft
        }
    }

    static func fromStoredRawValue(_ raw: String) -> DefaultReadingModeOption {
        DefaultReadingModeOption(rawValue: raw) ?? .automatic
    }
}

// When scanning iCloud folders right after relaunch, their contents may be temporarily unavailable.
func waitUntilFolderIsReadyForScan(_ folderURL: URL) {
    let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]

    guard let values = try? folderURL.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
        return
    }

    if values.ubiquitousItemDownloadingStatus != URLUbiquitousItemDownloadingStatus.current {
        try? FileManager.default.startDownloadingUbiquitousItem(at: folderURL)
    }

    for _ in 0..<30 {
        if let current = try? folderURL.resourceValues(forKeys: keys),
           current.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
            return
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
}
