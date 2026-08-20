# OneS1ght SDK — iOS

## 요구사항
- iOS 27.0+ · iPhone 12 이상 (UWB 칩) · Xcode 27+
- 미지원 기기에서도 앱은 정상 동작 (SDK만 비활성)

## 설치 (Swift Package Manager)
Xcode → **File → Add Package Dependencies** →
```
https://github.com/onecheck-inc/onesight-mobile-swift
```
측위 엔진(gpi-dltdoa)과 진출입 판정 엔진(gpi-prm)은 SPM이 자동으로 함께 받아오므로,
이 패키지 하나만 추가하면 됩니다.

## 빠른 시작
```swift
import OneS1ghtSDK

// ① 앱 시작 시 — 키 검증 + 설정 로드
try await OneS1ghtSDK.initialize(sdkKey: "ock_sdk_...")

// ② 매장 화면 진입 시 — 측위 시작 (위치 권한·수집 동의 후)
try await OneS1ghtSDK.start(consent: true)

// 구역 이벤트 수신
OneS1ghtSDK.onZoneEvent = { event in
    if case .enter(let zone, _) = event { print("진입: \(zone.name)") }
}

// ③ 매장 화면 이탈 시
await OneS1ghtSDK.stop()
```

## 주요 API
| 구분 | API |
|---|---|
| 함수 | `initialize(sdkKey:)` · `start(consent:)` · `stop()` · `identify(customerId:)` |
| 콜백 | `onZoneEvent` · `onTriggers` · `onDebugLog` |
| 조회 | `isInitialized` · `isPositioningAvailable` · `anonUserId` |

자세한 연동 절차(콘솔 설정·키 발급·Zone 구성)는 OneS1ght 연동 가이드 문서를 참조하세요.

## 문의
onesight-support@onecheck.co.kr
