import Foundation

enum SmartCollectionKind: String, CaseIterable, Identifiable {
    case today, yesterday, last7Days
    case shuffle, favorites, screenshots, videos, photos, livePhotos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7Days: return "Last 7 days"
        case .shuffle: return "Shuffle"
        case .favorites: return "Favorites"
        case .screenshots: return "Screenshots"
        case .videos: return "Videos"
        case .photos: return "Photos"
        case .livePhotos: return "Live photos"
        }
    }

    var iconName: String {
        switch self {
        case .today, .yesterday, .last7Days: return "calendar"
        case .shuffle: return "shuffle"
        case .favorites: return "heart.fill"
        case .screenshots: return "camera.viewfinder"
        case .videos: return "video.fill"
        case .photos: return "photo.fill"
        case .livePhotos: return "livephoto"
        }
    }
}
