import Foundation

struct ReleaseConfiguration: Sendable {
    static let feedURL = URL(string: "https://belloware.com/assets/bello_agent.appcast.xml")!
    static let publicKey = "slSJ7z2j8RDa266+E/7To5AOOloc2YtiMUZUVEIhwNA="
    let version: String
    let build: String
    let error: String?

    static var current: Self { Self(info: Bundle.main.infoDictionary ?? [:]) }

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        build = info["CFBundleVersion"] as? String ?? "Unknown"
        if info["SUFeedURL"] as? String != Self.feedURL.absoluteString {
            error = "The packaged update feed is invalid. Reinstall a signed release."
        } else if info["SUPublicEDKey"] as? String != Self.publicKey {
            error = "The packaged update signing key is invalid. Reinstall a signed release."
        } else if Int(build).map({ $0 > 0 }) != true {
            error = "The packaged build number is invalid. Reinstall a signed release."
        } else {
            error = nil
        }
    }
}
