//
//  HubError.swift
//  측위 엔진 오류 번호(1~12) — 엔진 README 의 표를 이름으로 옮긴 것.
//
//  ⚠️ 예전엔 번호 목록이 자리마다 따로 박혀 있었다(시작을 되돌릴 번호 [1,3,7,9,10,11,12]·사람이 풀어야 할
//     번호 [1,3,7,10]·E-코드 매핑 switch). 하나만 고치면 나머지가 어긋난다(2026-10-02 감사 K15).
//     번호의 뜻은 여기 한 곳에서만 정한다. 플랫폼 중립이라 맥 테스트에서도 그대로 검증된다.
//

import Foundation

enum HubError: Int, CaseIterable {
    case licenseMissing            = 1    // 라이선스 미등록
    case alreadyRunning            = 2    // 이미 측위 중 (호출 순서)
    case bluetoothUnavailable      = 3    // Bluetooth 불가(꺼짐·권한·미지원 — 메시지로 가른다)
    case anchorsMissing            = 4    // 그 층의 앵커 정보 없음
    case sessionFailed             = 5    // DL-TDoA 세션 오류
    case areaJudgeFailed           = 6    // 영역 판정 오류
    case locationUnavailable       = 7    // 위치 불가(권한·정밀도·서비스 꺼짐)
    case startWhileStopping        = 8    // 정지 중 start (호출 순서)
    case bluetoothKeyMissing       = 9    // Info.plist BT 키 누락
    case licenseRejected           = 10   // 서버가 라이선스 거부
    case licenseServerUnreachable  = 11   // 라이선스 서버 미도달
    case dltdoaUnsupported         = 12   // DL-TDoA 미지원 기기

    /// 시작 단계(아직 onStarted 가 안 옴)에서 나면 엔진이 **아예 뜨지 못한** 것인가 — 그때는 onStopped 가
    /// 오지 않으므로 provider 가 스스로 되돌려야 한다(2026-09-28 Bluetooth 고착).
    /// 2·8 은 호출 순서 문제라 엔진 상태를 바꾸지 않고, 4·5·6 은 엔진이 뜬 뒤에 난다.
    var abortsStart: Bool {
        switch self {
        case .licenseMissing, .bluetoothUnavailable, .locationUnavailable, .bluetoothKeyMissing,
             .licenseRejected, .licenseServerUnreachable, .dltdoaUnsupported:
            return true
        case .alreadyRunning, .anchorsMissing, .sessionFailed, .areaJudgeFailed, .startWhileStopping:
            return false
        }
    }

    /// 사람이 풀어야 하는가 — 다시 켜 봐야 같은 자리에서 접힌다(권한·Bluetooth·라이선스).
    var needsPerson: Bool {
        switch self {
        case .licenseMissing, .bluetoothUnavailable, .locationUnavailable, .licenseRejected:
            return true
        default:
            return false
        }
    }

    /// SDK E-코드. nil 은 "로그로만 남길 것" — 2·8 은 호출 순서 문제라 코드로 올리면 재시도마다 쌓여
    /// 진짜 오류를 덮는다.
    /// `message` 는 엔진이 같이 준 문장이다. 오류 3 하나로 Bluetooth "꺼짐·권한·미지원" 이 다 오는데,
    /// 꺼짐(`powered off`)은 켜면 풀리고 권한은 설정 앱에서 풀어야 해 할 일이 다르다(2026-09-28 실기기).
    func sdkCode(message: String = "") -> SdkErrorCode? {
        switch self {
        case .licenseMissing:            return .invalidKey
        case .bluetoothUnavailable:
            return message.localizedCaseInsensitiveContains("powered off") ? .bluetoothOff : .permissionDenied
        case .anchorsMissing:            return .locatorsMissing
        case .sessionFailed:             return .uwbSessionFailed
        case .areaJudgeFailed:           return .areaJudgeFailed
        case .locationUnavailable:       return .permissionDenied
        case .bluetoothKeyMissing:       return .permissionDenied
        case .licenseRejected:           return .invalidKey
        case .licenseServerUnreachable:  return .network
        case .dltdoaUnsupported:         return .deviceNotSupported
        case .alreadyRunning, .startWhileStopping: return nil
        }
    }
}
