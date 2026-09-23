import AVFoundation
import SwiftUI
import UIKit

enum VideoGestureRegion {
    case left
    case center
    case right
    case scrub
}

struct ZoomablePlayerView: UIViewRepresentable {
    let player: AVPlayer
    let onTap: (VideoGestureRegion) -> Void
    let onLongPressBegan: (VideoGestureRegion, CGFloat) -> Void
    let onLongPressChanged: (VideoGestureRegion, CGFloat) -> Void
    let onLongPressEnded: (VideoGestureRegion) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTap: onTap,
            onLongPressBegan: onLongPressBegan,
            onLongPressChanged: onLongPressChanged,
            onLongPressEnded: onLongPressEnded
        )
    }

    func makeUIView(context: Context) -> ZoomPlayerContainerView {
        let view = ZoomPlayerContainerView()
        view.setPlayer(player)
        context.coordinator.install(on: view)
        return view
    }

    func updateUIView(_ uiView: ZoomPlayerContainerView, context: Context) {
        uiView.setPlayer(player)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let onTap: (VideoGestureRegion) -> Void
        private let onLongPressBegan: (VideoGestureRegion, CGFloat) -> Void
        private let onLongPressChanged: (VideoGestureRegion, CGFloat) -> Void
        private let onLongPressEnded: (VideoGestureRegion) -> Void
        private var activeRegion: VideoGestureRegion?

        init(
            onTap: @escaping (VideoGestureRegion) -> Void,
            onLongPressBegan: @escaping (VideoGestureRegion, CGFloat) -> Void,
            onLongPressChanged: @escaping (VideoGestureRegion, CGFloat) -> Void,
            onLongPressEnded: @escaping (VideoGestureRegion) -> Void
        ) {
            self.onTap = onTap
            self.onLongPressBegan = onLongPressBegan
            self.onLongPressChanged = onLongPressChanged
            self.onLongPressEnded = onLongPressEnded
        }

        func install(on view: ZoomPlayerContainerView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            view.addGestureRecognizer(tap)

            let longPress = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            longPress.minimumPressDuration = 0.28
            longPress.allowableMovement = 10_000
            longPress.delegate = self
            view.addGestureRecognizer(longPress)
        }

        @objc
        private func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            let region = classify(point: point, in: view.bounds)

            // The lower strip is reserved for long-press frame scrubbing.
            // A normal tap there behaves like a center tap.
            onTap(region == .scrub ? .center : region)
        }

        @objc
        private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let point = recognizer.location(in: view)
            let fraction = max(0, min(1, point.x / max(1, view.bounds.width)))

            switch recognizer.state {
            case .began:
                let region = classify(point: point, in: view.bounds)
                activeRegion = region
                onLongPressBegan(region, fraction)

            case .changed:
                guard let activeRegion else { return }
                onLongPressChanged(activeRegion, fraction)

            case .ended, .cancelled, .failed:
                if let activeRegion {
                    onLongPressEnded(activeRegion)
                }
                activeRegion = nil

            default:
                break
            }
        }

        private func classify(
            point: CGPoint,
            in bounds: CGRect
        ) -> VideoGestureRegion {
            if point.y >= bounds.height * 0.72 {
                return .scrub
            }

            if point.x < bounds.width / 3 {
                return .left
            }

            if point.x > bounds.width * 2 / 3 {
                return .right
            }

            return .center
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

final class ZoomPlayerContainerView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let canvas = PlayerCanvasView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 8
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        scrollView.delaysContentTouches = false

        addSubview(scrollView)
        scrollView.addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds

        if scrollView.zoomScale == 1 {
            canvas.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
        }

        canvas.setNeedsLayout()
        centerCanvas()
    }

    func setPlayer(_ player: AVPlayer) {
        canvas.playerLayer.player = player
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        canvas
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerCanvas()
    }

    private func centerCanvas() {
        let boundsSize = scrollView.bounds.size
        var frame = canvas.frame

        frame.origin.x = frame.size.width < boundsSize.width
            ? (boundsSize.width - frame.size.width) / 2
            : 0
        frame.origin.y = frame.size.height < boundsSize.height
            ? (boundsSize.height - frame.size.height) / 2
            : 0

        canvas.frame = frame
    }
}

final class PlayerCanvasView: UIView {
    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
