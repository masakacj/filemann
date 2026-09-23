import AVFoundation
import Foundation

@MainActor
final class VideoEditorViewModel: ObservableObject {
    @Published var adjustments: MediaAdjustments = .neutral
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var frameRate: Double = 0
    @Published var isPlaying = false
    @Published var isFrameStepping = false
    @Published var errorMessage: String?

    let url: URL
    let player: AVPlayer

    private let asset: AVURLAsset
    private var timeObserver: Any?
    private var filterTask: Task<Void, Never>?
    private var frameStepTask: Task<Void, Never>?
    private var scrubTask: Task<Void, Never>?
    private var lastScrubDispatchAt = Date.distantPast

    init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 1.5

        self.player = AVPlayer(playerItem: item)
        self.player.automaticallyWaitsToMinimizeStalling = false

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self,
                      !self.isFrameStepping else {
                    return
                }

                let value = CMTimeGetSeconds(time)
                if value.isFinite {
                    self.currentTime = max(0, value)
                }
                self.isPlaying = self.player.rate != 0
            }
        }

        Task {
            await loadMetadata()
        }
    }

    deinit {
        frameStepTask?.cancel()
        scrubTask?.cancel()
        filterTask?.cancel()

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    var currentFrame: Int {
        guard frameRate > 0 else {
            return max(
                0,
                Int((currentTime * 30).rounded())
            )
        }

        return max(
            0,
            Int((currentTime * frameRate).rounded())
        )
    }

    var totalFrames: Int {
        guard duration > 0 else { return 0 }
        let fps = frameRate > 0 ? frameRate : 30
        return max(
            0,
            Int((duration * fps).rounded())
        )
    }

    func togglePlayback() {
        stopFrameStepping()
        scrubTask?.cancel()
        scrubTask = nil

        if player.rate == 0 {
            player.play()
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
    }

    func pause() {
        stopFrameStepping()
        scrubTask?.cancel()
        scrubTask = nil
        player.pause()
        isPlaying = false
    }

    func step(_ count: Int) {
        guard count != 0 else { return }

        stopFrameStepping()
        player.pause()
        isPlaying = false

        Task {
            await seekByFrames(count)
        }
    }

    func beginContinuousFrameStep(
        direction: Int
    ) {
        guard direction != 0 else { return }

        stopFrameStepping()
        scrubTask?.cancel()
        scrubTask = nil

        player.pause()
        isPlaying = false
        isFrameStepping = true

        frameStepTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await self.seekByFrames(direction)

            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: 85_000_000
                )
                guard !Task.isCancelled else {
                    break
                }

                await self.seekByFrames(direction)
            }
        }
    }

    func endContinuousFrameStep() {
        stopFrameStepping()
        player.pause()
        isPlaying = false
    }

    func beginScrub() {
        stopFrameStepping()
        scrubTask?.cancel()
        scrubTask = nil

        player.pause()
        isPlaying = false
        lastScrubDispatchAt = .distantPast
    }

    func scrub(
        to fraction: CGFloat
    ) {
        guard duration > 0 else { return }

        let clamped = max(
            0,
            min(1, Double(fraction))
        )
        let target = duration * clamped
        currentTime = target

        let now = Date()
        guard now.timeIntervalSince(
            lastScrubDispatchAt
        ) >= 0.04 else {
            return
        }

        lastScrubDispatchAt = now
        scheduleRealtimeSeek(to: target)
    }

    func endScrub() {
        player.pause()
        isPlaying = false
        scheduleRealtimeSeek(
            to: currentTime,
            force: true
        )
    }

    func reset() {
        adjustments = .neutral
        scheduleFilterUpdate(immediate: true)
    }

    func adjustmentsDidChange() {
        scheduleFilterUpdate(immediate: false)
    }

    private func stopFrameStepping() {
        frameStepTask?.cancel()
        frameStepTask = nil
        isFrameStepping = false
    }

    private func seekByFrames(
        _ count: Int
    ) async {
        let fps = frameRate > 0 ? frameRate : 30
        let frameSeconds = 1.0 / fps
        let target = currentTime +
            Double(count) * frameSeconds

        await seekAndWait(
            to: target
        )
    }

    private func scheduleRealtimeSeek(
        to seconds: Double,
        force: Bool = false
    ) {
        scrubTask?.cancel()

        if force {
            player.currentItem?.cancelPendingSeeks()
        }

        scrubTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.seekAndWait(to: seconds)
        }
    }

    private func seekAndWait(
        to seconds: Double
    ) async {
        let clamped = max(
            0,
            min(duration > 0 ? duration : seconds, seconds)
        )
        currentTime = clamped

        let target = CMTime(
            seconds: clamped,
            preferredTimescale: 60_000
        )

        await withCheckedContinuation { continuation in
            player.seek(
                to: target,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }

        let actual = CMTimeGetSeconds(
            player.currentTime()
        )
        if actual.isFinite {
            currentTime = max(0, actual)
        }
    }

    private func scheduleFilterUpdate(
        immediate: Bool
    ) {
        filterTask?.cancel()

        let adjustments = self.adjustments
        let asset = self.asset
        let playerItem = self.player.currentItem

        filterTask = Task {
            if !immediate {
                try? await Task.sleep(
                    nanoseconds: 150_000_000
                )
            }

            guard !Task.isCancelled else { return }

            if adjustments.isNeutral {
                playerItem?.videoComposition = nil
                return
            }

            do {
                let composition = try await AVVideoComposition
                    .videoComposition(
                        with: asset
                    ) { request in
                        let output = MediaFilterPipeline.apply(
                            to: request.sourceImage,
                            adjustments: adjustments
                        )
                        request.finish(
                            with: output,
                            context: nil
                        )
                    }

                guard !Task.isCancelled else { return }
                playerItem?.videoComposition = composition
            } catch {
                errorMessage =
                    "视频调整预览失败：\(error.localizedDescription)"
            }
        }
    }

    private func loadMetadata() async {
        do {
            let loadedDuration = try await asset.load(
                .duration
            )
            duration = max(
                0,
                CMTimeGetSeconds(loadedDuration)
            )

            if let track = try await asset
                .loadTracks(withMediaType: .video)
                .first {
                frameRate = Double(
                    try await track.load(.nominalFrameRate)
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
