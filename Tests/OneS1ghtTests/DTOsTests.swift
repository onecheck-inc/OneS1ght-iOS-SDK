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

    func testDecodeResBuildings() throws {
        let json = #"""
        { "synced_at": "2026-07-16T09:00:00Z",
          "buildings": [
            { "building_id": "b-uuid", "name": "금정역 skv1", "store_id": 3,
              "floors": [ { "floor_id": "f-uuid", "name": "f-uuid" } ] } ] }
        """#
        let res = try JSONDecoder().decode(ResBuildings.self, from: Data(json.utf8))
        XCTAssertEqual(res.buildings.first?.name, "금정역 skv1")
        XCTAssertEqual(res.buildings.first?.floors?.first?.floor_id, "f-uuid")
    }

    func testDecodeResFloorConfig_zoneParams9() throws {
        let json = #"""
        { "floor_id": "f-uuid", "building_id": "b-uuid", "name": "f-uuid",
          "synced_at": "2026-07-16T09:00:00Z",
          "zones": [
            { "zone_id": "z-uuid", "name": "입구존",
              "polygon": [[12.3, 4.5], [13.0, 4.5], [13.0, 6.0]],
              "trigger_type": "enter", "dwell_seconds": 3,
              "in_dist": 3.0, "in_count": 0, "in_count_interval": 0,
              "out_period": 0, "priority": 1, "call_inout": true, "is_active": true } ],
          "anchors": [] }
        """#
        let res = try JSONDecoder().decode(ResFloorConfig.self, from: Data(json.utf8))
        let z = try XCTUnwrap(res.zones.first)
        XCTAssertEqual(z.polygon?.first, [12.3, 4.5])
        XCTAssertEqual(z.in_dist, 3.0)
        XCTAssertTrue(z.call_inout && z.is_active)
        XCTAssertTrue(res.anchors.isEmpty)          // 현재 항상 []
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
        let req = ReqZoneEvent(anon_user_id: "A", visitor_id: "v-20260718-001",
                               floor_id: "F", zone_id: "Z",
                               status: .dwell, occurred_at: "2026-07-18T08:00:00Z",
                               platform_name: "iOS")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        XCTAssertEqual(obj["status"] as? String, "DWELL")        // enum → 서버 표기
        XCTAssertEqual(obj["occurred_at"] as? String, "2026-07-18T08:00:00Z")
        XCTAssertEqual(obj["anon_user_id"] as? String, "A")      // snake_case 그대로
    }

    func testEncodeReqVerify_omitsNilFields() throws {
        // client의 nil 필드는 JSON에서 빠져야 함 (보낸 필드만 갱신 규칙)
        let req = ReqVerify(platform_name: "iOS", app_id: nil,
                            client: ClientInfo(anon_user_id: "A", device_model: nil, os_name: nil,
                                               os_version: nil, app_version: nil, sdk_version: nil,
                                               device_language: nil, customer_id: nil,
                                               consent: nil, consent_at: nil, attributes: nil))
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as! [String: Any]
        let client = obj["client"] as! [String: Any]
        XCTAssertEqual(client.count, 1)                          // anon_user_id 하나만
        XCTAssertNil(obj["app_id"])
    }
}
