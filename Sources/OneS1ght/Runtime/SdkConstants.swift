//
//  SdkConstants.swift
//  여러 파일이 같은 값을 써야 하는 상수 — 한 곳만 바뀌어 어긋나지 않게 모아 둔다.
//

import Foundation

/// 서버 계약이 정한 상한.
enum SdkLimits {
    /// 좌표·로그 요청 하나에 실을 수 있는 최대 건수 — 서버가 넘으면 422 를 준다(사양서 §6.5).
    static let maxPerRequest = 500
}

/// 서버로 보내는 플랫폼 이름 — verify·좌표·존 이벤트·로그가 같은 값을 써야 콘솔이 한 기기로 묶는다.
enum SdkPlatform {
    static let name = "iOS"
}

/// 요청 타임아웃(초).
enum SdkTimeouts {
    /// SDK 백엔드(verify·좌표·존 이벤트) — 응답이 작아 짧게 둔다.
    static let api: TimeInterval = 10
    /// 공간 조회 — 도면 응답이 수백 KB(prod 실측 888KB)라 길게 둔다.
    static let space: TimeInterval = 20
}

extension Task where Success == Never, Failure == Never {
    /// 초 단위 대기 — `UInt64(x * 1_000_000_000)` 변환을 호출부마다 반복하지 않는다.
    /// 음수·NaN 은 0 으로 접는다(UInt64 변환이 트랩하지 않게).
    static func sleep(seconds: TimeInterval) async throws {
        let s = seconds.isFinite ? max(0, seconds) : 0
        try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }
}
