import AVFoundation
import Foundation

@MainActor
final class VideoEditorViewModel: ObservableObject {
    @Published var adjustments: MediaAdjustments = .neutral
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var frameRate: Double = 0
    @Published var isPlaying = false
    @Published var isShuttling = false
    @Published var errorMessage: String?

    let url: URL
    let player: AVPlayer

    private let asset: AVURLAsset
    private var timeObserver: Any?
    private var filterTask: Task<Void, Never>?
    private var reverseTask: Task<Void, Never>?
    private var wasPlayingBeforeShuttle = false

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
        reverseTask?.cancel()
        filterTask?.cancel()
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
        endShuttle()
        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func pause() {
        reverseTask?.cancel()
        reverseTask = nil
        player.pause()
        isPlaying = false
        isShuttling = false
    }

    func step(_ count: Int) {
        reverseTask?.cancel()
        reverseTask = nil
        player.pause()
        isPlaying = false
        isShuttling = false
        player.currentItem?.step(byCount: count)
        currentTime = max(0, CMTimeGetSeconds(player.currentTime()))
    }

    func beginReverseShuttle() {
        endShuttle()
        wasPlayingBeforeShuttle = player.rate != 0
        player.pause()
        isPlaying = false
        isShuttling = true

        reverseTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                let stepSeconds = 0.075
                let target = max(0, self.currentTime - stepSeconds)
                self.seekPrecisely(to: target)

                if target <= 0 {
                    break
                }

                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    func beginForwardShuttle() {
        endShuttle()
        wasPlayingBeforeShuttle = player.rate != 0
        player.play()
        player.rate = 1.5
        isPlaying = true
        isShuttling = true
    }

    func endShuttle() {
        reverseTask?.cancel()
        reverseTask = nil

        guard isShuttling else { return }

        if wasPlayingBeforeShuttle {
            player.play()
            player.rate = 1.0
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }

        isShuttling = false
    }

    func beginFrameScrub() {
        endShuttle()
        player.pause()
        isPlaying = false
    }

    func scrubFrames(to fraction: CGFloat) {
        guard duration > 0 else { return }

        let clamped = max(0, min(1, Double(fraction)))
        if frameRate > 0 {
            let frame = Int((Double(totalFrames) * clamped).rounded())
            seekToFrame(frame)
        } else {
            seekPrecisely(to: duration * clamped)
        }
    }

    func endFrameScrub() {
        player.pause()
        isPlaying = false
    }

    func reset() {
        adjustments = .neutral
        scheduleFilterUpdate(immediate: true)
    }

    func adjustmentsDidChange() {
        scheduleFilterUpdate(immediate: false)
    }

    private func seekToFrame(_ frame: Int) {
        guard frameRate > 0 else { return }
        let value = max(0, min(totalFrames, frame))
        seekPrecisely(to: Double(value) / frameRate)
    }

    private func seekPrecisely(to seconds: Double) {
        let clamped = max(0, min(duration, seconds))
        currentTime = clamped
        let target = CMTime(seconds: clamped, preferredTimescale: 60_000)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func scheduleFilterUpdate(immediate: Bool) {
        filterTask?.cancel()

        let adjustments = self.adjustments
        let asset = self.asset
        let playerItem = self.player.currentItem

        filterTask = Task {
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
