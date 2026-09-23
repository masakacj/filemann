import SwiftUI

struct VideoProgressOverlay: View {
    let currentTime: Double
    let duration: Double

    var body: some View {
        VStack(spacing: 7) {
            ProgressView(
                value: max(
                    0,
                    min(
                        currentTime,
                        max(duration, 0.001)
                    )
                ),
                total: max(
                    duration,
                    0.001
                )
            )
            .progressViewStyle(.linear)
            .tint(.white)

            HStack {
                Text(timeText(currentTime))
                Spacer()
                Text(timeText(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            .black.opacity(0.62),
            in: RoundedRectangle(
                cornerRadius: 12
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放进度")
        .accessibilityIdentifier("video-progress-overlay")
        .accessibilityValue(
            String(
                format: "current=%.3f;duration=%.3f",
                currentTime,
                duration
            )
        )
        .allowsHitTesting(false)
    }

    private func timeText(
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
