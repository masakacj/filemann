import SwiftUI

struct PhotoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: PhotoEditorViewModel
    @State private var selectedParameterID = "exposure"

    init(url: URL) {
        _viewModel = StateObject(wrappedValue: PhotoEditorViewModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("完成") {
                    dismiss()
                }

                Spacer()

                Text(viewModel.url.lastPathComponent)
                    .font(.subheadline)
                    .lineLimit(1)

                Spacer()

                Button {
                    viewModel.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("还原调整")
            }
            .padding()
            .background(.ultraThinMaterial)

            ZStack {
                Color.black

                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else if let image = viewModel.displayImage {
                    ZoomableImageView(image: image)
                        .ignoresSafeArea(edges: .horizontal)
                } else {
                    ContentUnavailableView(
                        "无法显示图片",
                        systemImage: "photo",
                        description: Text(viewModel.errorMessage ?? "未知错误")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            AdjustmentPanel(
                adjustments: $viewModel.adjustments,
                selectedParameterID: $selectedParameterID,
                onChange: {
                    viewModel.renderAndSave()
                },
                onReset: {
                    viewModel.reset()
                }
            )
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }
}
