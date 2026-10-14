import XCTest
@testable import Cotabby

/// "Same as autocomplete" is resolved by one pure function; every other choice passes through.
final class RewriteProviderResolverTests: XCTestCase {
    func test_sameAsAutocompleteFollowsTheAutocompleteEngine() {
        let expected: [(SuggestionEngineKind, RewriteProviderKind)] = [
            (.appleIntelligence, .appleIntelligence),
            (.llamaOpenSource, .openSource),
            (.openAICompatible, .localEndpoint),
            (.mlx, .mlx)
        ]
        for (engine, kind) in expected {
            XCTAssertEqual(RewriteProviderResolver.resolve(.sameAsAutocomplete, autocompleteEngine: engine), kind, "\(engine)")
        }
    }

    func test_explicitChoicesIgnoreTheAutocompleteEngine() {
        let explicit: [RewriteProviderKind] = [.appleIntelligence, .openSource, .localEndpoint, .mlx, .api]
        for kind in explicit {
            for engine in SuggestionEngineKind.allCases {
                XCTAssertEqual(RewriteProviderResolver.resolve(kind, autocompleteEngine: engine), kind)
            }
        }
    }

    func test_persistedRawValuesKeepApiAndMLX() {
        XCTAssertEqual(RewriteProviderKind(rawValue: "api"), .api)
        XCTAssertEqual(RewriteProviderKind(rawValue: "mlx"), .mlx)
        XCTAssertNil(RewriteProviderKind(rawValue: "local"), "local is migrated by the store, not decoded")
    }
}
