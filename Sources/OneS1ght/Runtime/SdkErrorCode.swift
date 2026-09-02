//
//  SdkErrorCode.swift
//  로그 코드 — 앱 로그·콘솔 로그 분석기·트러블슈팅 문서가 같은 값을 가리키게 하는 표식.
//
//  · 사람이 읽는 문구는 언어·표현이 바뀌지만 코드는 안 바뀐다. 고객 문의가 들어왔을 때
//    "E2003" 하나로 원인을 특정할 수 있어야 한다.
//  · **서버로는 코드와 문맥만 보낸다.** 문구는 콘솔이 관리자 화면 언어로 렌더링한다 —
//    로그를 읽는 사람은 기기 사용자가 아니라 관리자라, 기기 언어를 따르면 일본 사용자의
//    에러가 일본어로 쌓여 한국인 관리자가 읽게 된다.
//  · 앞 한 자리 = 계열. 새 코드는 계열 안에서 뒤 번호만 늘린다 —
//    **한 번 쓴 번호는 재사용하지 않는다**(옛 로그의 의미가 바뀌면 안 된다).
//
//      1xxx  초기화·인증      앱 개발자 / 테넌트 관리자
//      2xxx  기기·권한        최종 사용자
//      3xxx  공간·설정        테넌트 관리자 (콘솔·GeoSpace)
//      4xxx  측위             테넌트 관리자 (현장 하드웨어)
//      5xxx  전송             앱 개발자 / 통합 관리자
//

import Foundation

/// 로그 레벨 — 서버가 ERROR·WARN·INFO·LOG 네 단계로 정규화한다.
public enum SdkLogLevel: String, Sendable {
    case error = "ERROR"
    case warn  = "WARN"
    case info  = "INFO"
}

/// SDK 가 남기는 에러의 식별 코드.
public enum SdkErrorCode: String, Sendable, CaseIterable {

    // MARK: 1xxx — 초기화·인증

    /// initialize 없이 다른 API 를 호출했다.
    case notInitialized      = "E1001"
    /// SDK 키가 무효하거나 폐기됐다 (401). 재시도해도 소용없다.
    case invalidKey          = "E1002"
    /// 키는 유효하나 테넌트에서 측위가 꺼져 있다.
    case positioningDisabled = "E1003"
    /// identify(profileId:) 없이 측위를 시작하려 했다.
    case notIdentified       = "E1004"

    // MARK: 2xxx — 기기·권한

    /// iOS 27 미만. OS 업데이트로 해결된다.
    case osVersionTooLow     = "E2001"
    /// UWB(DL-TDoA) 칩이 없다. iPhone 12 이상 필요.
    case deviceNotSupported  = "E2002"
    /// 사용자가 측위 권한을 거부했다. 앱에서 재요청 불가 — 설정 앱으로 안내해야 한다.
    case permissionDenied    = "E2003"

    // MARK: 3xxx — 공간·설정

    /// setFloorMap 없이 측위를 시작했다. 파이프라인은 돌지만 좌표가 나오지 않는다.
    case floorNotSet         = "E3001"
    /// 층에 로케이터가 등록되어 있지 않다.
    case locatorsMissing     = "E3002"
    /// 층에 UWB 세션(networkIdentifier)이 없다. 측위 시작 불가.
    case sessionIdMissing    = "E3003"
    /// 층에 존이 하나도 없다 — 좌표는 쌓이지만 진출입 이벤트가 나오지 않는다. (WARN)
    case zonesEmpty          = "E3004"
    /// 로케이터 **조회 자체가 실패**했다(통신·서버·404). 층에 로케이터가 없는 것(E3002)과 다르다 —
    /// 그쪽은 "안 깔았다", 이쪽은 "못 받았다" 라서 확인할 곳이 현장이 아니라 연동·네트워크다.
    /// ⚠️ 도면·존 표시는 막지 않는다. 지도는 그대로 뜨고 측위만 못 한다.
    case locatorsFetchFailed = "E3006"

    // E3005 는 쓰지 않는다. v0.1.14 에서 "층에 도면 없음"에 잠깐 붙였다가 v0.1.15 에서
    // 거뒀다 — 도면이 없는 층은 **정상 구성**이라(산업 현장은 올릴 도면이 아예 없다)
    // 오류 계열에 있을 값이 아니었다. 지금은 정보 코드 I3002 다(아래 SdkInfoCode).
    // 번호는 재사용하지 않는다 — 옛 로그의 뜻이 바뀌면 안 된다.

    // MARK: 4xxx — 측위

