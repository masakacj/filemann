import CoreImage
import Foundation

struct MediaAdjustments: Codable, Equatable, Sendable {
    var exposure: Double = 0
    var brilliance: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var contrast: Double = 0
    var brightness: Double = 0
    var blackPoint: Double = 0
    var saturation: Double = 0
    var vibrance: Double = 0
    var warmth: Double = 0
    var tint: Double = 0
    var sharpness: Double = 0
    var definition: Double = 0
    var vignette: Double = 0

    static let neutral = MediaAdjustments()

    var isNeutral: Bool {
        self == .neutral
    }
}

struct AdjustmentParameter: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let range: ClosedRange<Double>
    let keyPath: WritableKeyPath<MediaAdjustments, Double>

    static let all: [AdjustmentParameter] = [
        .init(id: "exposure", title: "曝光", systemImage: "plusminus.circle", range: -2...2, keyPath: \.exposure),
        .init(id: "brilliance", title: "鲜明度", systemImage: "sun.max", range: -1...1, keyPath: \.brilliance),
        .init(id: "highlights", title: "高光", systemImage: "sun.max.fill", range: -1...1, keyPath: \.highlights),
        .init(id: "shadows", title: "阴影", systemImage: "circle.lefthalf.filled", range: -1...1, keyPath: \.shadows),
        .init(id: "contrast", title: "对比度", systemImage: "circle.righthalf.filled", range: -1...1, keyPath: \.contrast),
        .init(id: "brightness", title: "亮度", systemImage: "sun.min", range: -1...1, keyPath: \.brightness),
        .init(id: "blackPoint", title: "黑点", systemImage: "circle.fill", range: 0...1, keyPath: \.blackPoint),
        .init(id: "saturation", title: "饱和度", systemImage: "drop.fill", range: -1...1, keyPath: \.saturation),
        .init(id: "vibrance", title: "自然饱和度", systemImage: "paintpalette", range: -1...1, keyPath: \.vibrance),
        .init(id: "warmth", title: "色温", systemImage: "thermometer.medium", range: -1...1, keyPath: \.warmth),
        .init(id: "tint", title: "色调", systemImage: "eyedropper", range: -1...1, keyPath: \.tint),
        .init(id: "sharpness", title: "锐度", systemImage: "triangle", range: 0...1, keyPath: \.sharpness),
        .init(id: "definition", title: "清晰度", systemImage: "circle.dotted", range: 0...1, keyPath: \.definition),
        .init(id: "vignette", title: "晕影", systemImage: "circle.dashed.inset.filled", range: 0...1, keyPath: \.vignette)
    ]
}

enum MediaFilterPipeline {
    static func apply(to input: CIImage, adjustments: MediaAdjustments) -> CIImage {
        var image = input
        let extent = input.extent

        if abs(adjustments.exposure) > 0.0001 {
            image = image.applyingFilter(
                "CIExposureAdjust",
                parameters: [kCIInputEVKey: adjustments.exposure]
            )
        }

        let effectiveShadow = clamp(
            0,
            1,
            0.5 + (adjustments.shadows * 0.5) + (adjustments.brilliance * 0.20)
        )
        let effectiveHighlight = clamp(
            0,
            1,
            1.0 - (adjustments.highlights * 0.75) - (adjustments.brilliance * 0.12)
        )

        if abs(adjustments.shadows) > 0.0001 ||
            abs(adjustments.highlights) > 0.0001 ||
            abs(adjustments.brilliance) > 0.0001 {
            image = image.applyingFilter(
                "CIHighlightShadowAdjust",
                parameters: [
                    "inputShadowAmount": effectiveShadow,
                    "inputHighlightAmount": effectiveHighlight
                ]
            )
        }

        let saturation = max(
            0,
            1 + adjustments.saturation + (adjustments.brilliance * 0.08)
        )
        let brightness = adjustments.brightness * 0.35 + adjustments.brilliance * 0.04
        let contrast = max(
            0.25,
            1 + adjustments.contrast * 0.55 + adjustments.brilliance * 0.10
        )

        if abs(saturation - 1) > 0.0001 ||
            abs(brightness) > 0.0001 ||
            abs(contrast - 1) > 0.0001 {
            image = image.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: saturation,
                    kCIInputBrightnessKey: brightness,
                    kCIInputContrastKey: contrast
                ]
            )
        }

        if abs(adjustments.vibrance) > 0.0001 {
            image = image.applyingFilter(
                "CIVibrance",
                parameters: ["inputAmount": adjustments.vibrance]
            )
        }

        if abs(adjustments.warmth) > 0.0001 || abs(adjustments.tint) > 0.0001 {
            let neutral = CIVector(x: 6500, y: 0)
            let target = CIVector(
                x: 6500 + adjustments.warmth * 2200,
                y: adjustments.tint * 110
            )
            image = image.applyingFilter(
                "CITemperatureAndTint",
                parameters: [
                    "inputNeutral": neutral,
                    "inputTargetNeutral": target
                ]
            )
        }

        if adjustments.blackPoint > 0.0001 {
            let amount = adjustments.blackPoint
            image = image.applyingFilter(
                "CIToneCurve",
                parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0),
                    "inputPoint1": CIVector(x: 0.25 + amount * 0.08, y: 0.25),
                    "inputPoint2": CIVector(x: 0.5, y: 0.5),
                    "inputPoint3": CIVector(x: 0.75, y: 0.75),
                    "inputPoint4": CIVector(x: 1, y: 1)
                ]
            )
        }

        let sharpen = adjustments.sharpness * 1.2 + adjustments.definition * 0.9
        if sharpen > 0.0001 {
            image = image.applyingFilter(
                "CISharpenLuminance",
                parameters: [
                    kCIInputSharpnessKey: sharpen,
                    "inputRadius": 1.2 + adjustments.definition * 2.5
                ]
            )
        }

        if adjustments.vignette > 0.0001 {
            image = image.applyingFilter(
                "CIVignette",
                parameters: [
                    kCIInputIntensityKey: adjustments.vignette * 1.6,
                    kCIInputRadiusKey: min(extent.width, extent.height) * 0.45
                ]
            )
        }

        return image.cropped(to: extent)
    }

    private static func clamp(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
        min(upper, max(lower, value))
    }
}

enum MediaSidecarStore {
    static func load(for mediaURL: URL) -> MediaAdjustments {
        guard let sidecarURL = try? FileMannShared.sidecarURL(for: mediaURL),
              let data = try? Data(contentsOf: sidecarURL),
              let adjustments = try? JSONDecoder().decode(MediaAdjustments.self, from: data) else {
            return .neutral
        }
        return adjustments
    }

    static func save(_ adjustments: MediaAdjustments, for mediaURL: URL) throws {
        let sidecarURL = try FileMannShared.sidecarURL(for: mediaURL)

        if adjustments.isNeutral {
            try? FileManager.default.removeItem(at: sidecarURL)
            return
        }

        let data = try JSONEncoder().encode(adjustments)
        try data.write(to: sidecarURL, options: [.atomic])
    }
}
