import SwiftUI

struct RemoteMediaBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteMediaBrowserViewModel

    @AppStorage("filemann.media.thumbnailSize")
    private var thumbnailSize: Double = 112

    @State private var selectedEntry: RemoteMediaEntry?

    private let settings: SMBSettings
    private let password: String

    init(
        settings: SMBSettings,
        password: String
    ) {
        self.settings = settings
        self.password = password
        _viewModel = StateObject(
            wrappedValue: RemoteMediaBrowserViewModel(
                settings: settings,
                password: password
            )
        )
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: CGFloat(thumbnailSize)
                ),
                spacing: 2
            )
        ]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error = viewModel.errorMessage {
                    ContentUnavailableView(
                        "无法读取远程媒体",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(error)
                    )
                } else if viewModel.entries.isEmpty &&
                            !viewModel.isLoading {
                    ContentUnavailableView(
                        "当前目录没有图片或视频",
                        systemImage: "photo.on.rectangle.angled"
                    )
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: columns,
                            spacing: 2
                        ) {
                            ForEach(viewModel.entries) { entry in
                                cell(entry)
                            }
                        }
                    }
                }
            }
            .overlay {
                if viewModel.isLoading {
                    ProgressView("读取 NAS…")
                        .padding(18)
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(
                                cornerRadius: 14
                            )
                        )
                }
            }
            .navigationTitle("NAS 媒体")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    if viewModel.canGoUp {
                        Button {
                            viewModel.goUp()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }

                    Image(systemName: "folder")
                    Text(
                        viewModel.currentPath.isEmpty
                            ? "/"
                            : "/\(viewModel.currentPath)"
                    )
                    .font(.caption.monospaced())
                    .lineLimit(1)

                    Spacer()

                    if let endpoint = viewModel.endpointLabel {
                        Label(
                            endpoint,
                            systemImage: endpoint == "本地"
                                ? "wifi"
                                : "globe"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            }
            .toolbar {
                ToolbarItem(
                    placement: .cancellationAction
                ) {
                    Button("完成") {
                        dismiss()
                    }
                }

                ToolbarItemGroup(
                    placement: .topBarTrailing
                ) {
                    Button {
                        viewModel.load()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }

                    Menu {
                        Picker(
                            "缩略图大小",
                            selection: $thumbnailSize
                        ) {
                            Text("紧凑").tag(82.0)
                            Text("小").tag(108.0)
                            Text("中").tag(138.0)
                            Text("大").tag(178.0)
                        }
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                }
            }
        }
        .task {
            viewModel.load()
        }
        .fullScreenCover(item: $selectedEntry) { entry in
            if let baseURL = viewModel.resolvedBaseURL {
                switch entry.kind {
                case .image:
                    RemoteImageViewerView(
                        entry: entry,
                        settings: settings,
                        password: password,
                        baseURLString: baseURL
                    )
                case .video:
                    RemoteVideoPlayerView(
                        entry: entry,
                        settings: settings,
                        password: password,
                        baseURLString: baseURL
                    )
                default:
                    EmptyView()
                }
            }
        }
    }

    private func cell(
        _ entry: RemoteMediaEntry
    ) -> some View {
        Button {
            switch entry.kind {
            case .folder:
                viewModel.enter(entry)
            case .image, .video:
                selectedEntry = entry
            case .other:
                break
            }
        } label: {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    RemoteMediaThumbnailView(
                        entry: entry,
                        settings: settings,
                        password: password,
                        baseURLString:
                            viewModel.resolvedBaseURL,
                        targetSize: CGSize(
                            width: max(
                                180,
                                proxy.size.width * 2
                            ),
                            height: max(
                                180,
                                proxy.size.width * 2
                            )
                        )
                    )
                    .frame(
                        width: proxy.size.width,
                        height: proxy.size.width
                    )
                }
                .aspectRatio(1, contentMode: .fit)

                HStack(spacing: 4) {
                    if entry.kind == .folder {
                        Image(systemName: "folder.fill")
                    }

                    Text(entry.name)
                        .lineLimit(1)

                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
            }
        }
        .buttonStyle(.plain)
    }
}
