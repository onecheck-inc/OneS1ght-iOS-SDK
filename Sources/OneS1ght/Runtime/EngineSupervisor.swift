//
//  EngineSupervisor.swift
//  엔진이 **스스로** 꺼졌을 때 — 다시 켜 볼지, 세션을 닫을지.
//
//  SessionCoordinator 에서 떼어 냈다(2026-10-02 감사 K7).
//
//  닫는 이유: 세션을 "측위 중" 으로 둔 채 엔진만 죽어 있으면 앱의 `begin()` 이 "이미 측위 중" 으로
//  삼켜져, 앱을 껐다 켜기 전엔 측위가 안 돌아왔다(2026-10-02 온보딩 앱 — 백그라운드 복귀 후
//  층을 못 찾고 강제 종료). 닫으면 `FloorSession.isRunning` 이 false 가 되어 앱이 알고 다시 연다.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class EngineSupervisor {

    /// 다시 켜 보는 간격 — 이만큼 해도 안 되면 세션을 닫는다.
    private let delays: [TimeInterval]
    /// 지금까지 다시 켠 횟수 — 좌표가 한 번 나오거나 포그라운드로 돌아오면 0 으로.
    private var attempts = 0
    private var task: Task<Void, Never>?
    private let reporter: SdkReporter

    /// 앱이 화면에 떠 있는가 — 테스트가 바꿔 끼운다.
    var isAppActive: () -> Bool = { EngineSupervisor.appIsActive }

    init(delays: [TimeInterval], reporter: SdkReporter) {
        self.delays = delays
        self.reporter = reporter
    }

    /// 다시 살아났다(좌표가 나왔다)·새 기회다(포그라운드 복귀) — 다음 고장은 처음부터 센다.
    func resetAttempts() { attempts = 0 }

    /// 대기 중인 재시도를 멈춘다(백그라운드·정지).
    func cancel() { task?.cancel(); task = nil }

    /// 세션이 끝났다 — 재시도도 횟수도 지운다.
    func reset() { cancel(); attempts = 0 }

    /// 엔진이 스스로 꺼졌다 — 다시 켜 보거나(재시도 가능·횟수 남음), `giveUp` 으로 세션을 닫게 한다.
    /// - Parameter isLive: 다시 켤 순간에도 그 provider 의 세션이 살아 있는가(그 사이 끝났으면 켜지 않는다).
    func handleUnexpectedStop(_ p: PositioningProvider, retryable: Bool, context: String,
                              isLive: @escaping (PositioningProvider) -> Bool,
                              giveUp: @escaping () -> Void) {
        cancel()
        let attempt = attempts
        guard retryable, attempt < delays.count else {
            // 사람이 풀어야 하는 원인(권한·Bluetooth·라이선스)은 엔진이 이미 제 코드(E2003·E2004 등)로
            // 올렸다 — E4001(ERROR)을 덧붙이면 같은 일이 「고장」 으로 두 번 찍힌다. 재시도를 다 쓴 것만 올린다.
            let gaveUp = SdkLocalized.format("coord.engineGaveUp", context)
            if retryable { reporter.report(.uwbSessionFailed, "engine stopped, session closed — \(context)", message: gaveUp) }
            else { reporter.log(.warn, gaveUp) }
            giveUp()
            return
        }
        attempts += 1
        let delay = delays[attempt]
        reporter.report(.uwbSessionFailed,
                        "engine stopped, retry \(attempt + 1)/\(delays.count) in \(Int(delay))s — \(context)",
                        message: SdkLocalized.format("coord.engineRetry", attempt + 1, delays.count, Int(delay)))
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(seconds: delay)
            // 화면에 없으면 돌아올 때까지 기다린다 — UWB 는 포그라운드에서만 돈다.
            // ⚠️ 예전엔 여기서 그냥 돌아갔다. 제어 센터·전화 배너처럼 앱이 **비활성(inactive)** 일 뿐인
            //    때는 그 뒤 포그라운드 알림(willEnterForeground)이 오지 않아, 아무도 다시 켜지 않고
            //    「세션은 도는데 엔진은 죽음」 으로 남았다(S7). 진짜 백그라운드로 가면 배경 알림이
            //    이 작업을 취소하고, 포그라운드 복귀가 대신 켠다.
            while let self, !Task.isCancelled, !self.isAppActive() {
                try? await Task.sleep(seconds: 0.5)
            }
            guard self != nil, !Task.isCancelled, isLive(p) else { return }
            p.start()
        }
    }

    /// 앱이 화면에 떠 있는가. UIKit 이 없는 곳(macOS swift test)에선 true — 판정할 것이 없다.
    static var appIsActive: Bool {
        #if canImport(UIKit) && !os(watchOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }
}
