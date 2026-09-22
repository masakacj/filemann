import SwiftUI

struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: VideoEditorViewModel
    @State private var selectedParameterID = "exposure"
    @State private var wasPlayingBeforeScrub = false
    @State private var showAdjustments = false
    @State private var longPressFastForwardActive = false

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

                Color.clear
                    .frame(width: 44, height: 1)
            }
            .padding()
            .background(.ultraThinMaterial)

            ZStack(alignment: .topTrailing) {
                Color.black

                ZoomablePlayerView(player: viewModel.player)
                    .contentShape(Rectangle())
                    .onLongPressGesture(
                        minimumDuration: 0.35,
                        maximumDistance: 60,
                        pressing: { pressing in
                            if !pressing, longPressFastForwardActive {
                                longPressFastForwardActive = false
                                viewModel.endFastForward()
                            }
                        },
                        perform: {
                            longPressFastForwardActive = true
                            viewModel.beginFastForward()
                        }
                    )

                VStack(alignment: .trailing, spacing: 6) {
                    Text("双指局部放大 · 长按 2×")
                        .font(.caption2)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Capsule())

                    if viewModel.isFastForwarding {
                        Text("2×")
                            .font(.headline.monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
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

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showAdjustments.toggle()
                }
            } label: {
                HStack {
                    Label("视频调整", systemImage: "slider.horizontal.3")
                    Spacer()
                    Text("仅本次播放")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: showAdjustments ? "chevron.down" : "chevron.up")
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial)

            if showAdjustments {
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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

                RepeatFrameButton(direction: -1) {
                    viewModel.step(-1)
                }

                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44)
                }

                RepeatFrameButton(direction: 1) {
                    viewModel.step(1)
                }

                Spacer()

                Text("-" + timeString(max(0, viewModel.duration - viewModel.currentTime)))
                    .frame(width: 58, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())

            if viewModel.frameRate > 0 {
                HStack {
                    Text(String(format: "%.2f fps", viewModel.frameRate))
                    Spacer()
                    Text("帧 \(viewModel.currentFrame) / \(viewModel.totalFrames)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text("点按上一帧/下一帧精确逐帧；按住可连续逐帧")
                .font(.caption2)
                .foregroundStyle(.secondary)
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

private struct RepeatFrameButton: View {
    let direction: Int
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Button {
            action()
        } label: {
            Label(
                direction < 0 ? "上一帧" : "下一帧",
                systemImage: direction < 0 ? "backward.frame.fill" : "forward.frame.fill"
            )
            .labelStyle(.iconOnly)
            .frame(width: 36, height: 34)
            .contentShape(Rectangle())
        }
        .onLongPressGesture(
            minimumDuration: 0.35,
            maximumDistance: 50,
            pressing: { pressing in
                if !pressing {
                    stopRepeating()
                }
            },
            perform: {
                startRepeating()
            }
        )
        .onDisappear {
            stopRepeating()
        }
    }

    private func startRepeating() {
        stopRepeating()
        action()

        repeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 75_000_000)
                guard !Task.isCancelled else { break }
                action()
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
