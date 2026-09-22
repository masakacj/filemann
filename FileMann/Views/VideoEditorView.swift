import SwiftUI

struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: VideoEditorViewModel
    @State private var selectedParameterID = "exposure"
    @State private var wasPlayingBeforeScrub = false

    init(url: URL) {
        _viewModel = StateObject(wrappedValue: VideoEditorViewModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("完成") {
                    viewModel.pause()
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

            ZStack(alignment: .topTrailing) {
                Color.black

                ZoomablePlayerView(player: viewModel.player)

                Text("双指可局部放大")
                    .font(.caption2)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            videoControls

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }

            AdjustmentPanel(
                adjustments: $viewModel.adjustments,
                selectedParameterID: $selectedParameterID,
                onChange: {
                    viewModel.adjustmentsDidChange()
                },
                onReset: {
                    viewModel.reset()
                }
            )
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onDisappear {
            viewModel.pause()
        }
    }

    private var videoControls: some View {
        VStack(spacing: 8) {
            Slider(
                value: $viewModel.currentTime,
                in: 0...max(viewModel.duration, 0.001),
                onEditingChanged: { editing in
                    if editing {
                        wasPlayingBeforeScrub = viewModel.isPlaying
                        viewModel.pause()
                    } else {
                        viewModel.seek(to: viewModel.currentTime)
                        if wasPlayingBeforeScrub {
                            viewModel.togglePlayback()
                        }
                    }
                }
            )

            HStack {
                Text(timeString(viewModel.currentTime))
                    .frame(width: 58, alignment: .leading)

                Spacer()

                Button {
                    viewModel.step(-1)
                } label: {
                    Label("上一帧", systemImage: "backward.frame.fill")
                        .labelStyle(.iconOnly)
                }

                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44)
                }

                Button {
                    viewModel.step(1)
                } label: {
                    Label("下一帧", systemImage: "forward.frame.fill")
                        .labelStyle(.iconOnly)
                }

                Spacer()

                Text("-" + timeString(max(0, viewModel.duration - viewModel.currentTime)))
                    .frame(width: 58, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())

            if viewModel.frameRate > 0 {
                Text(String(format: "逐帧：%.2f fps", viewModel.frameRate))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
