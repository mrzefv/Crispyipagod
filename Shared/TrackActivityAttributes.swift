import ActivityKit
import Foundation

struct TrackActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var lat: Double
        var lon: Double
        var summary: String
        var updated: Date
    }
    var title: String
    var kind: String
}
