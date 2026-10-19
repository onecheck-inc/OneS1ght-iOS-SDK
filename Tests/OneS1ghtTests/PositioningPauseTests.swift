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

    /// provider 의 stop() 은 일시정지를 **유지**한다 — 백그라운드 정지·복귀가 일시정지를 풀면 앱은
    /// 「일시정지」 인데 좌표·존 이벤트가 다시 나갔다(2026-10-02 감사 S20).
    /// 새 세션(begin)·종료(end)에서 푸는 것은 코어 몫이다 — PauseLifecycleTests 가 본다.
    func testProviderStopKeepsPause() {
        let p = UwbPositioningProvider()
        p.isPaused = true
        p.stop()
        XCTAssertTrue(p.isPaused)
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

    // MARK: - 재개 때 죽은 엔진은 다시 띄운다 (2026-10-19)
    //
    // 화면에 있는 동안 iOS 가 NI 세션을 무효로 만들면 엔진은 오류 5 만 주고 「도는 중」 인 채 좌표를 안 낸다.
    // 일시정지 → 재개로 살아나야 한다. 멀쩡한 엔진은 건드리지 않는다(층 재탐색 없이 바로 이어져야 한다).

    private final class Clock { var t = Date(timeIntervalSince1970: 1_000_000) }

    /// 「층을 잡고 측위 중」 인 provider — 라이선스 서버 없이 상태만 세운다. 시계·화면 상태는 바꿔 끼운다.
    private func trackingProvider(_ clock: Clock, active: Bool = true) -> UwbPositioningProvider {
        let p = UwbPositioningProvider()
        p.now = { clock.t }
        p.isAppActive = { active }
        p.isRunning = true
        p.phase = .tracking
        return p
    }

    private func restartLines(_ p: UwbPositioningProvider) -> Int {
        p.log.filter { $0 == SdkLocalized.text("uwb.resumeRestart") }.count
    }

    /// 좌표가 계속 나오던 엔진 — 재개는 깃발만 내린다. 엔진을 건드리면 재개마다 층을 다시 찾는다.
    func testHealthyResumeDoesNotRestartEngine() {
        let clock = Clock()
        let p = trackingProvider(clock)
        p.positioned(14, 1, 2, 0)
        p.pause()
        clock.t += 1
        p.positioned(14, 1, 2, 0)            // 일시정지 중에도 엔진은 좌표를 준다 — 건강으로 센다
        clock.t += 30                        // 일시정지가 길어도
        p.positioned(14, 1, 2, 0)
        p.resume()
        XCTAssertFalse(p.isPaused)
        XCTAssertTrue(p.isRunning)
        XCTAssertEqual(p.phase, .tracking, "멀쩡한 엔진을 껐다")
        XCTAssertEqual(restartLines(p), 0)
    }

    /// 세션 오류(5) 뒤 좌표가 없으면 재개가 엔진을 한 번 다시 띄운다 — 생명주기 재시작과 같은 길(stop → start).
    func testResumeAfterSessionErrorRestartsOnce() {
        let clock = Clock()
        let p = trackingProvider(clock)
        p.positioned(14, 1, 2, 0)
        p.errored(HubError.sessionFailed.rawValue, "dl-tdoa session error: cell 41")
        p.pause()
        clock.t += 1                         // 좌표가 끊긴 지 1초 — 오류만으로도 다시 띄운다
        p.resume()
        XCTAssertFalse(p.isPaused, "재시작해도 일시정지는 풀려야 한다")
        XCTAssertEqual(p.phase, .stopping, "엔진을 내리지 않았다")
        XCTAssertEqual(restartLines(p), 1)

        // 내려가는 중에 다시 일시정지 → 재개해도 또 띄우지 않는다(이중 시작 금지 — 곧 새 엔진이 뜬다).
        p.pause()
        p.resume()
        p.resume()
        XCTAssertEqual(restartLines(p), 1, "재시작이 겹쳤다")
        XCTAssertEqual(p.phase, .stopping)
    }

    /// 오류는 없었지만 좌표가 기준(5초)보다 오래 끊겼다 — 다시 띄운다.
    func testResumeAfterStaleFixRestarts() {
        let clock = Clock()
        let p = trackingProvider(clock)
        p.positioned(14, 1, 2, 0)
        p.pause()
        clock.t += UwbPositioningProvider.resumeStaleFixThreshold + 1
        p.resume()
        XCTAssertFalse(p.isPaused)
        XCTAssertEqual(p.phase, .stopping)
        XCTAssertEqual(restartLines(p), 1)
    }

    /// 오류 뒤 좌표가 다시 왔으면 회복된 것이다 — 띄우지 않는다.
    func testErrorFollowedByFixIsHealthy() {
        let clock = Clock()
        let p = trackingProvider(clock)
        p.errored(HubError.sessionFailed.rawValue, "transient")
        p.positioned(14, 1, 2, 0)
        p.pause()
        p.resume()
        XCTAssertEqual(p.phase, .tracking)
        XCTAssertEqual(restartLines(p), 0)
    }

    /// 화면 밖이면 엔진을 켜지 않는다(엔진은 화면에서만 — 0.2.4). 깃발만 내린다.
    func testResumeWhileInactiveDoesNotRestart() {
        let clock = Clock()
        let p = trackingProvider(clock, active: false)
        p.positioned(14, 1, 2, 0)
        p.errored(HubError.sessionFailed.rawValue, "dl-tdoa session error")
        p.pause()
        clock.t += 60
        p.resume()
        XCTAssertFalse(p.isPaused)
        XCTAssertEqual(p.phase, .tracking, "화면 밖에서 엔진을 건드렸다")
        XCTAssertEqual(restartLines(p), 0)
    }

}
#endif
