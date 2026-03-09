import Foundation

struct MangaLibrary: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var bookmarkData: Data?
}

struct MangaChapter: Identifiable, Hashable {
    let title: String
    let groupPath: [String]
    let folderURL: URL?
    let pageURLs: [URL]

    var id: String {
        if let folderURL {
            return folderURL.standardizedFileURL.path
        }
        return (groupPath + [title]).joined(separator: "/")
    }

    var groupTitle: String {
        groupPath.isEmpty ? "Главы" : groupPath.joined(separator: " / ")
    }
}

struct MangaTitle: Identifiable, Hashable {
    let name: String
    let rootURL: URL
    let chapters: [MangaChapter]

    var id: String {
        rootURL.standardizedFileURL.path
    }
}

extension MangaTitle {
    var coverPageURL: URL? {
        chapters.first?.pageURLs.first
    }

    func chapter(forFolderURL folderURL: URL) -> MangaChapter? {
        chapters.first { chapter in
            chapter.folderURL?.standardizedFileURL.path == folderURL.standardizedFileURL.path
        }
    }

    func chapterStorageID(for chapter: MangaChapter) -> String {
        if let folderURL = chapter.folderURL {
            let chapterPath = folderURL.path
            let rootPath = rootURL.path
            if chapterPath.hasPrefix(rootPath) {
                let suffix = chapterPath.dropFirst(rootPath.count)
                return String(suffix)
            }
            return chapterPath
        }
        return (chapter.groupPath + [chapter.title]).joined(separator: "/")
    }

    func chapterIndex(forStorageID storageID: String) -> Int? {
        chapters.firstIndex { chapterStorageID(for: $0) == storageID }
    }

    func stopPointDescription(from state: MangaReadingState) -> String {
        guard let chapterIndex = chapterIndex(forStorageID: state.chapterID),
              chapters.indices.contains(chapterIndex) else {
            return "Точка: не определена"
        }

        let chapter = chapters[chapterIndex]
        let pageCount = chapter.pageURLs.count
        let clampedPage = pageCount > 0 ? min(max(state.logicalPageIndex, 0), pageCount - 1) + 1 : 1
        return "Точка: Гл. \(chapterIndex + 1), стр. \(clampedPage)"
    }

    func compactProgressDescription(from state: MangaReadingState) -> String {
        guard let chapterIndex = chapterIndex(forStorageID: state.chapterID),
              chapters.indices.contains(chapterIndex) else {
            return "Прогресс: —"
        }

        let chapter = chapters[chapterIndex]
        let pageCount = max(chapter.pageURLs.count, 1)
        let pageInChapter = min(max(state.logicalPageIndex, 0), pageCount - 1) + 1

        let totalPages = max(chapters.reduce(0) { $0 + max($1.pageURLs.count, 1) }, 1)
        let pagesBeforeChapter = chapters.prefix(chapterIndex).reduce(0) { $0 + max($1.pageURLs.count, 1) }
        let absolutePage = pagesBeforeChapter + pageInChapter
        let percent = Int((Double(absolutePage) / Double(totalPages) * 100).rounded())

        return "Гл \(chapterIndex + 1) • стр \(pageInChapter) • \(percent)%"
    }
}

enum ReadingMode: String, CaseIterable, Identifiable {
    case vertical = "Вертикально"
    case leftToRight = "Слева → направо"
    case rightToLeft = "Справа ← налево"

    var id: String { rawValue }
}

struct MangaReadingState: Codable {
    let chapterID: String
    let logicalPageIndex: Int
    let readingModeRawValue: String
    let pagedFitToScreen: Bool?
    let autoReadingMode: Bool?
    let lastReadAt: Date?
    let verticalOffsetInPage: Double?
}
