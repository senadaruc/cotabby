import Foundation

/// File overview:
/// Where "GitHub" in the menu, Home and About points: the repository this build comes from.
///
/// The official app points at the upstream project. A fork that ships its own builds (the dev
/// variant, `COTABBY_DEV_PROJECT_URL`) points at the fork, so people using that build find the
/// source and releases they actually run. The value comes from Info.plist (`CotabbyProjectURL`,
/// filled from the `COTABBY_PROJECT_URL` build setting) and falls back to upstream.
nonisolated enum ProjectLinks {
    static let upstream = URL(string: "https://github.com/FuJacob/cotabby")!

    static var repository: URL {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CotabbyProjectURL") as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
              url.scheme == "https", url.host != nil else { return upstream }
        return url
    }
}
