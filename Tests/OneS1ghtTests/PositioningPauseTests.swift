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
}
#endif
