import AVFoundation
import SwiftUI
import UIKit

struct ZoomablePlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> ZoomPlayerContainerView {
        let view = ZoomPlayerContainerView()
        view.setPlayer(player)
        return view
    }

    func updateUIView(_ uiView: ZoomPlayerContainerView, context: Context) {
        uiView.setPlayer(player)
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
