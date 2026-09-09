//
//  IHubZoneJudgeTests.swift
//  ihub 영역 이벤트 → 콘솔 존 매핑.
//
//  여기서 지키는 것은 **연결고리 하나**다. ihub 의 onAreaEvent 에는 존 ID 가 없고 이름만 온다.
//  그래서 콘솔 존과 잇는 유일한 끈이 이름이고, 그 끈이 끊기면 그 영역의 시책이 통째로 안 돈다.
//  끊긴 것을 조용히 넘기면 현장에서는 "쿠폰이 안 나온다"로만 보인다 — 그래서 알린다.
//
//  좌표를 먹지 않으므로 iOS 가드가 필요 없다. 맥에서 그대로 돈다.
//

import XCTest
@testable import OneS1ght

@MainActor
final class IHubZoneJudgeTests: XCTestCase {

    private func zone(_ id: String, _ name: String, dwell: Int? = nil) -> Zone {
        Zone(id: id, name: name,
             polygon: [Position(x: 0, y: 0), Position(x: 1, y: 0), Position(x: 1, y: 1)],
             dwellSeconds: dwell)
    }

    /// 이벤트·코드·로그를 모아 두는 관찰자. 테스트마다 새로 만든다.
    private func makeJudge() -> (IHubZoneJudge, Observed) {
        let o = Observed()
        let j = IHubZoneJudge()
        j.onEvent = { o.events.append($0) }
        j.onReport = { code, ctx in o.reports.append((code, ctx)) }
        j.onLog = { level, msg in o.logs.append((level, msg)) }
        return (j, o)
    }

    private final class Observed {
        var events: [ZoneEvent] = []
        var reports: [(SdkErrorCode, String)] = []
        var logs: [(LogLevel, String)] = []
    }

    // MARK: - 이름 매핑

    /// 이름이 맞으면 콘솔 zone_id 로 옮겨진다 — 이게 서버로 나가는 값이다.
    func testAreaNameMapsToConsoleZoneId() {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너")])

        j.handleAreaEvent(inOut: "IN", areaName: "정육 코너")

        XCTAssertEqual(o.events.count, 1)
        guard case .enter(let z, _) = o.events[0] else { return XCTFail("IN 이 아님") }
        XCTAssertEqual(z.id, "zn_7", "서버로 나가는 것은 이름이 아니라 콘솔 zone_id 다")
    }

    /// 대응하는 존이 없으면 **이벤트를 만들지 않고, 코드로 알린다.**
    /// 조용히 버리면 시책이 안 도는 이유를 아무도 모른다.
    func testUnmappedAreaIsReportedAndEmitsNothing() {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너")])

        j.handleAreaEvent(inOut: "IN", areaName: "수산 코너")   // 콘솔에 없는 이름

        XCTAssertTrue(o.events.isEmpty, "매핑 안 된 영역으로 이벤트를 만들면 안 된다")
        XCTAssertEqual(o.reports.first?.0, .zoneMappingFailed)
        XCTAssertTrue(o.reports.first?.1.contains("수산 코너") ?? false,
                      "어느 이름이 안 맞았는지 남아야 대조할 수 있다: \(o.reports)")
    }

    /// 같은 이름이 반복돼도 한 번만 알린다 — IN/OUT 이 오갈 때마다 쌓이면 로그가 덮인다.
    func testUnmappedAreaWarnsOnlyOncePerName() {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너")])

        j.handleAreaEvent(inOut: "IN", areaName: "수산 코너")
        j.handleAreaEvent(inOut: "OUT", areaName: "수산 코너")
        j.handleAreaEvent(inOut: "IN", areaName: "수산 코너")

        XCTAssertEqual(o.reports.filter { $0.0 == .zoneMappingFailed }.count, 1, "\(o.reports)")
    }

    /// 다른 이름은 따로 센다 — 하나 알렸다고 나머지를 삼키면 안 된다.
    func testDifferentUnmappedNamesEachWarn() {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너")])

        j.handleAreaEvent(inOut: "IN", areaName: "수산 코너")
        j.handleAreaEvent(inOut: "IN", areaName: "청과 코너")

        XCTAssertEqual(o.reports.filter { $0.0 == .zoneMappingFailed }.count, 2, "\(o.reports)")
    }

