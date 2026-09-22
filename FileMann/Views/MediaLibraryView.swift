import SwiftUI

struct MediaLibraryView: View {
    @EnvironmentObject private var archiveViewModel: ArchiveViewModel
    @StateObject private var viewModel = MediaLibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var presentedItem: MediaItem?
    @State private var showDeleteConfirmation = false

    private let columns = [
        GridItem(.adaptive(minimum: 105), spacing: 2)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if let error = viewModel.errorMessage {
                    ContentUnavailableView(
                        "无法打开 FileMann 媒体库",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if viewModel.items.isEmpty && !viewModel.isLoading {
                    ContentUnavailableView {
                        Label("媒体库为空", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("在 iOS 相册中选择图片或视频 → 分享 → 保存到 FileMann。")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(viewModel.items) { item in
                                mediaCell(item)
                            }
                        }
                    }
                }
            }
            .overlay {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView("读取媒体库…")
                }
            }
            .navigationTitle("媒体")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if viewModel.isSelectionMode {
                        Button("全选") {
                            viewModel.selectAll()
                        }

                        Button("完成") {
                            viewModel.isSelectionMode = false
                            viewModel.clearSelection()
                        }
                    } else {
                        Button("选择") {
                            viewModel.isSelectionMode = true
                        }
                        .disabled(viewModel.items.isEmpty)

                        Button {
                            viewModel.refresh(force: true)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.isSelectionMode && !viewModel.selectedIDs.isEmpty {
                    selectionBar
                }
            }
        }
        .onAppear {
            viewModel.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.refresh()
            }
        }
        .fullScreenCover(item: $presentedItem) { item in
            MediaViewerView(item: item)
        }
        .confirmationDialog(
            "删除 FileMann 中选中的本地媒体？",
            isPresented: $showDeleteConfirmation
        ) {
            Button("删除", role: .destructive) {
                viewModel.deleteSelected()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会直接删除 FileMann 自己保存的副本。")
        }
    }

    private func mediaCell(_ item: MediaItem) -> some View {
        Button {
            if viewModel.isSelectionMode {
                viewModel.toggleSelection(item)
            } else {
                presentedItem = item
            }
        } label: {
            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    MediaThumbnailView(
                        item: item,
                        targetSize: CGSize(
                            width: max(180, proxy.size.width * 2),
                            height: max(180, proxy.size.width * 2)
                        )
                    )
                    .frame(width: proxy.size.width, height: proxy.size.width)

                    if viewModel.isSelectionMode {
                        Image(
                            systemName: viewModel.selectedIDs.contains(item.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            viewModel.selectedIDs.contains(item.id) ? .white : .white,
                            viewModel.selectedIDs.contains(item.id) ? .blue : .black.opacity(0.35)
                        )
                        .padding(7)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(viewModel.selectedIDs.count) 项")
                .font(.subheadline.monospacedDigit())

            Spacer()

            Button {
                let urls = viewModel.selectedItems().map(\.url)
                archiveViewModel.addDocuments(urls)
                viewModel.isSelectionMode = false
                viewModel.clearSelection()
            } label: {
                Label("加入归档", systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.regularMaterial)
    }
}
