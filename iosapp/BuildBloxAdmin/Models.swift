import Foundation

// Codable models for the v1 (read-only) endpoints. Row-level fields for the
// chart endpoints map to the SQL SELECT columns in the worker's handleStats*
// functions — verify exact keys there when wiring each chart. The models below
// cover the hero screens; extend as you add charts.

// MARK: /stats/live
struct LiveStats: Codable {
    let target: String
    let placeId: String?
    let serverCount: Int
    let playerCount: Int
    let players: [String]
    let servers: [LiveServer]
}

struct LiveServer: Codable, Identifiable {
    let server_id: String
    let player_count: Int
    let uptime_seconds: Double?
    let last_heartbeat: Double?
    var id: String { server_id }
}

// MARK: /stats/daily-peak  -> rows: [{ date, peak, servers }]
struct DailyPeakResponse: Codable {
    let target: String
    let days: Int
    let rows: [DailyPeakRow]
}
struct DailyPeakRow: Codable, Identifiable {
    let date: String
    let peak: Int
    let servers: Int?
    var id: String { date }
}

// MARK: /stats/plus (Roblox Plus funnel)
struct PlusStats: Codable {
    let target: String
    let days: Int
    let taps: Int
    let uniqueTappers: Int
    let prospectTaps: Int
    let purchases: Int
    let originPurchases: Int
    let conversionRate: Double
    // rows / sources are dynamic; decode lazily when you build that chart.
}

// MARK: /stats/playerbase
struct PlayerbaseStats: Codable {
    let target: String
    let days: Int
    let churn: Churn
    let lifetime: Lifetime

    struct Churn: Codable {
        let active1: Int
        let active7: Int
        let active14: Int
        let active30: Int
        let lapsed_7_14: Int
        let lapsed_14_30: Int
        let lapsed_30p: Int
        let reactivated7: Int
    }
    struct Lifetime: Codable {
        let total: Int
        let avgDays: Double
        let avgSessions: Double
        let powerUsers: Int
    }
    // `acquisition` is an array of daily rows; decode when building that chart.
}

// MARK: /feedback?filter=inbox
struct FeedbackResponse: Codable {
    let target: String
    let filter: String
    let rows: [FeedbackItem]
}
struct FeedbackItem: Codable, Identifiable {
    let feedback_id: Int
    let user_id: Int?
    let username: String?
    let display_name: String?
    let text: String
    let spam: Int?
    var id: Int { feedback_id }
    var isSpam: Bool { (spam ?? 0) != 0 }
}

// MARK: /leaderboards
struct Leaderboards: Codable {
    let target: String
    let streak: [LeaderRow]
    let likes: [LeaderRow]
    let playtime: [LeaderRow]
    let ageSeconds: Double?
}
struct LeaderRow: Codable, Identifiable {
    let rank: Int
    let user_id: Int?
    let username: String?
    let value: Double
    var id: Int { rank }
}

// MARK: /thumbnails?userIds=a,b,c
struct ThumbnailsResponse: Codable {
    let thumbnails: [String: String]   // userId -> imageUrl
}
