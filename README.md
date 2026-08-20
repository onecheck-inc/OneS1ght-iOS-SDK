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

// ② 측위 권한 — 부르는 순간 시스템 팝업이 뜬다 (시점은 앱이 정한다)
switch await OneS1ght.permissions() {
case .authorized:  break
case .denied:      return showSettingsGuide()
case .unsupported: return showUnsupportedNotice()
}

// ③ 프로필 — 최초 1회 발급받아 앱이 보관, 이후 재사용
let profileId = savedProfileId ?? (try await OneS1ght.createProfile([
    "gender": "F", "ageBand": "20s"          // 나이는 연령대로 (재식별 방지)
]))
OneS1ght.identify(profileId: profileId)

// ④ 공간 선택 — 필수 (이걸 안 하면 좌표가 나오지 않습니다)
let buildings = try await OneS1ght.buildings()
let floors    = try await OneS1ght.floors(buildings[0].id)
try await OneS1ght.setFloorMap(floors[0], buildingID: buildings[0].id)

// ⑤ 지도 렌더 — 도면은 단건 조회에 담겨 온다
let floor = try await OneS1ght.floor(buildings[0].id, floors[0].id)
mapView.setBackground(floor.image)

// ⑥ 매장 화면 진입 시 — 측위 시작
let session = try OneS1ght.floorSession()
session.onZoneEnter = { zone in print("진입: \(zone.name)") }
session.onZoneExit  = { zone in print("이탈: \(zone.name)") }
session.onPosition  = { c in mapView.moveMarker(c) }
try await session.begin()

// ⑦ 매장 화면 이탈 시
await session.end()
```

## 주요 API
| 구분 | API |
|---|---|
| 초기화 | `initialize(sdkKey:geoSdkKey:)` · `permissions()` · `reset()` |
| 프로필 | `createProfile(_:)` · `getProfile(_:)` · `putProfile(_:_:)` · `deleteProfile(_:)` · `identify(profileId:)` |
| 공간 조회 | `buildings()` · `building(_:)` · `floors(_:)` · `floor(_:_:)` · `zones(_:_:)` · `zone(_:_:_:)` · `locators(_:_:)` |
| 층 지정 | `setFloorMap(_:buildingID:)` · `refreshZones()` |
| 측위 | `floorSession()` → `begin()` · `end()` |
| 세션 콜백 | `onZoneEnter` · `onZoneExit` · `onZoneDwell` · `onPosition` · `onTriggers` |
| 버퍼 | `send()`(전송) · `empty()`(폐기) |
| 조회 | `isInitialized` · `isDeviceAvailable` · `deviceAvailability` · `onDebugLog` · `sdkVersion` |

자세한 연동 절차(콘솔 설정·키 발급·Zone 구성)는 OneS1ght 연동 가이드 문서를 참조하세요.

## 문의
onesight-support@onecheck.co.kr
