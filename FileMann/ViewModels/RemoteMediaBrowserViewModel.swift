import Foundation

@MainActor
final class RemoteMediaBrowserViewModel: ObservableObject {
    @Published var entries: [RemoteMediaEntry] = []
    @Published var currentPath: String
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var endpointLabel: String?
    @Published var endpointTitle: String?
    @Published var resolvedBaseURL: String?

    let settings: SMBSettings
    let password: String
    let rootPath: String

    init(settings: SMBSettings, password: String) {
        self.settings = settings
        self.password = password
        self.rootPath = ""
        self.currentPath = ""
    }

    var canGoUp: Bool {
        normalize(currentPath) != normalize(rootPath)
    }

    func load(path: String? = nil) {
        let target = normalize(path ?? currentPath)
        currentPath = target
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let resolved = try await WebDAVArchiveService.resolveBestBaseURL(
                    settings: settings,
                    password: password
                )
                let service = try WebDAVArchiveService(
                    settings: settings,
                    password: password,
                    baseURLString: resolved
                )

                let values = try await service.listRemoteMedia(at: target)
                resolvedBaseURL = service.baseURLString
                endpointLabel = service.endpointLabel
                endpointTitle = settings.webDAVTitle(
                    for: service.baseURLString
                )
                entries = values.filter {
                    $0.kind == .folder ||
                    $0.kind == .image ||
                    $0.kind == .video
                }
            } catch {
                entries = []
                errorMessage = error.localizedDescription
            }

            isLoading = false
        }
    }

    func enter(_ entry: RemoteMediaEntry) {
        guard entry.kind == .folder else { return }
        load(path: entry.path)
    }

    func goUp() {
        guard canGoUp else { return }

        let parent = (normalize(currentPath) as NSString)
            .deletingLastPathComponent

        if normalize(rootPath).isEmpty {
            load(path: parent)
        } else if parent.count >= normalize(rootPath).count {
            load(path: parent)
        } else {
            load(path: rootPath)
        }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(
            in: CharacterSet(charactersIn: "/ ")
        )
    }
}
