import Foundation

enum TaskStore {
    private static let tasksKey = "filemann.archive.tasks.v1"
    private static let settingsKey = "filemann.smb.settings.v1"

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
}
