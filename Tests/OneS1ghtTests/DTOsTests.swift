//
//  DTOsTests.swift
//  사양서 §6의 JSON 예시가 DTO로 1:1 매핑되는지 검증 (CodingKeys 없이 snake_case 직결)
//

import XCTest
@testable import OneS1ght

final class DTOsTests: XCTestCase {

    // MARK: 응답 디코딩 — 사양서 예시 그대로

    func testDecodeResVerify() throws {
        let json = #"{ "valid": true, "tenant_code": "onecheck-internal", "positioning_enabled": true }"#
        let res = try JSONDecoder().decode(ResVerify.self, from: Data(json.utf8))
        XCTAssertTrue(res.valid)
        XCTAssertEqual(res.tenant_code, "onecheck-internal")
        XCTAssertTrue(res.positioning_enabled)
    }

    func testDecodeResZoneEvent_withTriggers() throws {
        let json = #"""
        { "accepted": true, "event_id": "evt_a1b2c3",
          "triggers": [ { "trigger_id": "act_9f3", "type": "coupon",
                          "payload": { "title": "아메리카노 무료" } } ] }
        """#
        let res = try JSONDecoder().decode(ResZoneEvent.self, from: Data(json.utf8))
        XCTAssertEqual(res.triggers.first?.type, "coupon")
        XCTAssertEqual(res.triggers.first?.payload?["title"], "아메리카노 무료")
    }

    func testDecodeResPositionBulk() throws {
        let res = try JSONDecoder().decode(ResPositionBulk.self,
                                           from: Data(#"{ "accepted_count": 100 }"#.utf8))
        XCTAssertEqual(res.accepted_count, 100)
    }

    // MARK: 요청 인코딩 — snake_case 키·상태 원문 확인

    func testEncodeReqZoneEvent_producesSnakeCaseAndRawStatus() throws {
        let req = ReqZoneEvent(profile_id: "A", visitor_id: "v-20260718-001",
                               floor_id: "F", zone_id: "Z",
                               status: .dwell, occurred_at: "2026-07-18T08:00:00Z",
                               platform_name: "iOS")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(obj["status"] as? String, "DWELL")        // enum → 서버 표기
        XCTAssertEqual(obj["occurred_at"] as? String, "2026-07-18T08:00:00Z")
        XCTAssertEqual(obj["profile_id"] as? String, "A")           // snake_case 그대로
    }

    func testEncodeReqVerify_omitsNilFields() throws {
        // nil 필드는 JSON 에서 빠져야 한다 (보낸 필드만 갱신 규칙). client 블록은 0.1.24 다음 판에서 없앴다.
        let req = ReqVerify(platform_name: "iOS", app_id: nil)
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(obj.count, 1)                              // platform_name 하나만
        XCTAssertNil(obj["app_id"])
        XCTAssertNil(obj["client"])
    }
}
