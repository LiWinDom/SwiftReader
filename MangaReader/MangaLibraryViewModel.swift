import Foundation
import SwiftUI
import Combine

@MainActor
final class MangaLibraryViewModel: ObservableObject {
    enum MangaSortOption: String, CaseIterable, Identifiable {
        case recentlyReadDesc = "Последние сверху"
        case recentlyReadAsc = "Последние снизу"
        case progressDesc = "% чтения: больше сверху"
        case progressAsc = "% чтения: меньше сверху"
        case sizeDesc = "Размер: больше сверху"
        case sizeAsc = "Размер: меньше сверху"
        case nameAsc = "Название: А-Я"
        case nameDesc = "Название: Я-А"

        var id: String { rawValue }

        var needsSizeCalculation: Bool {
            self == .sizeAsc || self == .sizeDesc
        }
    }

    @Published var mangas: [MangaTitle] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var defaultReadingModeRawValue: String = DefaultReadingModeOption.automatic.rawValue
    @Published var libraries: [MangaLibrary] = []
    @Published var selectedLibraryID: UUID?
    @Published var sortOptionRawValue: String = MangaSortOption.recentlyReadDesc.rawValue

    private var scopedURL: URL?
    private var scanTask: Task<Void, Never>?
    private var activeLoadToken = UUID()
    private var cachedSizeByMangaID: [String: Int64] = [:]

    private let librariesKey = "mangaLibraries"
    private let selectedLibraryIDKey = "selectedLibraryID"
    private let sortOptionKey = "mangaSortOption"

    // Legacy one-folder storage keys for migration.
    private let legacyExternalBookmarkKey = "externalRootBookmarkData"
    private let legacyExternalPathKey = "externalRootFolderPath"
    private let legacyBookmarkKey = "mangaRootBookmarkData"
    private let legacyRootFolderPathKey = "mangaRootFolderPath"

