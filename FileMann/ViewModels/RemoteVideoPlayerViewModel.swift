import AVFoundation
import Foundation

@MainActor
final class RemoteVideoPlayerViewModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var frameRate: Double = 0
    @Published var isPlaying = false
    @Published var isFrameStepping = false
    @Published var errorMessage: String?

    let entry: RemoteMediaEntry
    let player: AVPlayer

    private let loader: WebDAVAssetResourceLoader
    private let asset: AVURLAsset
    private let loaderQueue = DispatchQueue(
        label: "FileMann.RemoteVideo.ResourceLoader"
    )

    private var timeObserver: Any?
    private var frameStepTask: Task<Void, Never>?
    private var scrubTask: Task<Void, Never>?
    private var lastScrubDispatchAt = Date.distantPast

    init(
        entry: RemoteMediaEntry,
        settings: SMBSettings,
        password: String,
        preferredBaseURLString: String
    ) {
        self.entry = entry
        self.loader = WebDAVAssetResourceLoader(
            path: entry.path,
            settings: settings,
            password: password,
            preferredBaseURLString:
                preferredBaseURLString
        )

        let virtualURL = URL(
            string:
                "filemann-webdav://stream/\(UUID().uuidString)"
        )!

        self.asset = AVURLAsset(url: virtualURL)
        self.asset.resourceLoader.setDelegate(
            loader,
            queue: loaderQueue
        )

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2.0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused =
            true

        self.player = AVPlayer(
            playerItem: item
        )
        self.player.automaticallyWaitsToMinimizeStalling =
            true

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
                    self.currentTime = max(
                        0,
                        value
                    )
                }
                self.isPlaying =
                    self.player.rate != 0
            }
        }

        Task {
            await loadMetadata()
        }
    }

    deinit {
        frameStepTask?.cancel()
        scrubTask?.cancel()

        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    var currentFrame: Int {
        let fps = frameRate > 0 ? frameRate : 30
        return max(
            0,
            Int((currentTime * fps).rounded())
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

    func step(
        _ count: Int
    ) {
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
                    nanoseconds: 100_000_000
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
        ) >= 0.055 else {
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

    private func stopFrameStepping() {
        frameStepTask?.cancel()
        frameStepTask = nil
        isFrameStepping = false
    }

    private func seekByFrames(
        _ count: Int
    ) async {
        let fps = frameRate > 0 ? frameRate : 30
        let target = currentTime +
            Double(count) / fps

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
