import Foundation

enum MangaScanner {
    // Supports both "library root with many titles" and "selected folder is one title" flows.
    static func scanLibrary(at rootURL: URL) -> [MangaTitle] {
        let mangaFolders = subdirectories(in: rootURL)

        let scanned: [MangaTitle] = mangaFolders.compactMap { folder -> MangaTitle? in
            let chapters = collectChapters(in: folder)
            if chapters.isEmpty { return nil }
            return MangaTitle(name: folder.lastPathComponent, rootURL: folder, chapters: chapters)
        }

        if !scanned.isEmpty {
            return scanned
        }

        let rootChapters = collectChapters(in: rootURL)
        if !rootChapters.isEmpty {
            return [MangaTitle(name: rootURL.lastPathComponent, rootURL: rootURL, chapters: rootChapters)]
        }

        return []
    }

    private static func collectChapters(in mangaFolder: URL) -> [MangaChapter] {
        let directImages = imageFiles(in: mangaFolder)
        var chapters: [MangaChapter] = []

        if !directImages.isEmpty {
            chapters.append(
                MangaChapter(
                    title: "Глава 1",
                    groupPath: [],
                    folderURL: mangaFolder,
                    pageURLs: directImages
                )
            )
        }

        chapters.append(contentsOf: collectNestedChapters(in: mangaFolder, currentPath: []))
        return chapters.sorted { lhs, rhs in
            let lg = lhs.groupPath.joined(separator: "/")
            let rg = rhs.groupPath.joined(separator: "/")
            if lg == rg {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lg.localizedStandardCompare(rg) == .orderedAscending
        }
    }

    private static func collectNestedChapters(in folder: URL, currentPath: [String]) -> [MangaChapter] {
        let subdirs = subdirectories(in: folder)
        if subdirs.isEmpty {
            return []
        }

        var collected: [MangaChapter] = []

        for subdir in subdirs {
            let name = subdir.lastPathComponent
            let images = imageFiles(in: subdir)
            let nextPath = currentPath + [name]

            if !images.isEmpty {
                let group = Array(currentPath)
                collected.append(
                    MangaChapter(
                        title: name,
                        groupPath: group,
                        folderURL: subdir,
                        pageURLs: images
                    )
                )
            }

            let nested = collectNestedChapters(in: subdir, currentPath: nextPath)
            collected.append(contentsOf: nested)
        }

        return collected
    }

    static func subdirectories(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])) ?? []

        return urls
            .filter { url in
                if url.lastPathComponent.hasPrefix(".") {
                    return false
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isHidden != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func imageFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsSubdirectoryDescendants])) ?? []

        return urls
            .filter { url in
                if url.lastPathComponent.hasPrefix(".") {
                    return false
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory != true else {
                    return false
                }
                let ext = url.pathExtension.lowercased()
                return supportedImageExtensions.contains(ext)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
