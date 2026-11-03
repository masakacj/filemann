import Foundation

enum TaskStore {
    private static let tasksKey = "filemann.archive.tasks.v1"
    private static let settingsKey = "filemann.smb.settings.v1"
    private static let locationsKey = "filemann.source.locations.v1"
    private static let duplicatesKey = "filemann.duplicate.candidates.v1"
    private static let verificationKey = "filemann.last.verification.v1"
    private static let autoResumeKey = "filemann.background.resume.intent.v1"

    // Durable, atomically-written queue; UserDefaults retained as a backup
    // and migration path from previous versions.
    private static func queueFileURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let folder = support.appendingPathComponent(
            "FileMann/TransferQueue", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true
        )
        return folder.appendingPathComponent("tasks.json")
    }

    static func loadTasks() -> [ArchiveTask] {
        if let url = try? queueFileURL(),
           let data = try? Data(contentsOf: url),
           let tasks = try? JSONDecoder().decode([ArchiveTask].self, from: data) {
            return tasks
        }
        guard let data = UserDefaults.standard.data(forKey: tasksKey),
              let tasks = try? JSONDecoder().decode([ArchiveTask].self, from: data) else {
            return []
        }
        return tasks
    }

    static func saveTasks(_ tasks: [ArchiveTask]) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        if let url = try? queueFileURL() {
            try? data.write(to: url, options: .atomic)
        }
        UserDefaults.standard.set(data, forKey: tasksKey)
    }

    /// A user-started batch remains eligible to resume when the user
    /// reopens FileMann after iOS stops the process. User Pause/Clear sets
    /// this false; it is not a background execution entitlement.
    static func shouldResumeArchive() -> Bool {
        UserDefaults.standard.bool(forKey: autoResumeKey)
    }

    static func setShouldResumeArchive(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: autoResumeKey)
    }

    static func loadSettings() -> SMBSettings {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let value = try? JSONDecoder().decode(SMBSettings.self, from: data) else {
            return SMBSettings()
        }
        return value
    }

    static func saveSettings(_ settings: SMBSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    static func loadLocations() -> [SourceLocation] {
        guard let data = UserDefaults.standard.data(forKey: locationsKey),
              let value = try? JSONDecoder().decode([SourceLocation].self, from: data) else {
            return []
        }
        return value
    }

    static func saveLocations(_ locations: [SourceLocation]) {
        guard let data = try? JSONEncoder().encode(locations) else { return }
        UserDefaults.standard.set(data, forKey: locationsKey)
    }

    static func loadDuplicates() -> [DuplicateCandidate] {
        guard let data = UserDefaults.standard.data(forKey: duplicatesKey),
              let value = try? JSONDecoder().decode([DuplicateCandidate].self, from: data) else {
            return []
        }
        return value
    }

    static func saveDuplicates(_ duplicates: [DuplicateCandidate]) {
        guard let data = try? JSONEncoder().encode(duplicates) else { return }
        UserDefaults.standard.set(data, forKey: duplicatesKey)
    }

    static func loadVerification() -> BatchVerification? {
        guard let data = UserDefaults.standard.data(forKey: verificationKey) else { return nil }
        return try? JSONDecoder().decode(BatchVerification.self, from: data)
    }

    static func saveVerification(_ verification: BatchVerification?) {
        guard let verification else {
            UserDefaults.standard.removeObject(forKey: verificationKey)
            return
        }
        guard let data = try? JSONEncoder().encode(verification) else { return }
        UserDefaults.standard.set(data, forKey: verificationKey)
    }
}
