import XCTest
@testable import OneS1ght

/// ⚠️ 서버가 항목을 늘렸을 때 구버전 SDK 가 깨지면 안 된다 —
/// 모르는 event 타입도, 모르는 data 필드도 조용히 넘어가야 한다.
final class ConfigChangeTests: XCTestCase {

    func testZonesChangedCarriesFloorAndSeq() {
        let f = SseFrame(event: "zones.changed",
                         data: #"{"seq":42,"tenant_id":7,"floor_id":"f-1"}"#)

        let s = LiveSignal.parse(f)

        XCTAssertEqual(s?.seq, 42)
        XCTAssertEqual(s?.change, .zonesChanged(floorId: "f-1"))
    }

    func testHelloCarriesSeqButNoChange() {
        let f = SseFrame(event: "hello", data: #"{"seq":100,"tenant_id":7}"#)

        let s = LiveSignal.parse(f)

        XCTAssertEqual(s?.seq, 100)
        XCTAssertNil(s?.change)
    }

    func testUnknownEventTypeYieldsSeqOnlyNotNil() {
        // 서버가 새 타입을 늘려도 seq 추적은 계속돼야 한다 — 안 그러면 갭 오탐이 난다.
        let f = SseFrame(event: "something.new", data: #"{"seq":43,"tenant_id":7}"#)

        let s = LiveSignal.parse(f)

        XCTAssertEqual(s?.seq, 43)
        XCTAssertNil(s?.change)
    }

    func testUnknownDataFieldsAreIgnored() {
        let f = SseFrame(event: "zones.changed",
                         data: #"{"seq":1,"tenant_id":7,"floor_id":"f","brand_new":{"a":[1,2]}}"#)

        XCTAssertEqual(LiveSignal.parse(f)?.change, .zonesChanged(floorId: "f"))
    }

    func testMalformedJsonIsDroppedWithoutCrashing() {
        XCTAssertNil(LiveSignal.parse(SseFrame(event: "zones.changed", data: "not json")))
    }

    func testSdkConfigChangedReadsSnakeCaseFields() {
        let f = SseFrame(event: "sdk.config.changed",
                         data: #"{"seq":5,"tenant_id":7,"rate_hz":4,"log_level":"info"}"#)

        XCTAssertEqual(LiveSignal.parse(f)?.change,
                       .sdkConfigChanged(rateHz: 4, logLevel: "info"))
    }
}
