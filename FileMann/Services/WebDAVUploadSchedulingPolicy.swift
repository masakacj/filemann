import Foundation

/// The iOS background upload daemon can continue tasks that have *already
/// been submitted* when FileMann is suspended. A two-task foreground-only
/// refill loop leaves hundreds of HEIC files waiting for the app to wake.
/// Submit a bounded queue of small media up front; the system still uses at
/// most two connections and owns the actual background uploads.
///
/// URLSession may stage a private temporary copy for each submitted file:
/// cap aggregate staging to 160 MiB and avoid queueing multiple large files.
enum WebDAVUploadSchedulingPolicy {
    static let largeFileThresholdBytes: Int64 = 64 * 1024 * 1024
    static let backgroundPrefetchMaxFileBytes: Int64 = 16 * 1024 * 1024
    static let maximumPreparedSmallUploads = 16
    static let maximumPreparedBytes: Int64 = 160 * 1024 * 1024
    static let maximumHTTPConnections = 2

    static func canSchedule(
        fileSize: Int64,
        inFlightSizes: [Int64]
    ) -> Bool {
        guard fileSize > 0,
              inFlightSizes.count < maximumPreparedSmallUploads,
              // Equal-size media can be byte-identical. Wait until the
              // first one is visible on the NAS before processing another.
              !inFlightSizes.contains(fileSize),
              !inFlightSizes.contains(where: {
                  $0 > backgroundPrefetchMaxFileBytes
              }) else {
            return false
        }

        if fileSize > backgroundPrefetchMaxFileBytes {
            // MOV, long video or unusually large media: one at a time.
            return inFlightSizes.isEmpty
        }

        let stagedBytes = inFlightSizes.reduce(Int64(0)) { result, size in
            result + max(0, size)
        }
        return stagedBytes <= maximumPreparedBytes - fileSize
    }
}
