import Foundation

/// URLSession background tasks already handed to iOS can keep transferring
/// when the app is suspended. Submit a bounded queue of small files in advance,
/// but use separate background sessions for LAN and WAN connection limits.
enum WebDAVUploadSchedulingPolicy {
    static let largeFileThresholdBytes: Int64 = 64 * 1024 * 1024
    static let backgroundPrefetchMaxFileBytes: Int64 = 16 * 1024 * 1024
    // 223+ item batches previously stalled after only 16 queued files.
    // Hand more *small* files to iOS at once without unlimited staging.
    static let maximumPreparedSmallUploads = 64
    static let maximumPreparedBytes: Int64 = 384 * 1024 * 1024
    static let maximumLANMediumUploads = 2
    static let maximumWANHTTPConnections = 2
    static let maximumLANHTTPConnections = 4
    // Kept for old call sites and migration tests.
    static let maximumHTTPConnections = maximumWANHTTPConnections

    /// Only select the faster LAN pipeline after the *working* local URL was
    /// probed. Being on Wi-Fi alone must not classify an HTTPS WAN fallback
    /// as local (the two endpoints may expose different WebDAV roots).
    static func usesLocalLAN(
        endpoint: String,
        settings: SMBSettings
    ) -> Bool {
        let active = endpoint.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let configuredLocal = settings.normalizedWebDAVBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !configuredLocal.isEmpty,
              active == configuredLocal,
              let host = URL(string: active)?.host else {
            return false
        }
        return SMBSettings.isPrivateLANHost(host)
    }

    static func canSchedule(
        fileSize: Int64,
        inFlightSizes: [Int64],
        isLocalLAN: Bool = false,
        verifiedDifferentContentAtSameSize: Bool = false
    ) -> Bool {
        guard fileSize > 0,
              inFlightSizes.count < maximumPreparedSmallUploads,
              (verifiedDifferentContentAtSameSize ||
               !inFlightSizes.contains(fileSize)),
              !inFlightSizes.contains(where: {
                  $0 > largeFileThresholdBytes
              }) else {
            return false
        }

        if fileSize > largeFileThresholdBytes {
            // Huge videos stay exclusive, avoiding several multi-GB copies
            // in the private staging area of the iOS upload daemon.
            return inFlightSizes.isEmpty
        }

        let mediumInFlight = inFlightSizes.filter {
            $0 > backgroundPrefetchMaxFileBytes
        }.count
        if fileSize > backgroundPrefetchMaxFileBytes {
            if !isLocalLAN {
                // Preserve conservative WAN upload behavior.
                return inFlightSizes.isEmpty
            }
            guard mediumInFlight < maximumLANMediumUploads else {
                return false
            }
        } else if !isLocalLAN && mediumInFlight > 0 {
            return false
        }

        let stagedBytes = inFlightSizes.reduce(Int64(0)) { result, size in
            result + max(0, size)
        }
        return stagedBytes <= maximumPreparedBytes - fileSize
    }
}
