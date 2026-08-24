import XCTest
@testable import OneS1ght

/// SDK 는 신호를 전달만 한다 — 존을 대신 다시 받지 않는다.
@MainActor
final class SessionCoordinatorLiveTests: XCTestCase {

    func testConfigChangeIsForwardedUntouched() {
        let defaults = UserDefaults(suiteName: "SessionCoordinatorLiveTests")!
        defaults.removePersistentDomain(forName: "SessionCoordinatorLiveTests")
        let identity = IdentityStore(secure: InMemorySecureStore(), defaults: defaults)
        let coord = SessionCoordinator(api: ApiClient(apiKey: "ock_test"),
                                       identity: identity)
        var got: [ConfigChange] = []
        coord.onConfigChange = { got.append($0) }

        coord.deliverConfigChangeForTest(.zonesChanged(floorId: "f-1"))
        coord.deliverConfigChangeForTest(.resyncNeeded)
        coord.deliverConfigChangeForTest(.rulesChanged(zoneId: "88"))

        XCTAssertEqual(got, [.zonesChanged(floorId: "f-1"),
                             .resyncNeeded,
                             .rulesChanged(zoneId: "88")])
    }
}
