import Foundation

@MainActor
final class MediaLibraryViewModel: ObservableObject {
    @Published var items: [MediaItem] = []
    @Published var selectedIDs: Set<String> = []
    @Published var isSelectionMode = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    private var lastGeneration = -1

    func refresh(force: Bool = false) {
        let generation = FileMannShared.currentGeneration()
        if !force && generation == lastGeneration && !items.isEmpty {
            return
        }

        lastGeneration = generation
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let values = try await Task.detached(priority: .userInitiated) {
                    let directory = try FileMannShared.mediaDirectory()
                    let urls = try FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    )

                    return urls
                        .compactMap(MediaItem.init(url:))
                        .sorted { $0.modifiedAt > $1.modifiedAt }
                }.value

                items = values
                selectedIDs.formIntersection(Set(values.map(\.id)))
            } catch {
                errorMessage = error.localizedDescription
                items = []
            }
            isLoading = false
        }
    }

    func toggleSelection(_ item: MediaItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func selectAll() {
        selectedIDs = Set(items.map(\.id))
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func selectedItems() -> [MediaItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    func deleteSelected() {
        let targets = selectedItems()
        for item in targets {
            try? FileManager.default.removeItem(at: item.url)
            if let sidecar = try? FileMannShared.sidecarURL(for: item.url) {
                try? FileManager.default.removeItem(at: sidecar)
            }
        }
        FileMannShared.noteLibraryChanged()
        selectedIDs.removeAll()
        refresh(force: true)
    }
}
