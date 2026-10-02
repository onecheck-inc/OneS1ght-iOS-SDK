//
//  IdentityStoreTests.swift
//  visitor_id 형식/카운터/날짜리셋 (사양서 §4)
//

import XCTest
@testable import OneS1ght

final class IdentityStoreTests: XCTestCase {

    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "IdentityStoreTests")!
        defaults.removePersistentDomain(forName: "IdentityStoreTests")
    }

    // visitor_id — 형식 v-YYYYMMDD-NNN + 같은 날 카운터 증가
    func testVisitorId_formatAndDailyCounter() {
        let fixed = date("2026-07-18 10:00")
        let store = IdentityStore(defaults: defaults, now: { fixed })
        XCTAssertEqual(store.newVisitorId(), "v-20260718-001")
        XCTAssertEqual(store.newVisitorId(), "v-20260718-002")
        XCTAssertEqual(store.newVisitorId(), "v-20260718-003")
    }

    // 날짜 바뀌면 카운터 001로 리셋
    func testVisitorId_resetsOnNewDay() {
        var current = date("2026-07-18 23:50")
        let store = IdentityStore(defaults: defaults, now: { current })
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
