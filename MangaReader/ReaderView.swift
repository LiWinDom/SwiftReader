import SwiftUI
import UIKit
import ImageIO

private struct VerticalPageFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss

    let manga: MangaTitle
    let chapters: [MangaChapter]
    let selectedChapter: MangaChapter
    let preferSavedPosition: Bool

    @State private var currentChapterIndex = 0
    @State private var selectedMode: ReadingMode = .vertical
    @State private var selectedPage = 0
    @State private var isPagedFitToScreen = true
    @State private var isAutoReadingMode = true
    @State private var isChromeHidden = false
    @State private var hasRestoredState = false
    @State private var verticalRestoreTarget: Int?
    @State private var verticalRestoreOffsetInPage: CGFloat?
    @State private var isRestoringState = false
    @State private var pendingChapterLogicalPage: Int?
    @State private var skipAutoModeForNextChapterChange = false
    @State private var isVerticalAtTopBoundary = true
    @State private var isVerticalAtBottomBoundary = false
    @State private var verticalPageFrames: [Int: CGRect] = [:]

    private var currentChapter: MangaChapter {
        chapters[currentChapterIndex]
    }

    private var pagesInCurrentDirection: [URL] {
        switch selectedMode {
        case .vertical, .leftToRight:
            return currentChapter.pageURLs
        case .rightToLeft:
            return currentChapter.pageURLs.reversed()
        }
    }

    private var mangaStorageID: String {
        manga.rootURL.path
    }

    private func chapterStorageID(for chapter: MangaChapter) -> String {
        manga.chapterStorageID(for: chapter)
    }

    private func chapterIndex(for storageID: String) -> Int? {
        manga.chapterIndex(forStorageID: storageID)
    }

    private func clampedDisplayIndex(_ index: Int, in chapter: MangaChapter) -> Int {
        let count = chapter.pageURLs.count
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private func logicalPageIndex(from displayIndex: Int, mode: ReadingMode, chapter: MangaChapter) -> Int {
        let clamped = clampedDisplayIndex(displayIndex, in: chapter)
        switch mode {
        case .vertical, .leftToRight:
            return clamped
        case .rightToLeft:
            return max(chapter.pageURLs.count - 1 - clamped, 0)
        }
    }

    private func displayPageIndex(from logicalPageIndex: Int, mode: ReadingMode, chapter: MangaChapter) -> Int {
        let logical = clampedDisplayIndex(logicalPageIndex, in: chapter)
        switch mode {
        case .vertical, .leftToRight:
            return logical
        case .rightToLeft:
            return max(chapter.pageURLs.count - 1 - logical, 0)
        }
    }

    private func persistCurrentReadingState() {
        guard chapters.indices.contains(currentChapterIndex) else {
            return
        }

        let chapter = chapters[currentChapterIndex]
        let state = MangaReadingState(
            chapterID: chapterStorageID(for: chapter),
            logicalPageIndex: logicalPageIndex(from: selectedPage, mode: selectedMode, chapter: chapter),
            readingModeRawValue: selectedMode.rawValue,
            pagedFitToScreen: isPagedFitToScreen,
            autoReadingMode: isAutoReadingMode,
            lastReadAt: Date(),
            verticalOffsetInPage: nil
        )
        MangaReadingStateStore.shared.save(state: state, for: mangaStorageID)
    }

    private func restoreVerticalPosition(with proxy: ScrollViewProxy, pageIndex: Int, offsetInPage: CGFloat?) {
        let clampedOffset = min(max(offsetInPage ?? 0, 0), 0.999)
        let anchor = UnitPoint(x: 0.5, y: clampedOffset)
        DispatchQueue.main.async {
            proxy.scrollTo(pageIndex, anchor: anchor)
            verticalRestoreTarget = nil
            verticalRestoreOffsetInPage = nil
        }
    }

    private func switchChapterByEdgeSwipe(forward: Bool) {
        let newChapterIndex = forward ? currentChapterIndex + 1 : currentChapterIndex - 1
        guard chapters.indices.contains(newChapterIndex) else {
            return
        }

        let newChapter = chapters[newChapterIndex]
        let targetLogicalPage: Int = forward ? 0 : max(newChapter.pageURLs.count - 1, 0)

        pendingChapterLogicalPage = targetLogicalPage
        skipAutoModeForNextChapterChange = true
        currentChapterIndex = newChapterIndex
    }

    private func autoDetectedMode(for chapter: MangaChapter) async -> ReadingMode {
        await Task.detached(priority: .utility) {
            let sampleURLs = Array(chapter.pageURLs.prefix(12))
            var analyzedCount = 0
            var longStripCount = 0
            var aspectRatios: [CGFloat] = []

            for url in sampleURLs {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                      let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
                      height > 0,
                      width > 0 else {
                    continue
                }

                analyzedCount += 1
                let ratio = height / width
                aspectRatios.append(ratio)

                if ratio >= 1.9 {
                    longStripCount += 1
                }
            }

            guard analyzedCount > 0 else {
                return .rightToLeft
            }

            let longStripShare = CGFloat(longStripCount) / CGFloat(analyzedCount)
            let averageRatio = aspectRatios.reduce(0, +) / CGFloat(aspectRatios.count)
            if longStripShare >= 0.30 || averageRatio >= 1.75 {
                return .vertical
            }
            return .rightToLeft
        }.value
    }

    private func applyAutoModeIfNeeded() {
        guard isAutoReadingMode, chapters.indices.contains(currentChapterIndex) else {
            return
        }
        let chapter = chapters[currentChapterIndex]

        Task {
            let detectedMode = await autoDetectedMode(for: chapter)
            guard isAutoReadingMode, chapters.indices.contains(currentChapterIndex) else {
                return
            }

            isRestoringState = true
            selectedMode = detectedMode
            selectedPage = initialPageIndexForCurrentMode()
            if selectedMode == .vertical {
                verticalRestoreTarget = selectedPage
                verticalRestoreOffsetInPage = 0
            } else {
                verticalRestoreOffsetInPage = nil
            }
            isRestoringState = false
            persistCurrentReadingState()
        }
    }

    private func restoreReadingStateIfNeeded() {
        guard !hasRestoredState else {
            return
        }

        hasRestoredState = true
        isRestoringState = true

        let defaultOption: DefaultReadingModeOption = {
            let raw = UserDefaults.standard.string(forKey: defaultReadingModeKey) ?? DefaultReadingModeOption.automatic.rawValue
            return DefaultReadingModeOption.fromStoredRawValue(raw)
        }()

        var resolvedMode: ReadingMode = defaultOption.readingMode ?? .rightToLeft
        var resolvedChapterIndex = chapters.firstIndex(of: selectedChapter) ?? 0
        var resolvedPageIndex = 0
        isAutoReadingMode = (defaultOption == .automatic)

        if preferSavedPosition,
           let saved = MangaReadingStateStore.shared.state(for: mangaStorageID) {
            if let savedMode = ReadingMode(rawValue: saved.readingModeRawValue) {
                resolvedMode = savedMode
            }
            isPagedFitToScreen = saved.pagedFitToScreen ?? true
            isAutoReadingMode = saved.autoReadingMode ?? true

            if let savedChapterIndex = chapterIndex(for: saved.chapterID),
               chapters.indices.contains(savedChapterIndex) {
                resolvedChapterIndex = savedChapterIndex
                let savedChapter = chapters[savedChapterIndex]
                resolvedPageIndex = displayPageIndex(from: saved.logicalPageIndex, mode: resolvedMode, chapter: savedChapter)
            }
        }

        selectedMode = resolvedMode
        currentChapterIndex = resolvedChapterIndex
        selectedPage = resolvedPageIndex

        if selectedMode == .vertical {
            verticalRestoreTarget = selectedPage
        } else {
            verticalRestoreOffsetInPage = nil
        }
        isRestoringState = false

        if isAutoReadingMode {
            applyAutoModeIfNeeded()
        }
    }

    private func initialPageIndexForCurrentMode() -> Int {
        guard !pagesInCurrentDirection.isEmpty else {
            return 0
        }
        switch selectedMode {
        case .vertical, .leftToRight:
            return 0
        case .rightToLeft:
            return pagesInCurrentDirection.count - 1
        }
    }

    private var currentPageDisplayNumber: Int {
        logicalPageIndex(from: selectedPage, mode: selectedMode, chapter: currentChapter) + 1
    }

    private func trimReaderImageCacheWindow() {
        guard !pagesInCurrentDirection.isEmpty else {
            MangaImageView.clearCache()
            return
        }

        let lowerBound = max(selectedPage - 2, 0)
        let upperBound = min(selectedPage + 2, pagesInCurrentDirection.count - 1)
        let keepPaths = Set(pagesInCurrentDirection[lowerBound...upperBound].map(\.path))
        MangaImageView.trimCache(keepingPaths: keepPaths)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            Group {
                if currentChapter.pageURLs.isEmpty {
                    ContentUnavailableView("Нет страниц", systemImage: "exclamationmark.triangle")
                } else {
                    readerBody
                        .ignoresSafeArea(edges: .top)
                }
            }
        }
        .navigationTitle(currentChapter.title)
        .navigationBarTitleDisplayMode(.inline)
        .statusBar(hidden: isChromeHidden)
        .toolbar(isChromeHidden ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if !isChromeHidden {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Автовыбор режима", isOn: $isAutoReadingMode)

                        Picker("Режим чтения", selection: $selectedMode) {
                            ForEach(ReadingMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .disabled(isAutoReadingMode)

                        if selectedMode != .vertical {
                            Toggle("Вписывать страницу целиком", isOn: $isPagedFitToScreen)
                        }
                    } label: {
                        Label("Режим чтения", systemImage: "text.book.closed")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !isChromeHidden {
                chapterControls
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            restoreReadingStateIfNeeded()
            trimReaderImageCacheWindow()
        }
        .onChange(of: currentChapterIndex) {
            guard !isRestoringState else { return }
            verticalPageFrames = [:]
            isVerticalAtTopBoundary = true
            isVerticalAtBottomBoundary = false

            if let targetLogicalPage = pendingChapterLogicalPage {
                pendingChapterLogicalPage = nil
                let chapter = chapters[currentChapterIndex]
                selectedPage = displayPageIndex(from: targetLogicalPage, mode: selectedMode, chapter: chapter)
                if selectedMode == .vertical {
                    verticalRestoreTarget = selectedPage
                    verticalRestoreOffsetInPage = 0
                }
                skipAutoModeForNextChapterChange = false
                trimReaderImageCacheWindow()
                return
            }

            if isAutoReadingMode, !skipAutoModeForNextChapterChange {
                applyAutoModeIfNeeded()
                return
            }

            skipAutoModeForNextChapterChange = false
            selectedPage = initialPageIndexForCurrentMode()
            if selectedMode == .vertical {
                verticalRestoreTarget = selectedPage
                verticalRestoreOffsetInPage = 0
            }
            trimReaderImageCacheWindow()
            persistCurrentReadingState()
        }
        .onChange(of: selectedMode) {
            guard !isRestoringState else { return }
            verticalPageFrames = [:]
            isVerticalAtTopBoundary = true
            isVerticalAtBottomBoundary = false
            selectedPage = initialPageIndexForCurrentMode()
            if selectedMode == .vertical {
                verticalRestoreTarget = selectedPage
                verticalRestoreOffsetInPage = 0
            } else {
                verticalRestoreOffsetInPage = nil
            }
            trimReaderImageCacheWindow()
            persistCurrentReadingState()
        }
        .onChange(of: selectedPage) {
            guard !isRestoringState else { return }
            trimReaderImageCacheWindow()
            persistCurrentReadingState()
        }
        .onChange(of: isPagedFitToScreen) {
            guard !isRestoringState else { return }
            persistCurrentReadingState()
        }
        .onChange(of: isAutoReadingMode) {
            guard !isRestoringState else { return }
            if isAutoReadingMode {
                applyAutoModeIfNeeded()
            } else {
                persistCurrentReadingState()
            }
        }
        .onDisappear {
            persistCurrentReadingState()
            NotificationCenter.default.post(name: readerDidCloseNotification, object: nil)
        }
    }

    private var readerBody: some View {
        Group {
            switch selectedMode {
            case .vertical:
                ScrollViewReader { proxy in
                    GeometryReader { scrollGeo in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(pagesInCurrentDirection.enumerated()), id: \.offset) { index, pageURL in
                                    MangaImageView(url: pageURL)
                                        .id(index)
                                        .background(
                                            GeometryReader { pageGeo in
                                                Color.clear.preference(
                                                    key: VerticalPageFramePreferenceKey.self,
                                                    value: [index: pageGeo.frame(in: .named("readerVerticalScroll"))]
                                                )
                                            }
                                        )
                                }
                            }
                        }
                        .coordinateSpace(name: "readerVerticalScroll")
                        .scrollBounceBehavior(.basedOnSize)
                        .onPreferenceChange(VerticalPageFramePreferenceKey.self) { frames in
                            verticalPageFrames = frames
                            let viewportHeight = scrollGeo.size.height
                            let visible = frames.filter { _, rect in
                                rect.maxY > 0 && rect.minY < viewportHeight
                            }

                            guard !visible.isEmpty else { return }

                            let candidate = visible.min { lhs, rhs in
                                abs(lhs.value.minY) < abs(rhs.value.minY)
                            }

                            if let candidate, selectedPage != candidate.key {
                                selectedPage = candidate.key
                            }

                            let edgeTolerance: CGFloat = 2
                            let firstRect = frames[0]
                            let lastRect = frames[max(pagesInCurrentDirection.count - 1, 0)]
                            if let firstRect {
                                isVerticalAtTopBoundary = firstRect.minY >= -edgeTolerance
                            } else {
                                isVerticalAtTopBoundary = false
                            }

                            if let lastRect {
                                isVerticalAtBottomBoundary = lastRect.maxY <= (viewportHeight + edgeTolerance)
                            } else {
                                isVerticalAtBottomBoundary = false
                            }
                        }
                        .onAppear {
                            if let target = verticalRestoreTarget {
                                restoreVerticalPosition(with: proxy, pageIndex: target, offsetInPage: verticalRestoreOffsetInPage)
                            }
                        }
                        .onChange(of: verticalRestoreTarget) { target in
                            guard let target else { return }
                            restoreVerticalPosition(with: proxy, pageIndex: target, offsetInPage: verticalRestoreOffsetInPage)
                        }
                    }
                }

            case .leftToRight, .rightToLeft:
                TabView(selection: $selectedPage) {
                    ForEach(Array(pagesInCurrentDirection.enumerated()), id: \.offset) { index, pageURL in
                        GeometryReader { geo in
                            if isPagedFitToScreen {
                                MangaImageView(url: pageURL)
                                    .frame(width: geo.size.width, height: geo.size.height)
                            } else {
                                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                                    MangaImageView(url: pageURL)
                                        .frame(width: geo.size.width)
                                }
                            }
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            let verticalDistance = value.translation.height
                            let horizontalDistance = abs(value.translation.width)
                            guard abs(verticalDistance) > max(110, horizontalDistance * 1.2) else {
                                return
                            }
                            dismiss()
                        }
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isChromeHidden.toggle()
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard selectedMode == .vertical else {
                        return
                    }
                    let horizontalDistance = value.translation.width
                    let verticalDistance = abs(value.translation.height)
                    guard horizontalDistance > max(110, verticalDistance * 1.2) else {
                        return
                    }
                    dismiss()
                }
        )
        .overlay(alignment: .topTrailing) {
            if selectedMode != .vertical && !isChromeHidden {
                Text("\(currentPageDisplayNumber) / \(pagesInCurrentDirection.count)")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
        }
    }

    private var chapterControls: some View {
        HStack {
            Button {
                skipAutoModeForNextChapterChange = false
                pendingChapterLogicalPage = nil
                currentChapterIndex = max(currentChapterIndex - 1, 0)
            } label: {
                Label("Назад", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(currentChapterIndex == 0)

            Spacer()

            Text("\(currentChapterIndex + 1) / \(chapters.count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                skipAutoModeForNextChapterChange = false
                pendingChapterLogicalPage = nil
                currentChapterIndex = min(currentChapterIndex + 1, chapters.count - 1)
            } label: {
                Label("Далее", systemImage: "chevron.right")
            }
            .buttonStyle(.bordered)
            .disabled(currentChapterIndex >= chapters.count - 1)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct MangaImageView: View {
    static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 180 * 1024 * 1024
        return cache
    }()
    private static var cachedKeys: Set<String> = []
    private static let cacheLock = NSLock()

    let url: URL
    var onVisible: (() -> Void)? = nil
    var maxPixelSize: CGFloat? = nil

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var isDownloadingFromCloud = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else if isLoading {
                VStack(spacing: 8) {
                    ProgressView()
                    if isDownloadingFromCloud {
                        Text("Загрузка из iCloud...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                Color.gray.opacity(0.08)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "photo")
                            Text("Не удалось открыть изображение")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
        .task(id: url.path) {
            await loadImage()
        }
        .onAppear {
            onVisible?()
        }
    }

    private func loadImage() async {
        let cacheKeyString = url.path
        let cacheKey = cacheKeyString as NSString
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            image = cached
            return
        }

        isLoading = true
        isDownloadingFromCloud = false
        defer { isLoading = false }

        // For reader pages, nil means original quality decode.
        let targetMaxPixelSize = maxPixelSize
        let result = await Task.detached(priority: .utility) {
            Self.loadImageForDisplay(from: url, maxPixelSize: targetMaxPixelSize)
        }.value

        if let loaded = result.image {
            Self.imageCache.setObject(loaded, forKey: cacheKey, cost: Self.cacheCost(for: loaded))
            Self.cacheLock.lock()
            Self.cachedKeys.insert(cacheKeyString)
            Self.cacheLock.unlock()
        }

        isDownloadingFromCloud = result.usedCloudDownload
        image = result.image
    }

    static func loadImageForDisplay(from fileURL: URL, maxPixelSize: CGFloat?, waitForCloudDownload: Bool = true) -> (image: UIImage?, usedCloudDownload: Bool) {
        let usedCloudDownload = ensureFileAvailableLocally(fileURL, waitForDownload: waitForCloudDownload)
        guard let image = decodedImage(at: fileURL, maxPixelSize: maxPixelSize) else {
            return (nil, usedCloudDownload)
        }
        return (image, usedCloudDownload)
    }

    static func trimCache(keepingPaths: Set<String>) {
        cacheLock.lock()
        let keysToRemove = cachedKeys.filter { !keepingPaths.contains($0) }
        for key in keysToRemove {
            imageCache.removeObject(forKey: key as NSString)
            cachedKeys.remove(key)
        }
        cacheLock.unlock()
    }

    static func clearCache() {
        imageCache.removeAllObjects()
        cacheLock.lock()
        cachedKeys.removeAll()
        cacheLock.unlock()
    }

    private static func cacheCost(for image: UIImage) -> Int {
        let pixelsWide = image.size.width * image.scale
        let pixelsHigh = image.size.height * image.scale
        return Int(max(pixelsWide * pixelsHigh * 4, 1))
    }

    private static func ensureFileAvailableLocally(_ fileURL: URL, waitForDownload: Bool) -> Bool {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]

        guard let values = try? fileURL.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
            return false
        }

        let isDownloaded = values.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current
        guard !isDownloaded else {
            return false
        }

        try? FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
        guard waitForDownload else { return true }

        for _ in 0..<60 {
            if let updated = try? fileURL.resourceValues(forKeys: keys),
               updated.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        return true
    }

    private static func decodedImage(at fileURL: URL, maxPixelSize: CGFloat?) -> UIImage? {
        let options: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else {
            return nil
        }

        if let maxPixelSize {
            let downsampleOptions: CFDictionary = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ] as CFDictionary

            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }

        let fullOptions: CFDictionary = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, fullOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
