import Foundation

/// Read-only compatibility and curated-fix feeds. This fork has no submission client.
nonisolated enum CommunityDatabase {
    static let baseURL = URL(string: "https://kagerou.glass/api/sevoflurane/v1")!
}