    /// NISession 이 무효화됐다 (권한 외 사유).
    case uwbSessionFailed    = "E4001"
    /// 로케이터 신호는 잡히는데 좌표가 산출되지 않는다 — 등록 좌표와 실제 배치 불일치 의심.
    case noPositionFix       = "E4002"
    /// 등록된 로케이터 중 일부가 수신되지 않는다 — 전원·배치 확인 필요. (WARN)
    case locatorNotReceived  = "E4003"

    // MARK: 5xxx — 전송

    /// 네트워크 실패 (오프라인·타임아웃).
    case network             = "E5001"
    /// 서버 5xx.
    case server              = "E5002"
    /// 페이로드가 서버 계약과 맞지 않는다 (422). 대개 SDK·서버 버전 불일치.
    case unprocessable       = "E5003"
    /// 다른 테넌트의 자원에 접근했다 (403).
    case forbidden           = "E5004"
    /// 응답 JSON 이 예상 형태와 다르다.
    case decoding            = "E5005"
    /// 미전송 좌표가 버려졌다 (인메모리 버퍼 — 앱 종료·복구 불가 실패).
    case pendingDropped      = "E5006"

    /// 기본 레벨. 동작이 이어지는 것은 WARN, 그 외는 ERROR.
    public var level: SdkLogLevel {
        switch self {
        case .zonesEmpty, .locatorNotReceived, .pendingDropped: return .warn
        default:                                                return .error
        }
    }

    /// 사람이 읽는 한 줄 설명 — `onDebugLog` 에만 쓴다(서버로는 코드만 간다).
    public var summary: String {
        switch self {
        case .notInitialized:      return "SDK 가 초기화되지 않음"
        case .invalidKey:          return "SDK 키 무효 또는 폐기"
        case .positioningDisabled: return "테넌트에서 측위 비활성"
        case .notIdentified:       return "프로필 미연결"
        case .osVersionTooLow:     return "iOS 버전 미달"
        case .deviceNotSupported:  return "UWB 미지원 기기"
        case .permissionDenied:    return "측위 권한 거부"
        case .floorNotSet:         return "층 미지정"
        case .locatorsMissing:     return "층에 로케이터 없음"
        case .sessionIdMissing:    return "층에 UWB 세션 없음"
        case .zonesEmpty:          return "층에 존 없음"
        case .locatorsFetchFailed: return "로케이터 조회 실패 (지도는 정상)"
        case .uwbSessionFailed:    return "UWB 세션 실패"
        case .noPositionFix:       return "좌표 미산출"
        case .locatorNotReceived:  return "로케이터 일부 미수신"
        case .network:             return "네트워크 실패"
        case .server:              return "서버 오류"
        case .unprocessable:       return "요청 형식 불일치"
        case .forbidden:           return "권한 없는 자원 접근"
        case .decoding:            return "응답 해석 실패"
        case .pendingDropped:      return "미전송 좌표 유실"
        }
    }
}

/// 세션 추적용 정보 코드 — 에러가 아니다.
/// 이게 있어야 "언제 어느 층에서 세션을 열었는데 좌표가 안 나왔다"를 코드 없이 추적할 수 있다.
public enum SdkInfoCode: String, Sendable, CaseIterable {
    case initialized   = "I1001"   // 초기화 완료
    case identified    = "I1002"   // 프로필 연결
    case floorSet      = "I3001"   // 층 지정
    case planMissing   = "I3002"   // 층에 도면 없음 — 지도만 배경 없이 그린다(측위는 정상)
    case positioningOn = "I4001"   // 측위 시작
    case positioningOff = "I4002"  // 측위 종료
    case rateApplied   = "I5001"   // 전송 주기 적용 (기본값과 다를 때만)

    public var summary: String {
        switch self {
        case .initialized:    return "초기화 완료"
        case .identified:     return "프로필 연결"
        case .floorSet:       return "층 지정"
        case .planMissing:    return "층에 도면 없음 (측위는 정상)"
        case .positioningOn:  return "측위 시작"
        case .positioningOff: return "측위 종료"
        case .rateApplied:    return "전송 주기 적용"
        }
    }
}

// MARK: - 기존 에러 타입 → 코드

public extension SdkError {
    var code: SdkErrorCode {
        switch self {
        case .notInitialized:      return .notInitialized
        case .notIdentified:       return .notIdentified
        case .positioningDisabled: return .positioningDisabled
        case .deviceNotSupported:  return .deviceNotSupported
        case .osVersionTooLow:     return .osVersionTooLow
        }
    }
}

public extension ApiError {
    var code: SdkErrorCode {
        switch self {
        case .invalidKey:    return .invalidKey
        case .forbidden:     return .forbidden
        case .notFound:      return .unprocessable   // 404 는 대개 계약 불일치
        case .unprocessable: return .unprocessable
        case .server:        return .server
        case .network:       return .network
        case .decoding:      return .decoding
        }
    }
}
