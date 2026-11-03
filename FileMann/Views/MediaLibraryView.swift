import SwiftUI

struct MediaLibraryView: View {
    @EnvironmentObject private var archiveViewModel:
        ArchiveViewModel
    @StateObject private var viewModel =
        MediaLibraryViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("filemann.media.thumbnailSize")
    private var thumbnailSize: Double = 112
    @AppStorage("filemann.media.sortOrder")
    private var sortOrderRaw =
        MediaLibrarySortOrder.shootingNewest.rawValue
    @AppStorage("filemann.media.displayMode")
    private var displayMode = "grid"

    @State private var presentedItem: MediaItem?
    @State private var showDeleteConfirmation = false
    @State private var showExternalFolderPicker = false

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: CGFloat(thumbnailSize)
                ),
                spacing: 9
            )
        ]
    }

    private var sortOrder: MediaLibrarySortOrder {
        MediaLibrarySortOrder(rawValue: sortOrderRaw) ??
            .shootingNewest
    }

    private struct GallerySection: Identifiable {
        let id: String
        let title: String
        var items: [MediaItem]
    }

    private var gallerySections: [GallerySection] {
        let sorted = MediaLibraryOrdering.sorted(
            viewModel.items,
            by: sortOrder
        )
        if !sortOrder.groupsByDay {
            return [
                GallerySection(
                    id: "all",
                    title: "全部媒体",
                    items: sorted
                )
            ]
        }

        var sections: [GallerySection] = []
        let calendar = Calendar.current
        for item in sorted {
            let unknownDate = item.preferredDate == .distantPast
            let date = calendar.startOfDay(for: item.preferredDate)
            let key = unknownDate
                ? "undated"
                : String(Int(date.timeIntervalSince1970))
            let title = unknownDate
                ? "日期未知"
                : date.formatted(date: .abbreviated, time: .omitted)
            if sections.last?.id == key {
                sections[sections.count - 1].items.append(item)
            } else {
                sections.append(
                    GallerySection(id: key, title: title, items: [item])
                )
            }
        }
        return sections
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ArchiveInlinePanel()
                        .environmentObject(
                            archiveViewModel
                        )
                        .padding(.horizontal)

                    if let error = viewModel.errorMessage {
                        ContentUnavailableView(
                            "无法打开 FileMann 媒体库",
                            systemImage:
                                "exclamationmark.triangle",
                            description: Text(error)
                        )
                        .padding(.top, 60)
                    } else if viewModel.items.isEmpty &&
                                !viewModel.isLoading {
                        VStack(spacing: 16) {
                            ContentUnavailableView {
                                Label(
                                    "媒体库为空",
                                    systemImage:
                                        "photo.on.rectangle"
                                )
                            } description: {
                                if let folder =
                                    viewModel
                                        .externalFolderName {
                                    Text(
                                        "已映射“\(folder)”，当前没有可显示的图片或视频。"
                                    )
                                } else {
                                    Text(
                                        "建议让“保存到 FileMann”快捷指令保存到 iCloud Drive 中的独立文件夹，再把该文件夹映射到 FileMann。"
                                    )
                                }
                            }

                            if viewModel
                                .externalFolderName == nil {
                                Button {
                                    showExternalFolderPicker =
                                        true
                                } label: {
                                    Label(
                                        "映射外部文件夹",
                                        systemImage:
                                            "folder.badge.plus"
                                    )
                                }
                                .buttonStyle(
                                    .borderedProminent
                                )
                            }
                        }
                        .padding(
                            .top,
                            archiveViewModel.tasks.isEmpty
                                ? 100
                                : 20
                        )
                    } else {
                        galleryContent
                    }
                }
                .padding(.top, 4)
            }
            .overlay {
                if viewModel.isLoading &&
                    viewModel.items.isEmpty {
                    ProgressView("读取媒体库…")
                }

                if viewModel.isImportingInbox {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(
                            viewModel
                                .inboxImportProgress
                        )
                        .font(.subheadline)
                    }
                    .padding(20)
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(
                            cornerRadius: 14
                        )
                    )
                }
            }
            .navigationTitle("FileMann")
            .toolbar {
                ToolbarItemGroup(
                    placement: .topBarTrailing
                ) {
                    if viewModel.isSelectionMode {
                        Button("全选") {
                            viewModel.selectAll()
                        }

                        Button("完成") {
                            viewModel.isSelectionMode =
                                false
                            viewModel.clearSelection()
                        }
                    } else {
                        Button("选择") {
                            viewModel.isSelectionMode =
                                true
                        }
                        .disabled(viewModel.items.isEmpty)

                        Menu {
                            Section("缩略图大小") {
                                Picker(
                                    "缩略图大小",
                                    selection: $thumbnailSize
                                ) {
                                    Text("紧凑")
                                        .tag(82.0)
                                    Text("小")
                                        .tag(108.0)
                                    Text("中")
                                        .tag(138.0)
                                    Text("大")
                                        .tag(178.0)
                                }
                            }

                            Section("排列方式") {
                                Picker(
                                    "排序",
                                    selection: $sortOrderRaw
                                ) {
                                    ForEach(MediaLibrarySortOrder.allCases) { order in
                                        Text(order.title).tag(order.rawValue)
                                    }
                                }
                                Picker(
                                    "视图",
                                    selection: $displayMode
                                ) {
                                    Text("缩略图").tag("grid")
                                    Text("详细列表").tag("list")
                                }
                            }

                            Section("媒体来源") {
                                if let folder =
                                    viewModel
                                        .externalFolderName {
                                    Button {
                                        showExternalFolderPicker =
                                            true
                                    } label: {
                                        Label(
                                            "更换外部文件夹 · \(folder)",
                                            systemImage:
                                                "folder.badge.gearshape"
                                        )
                                    }

                                    Button(
                                        role: .destructive
                                    ) {
                                        viewModel
                                            .clearExternalFolder()
                                    } label: {
                                        Label(
                                            "取消外部文件夹映射",
                                            systemImage:
                                                "folder.badge.minus"
                                        )
                                    }
                                } else {
                                    Button {
                                        showExternalFolderPicker =
                                            true
                                    } label: {
                                        Label(
                                            "映射外部文件夹",
                                            systemImage:
                                                "folder.badge.plus"
                                        )
                                    }
                                }
                            }

                            Section("归档") {
                                if !archiveViewModel
                                    .duplicateCandidates
                                    .isEmpty {
                                    Button {
                                        archiveViewModel
                                            .isShowingDuplicateReview =
                                            true
                                    } label: {
                                        Label(
                                            "重复文件（\(archiveViewModel.unresolvedDuplicateCount)）",
                                            systemImage:
                                                "square.on.square"
                                        )
                                    }
                                }

                                if archiveViewModel
                                    .completedCount > 0 {
                                    Button(
                                        "清理已完成任务"
                                    ) {
                                        archiveViewModel
                                            .clearCompleted()
                                    }
                                }
                            }

                            Section {
                                Button {
                                    viewModel
                                        .importInboxAndRefresh()
                                } label: {
                                    Label(
                                        "导入旧 Shortcut Inbox",
                                        systemImage:
                                            "tray.and.arrow.down"
                                    )
                                }

                                Button {
                                    viewModel.refresh(
                                        force: true
                                    )
                                } label: {
                                    Label(
                                        "刷新媒体库",
                                        systemImage:
                                            "arrow.clockwise"
                                    )
                                }
                            }
                        } label: {
                            Image(
                                systemName:
                                    "ellipsis.circle"
                            )
                        }
                        .accessibilityLabel("更多")
                        .accessibilityIdentifier(
                            "media-library-more-menu"
                        )
                    }

                    Button {
                        archiveViewModel
                            .isShowingSettings = true
                    } label: {
                        Image(
                            systemName: "gearshape"
                        )
                    }
                    .accessibilityLabel("设置")
                }
            }
            .safeAreaInset(edge: .top) {
                Group {
                    if let status =
                        viewModel.statusMessage,
                       !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(
                                .secondary
                            )
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 7)
                            .background(
                                .thinMaterial
                            )
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.isSelectionMode &&
                    !viewModel.selectedIDs.isEmpty {
                    selectionBar
                }
            }
        }
        .onAppear {
            viewModel.importInboxAndRefresh(
                showStatus: true
            )
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                viewModel.importInboxAndRefresh(
                    showStatus: true
                )
            }
        }
        .sheet(
            isPresented: $showExternalFolderPicker
        ) {
            FolderPicker { url in
                showExternalFolderPicker = false
                viewModel.mapExternalFolder(url)
            }
        }
        .sheet(
            isPresented:
                $archiveViewModel
                    .isShowingDuplicateReview
        ) {
            DuplicateReviewView()
                .environmentObject(
                    archiveViewModel
                )
        }
        .fullScreenCover(
            item: $presentedItem
        ) { item in
            MediaViewerView(item: item)
        }
        .confirmationDialog(
            "删除选中的媒体文件？",
            isPresented: $showDeleteConfirmation
        ) {
            Button(
                "删除",
                role: .destructive
            ) {
                viewModel.deleteSelected()
            }
            Button(
                "取消",
                role: .cancel
            ) {}
        } message: {
            Text(
                "这会直接删除所选文件；如果文件来自映射的外部文件夹，外部文件本身也会被删除。"
            )
        }
    }

    private var galleryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                let photos = viewModel.items.filter {
                    $0.kind == .image
                }.count
                let videos = viewModel.items.count - photos
                Text("\(photos) 张照片 · \(videos) 个视频")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 4)

                Menu {
                    Picker("排序方式", selection: $sortOrderRaw) {
                        ForEach(MediaLibrarySortOrder.allCases) { order in
                            Text(order.title).tag(order.rawValue)
                        }
                    }
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                        .font(.caption)
                }
                .accessibilityIdentifier("media-library-sort-menu")

                Button {
                    displayMode = displayMode == "grid"
                        ? "list" : "grid"
                } label: {
                    Image(
                        systemName: displayMode == "grid"
                            ? "list.bullet" : "square.grid.3x3"
                    )
                    .frame(width: 28, height: 30)
                }
                .accessibilityLabel(
                    displayMode == "grid" ? "切换列表视图" : "切换缩略图视图"
                )
                .accessibilityIdentifier("media-library-layout-toggle")
            }
            .padding(.vertical, 3)

            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(gallerySections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(section.title)
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(section.items.count) 项")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                        .accessibilityElement(children: .combine)

                        if displayMode == "list" {
                            LazyVStack(spacing: 1) {
                                ForEach(section.items) { item in
                                    mediaListRow(item)
                                }
                            }
                        } else {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(section.items) { item in
                                    mediaCell(item)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 24)
    }

    private func openOrSelect(_ item: MediaItem) {
        if viewModel.isSelectionMode {
            viewModel.toggleSelection(item)
        } else {
            presentedItem = item
        }
    }

    private func mediaListRow(_ item: MediaItem) -> some View {
        Button {
            openOrSelect(item)
        } label: {
            HStack(spacing: 12) {
                MediaThumbnailView(
                    item: item,
                    targetSize: CGSize(width: 160, height: 160)
                )
                .frame(width: 68, height: 68)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)

                    HStack(spacing: 7) {
                        Text(item.url.pathExtension.uppercased())
                        Text(ByteFormat.string(item.fileSize))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if item.preferredDate != .distantPast {
                        Text(
                            item.preferredDate.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                if viewModel.isSelectionMode {
                    Image(
                        systemName: viewModel.selectedIDs.contains(item.id)
                            ? "checkmark.circle.fill" : "circle"
                    )
                    .font(.title3)
                    .foregroundStyle(
                        viewModel.selectedIDs.contains(item.id)
                            ? .blue : .secondary
                    )
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                .thinMaterial,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mediaCell(
        _ item: MediaItem
    ) -> some View {
        Button {
            openOrSelect(item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .topTrailing) {
                        MediaThumbnailView(
                            item: item,
                            targetSize: CGSize(
                                width: max(180, geometry.size.width * 2),
                                height: max(180, geometry.size.width * 2)
                            )
                        )
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.width
                        )
                        .clipped()

                        if viewModel.isSelectionMode {
                            Image(
                                systemName: viewModel.selectedIDs.contains(item.id)
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                .white,
                                viewModel.selectedIDs.contains(item.id)
                                    ? .blue : .black.opacity(0.35)
                            )
                            .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text(item.url.pathExtension.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(5)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.name)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 30,
                        maxHeight: 30,
                        alignment: .topLeading
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(item.name)，\(item.kind == .image ? "照片" : "视频")"
        )
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(
                "\(viewModel.selectedIDs.count) 项"
            )
            .font(
                .subheadline.monospacedDigit()
            )

            Spacer()

            Button {
                let urls =
                    viewModel
                        .selectedItems()
                        .map(\.url)
                archiveViewModel
                    .addDocuments(urls)
                viewModel.isSelectionMode = false
                viewModel.clearSelection()
                archiveViewModel.start()
            } label: {
                Label(
                    "归档到 NAS",
                    systemImage:
                        "externaldrive.badge.plus"
                )
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
