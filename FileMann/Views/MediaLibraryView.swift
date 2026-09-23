import PhotosUI
import SwiftUI

struct MediaLibraryView: View {
    @EnvironmentObject private var archiveViewModel: ArchiveViewModel
    @StateObject private var viewModel = MediaLibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("filemann.photos.deleteAfterImport")
    private var deletePhotosAfterImport = true

    @AppStorage("filemann.shortcut.askDeleteOriginals")
    private var askDeleteAfterShortcutImport = false

    @AppStorage("filemann.media.thumbnailSize")
    private var thumbnailSize: Double = 112

    @State private var presentedItem: MediaItem?
    @State private var showDeleteConfirmation = false
    @State private var showPhotoPicker = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(thumbnailSize)), spacing: 2)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ArchiveInlinePanel()
                        .environmentObject(archiveViewModel)
                        .padding(.horizontal)

                    if let error = viewModel.errorMessage {
                        ContentUnavailableView(
                            "无法打开 FileMann 媒体库",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                        .padding(.top, 60)
                    } else if viewModel.items.isEmpty && !viewModel.isLoading {
                        VStack(spacing: 16) {
                            ContentUnavailableView {
                                Label("媒体库为空", systemImage: "photo.on.rectangle")
                            } description: {
                                Text("可从相册直接导入，也可以通过“保存到 FileMann”快捷指令复制到 Shortcut Inbox。")
                            }

                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("从相册导入", systemImage: "photo.badge.plus")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, archiveViewModel.tasks.isEmpty ? 100 : 20)
                    } else {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(viewModel.items) { item in
                                mediaCell(item)
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
            .overlay {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    ProgressView("读取媒体库…")
                }

                if viewModel.isImportingPhotos || viewModel.isImportingInbox {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(
                            viewModel.isImportingPhotos
                                ? viewModel.photoImportProgress
                                : viewModel.inboxImportProgress
                        )
                        .font(.subheadline)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle("FileMann")
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
                            Section("缩略图大小") {
                                Picker("缩略图大小", selection: $thumbnailSize) {
                                    Text("紧凑").tag(82.0)
                                    Text("小").tag(108.0)
                                    Text("中").tag(138.0)
                                    Text("大").tag(178.0)
                                }
                            }

                            Section("相册") {
                                Toggle(
                                    "FileMann 导入后清理相册原件",
                                    isOn: $deletePhotosAfterImport
                                )

                                Toggle(
                                    "快捷指令复制后询问删除相册原件",
                                    isOn: $askDeleteAfterShortcutImport
                                )
                            }

                            Section("归档") {
                                if !archiveViewModel.duplicateCandidates.isEmpty {
                                    Button {
                                        archiveViewModel.isShowingDuplicateReview = true
                                    } label: {
                                        Label(
                                            "重复文件（\(archiveViewModel.unresolvedDuplicateCount)）",
                                            systemImage: "square.on.square"
                                        )
                                    }
                                }

                                if archiveViewModel.completedCount > 0 {
                                    Button("清理已完成任务") {
                                        archiveViewModel.clearCompleted()
                                    }
                                }
                            }

                            Section {
                                Button {
                                    viewModel.importInboxAndRefresh()
                                } label: {
                                    Label("扫描 Shortcut Inbox", systemImage: "tray.and.arrow.down")
                                }

                                Button {
                                    viewModel.refresh(force: true)
                                } label: {
                                    Label("刷新媒体库", systemImage: "arrow.clockwise")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }

                    Button {
                        archiveViewModel.isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .safeAreaInset(edge: .top) {
                Group {
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
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.isSelectionMode && !viewModel.selectedIDs.isEmpty {
                    selectionBar
                }
            }
        }
        .onAppear {
            syncShortcutSettings()
            viewModel.importInboxAndRefresh(showStatus: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                syncShortcutSettings()
                viewModel.importInboxAndRefresh(showStatus: true)
            }
        }
        .onChange(of: askDeleteAfterShortcutImport) { _, _ in
            syncShortcutSettings()
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
        .sheet(isPresented: $archiveViewModel.isShowingSettings) {
            SettingsView()
                .environmentObject(archiveViewModel)
        }
        .sheet(isPresented: $archiveViewModel.isShowingDuplicateReview) {
            DuplicateReviewView()
                .environmentObject(archiveViewModel)
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
                                .white,
                                viewModel.selectedIDs.contains(item.id)
                                    ? .blue
                                    : .black.opacity(0.35)
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
                archiveViewModel.start()
            } label: {
                Label("归档到 NAS", systemImage: "externaldrive.badge.plus")
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

    private func syncShortcutSettings() {
        try? FileMannShared.writeShortcutSettings(
            askDeleteOriginals: askDeleteAfterShortcutImport
        )
    }
}
