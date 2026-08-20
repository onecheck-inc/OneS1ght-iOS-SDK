//
//  PositioningPermission.swift
//  측위 권한 확인 — NearbyInteraction 전용 프로브
//
//  ⚠️ NearbyInteraction 에는 CLLocationManager.authorizationStatus 같은
//     "상태 조회" API 가 없다(iOS 26.5 SDK 헤더 전수 확인). 권한을 알 수 있는
//     유일한 길은 NISession 을 실제로 띄워 보는 것이고, 그 순간 시스템 팝업이 뜬다.
//     → 확인과 요청이 분리되지 않는다. 그래서 "언제 물어볼지"를 SDK 가 정하지 않고
//       permissions() 라는 별도 문으로 앱에 맡긴다.
//
//  판정 근거는 세션의 첫 반응 하나뿐이다:
//    · sessionDidStartRunning              → 허용됨
//    · didInvalidateWith(userDidNotAllow)  → 거부됨
//    · didInvalidateWith(그 외)            → 권한은 통과, 세션 구성이 문제 (허용으로 본다)
//
//  networkIdentifier 는 층마다 다른 값이라 이 시점엔 알 수 없어 0 을 넣는다.
//  유효하지 않은 값이지만 권한 판정에는 지장이 없다 — 권한 프롬프트는 "NI 를 쓰는가"에
//  대한 것이지 특정 network 에 대한 것이 아니기 때문. 잘못된 network 로 인한 실패는
//  userDidNotAllow 가 아닌 다른 코드로 와서 위 규칙이 구분해 낸다.
//

import Foundation

/// 측위 권한 상태.
public enum PermissionStatus: Equatable {
    /// 사용 가능 — 측위를 시작할 수 있다.
    case authorized
    /// 사용자가 거부했다. 앱에서 다시 물을 수 없으므로 설정 앱으로 안내해야 한다.
    case denied
    /// 이 기기·OS 에서는 측위 자체가 불가 — 물어볼 것도 없다.
    case unsupported
}

#if os(iOS)

import NearbyInteraction

/// NISession 을 한 번 띄워 권한만 확인하고 즉시 내리는 일회용 프로브.
@available(iOS 27.0, *)
@MainActor
final class NIPermissionProbe: NSObject, NISessionDelegate {

    /// 프롬프트 응답을 기다리는 상한. 사용자가 팝업을 방치하면 앱이 영영 멈추므로 둔다.
    private static let timeout: TimeInterval = 30

    private var session: NISession?
    private var continuation: CheckedContinuation<PermissionStatus, Never>?
    private var timeoutTask: Task<Void, Never>?

    func run() async -> PermissionStatus {
        await withCheckedContinuation { cont in
            continuation = cont
            let s = NISession()
            s.delegate = self
            session = s
            // 층을 아직 모르므로 networkIdentifier 는 0 (권한 판정에는 무관 — 파일 헤더 참고)
            s.run(NIDLTDOAConfiguration(networkIdentifier: 0))
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.timeout) * 1_000_000_000)
                // 응답이 없으면 "확인 못 함" 이므로 보수적으로 거부 취급
                self?.finish(.denied)
            }
        }
    }

    /// 결과 확정 — 어느 경로로 오든 여기 한 곳에서만 continuation 을 소비한다(중복 재개 = 크래시).
    private func finish(_ status: PermissionStatus) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel(); timeoutTask = nil
        session?.invalidate(); session = nil
        cont.resume(returning: status)
    }

    nonisolated func sessionDidStartRunning(_ session: NISession) {
        Task { @MainActor [weak self] in self?.finish(.authorized) }
    }

    nonisolated func session(_ session: NISession, didInvalidateWith error: Error) {
        let denied = (error as NSError).code == NIError.Code.userDidNotAllow.rawValue
        Task { @MainActor [weak self] in self?.finish(denied ? .denied : .authorized) }
    }
}

#endif
