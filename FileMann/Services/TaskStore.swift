import Foundation

enum TaskStore {
    private static let tasksKey = "filemann.archive.tasks.v1"
    private static let settingsKey = "filemann.smb.settings.v1"
    private static let locationsKey = "filemann.source.locations.v1"
    private static let duplicatesKey = "filemann.duplicate.candidates.v1"
    private static let verificationKey = "filemann.last.verification.v1"

    static func loadTasks() -> [ArchiveTask] {
        guard let data = UserDefaults.standard.data(forKey: tasksKey),
              let value = try? JSONDecoder().decode([ArchiveTask].self, from: data) else {
            return []
        }
        return value
    }

    static func saveTasks(_ tasks: [ArchiveTask]) {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: tasksKey)
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