    private var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
    #if os(iOS)
        []
    #else
        [.withSecurityScope]
    #endif
    }

    private var bookmarkCreationOptions: URL.BookmarkCreationOptions {
    #if os(iOS)
        [.minimalBookmark]
    #else
        [.withSecurityScope]
    #endif
    }

    init() {
        loadDefaultReadingMode()
        loadSortOption()
        loadLibraries()
        migrateLegacyLibraryIfNeeded()
        restoreSelectedLibrary()
        reload()
    }

    deinit {
        scanTask?.cancel()
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    var sourceTitle: String {
        selectedLibrary?.name ?? "Библиотеки"
    }

    var hasLibraries: Bool {
        !libraries.isEmpty
    }

    var selectedLibrary: MangaLibrary? {
        guard let selectedLibraryID else { return nil }
        return libraries.first { $0.id == selectedLibraryID }
    }

    var selectedLibraryURL: URL? {
        guard let selectedLibrary else { return nil }
        return resolvedSecurityURL(for: selectedLibrary) ?? URL(fileURLWithPath: selectedLibrary.path)
    }

    func state(for manga: MangaTitle) -> MangaReadingState? {
        MangaReadingStateStore.shared.state(for: manga.rootURL.path)
    }

    func clearReadingData(for manga: MangaTitle) {
        MangaReadingStateStore.shared.removeState(for: manga.rootURL.path)
        softReload()
    }

    func canDeleteMangaFolder(_ manga: MangaTitle) -> Bool {
        guard let selectedLibrary else { return false }
        let libraryPath = URL(fileURLWithPath: selectedLibrary.path).standardizedFileURL.path
        let mangaPath = manga.rootURL.standardizedFileURL.path
        return mangaPath != libraryPath
    }

    func deleteMangaFolder(_ manga: MangaTitle) {
        guard canDeleteMangaFolder(manga) else {
            errorMessage = "Нельзя удалить корневую папку библиотеки из карточки манги."
            return
        }

        do {
            try FileManager.default.removeItem(at: manga.rootURL)
            reload()
        } catch {
            errorMessage = "Не удалось удалить папку манги: \(error.localizedDescription)"
        }
    }

    func addLibrary(from folderURL: URL) {
        let standardizedPath = folderURL.standardizedFileURL.path
        let hasScopedAccess = folderURL.startAccessingSecurityScopedResource()

        let bookmark = try? folderURL.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        if hasScopedAccess {
            stopScopedAccess()
            scopedURL = folderURL
        }

        if bookmark == nil {
            errorMessage = "Не удалось сохранить постоянный доступ к этой папке. Выберите папку снова."
        }

        if let existingIndex = libraries.firstIndex(where: { $0.path == standardizedPath }) {
            libraries[existingIndex].name = folderURL.lastPathComponent
            libraries[existingIndex].bookmarkData = bookmark
            selectedLibraryID = libraries[existingIndex].id
        } else {
            let library = MangaLibrary(
                id: UUID(),
                name: folderURL.lastPathComponent,
                path: standardizedPath,
                bookmarkData: bookmark
            )
            libraries.append(library)
            selectedLibraryID = library.id
        }

        persistLibraries()
        persistSelectedLibraryID()
        reload()
    }

    func removeLibrary(_ library: MangaLibrary) {
        libraries.removeAll { $0.id == library.id }

        if selectedLibraryID == library.id {
            selectedLibraryID = libraries.first?.id
            stopScopedAccess()
        }

        persistLibraries()
        persistSelectedLibraryID()
        reload()
    }

    func selectLibrary(_ libraryID: UUID) {
        guard libraries.contains(where: { $0.id == libraryID }) else { return }
        selectedLibraryID = libraryID
        persistSelectedLibraryID()
        reload()
    }

    func updateDefaultReadingModeOption(rawValue: String) {
        let option = DefaultReadingModeOption.fromStoredRawValue(rawValue)
        defaultReadingModeRawValue = option.rawValue
        UserDefaults.standard.set(option.rawValue, forKey: defaultReadingModeKey)
    }

    func updateSortOption(rawValue: String) {
        let option = MangaSortOption(rawValue: rawValue) ?? .recentlyReadDesc
        sortOptionRawValue = option.rawValue
        UserDefaults.standard.set(option.rawValue, forKey: sortOptionKey)
        if option.needsSizeCalculation {
            hardReload()
        } else {
            softReload()
        }
    }

    func hardReload() {
        guard let selectedLibrary else {
            scanTask?.cancel()
            stopScopedAccess()
            mangas = []
            isLoading = false
            MangaReadingStateStore.shared.setSyncFolderURL(nil)
            return
        }

        let pathURL = URL(fileURLWithPath: selectedLibrary.path)
        let bookmarkURL = resolvedSecurityURL(for: selectedLibrary) ?? pathURL
        let canAccess = beginScopedAccess(for: bookmarkURL)

        guard canAccess else {
            scanTask?.cancel()
            mangas = []
            isLoading = false
            MangaReadingStateStore.shared.setSyncFolderURL(nil)
            errorMessage = "iOS не восстановил доступ к библиотеке \"\(selectedLibrary.name)\". Выберите папку заново."
            return
        }

        loadLibrary(primaryURL: bookmarkURL, visibleFolderURL: pathURL)
    }

    func softReload() {
        guard let selectedLibrary else {
            mangas = []
            return
        }

        let pathURL = URL(fileURLWithPath: selectedLibrary.path)
        MangaReadingStateStore.shared.setSyncFolderURL(pathURL)
        withAnimation(.easeInOut(duration: 0.28)) {
            mangas = sortedMangas(mangas)
        }
    }

    // Backward-compatible alias for existing call sites.
    func reload() {
        hardReload()
    }

    private func loadDefaultReadingMode() {
        if let raw = UserDefaults.standard.string(forKey: defaultReadingModeKey) {
            defaultReadingModeRawValue = DefaultReadingModeOption.fromStoredRawValue(raw).rawValue
        } else {
            defaultReadingModeRawValue = DefaultReadingModeOption.automatic.rawValue
            UserDefaults.standard.set(defaultReadingModeRawValue, forKey: defaultReadingModeKey)
        }
    }

    private func loadSortOption() {
        let raw = UserDefaults.standard.string(forKey: sortOptionKey) ?? MangaSortOption.recentlyReadDesc.rawValue
        sortOptionRawValue = (MangaSortOption(rawValue: raw) ?? .recentlyReadDesc).rawValue
    }

    private func loadLibraries() {
        guard let data = UserDefaults.standard.data(forKey: librariesKey),
              let decoded = try? JSONDecoder().decode([MangaLibrary].self, from: data) else {
            libraries = []
            return
        }

        libraries = decoded
    }

    private func persistLibraries() {
        guard let data = try? JSONEncoder().encode(libraries) else { return }
        UserDefaults.standard.set(data, forKey: librariesKey)
    }

    private func restoreSelectedLibrary() {
        if let raw = UserDefaults.standard.string(forKey: selectedLibraryIDKey),
           let id = UUID(uuidString: raw),
           libraries.contains(where: { $0.id == id }) {
            selectedLibraryID = id
            return
        }

        selectedLibraryID = libraries.first?.id
        persistSelectedLibraryID()
    }

    private func persistSelectedLibraryID() {
        if let selectedLibraryID {
            UserDefaults.standard.set(selectedLibraryID.uuidString, forKey: selectedLibraryIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedLibraryIDKey)
        }
    }

    private func migrateLegacyLibraryIfNeeded() {
        guard libraries.isEmpty else { return }

        let legacyPath = UserDefaults.standard.string(forKey: legacyExternalPathKey)
            ?? UserDefaults.standard.string(forKey: legacyRootFolderPathKey)

        guard let legacyPath, !legacyPath.isEmpty else { return }

        let legacyBookmark = UserDefaults.standard.data(forKey: legacyExternalBookmarkKey)
            ?? UserDefaults.standard.data(forKey: legacyBookmarkKey)

        let folderURL = URL(fileURLWithPath: legacyPath)
        let migrated = MangaLibrary(
            id: UUID(),
            name: folderURL.lastPathComponent,
            path: folderURL.standardizedFileURL.path,
            bookmarkData: legacyBookmark
        )

        libraries = [migrated]
        selectedLibraryID = migrated.id
        persistLibraries()
        persistSelectedLibraryID()
    }

    private func resolvedSecurityURL(for library: MangaLibrary) -> URL? {
        guard let bookmark = library.bookmarkData, !bookmark.isEmpty else {
            return nil
        }

        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: bookmarkResolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }

        if stale {
            refreshBookmarkIfPossible(for: library.id, resolvedURL: url)
        }

        return url
    }

    private func refreshBookmarkIfPossible(for libraryID: UUID, resolvedURL: URL) {
        guard let refreshed = try? resolvedURL.bookmarkData(
            options: bookmarkCreationOptions,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            return
        }

        guard let index = libraries.firstIndex(where: { $0.id == libraryID }) else {
            return
        }

        libraries[index].bookmarkData = refreshed
        libraries[index].path = resolvedURL.standardizedFileURL.path
        libraries[index].name = resolvedURL.lastPathComponent
        persistLibraries()
    }

    private func loadLibrary(primaryURL: URL, visibleFolderURL: URL) {
        scanTask?.cancel()
        activeLoadToken = UUID()
        let loadToken = activeLoadToken

        errorMessage = nil
        isLoading = true
        MangaReadingStateStore.shared.setSyncFolderURL(visibleFolderURL)

        scanTask = Task.detached(priority: .userInitiated) {
            waitUntilFolderIsReadyForScan(primaryURL)
            let scanned = MangaScanner.scanLibrary(at: primaryURL)
            let sortOption = MangaSortOption(rawValue: await MainActor.run { self.sortOptionRawValue }) ?? .recentlyReadDesc
            let sizeMap: [String: Int64]
            if sortOption.needsSizeCalculation {
                var map: [String: Int64] = [:]
                for manga in scanned {
                    map[manga.id] = Self.calculateFolderSize(at: manga.rootURL)
                }
                sizeMap = map
            } else {
                sizeMap = [:]
            }

            if Task.isCancelled {
                return
            }

            await MainActor.run {
                guard loadToken == self.activeLoadToken else { return }
                self.cachedSizeByMangaID = sizeMap
                self.mangas = self.sortedMangas(scanned, sizeMap: sizeMap)
                if scanned.isEmpty {
                    let libraryName = self.selectedLibrary?.name ?? "выбранной библиотеке"
                    self.errorMessage = "В библиотеке \"\(libraryName)\" ничего не найдено."
                }
                self.isLoading = false
            }
        }
    }

    private func beginScopedAccess(for url: URL) -> Bool {
        if let scopedURL,
           scopedURL.standardizedFileURL.path == url.standardizedFileURL.path {
            return true
        }

        stopScopedAccess()
        guard url.startAccessingSecurityScopedResource() else {
            return false
        }

        scopedURL = url
        return true
    }

    private func stopScopedAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    private func sortedMangas(_ source: [MangaTitle], sizeMap: [String: Int64]? = nil) -> [MangaTitle] {
        let resolvedSizeMap = sizeMap ?? cachedSizeByMangaID
        let option = MangaSortOption(rawValue: sortOptionRawValue) ?? .recentlyReadDesc
        return source.sorted { lhs, rhs in
            switch option {
            case .nameAsc:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .nameDesc:
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedDescending
            case .recentlyReadDesc, .recentlyReadAsc:
                let lhsDate = MangaReadingStateStore.shared.state(for: lhs.rootURL.path)?.lastReadAt
                let rhsDate = MangaReadingStateStore.shared.state(for: rhs.rootURL.path)?.lastReadAt
                if lhsDate != rhsDate {
                    switch (lhsDate, rhsDate) {
                    case let (l?, r?):
                        return option == .recentlyReadDesc ? l > r : l < r
                    case (_?, nil):
                        return option == .recentlyReadDesc
                    case (nil, _?):
                        return option == .recentlyReadAsc
                    case (nil, nil):
                        break
                    }
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .progressDesc, .progressAsc:
                let lhsProgress = readingProgress(for: lhs)
                let rhsProgress = readingProgress(for: rhs)
                if lhsProgress != rhsProgress {
                    return option == .progressDesc ? lhsProgress > rhsProgress : lhsProgress < rhsProgress
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .sizeDesc, .sizeAsc:
                let lhsSize = resolvedSizeMap[lhs.id] ?? 0
                let rhsSize = resolvedSizeMap[rhs.id] ?? 0
                if lhsSize != rhsSize {
                    return option == .sizeDesc ? lhsSize > rhsSize : lhsSize < rhsSize
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func readingProgress(for manga: MangaTitle) -> Double {
        guard let state = MangaReadingStateStore.shared.state(for: manga.rootURL.path),
              let chapterIndex = manga.chapterIndex(forStorageID: state.chapterID),
              manga.chapters.indices.contains(chapterIndex) else {
            return 0
        }

        let currentChapter = manga.chapters[chapterIndex]
        let pageCount = max(currentChapter.pageURLs.count, 1)
        let pageInChapter = min(max(state.logicalPageIndex, 0), pageCount - 1) + 1

        let totalPages = max(manga.chapters.reduce(0) { $0 + max($1.pageURLs.count, 1) }, 1)
        let pagesBeforeChapter = manga.chapters.prefix(chapterIndex).reduce(0) { $0 + max($1.pageURLs.count, 1) }
        let absolutePage = pagesBeforeChapter + pageInChapter

        return Double(absolutePage) / Double(totalPages)
    }

    nonisolated private static func calculateFolderSize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
}
