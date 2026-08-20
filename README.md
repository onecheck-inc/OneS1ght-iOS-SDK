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
import OneS1ght

// ① 앱 시작 시 — 키 검증 + 테넌트 설정 수신
try await OneS1ght.initialize(sdkKey: "ock_sdk_...", geoSdkKey: "gsk_...")

// ② 공간 선택 — 필수 (이걸 안 하면 좌표가 나오지 않습니다)
let buildings = try await OneS1ght.buildings()
if let b = buildings.first, let f = b.floors.first {
    try await OneS1ght.loadFloor(buildingId: b.id, floorId: f.id)
}

// ③ 인증 — 회원 ID 또는 createGuestID() 로 받아 앱이 보관한 값
OneS1ght.identify(userId: "emp_1234")

// ④ 매장 화면 진입 시 — 측위 시작
try await OneS1ght.start()

// 구역 이벤트 수신
OneS1ght.onZoneEvent = { event in
    if case .enter(let zone, _) = event { print("진입: \(zone.name)") }
}

// ⑤ 매장 화면 이탈 시
await OneS1ght.stop()
```

## 주요 API
| 구분 | API |
|---|---|
| 함수 | `initialize(sdkKey:geoSdkKey:)` · `identify(userId:)` · `createGuestID()` · `start()` · `stop()` · `buildings()` · `loadFloor(buildingId:floorId:)` · `refreshZones()` · `reset()` |
| 콜백 | `onZoneEvent` · `onTriggers` · `onPosition` · `onDebugLog` |
| 조회 | `isInitialized` · `isDeviceAvailable` · `deviceAvailability` · `permissions()` · `sdkVersion` |

자세한 연동 절차(콘솔 설정·키 발급·Zone 구성)는 OneS1ght 연동 가이드 문서를 참조하세요.

## 문의
onesight-support@onecheck.co.kr
