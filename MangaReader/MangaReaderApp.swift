//
//  MangaReaderApp.swift
//  MangaReader
//
//  Created by LiWinDom on 08.03.2026.
//

import SwiftUI

@main
struct MangaReaderApp: App {
    init() {
        Self.prepareAppFilesContainer()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    private static func prepareAppFilesContainer() {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        let markerURL = documents.appendingPathComponent("MangaReader_Files_Access.txt")
        if !fm.fileExists(atPath: markerURL.path) {
            let text = "MangaReader Files storage.\nPut manga into MangaLibrary folder.\n"
            try? text.write(to: markerURL, atomically: true, encoding: .utf8)
        }

        let libraryURL = documents.appendingPathComponent("MangaLibrary", isDirectory: true)
        try? fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)

        let readmeURL = libraryURL.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readmeURL.path) {
            let text = "Drop manga folders here.\nSupported: chapter/image and volume/chapter/image structures.\n"
            try? text.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
    }
}
