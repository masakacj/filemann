import SwiftUI

struct VideoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: VideoEditorViewModel

    @State private var selectedParameterID = "exposure"
    @State private var showAdjustments = false
    @State private var gestureHUD: String?
    @State private var hudTask: Task<Void, Never>?

    init(url: URL) {
        _viewModel = StateObject(wrappedValue: VideoEditorViewModel(url: url))
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let gestureHUD {
                Text(gestureHUD)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: Capsule())
                    .allowsHitTesting(false)
            }

            if showAdjustments {
                VStack {
                    Spacer()

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
                .ignoresSafeArea(edges: .bottom)
            }

            VStack {
                Spacer()

                HStack {
                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showAdjustments.toggle()
                        }
                    } label: {
                        Image(systemName: showAdjustments ? "xmark" : "slider.horizontal.3")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(.black.opacity(0.58), in: Circle())
                    }
                    .accessibilityLabel(showAdjustments ? "关闭视频调整" : "打开视频调整")
                }
                .padding(.trailing, 18)
                .padding(
                    .bottom,
                    showAdjustments ? 172 : 18
                )
            }
            .allowsHitTesting(true)
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            hudTask?.cancel()
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
                .frame(width: 44, height: 1)
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.5))
    }

    private func handleTap(_ region: VideoGestureRegion) {
        switch region {
        case .left:
            viewModel.step(-1)
            showHUD("−1 帧")
        case .center:
            let willPlay = !viewModel.isPlaying
            viewModel.togglePlayback()
            showHUD(willPlay ? "播放" : "暂停")
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
        switch region {
        case .left:
            viewModel.beginReverseShuttle()
            showHUD("1.5× 倒退", persistent: true)

        case .right:
            viewModel.beginForwardShuttle()
            showHUD("1.5× 快进", persistent: true)

        case .scrub:
            viewModel.beginFrameScrub()
            viewModel.scrubFrames(to: fraction)
            showScrubHUD()

        case .center:
            break
        }
    }

    private func handleLongPressChanged(
        _ region: VideoGestureRegion,
        fraction: CGFloat
    ) {
        guard region == .scrub else { return }
        viewModel.scrubFrames(to: fraction)
        showScrubHUD()
    }

    private func handleLongPressEnded(_ region: VideoGestureRegion) {
        switch region {
        case .left, .right:
            viewModel.endShuttle()
            showHUD(
                viewModel.isPlaying ? "1× 播放" : "暂停",
                persistent: false
            )

        case .scrub:
            viewModel.endFrameScrub()
            showHUD(
                "帧 \(viewModel.currentFrame) / \(viewModel.totalFrames)",
                persistent: false
            )

        case .center:
            hideHUD()
        }
    }

    private func showScrubHUD() {
        let seconds = max(0, viewModel.currentTime)
        let whole = Int(seconds)
        let milliseconds = Int((seconds - Double(whole)) * 100)
        let time = String(
            format: "%d:%02d.%02d",
            whole / 60,
            whole % 60,
            milliseconds
        )

        showHUD(
            "帧 \(viewModel.currentFrame) / \(viewModel.totalFrames)  ·  \(time)",
            persistent: true
        )
    }

    private func showHUD(
        _ text: String,
        persistent: Bool = false
    ) {
        hudTask?.cancel()
        gestureHUD = text

        guard !persistent else { return }

        hudTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                gestureHUD = nil
            }
        }
    }

    private func hideHUD() {
        hudTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            gestureHUD = nil
        }
    }
}
