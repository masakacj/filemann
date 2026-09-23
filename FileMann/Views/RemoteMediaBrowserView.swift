import SwiftUI

struct RemoteMediaBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteMediaBrowserViewModel

    @AppStorage("filemann.media.thumbnailSize")
    private var thumbnailSize: Double = 112

    @State private var selectedEntry: RemoteMediaEntry?

    private let settings: SMBSettings
    private let password: String
    private let showsDismissButton: Bool
    private let onSettings: (() -> Void)?

    init(
        settings: SMBSettings,
        password: String,
        showsDismissButton: Bool = true,
        onSettings: (() -> Void)? = nil
    ) {
        self.settings = settings
        self.password = password
        self.showsDismissButton = showsDismissButton
        self.onSettings = onSettings

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
                spacing: 18
            )
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                browserContent
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(
                Color.black,
                for: .navigationBar
            )
            .toolbarBackground(
                .visible,
                for: .navigationBar
            )
            .toolbarColorScheme(
                .dark,
                for: .navigationBar
            )
            .toolbar {
                ToolbarItem(
                    placement: .topBarLeading
                ) {
                    leadingToolbar
                }

                ToolbarItem(
                    placement: .principal
                ) {
                    titleView
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
                            "图标大小",
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

                    if let onSettings {
                        Button {
                            onSettings()
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("设置")
                    }
                }
            }
        }
        .tint(.yellow)
        .preferredColorScheme(.dark)
        .task {
            viewModel.load()
        }
        .fullScreenCover(
            item: $selectedEntry
        ) { entry in
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

    @ViewBuilder
    private var browserContent: some View {
        if let error = viewModel.errorMessage {
            VStack(spacing: 14) {
                Image(
                    systemName:
                        "externaldrive.badge.exclamationmark"
                )
                .font(.system(size: 54))
                .foregroundStyle(.gray)

                Text("无法读取远程媒体")
                    .font(.title3.bold())
                    .foregroundStyle(.white)

                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Button("重试") {
                    viewModel.load()
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )

        } else if viewModel.entries.isEmpty &&
                    !viewModel.isLoading {
            VStack(spacing: 14) {
                Image(systemName: "folder")
                    .font(.system(size: 58, weight: .thin))
                    .foregroundStyle(.yellow)

                Text("当前目录为空")
                    .font(.headline)
                    .foregroundStyle(.white)

                Text("没有可显示的文件夹、图片或视频")
                    .font(.footnote)
                    .foregroundStyle(.gray)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity
            )

        } else {
            ScrollView {
                LazyVGrid(
                    columns: columns,
                    spacing: 24
                ) {
                    ForEach(viewModel.entries) { entry in
                        cell(entry)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                viewModel.load()
            }
        }

        if viewModel.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.yellow)

                Text("读取 NAS…")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .padding(18)
            .background(
                .black.opacity(0.72),
                in: RoundedRectangle(
                    cornerRadius: 14
                )
            )
        }
    }

    @ViewBuilder
    private var leadingToolbar: some View {
        if showsDismissButton {
            Button("完成") {
                dismiss()
            }
        } else if viewModel.canGoUp {
            Button {
                viewModel.goUp()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("上一级")
                }
            }
        } else {
            Color.clear
                .frame(width: 1, height: 1)
        }
    }

    private var titleView: some View {
        VStack(spacing: 1) {
            Text(
                viewModel.endpointTitle
                    ?? settings.webDAVLocalTitle
                    .nonEmptyOr("NAS")
            )
            .font(.headline)
            .foregroundStyle(.white)
            .lineLimit(1)

            HStack(spacing: 5) {
                if let endpoint = viewModel.endpointLabel {
                    Image(
                        systemName: endpoint == "本地"
                            ? "wifi"
                            : "globe"
                    )
                }

                Text(
                    viewModel.currentPath.isEmpty
                        ? "/"
                        : "/\(viewModel.currentPath)"
                )
                .lineLimit(1)
            }
            .font(.caption2.monospaced())
            .foregroundStyle(.gray)
        }
        .frame(maxWidth: 220)
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
            VStack(spacing: 9) {
                if entry.kind == .folder {
                    Image(systemName: "folder")
                        .resizable()
                        .scaledToFit()
                        .fontWeight(.ultraLight)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 78,
                            maxHeight: 92
                        )
                } else {
                    GeometryReader { proxy in
                        RemoteMediaThumbnailView(
                            entry: entry,
                            settings: settings,
                            password: password,
                            baseURLString:
                                viewModel.resolvedBaseURL,
                            targetSize: CGSize(
                                width: proxy.size.width,
                                height: proxy.size.width
                            )
                        )
                        .frame(
                            width: proxy.size.width,
                            height: proxy.size.width
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 8
                            )
                        )
                    }
                    .aspectRatio(1, contentMode: .fit)
                }

                Text(entry.name)
                    .font(.subheadline)
                    .foregroundStyle(
                        entry.kind == .folder
                            ? Color.gray
                            : Color.white
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 34,
                        alignment: .top
                    )
            }
        }
        .buttonStyle(.plain)
    }
}

private extension String {
    func nonEmptyOr(
        _ fallback: String
    ) -> String {
        let value = trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return value.isEmpty ? fallback : value
    }
}
