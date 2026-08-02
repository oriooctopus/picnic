import Foundation
import Photos

struct MonthBucket: Identifiable {
    let year: Int
    let month: Int // 1...12
    var assets: [PHAsset] // ascending by creationDate

    var id: String { key }
    var key: String { String(format: "%04d-%02d", year, month) }

    var monthAbbreviation: String {
        DateFormatter().shortMonthSymbols[month - 1]
    }

    var title: String {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = 1
        let date = Calendar.current.date(from: comps) ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }

    /// Determinism over "most recent" — the reference screenshots show a
    /// fixed cover per month, not one that reshuffles as photos get sorted.
    var coverAsset: PHAsset? { assets.first }
}

extension PHAsset: Identifiable {
    public var id: String { localIdentifier }
}
