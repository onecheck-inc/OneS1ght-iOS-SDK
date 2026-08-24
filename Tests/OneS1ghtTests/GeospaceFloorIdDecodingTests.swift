import XCTest
@testable import OneS1ght

/**
 GeoSpace 건물 트리의 `floorId` 는 **숫자로 온다.**

 2026-08-20 에 같은 원인으로 콘솔 GCH 화면이 전부 500 이 났고(PR#461 에서 경계 정규화로 수습),
 SDK 에는 같은 결함이 남아 있었다 — `floorId` 를 `String` 으로 선언해 두어 JSON 디코딩이
 통째로 실패했다. 그 결과 콘솔이 층을 0개로 주는 건물에서 **폴백이 항상 죽어** 층 드롭다운이
 비었다.

 실패는 조용하다. 호출부가 `try?` 로 감싸고 있어 오류가 사라지고 빈 목록만 남는다 —
 그래서 "층이 안 뜬다"는 증상만 보이고 원인은 드러나지 않았다.

 아래 픽스처는 2026-08-24 prod `GET https://geospace.geoplan.io/api/m/buildings` 응답을
 그대로 옮긴 것이다.
 */
final class GeospaceFloorIdDecodingTests: XCTestCase {

    /// prod 실응답 — `floorId` 가 따옴표 없는 숫자다.
    private let realResponse = """
    {
      "tenantId": "a4455e99-7b71-4ad1-98a7-654e4a851cec",
      "buildings": [
        {
          "buildingId": "0fe8f405-a710-44ee-96a2-f927c44b9cde",
          "buildingName": "금정역 skv1",
          "floors": [
            { "floorId": 14, "floorName": "607호", "hasPlan": true, "aligned": false }
          ]
        }
      ]
    }
    """

    func testDecodesNumericFloorId() throws {
        let data = Data(realResponse.utf8)

        let res = try JSONDecoder().decode(GeospaceBuildingsResponse.self, from: data)

        XCTAssertEqual(res.buildings.count, 1)
        XCTAssertEqual(res.buildings[0].buildingId, "0fe8f405-a710-44ee-96a2-f927c44b9cde")
        XCTAssertEqual(res.buildings[0].floors.count, 1)
        // 숫자 14 가 문자열 "14" 로 정규화돼야 한다 — 콘솔 /floors 가 주는 형태와 같아야
        // 두 경로에서 온 층 ID 를 같은 값으로 다룰 수 있다.
        XCTAssertEqual(res.buildings[0].floors[0].floorId, "14")
        XCTAssertEqual(res.buildings[0].floors[0].floorName, "607호")
        XCTAssertTrue(res.buildings[0].floors[0].hasPlan)
    }

    /// 서버가 언젠가 문자열로 바꿔 보내도 깨지지 않아야 한다 — 경계 정규화의 요점은
    /// 어느 쪽이 오든 같은 값으로 받는 것이지, 반대쪽으로 갈아타는 게 아니다.
    func testStillDecodesStringFloorId() throws {
        let data = Data("""
        {
          "buildings": [
            {
              "buildingId": "b-1",
              "buildingName": "이름",
              "floors": [
                { "floorId": "15", "floorName": "304로", "hasPlan": false }
              ]
            }
          ]
        }
        """.utf8)

        let res = try JSONDecoder().decode(GeospaceBuildingsResponse.self, from: data)

        XCTAssertEqual(res.buildings[0].floors[0].floorId, "15")
        XCTAssertFalse(res.buildings[0].floors[0].hasPlan)
    }

    /// 숫자도 문자열도 아니면 그 층만 버리는 게 아니라 디코딩이 실패해야 한다 —
    /// 조용히 빈 목록을 돌려주면 이번과 같은 증상이 다시 숨는다.
    func testRejectsUnusableFloorId() {
        let data = Data("""
        { "buildings": [ { "buildingId": "b", "buildingName": "n",
          "floors": [ { "floorId": null, "floorName": "x", "hasPlan": true } ] } ] }
        """.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(GeospaceBuildingsResponse.self, from: data))
    }
}
