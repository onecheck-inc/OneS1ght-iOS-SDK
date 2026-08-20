//
//  IdentityStoreTests.swift
//  anon_user_id 영속 · visitor_id 형식/카운터/날짜리셋 (사양서 §4)
//

import XCTest
@testable import OneS1ght

/// Keychain 대역 — 딕셔너리에 저장 (프로세스 내 영속 시뮬레이션)
final class InMemorySecureStore: SecureStore {
    var storage: [String: String] = [:]
    func read(_ key: String) -> String? { storage[key] }
    func write(_ key: String, _ value: String) { storage[key] = value }
}

final class IdentityStoreTests: XCTestCase {

    var secure: InMemorySecureStore!
    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        secure = InMemorySecureStore()
        defaults = UserDefaults(suiteName: "IdentityStoreTests")!
        defaults.removePersistentDomain(forName: "IdentityStoreTests")
    }

    // 게스트 ID — 발급만 하고 SDK 는 보관하지 않는다 (앱이 저장할 몫).
    // 부를 때마다 다른 값이 나와야 "SDK 가 몰래 영속시키지 않는다"가 보장된다.
    func testCreateGuestID_isFreshEachCall() {
        let a = IdentityStore.createGuestID()
        let b = IdentityStore.createGuestID()
        XCTAssertTrue(a.hasPrefix("guest_"))
        XCTAssertNotEqual(a, b)
    }

    // visitor_id — 형식 v-YYYYMMDD-NNN + 같은 날 카운터 증가
    func testVisitorId_formatAndDailyCounter() {
        let fixed = date("2026-07-18 10:00")
        let store = IdentityStore(secure: secure, defaults: defaults, now: { fixed })
        XCTAssertEqual(store.newVisitorId(), "v-20260718-001")
        XCTAssertEqual(store.newVisitorId(), "v-20260718-002")
        XCTAssertEqual(store.newVisitorId(), "v-20260718-003")
    }

    // 날짜 바뀌면 카운터 001로 리셋
    func testVisitorId_resetsOnNewDay() {
        var current = date("2026-07-18 23:50")
        let store = IdentityStore(secure: secure, defaults: defaults, now: { current })
        XCTAssertEqual(store.newVisitorId(), "v-20260718-001")
        XCTAssertEqual(store.newVisitorId(), "v-20260718-002")

        current = date("2026-07-19 00:10")            // 자정 넘김
        XCTAssertEqual(store.newVisitorId(), "v-20260719-001")
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
}