    /// 콘솔에서 같은 이름을 두 번 쓴 경우 — 뒤엣것은 `#2` 로 유일화된다(PrmZoneEngine 과 같은 규칙).
    func testDuplicateConsoleNamesAreDisambiguated() {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_a", "코너"), zone("zn_b", "코너")])

        j.handleAreaEvent(inOut: "IN", areaName: "코너")
        j.handleAreaEvent(inOut: "IN", areaName: "코너#2")

        XCTAssertEqual(o.events.count, 2)
        guard case .enter(let z1, _) = o.events[0], case .enter(let z2, _) = o.events[1] else {
            return XCTFail("IN 두 건이 아님")
        }
        XCTAssertEqual([z1.id, z2.id], ["zn_a", "zn_b"])
    }

    // MARK: - IN / OUT

    /// 알 수 없는 inOut 값은 이벤트로 만들지 않는다. 엔진이 규약을 바꿔도 조용히 새 뜻을 지어내면 안 된다.
    func testUnknownInOutValueIsRejected() {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너")])

        j.handleAreaEvent(inOut: "ENTER", areaName: "정육 코너")   // 규약은 "IN"/"OUT"

        XCTAssertTrue(o.events.isEmpty, "\(o.events)")
        XCTAssertFalse(o.logs.isEmpty, "무시했으면 그 사실은 남겨야 한다")
    }

    func testOutEmitsExit() {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너")])

        j.handleAreaEvent(inOut: "IN", areaName: "정육 코너")
        j.handleAreaEvent(inOut: "OUT", areaName: "정육 코너")

        XCTAssertEqual(o.events.count, 2)
        guard case .exit(let z, _) = o.events[1] else { return XCTFail("OUT 이 아님") }
        XCTAssertEqual(z.id, "zn_7")
    }

    // MARK: - DWELL 파생

    /// dwell_seconds 가 없는 존은 체류 이벤트를 만들지 않는다.
    func testNoDwellWhenNotConfigured() async throws {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너")])          // dwell 미설정

        j.handleAreaEvent(inOut: "IN", areaName: "정육 코너")
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(o.events.contains { if case .dwell = $0 { return true }; return false },
                       "\(o.events)")
    }

    /// 존을 갈아끼우면 진행 중이던 체류 타이머는 죽는다 —
    /// 사라진 존의 DWELL 이 뒤늦게 튀어나오면 없는 구역의 시책이 발화한다.
    func testApplyZonesCancelsPendingDwell() async throws {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너", dwell: 1)])
        j.handleAreaEvent(inOut: "IN", areaName: "정육 코너")

        j.apply(zones: [])                                  // 층 전환 · 존 전부 삭제
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(o.events.contains { if case .dwell = $0 { return true }; return false },
                       "존이 사라졌는데 체류가 발화했다: \(o.events)")
    }

    /// OUT 이 오면 체류 타이머도 함께 끝난다.
    func testExitCancelsPendingDwell() async throws {
        let (j, o) = makeJudge()
        j.apply(zones: [zone("zn_7", "정육 코너", dwell: 1)])

        j.handleAreaEvent(inOut: "IN", areaName: "정육 코너")
        j.handleAreaEvent(inOut: "OUT", areaName: "정육 코너")
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(o.events.contains { if case .dwell = $0 { return true }; return false },
                       "\(o.events)")
    }

    // MARK: - 판정 파라미터 무력화 안내

    /// 존이 있으면 "콘솔 판정 파라미터가 이 경로에서 안 쓰인다"를 한 번 말한다.
    /// 조용히 두면 "값을 바꿨는데 왜 그대로냐"를 며칠씩 파게 된다.
    func testJudgingParamsIgnoredIsAnnouncedOnce() {
        let (j, o) = makeJudge()

        j.apply(zones: [zone("zn_7", "정육 코너")])
        j.apply(zones: [zone("zn_8", "수산 코너")])          // 층 전환 — 다시 말하지 않는다

        let warned = o.logs.filter { $0.0 == .warn && $0.1.contains("%") == false }
        XCTAssertEqual(warned.count, 1, "층마다 반복하면 로그가 덮인다: \(o.logs)")
    }

    /// 존이 하나도 없으면 말하지 않는다 — 할 말이 없는 상황이다.
    func testNothingAnnouncedWhenThereAreNoZones() {
        let (j, o) = makeJudge()

        j.apply(zones: [])

        XCTAssertTrue(o.logs.isEmpty, "\(o.logs)")
    }
}
