import SwiftData

enum PersistenceController {
    static let schema = Schema([
        AssetSortRecord.self,
        MonthSortMeta.self,
        StreakRecord.self,
        MirrorJobRecord.self,
        CompareGroupResolution.self,
    ])

    static let container: ModelContainer = {
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Failed to create Picnic ModelContainer: \(error)")
        }
    }()
}
