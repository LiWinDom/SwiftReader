import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Root Library Screens
struct ContentView: View {
    @StateObject private var vm = MangaLibraryViewModel()
    @State private var isImporterShown = false
    @State private var isSettingsShown = false
    @State private var mangaToDeleteFolder: MangaTitle?
    @State private var pendingScrollToTopAfterReload = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Сканирую библиотеку...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.mangas.isEmpty {
                    emptyState
                } else {
                    mangaList
                }
            }
            .navigationTitle(vm.sourceTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    sourceMenu
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            pendingScrollToTopAfterReload = true
                            vm.hardReload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Полное пересканирование")

                        Button {
                            isSettingsShown = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Настройки")
                    }
                }
            }
        }
        .onAppear {
            vm.hardReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: readerDidCloseNotification)) { _ in
            vm.softReload()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            MangaImageView.clearCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            MangaImageView.clearCache()
        }
        .fileImporter(
            isPresented: $isImporterShown,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                vm.addLibrary(from: url)
            case .failure(let error):
                vm.errorMessage = "Ошибка выбора папки: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $isSettingsShown) {
            SettingsView(vm: vm, isImporterShown: $isImporterShown)
        }
        .alert("Ошибка", isPresented: .constant(vm.errorMessage != nil), actions: {
            Button("OK") {
                vm.errorMessage = nil
            }
        }, message: {
            Text(vm.errorMessage ?? "Неизвестная ошибка")
        })
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Манга не найдена")
                .font(.headline)
            Text("Добавьте хотя бы одну внешнюю библиотеку с мангой через выбор папки.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Button("Добавить библиотеку") {
                isImporterShown = true
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sourceMenu: some View {
        Menu {
            if vm.libraries.isEmpty {
                Text("Нет библиотек")
            } else {
                ForEach(vm.libraries) { library in
                    Button {
                        vm.selectLibrary(library.id)
                    } label: {
                        if vm.selectedLibraryID == library.id {
                            Label(library.name, systemImage: "checkmark")
                        } else {
                            Text(library.name)
                        }
                    }
                }
            }

            Divider()

            Button("Добавить библиотеку") {
                isImporterShown = true
            }

            Button("Открыть текущую в Files") {
                openCurrentLibraryInFiles()
            }
            .disabled(vm.selectedLibraryURL == nil)
        } label: {
            Label("Библиотеки", systemImage: "books.vertical")
        }
    }

    private func openCurrentLibraryInFiles() {
        guard let url = vm.selectedLibraryURL else {
            vm.errorMessage = "Сначала выберите коллекцию."
            return
        }

        UIApplication.shared.open(url, options: [:]) { opened in
            if !opened {
                vm.errorMessage = "iOS не смог открыть эту папку в Files. Попробуйте выбрать папку заново."
            }
        }
    }

    private var mangaList: some View {
        let columns = [
            GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12, alignment: .top)
        ]

        let topAnchorID = "manga-list-top"

        return ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id(topAnchorID)

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(vm.mangas) { manga in
                        NavigationLink {
                            MangaFolderBrowserView(manga: manga, folderURL: manga.rootURL, relativePath: [])
                        } label: {
                            MangaCardView(manga: manga, state: vm.state(for: manga))
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(role: .destructive) {
                                vm.clearReadingData(for: manga)
                            } label: {
                                Label("Удалить данные чтения", systemImage: "clock.arrow.circlepath")
                            }

                            Button(role: .destructive) {
                                mangaToDeleteFolder = manga
                            } label: {
                                Label("Удалить папку манги", systemImage: "folder.badge.minus")
                            }
                            .disabled(!vm.canDeleteMangaFolder(manga))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.28), value: vm.mangas.map(\.id))
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 18)
            }
            .refreshable {
                pendingScrollToTopAfterReload = true
                vm.hardReload()
            }
            .onChange(of: vm.isLoading) {
                guard !vm.isLoading, pendingScrollToTopAfterReload else { return }
                pendingScrollToTopAfterReload = false
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(topAnchorID, anchor: .top)
                    }
                }
            }
        }
        .confirmationDialog(
            "Удалить папку манги?",
            isPresented: Binding(
                get: { mangaToDeleteFolder != nil },
                set: { if !$0 { mangaToDeleteFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Удалить папку и файлы", role: .destructive) {
                if let mangaToDeleteFolder {
                    vm.deleteMangaFolder(mangaToDeleteFolder)
                }
                mangaToDeleteFolder = nil
            }
            Button("Отмена", role: .cancel) {
                mangaToDeleteFolder = nil
            }
        } message: {
            if let mangaToDeleteFolder {
                Text("Папка \"\(mangaToDeleteFolder.name)\" будет удалена вместе со всеми главами и изображениями.")
            }
        }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @ObservedObject var vm: MangaLibraryViewModel
    @Binding var isImporterShown: Bool
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Общее") {
                    Picker("Режим чтения по умолчанию", selection: Binding(
                        get: { vm.defaultReadingModeRawValue },
                        set: { vm.updateDefaultReadingModeOption(rawValue: $0) }
                    )) {
                        ForEach(DefaultReadingModeOption.allCases) { option in
                            Text(option.rawValue).tag(option.rawValue)
                        }
                    }

                    Picker("Сортировка манги", selection: Binding(
                        get: { vm.sortOptionRawValue },
                        set: { vm.updateSortOption(rawValue: $0) }
                    )) {
                        ForEach(MangaLibraryViewModel.MangaSortOption.allCases) { option in
                            Text(option.rawValue).tag(option.rawValue)
                        }
                    }
                }

                Section("Библиотеки") {
                    if vm.libraries.isEmpty {
                        Text("Пока нет библиотек")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(vm.libraries) { library in
                        Button {
                            vm.selectLibrary(library.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(library.name)
                                        .foregroundStyle(.primary)
                                    Text(library.path)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if vm.selectedLibraryID == library.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) {
                            vm.removeLibrary(vm.libraries[index])
                        }
                    }

                    Button {
                        isImporterShown = true
                        dismiss()
                    } label: {
                        Label("Добавить библиотеку", systemImage: "folder.badge.plus")
                    }
                }

                Section("Чтение") {
                    Text("Сохраняются глава и страница для продолжения. Точная позиция скролла не сохраняется.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("О приложении") {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text(appVersion)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Text("Сборка")
                        Spacer()
                        Text(appBuild)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Library Cards
struct MangaCardView: View {
    let manga: MangaTitle
    let state: MangaReadingState?

    private static let lastReadFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var progressText: String {
        guard let state else { return "Гл - • стр - • 0%" }
        return manga.compactProgressDescription(from: state)
    }

    private var lastReadText: String {
        guard let date = state?.lastReadAt else { return "Не читалось" }
        return "Читал: \(Self.lastReadFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MangaThumbnailView(url: manga.coverPageURL)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 5)

            VStack(alignment: .leading, spacing: 4) {
                Text(manga.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text("Глав: \(manga.chapters.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(progressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(lastReadText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        }
        .padding(10)
        .frame(height: 318)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MangaThumbnailView: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var retryID = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.05, green: 0.06, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 24))
                    Text("iCloud")
                        .font(.caption2)
                }
                .foregroundStyle(.white.opacity(0.75))
            }
        }
        .clipped()
        .task(id: "\(url?.path ?? "")-\(retryID)") {
            guard let url else { return }
            let cacheKey = ("thumb-hq:" + url.path) as NSString
            if let cached = MangaImageView.imageCache.object(forKey: cacheKey) {
                image = cached
                return
            }
            let loaded = await Task.detached(priority: .utility) {
                MangaImageView.loadImageForDisplay(from: url, maxPixelSize: 1800, waitForCloudDownload: false).image
            }.value
            if let loaded {
                MangaImageView.imageCache.setObject(loaded, forKey: cacheKey, cost: 1800 * 1800 * 4)
                withAnimation(.easeInOut(duration: 0.2)) {
                    image = loaded
                }
            } else if retryID < 2 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                retryID += 1
            }
        }
    }
}

// MARK: - Folder Browser
struct MangaFolderBrowserView: View {
    let manga: MangaTitle
    let folderURL: URL
    let relativePath: [String]
    @State private var progressRevision = 0

    private var mangaStorageID: String {
        manga.rootURL.path
    }

    private var isRootLevel: Bool {
        relativePath.isEmpty
    }

    private var folderTitle: String {
        isRootLevel ? manga.name : folderURL.lastPathComponent
    }

    private var currentFolderDirectChapter: MangaChapter? {
        let images = MangaScanner.imageFiles(in: folderURL)
        guard !images.isEmpty else { return nil }
        return manga.chapter(forFolderURL: folderURL)
    }

    private var folderRows: [URL] {
        MangaScanner.subdirectories(in: folderURL)
    }

    private var hasSubfolders: Bool {
        !folderRows.isEmpty
    }

    private var autoOpenChapter: MangaChapter? {
        guard !hasSubfolders else { return nil }
        return currentFolderDirectChapter
    }

    private var savedState: MangaReadingState? {
        _ = progressRevision
        return MangaReadingStateStore.shared.state(for: mangaStorageID)
    }

    private var continueChapter: MangaChapter? {
        guard let savedState else { return nil }
        return manga.chapters.first { manga.chapterStorageID(for: $0) == savedState.chapterID }
    }

    private var continueModeTitle: String {
        guard let savedState,
              let mode = ReadingMode(rawValue: savedState.readingModeRawValue) else {
            return "Вертикально"
        }
        return mode.rawValue
    }

    var body: some View {
        Group {
            if let chapter = autoOpenChapter {
                ReaderView(
                    manga: manga,
                    chapters: manga.chapters,
                    selectedChapter: chapter,
                    preferSavedPosition: isRootLevel
                )
            } else {
                List {
                    if isRootLevel, let continueChapter, let savedState {
                        Section {
                            NavigationLink {
                                ReaderView(
                                    manga: manga,
                                    chapters: manga.chapters,
                                    selectedChapter: continueChapter,
                                    preferSavedPosition: true
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Продолжить")
                                        .font(.headline)
                                    Text("\(continueChapter.title) • стр. \(savedState.logicalPageIndex + 1) • \(continueModeTitle)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Section("Папки") {
                        ForEach(folderRows, id: \.path) { childFolder in
                            let hasNested = !MangaScanner.subdirectories(in: childFolder).isEmpty
                            let childImagesCount = MangaScanner.imageFiles(in: childFolder).count

                            if hasNested || childImagesCount == 0 {
                                NavigationLink {
                                    MangaFolderBrowserView(
                                        manga: manga,
                                        folderURL: childFolder,
                                        relativePath: relativePath + [childFolder.lastPathComponent]
                                    )
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.orange)
                                        Text(childFolder.lastPathComponent)
                                        Spacer()
                                        if hasNested {
                                            Text("Папка")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            } else if let chapter = manga.chapter(forFolderURL: childFolder) {
                                NavigationLink {
                                    ReaderView(
                                        manga: manga,
                                        chapters: manga.chapters,
                                        selectedChapter: chapter,
                                        preferSavedPosition: false
                                    )
                                } label: {
                                    HStack {
                                        Image(systemName: "book.pages")
                                            .foregroundStyle(.blue)
                                        Text(chapter.title)
                                        Spacer()
                                        Text("\(chapter.pageURLs.count) стр.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: readerDidCloseNotification)) { _ in
            progressRevision += 1
        }
    }
}

#Preview {
    ContentView()
}
