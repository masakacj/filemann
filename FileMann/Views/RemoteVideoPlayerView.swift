import SwiftUI

struct RemoteVideoPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteVideoPlayerViewModel

    @State private var gestureHUD: String?
    @State private var hudTask: Task<Void, Never>?

    init(
        entry: RemoteMediaEntry,
        settings: SMBSettings,
        password: String,
        baseURLString: String
    ) {
        _viewModel = StateObject(
            wrappedValue: RemoteVideoPlayerViewModel(
                entry: entry,
                settings: settings,
                password: password,
                preferredBaseURLString: baseURLString
            )
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

            if let error = viewModel.errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding()
                }
            }
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

            Text(viewModel.entry.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.secondary)
                .frame(width: 44)
        }
        .foregroundStyle(.white)
        .padding()
        .background(.black.opacity(0.5))
    }

    private func handleTap(
        _ region: VideoGestureRegion
    ) {
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

    private func handleLongPressEnded(
        _ region: VideoGestureRegion
    ) {
        switch region {
        case .left, .right:
            viewModel.endShuttle()
            showHUD(
                viewModel.isPlaying
                    ? "1× 播放"
                    : "暂停"
            )

        case .scrub:
            viewModel.endFrameScrub()
            showHUD(
                "帧 \(viewModel.currentFrame) / \(viewModel.totalFrames)"
            )

        case .center:
            break
        }
    }

    private func showScrubHUD() {
        let seconds = max(0, viewModel.currentTime)
        let whole = Int(seconds)
        let hundredths = Int(
            (seconds - Double(whole)) * 100
        )
        let time = String(
            format: "%d:%02d.%02d",
            whole / 60,
            whole % 60,
            hundredths
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
            try? await Task.sleep(
                nanoseconds: 650_000_000
            )
            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: 0.16)) {
                gestureHUD = nil
            }
        }
    }
}
