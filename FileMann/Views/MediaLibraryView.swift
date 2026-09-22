import PhotosUI
import SwiftUI

struct MediaLibraryView: View {
    @EnvironmentObject private var archiveViewModel: ArchiveViewModel
    @StateObject private var viewModel = MediaLibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("filemann.photos.deleteAfterImport")
    private var deletePhotosAfterImport = true

    @State private var presentedItem: MediaItem?
    @State private var showDeleteConfirmation = false
    @State private var showPhotoPicker = false

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
                    VStack(spacing: 16) {
                        ContentUnavailableView {
                            Label("媒体库为空", systemImage: "photo.on.rectangle")
                        } description: {
                            Text("可从 FileMann 内导入相册，也可以在 iOS 相册中“分享 → 保存到 FileMann”。")
                        }

                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("从相册导入", systemImage: "photo.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
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

                if viewModel.isImportingPhotos {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(viewModel.photoImportProgress)
                            .font(.subheadline)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
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
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Image(systemName: "photo.badge.plus")
                        }
                        .accessibilityLabel("从相册导入")

                        Button("选择") {
                            viewModel.isSelectionMode = true
                        }
                        .disabled(viewModel.items.isEmpty)

                        Menu {
                            Toggle(
                                "导入后清理相册原件",
                                isOn: $deletePhotosAfterImport
                            )

                            Button {
                                viewModel.refresh(force: true)
                            } label: {
                                Label("刷新媒体库", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if let status = viewModel.statusMessage, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 7)
                        .background(.thinMaterial)
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
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { results in
                showPhotoPicker = false
                viewModel.importPhotoPickerResults(
                    results,
                    deleteOriginalsAfterImport: deletePhotosAfterImport
                )
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

                    VStack(alignment: .trailing, spacing: 5) {
                        if let metadata = item.importMetadata,
                           metadata.source == .photoPicker,
                           metadata.photoDeletedAt != nil {
                            Image(systemName: "photo.badge.checkmark")
                                .font(.caption)
                                .padding(5)
                                .background(.ultraThinMaterial, in: Circle())
                        }

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
                        }
                    }
                    .padding(7)
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
