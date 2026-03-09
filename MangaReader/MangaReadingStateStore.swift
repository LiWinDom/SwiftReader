import Foundation

final class MangaReadingStateStore {
    static let shared = MangaReadingStateStore()
    static let syncFileName = "MangaReaderProgress.json"

    private let defaultsKey = "mangaReadingStateByTitle"
    private var cachedStates: [String: MangaReadingState] = [:]
    private var syncFileURL: URL?

    private init() {
        load()
    }

    func state(for mangaID: String) -> MangaReadingState? {
        cachedStates[mangaID]
    }

    // Sync progress inside library folder so iCloud/shared folders can carry progress between devices.
    func setSyncFolderURL(_ folderURL: URL?) {
        guard let folderURL else {
            syncFileURL = nil
            loadFromDefaultsOnly()
            return
        }

        let normalized = folderURL.standardizedFileURL
        syncFileURL = normalized.appendingPathComponent(Self.syncFileName)
        loadFromDefaultsOnly()
        mergeFromSyncFile()
    }

    func save(state: MangaReadingState, for mangaID: String) {
        cachedStates[mangaID] = state
        persist()
    }

    func removeState(for mangaID: String) {
        cachedStates.removeValue(forKey: mangaID)
        persist()
    }

    func removeAllStates() {
        cachedStates = [:]
        persist()
    }

    private func load() {
        loadFromDefaultsOnly()
        mergeFromSyncFile()
    }

    private func loadFromDefaultsOnly() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            cachedStates = [:]
            return
        }

        do {
            cachedStates = try JSONDecoder().decode([String: MangaReadingState].self, from: data)
        } catch {
            cachedStates = [:]
        }
    }

    private func mergeFromSyncFile() {
        guard let syncFileURL,
              let data = try? Data(contentsOf: syncFileURL),
              let decoded = try? JSONDecoder().decode([String: MangaReadingState].self, from: data) else {
            return
        }

        for (key, value) in decoded {
            cachedStates[key] = value
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cachedStates) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
        if let syncFileURL {
            try? data.write(to: syncFileURL, options: [.atomic])
        }
    }
}
