//
//  PositioningPauseTests.swift
//  일시정지는 **엔진을 끄지 않는다** — 그게 stop() 과 갈리는 유일한 지점이고,
//  이게 무너지면 재개할 때마다 앵커를 처음부터 찾게 되어 걷기 검증이 못 쓰게 된다.
//
//  ⚠️ **iOS 27 미만에서는 건너뛴다.** 타입에 붙인 `@available` 은 컴파일 시점 표식일 뿐,
//     XCTest 는 ObjC 런타임으로 테스트를 찾아 **그 아래 OS 에서도 실행한다.** 그런데
//     `UwbPositioningProvider()` 생성이 iOS 27 전용 셀렉터
//     (`NIDeviceCapabilities.supportsDLTDOAMeasurement`)를 건드려 iOS 18 시뮬에서
//     NSInvalidArgumentException 으로 터진다. SDK 본체는 전부 `#available` 로 막혀 있어
//     안전하다 — 막히지 않은 것은 이 테스트뿐이었다(iOS 18.6 시뮬에서 4건 실패로 드러남).
//

#if os(iOS)
import XCTest
@testable import OneS1ght

@available(iOS 27.0, *)
@MainActor
final class PositioningPauseTests: XCTestCase {

    /// iOS 27 미만에서는 provider 를 만들 수조차 없다(머리말 참고).
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard #available(iOS 27.0, *) else {
            throw XCTSkip("iOS 27 미만 — UwbPositioningProvider 를 생성할 수 없다")
        }
    }

    /// 시작 직후는 일시정지가 아니다.
    func testStartsUnpaused() {
        XCTAssertFalse(UwbPositioningProvider().isPaused)
    }

    /// 측위 중이 아니면 일시정지는 의미가 없다 — 조용히 무시한다.
    /// (여기서 isPaused 가 켜지면, 다음에 start 했을 때 좌표가 통째로 버려진다.)
    func testPauseIsIgnoredWhenNotRunning() {
        let p = UwbPositioningProvider()
        p.pause()
        XCTAssertFalse(p.isPaused, "안 돌고 있는데 일시정지가 걸렸다")
    }

    /// 해제는 멱등이다 — 두 번 눌러도 상태가 뒤집히지 않는다.
    func testResumeIsIdempotent() {
        let p = UwbPositioningProvider()
        p.resume(); p.resume()
        XCTAssertFalse(p.isPaused)
    }

    /// stop() 은 일시정지 상태를 남기지 않는다.
    ///
    /// 남기면 다음 begin() 이 "시작은 됐는데 좌표가 하나도 안 나오는" 상태로 뜬다 —
    /// 화면상 증상이 측위 실패와 똑같아서 원인을 찾기 어렵다.
    func testStopClearsPause() {
        let p = UwbPositioningProvider()
        p.stop()
        XCTAssertFalse(p.isPaused)
    }
    // MARK: - 일시정지는 영역 이벤트도 막아야 한다

    /// ⚠️ **이게 이번 회귀의 본체다.**
    ///
    /// `pause()` 는 "화면의 내 위치·서버 전송·**존 판정**을 멈춘다" 고 약속한다. 그런데
    /// 영역 경로는 `isRunning` 만 보고 있었고 pause 는 isRunning 을 건드리지 않는다 —
    /// 좌표 경로에는 가드를 넣었으면서 여기에는 빠뜨렸다. 그래서 「내 위치 표시 중지」를
    /// 눌러도 진입·이탈 알림이 계속 떴다(2026-09-10 실기기 로그에 그대로 찍혔다).
    ///
    /// 기존 pause 테스트 4건은 **상태 전이만** 봤기 때문에 이걸 못 잡았다.
    func test_일시정지_중에는_영역이벤트를_내보내지_않는다() {
        let provider = UwbPositioningProvider()
        var delivered: [String] = []
        provider.onRawAreaEvent = { _, name, inOut, _ in delivered.append("\(inOut):\(name)") }

        provider.isPaused = true
        provider.areaEvent(14, "새 존 2", "IN")
        provider.areaEvent(14, "새 존 2", "OUT")

        XCTAssertTrue(delivered.isEmpty,
                      "일시정지 중인데 영역 이벤트가 밖으로 나갔다: \(delivered)")
    }

    /// 막는 것만 맞으면 절반이다 — 재개하면 다시 나가야 한다.
    /// 이게 없으면 "영원히 막는" 구현도 위 테스트를 통과한다.
    func test_재개하면_영역이벤트가_다시_나간다() {
        let provider = UwbPositioningProvider()
        var delivered: [String] = []
        provider.onRawAreaEvent = { _, name, inOut, _ in delivered.append("\(inOut):\(name)") }

        provider.isPaused = true
        provider.areaEvent(14, "새 존 2", "IN")
        provider.isPaused = false
        provider.areaEvent(14, "새 존 2", "IN")

        XCTAssertEqual(delivered, ["IN:새 존 2"], "재개 뒤의 이벤트가 한 건만 나가야 한다")
    }

}
#endif
