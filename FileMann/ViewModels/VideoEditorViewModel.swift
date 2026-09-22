import AVFoundation
import Foundation

@MainActor
final class VideoEditorViewModel: ObservableObject {
    @Published var adjustments: MediaAdjustments = .neutral
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var frameRate: Double = 0
    @Published var isPlaying = false
    @Published var isFastForwarding = false
    @Published var errorMessage: String?

    let url: URL
    let player: AVPlayer

    private let asset: AVURLAsset
    private var timeObserver: Any?
    private var filterTask: Task<Void, Never>?
    private var wasPlayingBeforeFastForward = false

    init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)
        self.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = max(0, CMTimeGetSeconds(time))
                self.isPlaying = self.player.rate != 0
            }
        }

        Task {
            await loadMetadata()
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    var currentFrame: Int {
        guard frameRate > 0 else { return 0 }
        return max(0, Int((currentTime * frameRate).rounded()))
    }

    var totalFrames: Int {
        guard frameRate > 0, duration > 0 else { return 0 }
        return max(0, Int((duration * frameRate).rounded()))
    }

    func togglePlayback() {
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
        isFastForwarding = false
    }

    func step(_ count: Int) {
        player.pause()
        isPlaying = false
        isFastForwarding = false
        player.currentItem?.step(byCount: count)
        currentTime = max(0, CMTimeGetSeconds(player.currentTime()))
    }

    func seek(to seconds: Double) {
        let target = CMTime(
            seconds: max(0, min(duration, seconds)),
            preferredTimescale: 600
        )
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func beginFastForward() {
        guard !isFastForwarding else { return }
        wasPlayingBeforeFastForward = player.rate != 0

        if !wasPlayingBeforeFastForward {
            player.play()
        }
        player.rate = 2.0
        isPlaying = true
        isFastForwarding = true
    }

    func endFastForward() {
        guard isFastForwarding else { return }

        if wasPlayingBeforeFastForward {
            player.rate = 1.0
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        isFastForwarding = false
    }

    func reset() {
        adjustments = .neutral
        scheduleFilterUpdate(immediate: true)
    }

    func adjustmentsDidChange() {
        scheduleFilterUpdate(immediate: false)
    }

    private func scheduleFilterUpdate(immediate: Bool) {
        filterTask?.cancel()

        let adjustments = self.adjustments
        let asset = self.asset
        let playerItem = self.player.currentItem

        filterTask = Task {
            // Video adjustments are intentionally session-only.
            // Do not write a sidecar or touch the original file.
            if !immediate {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled else { return }

            if adjustments.isNeutral {
                playerItem?.videoComposition = nil
                return
            }

            do {
                let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
                    let output = MediaFilterPipeline.apply(
                        to: request.sourceImage,
                        adjustments: adjustments
                    )
                    request.finish(with: output, context: nil)
                }

                guard !Task.isCancelled else { return }
                playerItem?.videoComposition = composition
            } catch {
                errorMessage = "视频调整预览失败：\(error.localizedDescription)"
            }
        }
    }

    private func loadMetadata() async {
        do {
            let loadedDuration = try await asset.load(.duration)
            duration = max(0, CMTimeGetSeconds(loadedDuration))

            if let track = try await asset.loadTracks(withMediaType: .video).first {
                frameRate = Double(try await track.load(.nominalFrameRate))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
