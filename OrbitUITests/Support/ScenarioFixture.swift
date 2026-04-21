import Foundation

enum ScenarioFixture: String, CaseIterable {
    case idle
    case pendingPermission = "pending-permission"
    case onboardingDrift = "onboarding-drift"
    case activeAndHistory = "active-and-history"

    func resourceURL(in bundle: Bundle = Bundle(for: BundleToken.self)) throws -> URL {
        // Xcode may flatten copied test resources into the bundle root instead of preserving the Fixtures/ subdirectory.
        let url =
            bundle.url(forResource: rawValue, withExtension: "json", subdirectory: "Fixtures") ??
            bundle.url(forResource: rawValue, withExtension: "json")

        guard let url else {
            throw ScenarioFixtureError.missingFixture(rawValue)
        }
        return url
    }
}

enum ScenarioFixtureError: LocalizedError {
    case missingFixture(String)

    var errorDescription: String? {
        switch self {
        case .missingFixture(let name):
            return "Missing scenario fixture: \(name)"
        }
    }
}

private final class BundleToken {}
