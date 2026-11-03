import Foundation

/// Conservative pipeline for small Photos exports. URLSession background
/// uploads stage a copy of each source in iOS temporary storage. Keep large
/// video uploads serial and allow two HEIC/JPEG items at once to overlap
/// latency without filling the phone with multiple multi-GB copies.
enum WebDAVUploadSchedulingPolicy {
    static let largeFileThresholdBytes: Int64 = 64 * 1024 * 1024
    static let maximumConcurrentSmallUploads = 2

    static func canSchedule(
        fileSize: Int64,
        inFlightSizes: [Int64]
    ) -> Bool {
        guard fileSize > 0,
              inFlightSizes.count < maximumConcurrentSmallUploads,
              !inFlightSizes.contains(where: {
                  $0 > largeFileThresholdBytes
              }) else {
            return false
        }

        if fileSize > largeFileThresholdBytes {
            return inFlightSizes.isEmpty
        }
        return true
    }
}
