import SwiftUI
import UIKit

struct RemoteVideoPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteVideoPlayerViewModel

    @State private var gestureHUD: String?
    @State private var hudTask: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var posterImage: UIImage?

    private let settings: SMBSettings
    private let password: String
    private let baseURLString: String

    init(
        entry: RemoteMediaEntry,
        settings: SMBSettings,
        password: String,
        baseURLString: String
    ) {
        self.settings = settings
        self.password = password
        self.baseURLString = baseURLString

        _viewModel = StateObject(
            wrappedValue: RemoteVideoPlayerViewModel(
                entry: entry,
                settings: settings,
                password: password,
                preferredBaseURLString:
                    baseURLString
            )
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                ZStack {
                    ZoomablePlayerView(
                        player: viewModel.player,
                        onTap: handleTap,
                        onLongPressBegan:
                            handleLongPressBegan,
                        onLongPressChanged:
                            handleLongPressChanged,
                        onLongPressEnded:
                            handleLongPressEnded
                    )
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )

                    if let posterImage,
                       viewModel.currentTime < 0.01 {
                        Image(uiImage: posterImage)
                            .resizable()
                            .scaledToFit()
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity
                            )
                            .background(Color.black)
                            .allowsHitTesting(false)
                    }
                }
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

            if controlsVisible {
                VStack {
                    Spacer()

                    VideoProgressOverlay(
                        currentTime: viewModel.currentTime,
                        duration: viewModel.duration
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                    .transition(.opacity)
                }
                .allowsHitTesting(false)
            }

            if let error = viewModel.errorMessage {
                VStack {
                    Spacer()

                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal)
                        .padding(.bottom, 74)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            showControls()
        }
        .task {
            posterImage = await RemoteThumbnailStore.shared.load(
                entry: viewModel.entry,
                settings: settings,
                password: password,
                baseURLString: baseURLString,
                maxPixelSize: 1280
            )
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

            Text(viewModel.entry.name)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            Image(
                systemName:
                    "icloud.and.arrow.down"
            )
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
