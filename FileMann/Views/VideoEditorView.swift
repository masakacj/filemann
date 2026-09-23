import SwiftUI

struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: VideoEditorViewModel

    @State private var selectedParameterID = "exposure"
    @State private var showAdjustments = false
    @State private var gestureHUD: String?
    @State private var hudTask: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?

    init(url: URL) {
        _viewModel = StateObject(
            wrappedValue: VideoEditorViewModel(url: url)
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                ZoomablePlayerView(
                    player: viewModel.player,
                    onTap: handleTap,
                    onLongPressBegan: handleLongPressBegan,
                    onLongPressChanged: handleLongPressChanged,
                    onLongPressEnded: handleLongPressEnded
                )
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }

            if let gestureHUD {
                Text(gestureHUD)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        .black.opacity(0.55),
                        in: Capsule()
                    )
                    .allowsHitTesting(false)
            }

            if showAdjustments {
                VStack {
                    Spacer()

                    AdjustmentPanel(
                        adjustments: $viewModel.adjustments,
                        selectedParameterID:
                            $selectedParameterID,
                        onChange: {
                            viewModel.adjustmentsDidChange()
                            showControls()
                        },
                        onReset: {
                            viewModel.reset()
                            showControls()
                        }
                    )
                    .transition(
                        .move(edge: .bottom)
                        .combined(with: .opacity)
                    )
                }
                .ignoresSafeArea(edges: .bottom)
            }

            if controlsVisible {
                VStack {
                    Spacer()

                    VideoProgressOverlay(
                        currentTime: viewModel.currentTime,
                        duration: viewModel.duration
                    )
                    .padding(.horizontal, 14)
                    .padding(
                        .bottom,
                        showAdjustments ? 190 : 16
                    )
                    .transition(.opacity)
                }
                .allowsHitTesting(false)
            }

            VStack {
                Spacer()

                HStack {
                    Spacer()

                    Button {
                        withAnimation(
                            .easeInOut(duration: 0.18)
                        ) {
                            showAdjustments.toggle()
                        }
                        showControls()
                    } label: {
                        Image(
                            systemName: showAdjustments
                                ? "xmark"
                                : "slider.horizontal.3"
                        )
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(
                            width: 48,
                            height: 48
                        )
                        .background(
                            .black.opacity(0.58),
                            in: Circle()
                        )
                    }
                    .accessibilityLabel(
                        showAdjustments
                            ? "关闭视频调整"
                            : "打开视频调整"
                    )
                }
                .padding(.trailing, 18)
                .padding(
                    .bottom,
                    showAdjustments ? 188 : 76
                )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            showControls()
        }
        .onDisappear {
            hudTask?.cancel()
            controlsHideTask?.cancel()
            viewModel.pause()
        }
    }

    private var topBar: some View {
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
                .frame(
                    width: 44,
                    height: 1
                )
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.5))
    }

    private func handleTap(
        _ region: VideoGestureRegion
    ) {
        showControls()

        switch region {
        case .left:
            viewModel.step(-1)
            showHUD("−1 帧")

        case .center:
            let willPlay = !viewModel.isPlaying
            viewModel.togglePlayback()
            showHUD(
                willPlay
                    ? "播放"
                    : "暂停"
            )

        case .right:
            viewModel.step(1)
            showHUD("+1 帧")

        case .scrub:
            break
        }
    }

    private func handleLongPressBegan(
        _ region: VideoGestureRegion,
        fraction: CGFloat
    ) {
        showControls(autoHide: false)

        switch region {
        case .left:
            viewModel.beginContinuousFrameStep(
                direction: -1
            )
            showHUD(
                "逐帧倒退",
                persistent: true
            )

        case .right:
            viewModel.beginContinuousFrameStep(
                direction: 1
            )
            showHUD(
                "逐帧前进",
                persistent: true
            )

        case .scrub:
            viewModel.beginScrub()
            viewModel.scrub(to: fraction)
            showScrubHUD()

        case .center:
            break
        }
    }

    private func handleLongPressChanged(
        _ region: VideoGestureRegion,
        fraction: CGFloat
    ) {
        showControls(autoHide: false)

        guard region == .scrub else {
            return
        }

        viewModel.scrub(to: fraction)
        showScrubHUD()
    }

    private func handleLongPressEnded(
        _ region: VideoGestureRegion
    ) {
        switch region {
        case .left, .right:
            viewModel.endContinuousFrameStep()
            showHUD("暂停")

        case .scrub:
            viewModel.endScrub()
            showScrubHUD(
                persistent: false
            )

        case .center:
            hideHUD()
        }

        showControls()
    }

    private func showScrubHUD(
        persistent: Bool = true
    ) {
        showHUD(
            "\(timeString(viewModel.currentTime)) / " +
            "\(timeString(viewModel.duration))",
            persistent: persistent
        )
    }

    private func showControls(
        autoHide: Bool = true
    ) {
        controlsHideTask?.cancel()

        withAnimation(
            .easeOut(duration: 0.15)
        ) {
            controlsVisible = true
        }

        guard autoHide else {
            return
        }

        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: 5_000_000_000
            )
            guard !Task.isCancelled else {
                return
            }

            withAnimation(
                .easeOut(duration: 0.22)
            ) {
                controlsVisible = false
            }
        }
    }

    private func showHUD(
        _ text: String,
        persistent: Bool = false
    ) {
        hudTask?.cancel()
        gestureHUD = text

        guard !persistent else {
            return
        }

        hudTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: 700_000_000
            )
            guard !Task.isCancelled else {
                return
            }

            withAnimation(
                .easeOut(duration: 0.16)
            ) {
                gestureHUD = nil
            }
        }
    }

    private func hideHUD() {
        hudTask?.cancel()

        withAnimation(
            .easeOut(duration: 0.16)
        ) {
            gestureHUD = nil
        }
    }

    private func timeString(
        _ value: Double
    ) -> String {
        guard value.isFinite else {
            return "0:00"
        }

        let seconds = max(
            0,
            Int(value.rounded(.down))
        )

        if seconds >= 3600 {
            return String(
                format: "%d:%02d:%02d",
                seconds / 3600,
                (seconds % 3600) / 60,
                seconds % 60
            )
        }

        return String(
            format: "%d:%02d",
            seconds / 60,
            seconds % 60
        )
    }
}
