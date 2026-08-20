# OneS1ght SDK for iOS

[English](README.md) | **한국어** | [日本語](README.ja.md)

OneS1ght SDK for iOS는 iOS 모바일 환경에서 UWB 통신을 통해 실시간으로 정확도가 높은 측위 데이터를 제공하고 제공된 데이터를 통해 세밀한 마케팅 인사이트를 제공합니다. 

SDK 에 대해 
- GitHub: https://github.com/onecheck-inc/onesight-mobile-swift
- 개발자 문서: https://docs.ones1ght.com/sdk/overview 

---

## 요구사항

| 항목 | 요구사항 |
|---|---|
| 측위 동작 | **iOS 27.0+** · **iPhone 12 이상** (UWB 칩) |
| 패키지 추가 | iOS 15.0+ — 미지원 기기에서도 앱은 정상 동작하고 SDK만 비활성 |
| 빌드 환경 | Xcode 26.6+ |

SDK가 실제로 동작하려면 키와 공간 설정이 먼저 준비되어야 합니다.

| 사전 준비 | 어디서 |
|---|---|
| SDK 키 (`ock_sdk_…`) | OneS1ght 콘솔 → **모바일 SDK** |
| GeoSpace 키 (`gsk_…`) | GeoSpace 파트너 콘솔 |
| 건물·층·로케이터 설치 | GeoSpace |
| 구역(Zone) | OneS1ght 콘솔 → **공간 관리** |

---

## Step 1: 프로젝트 설정

Xcode → **File → Add Package Dependencies…** 에서 아래 주소를 입력합니다.

```
https://github.com/onecheck-inc/onesight-mobile-swift
```

`Package.swift` 로 붙이는 경우:

```swift
dependencies: [
    .package(url: "https://github.com/onecheck-inc/onesight-mobile-swift", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "OneS1ght", package: "OneS1ght")
    ])
]
```

측위 엔진과 진출입 판정 엔진은 자동으로 함께 받아오므로 이 패키지 하나만 추가하면 됩니다.

### Info.plist

```xml
<key>NSNearbyInteractionUsageDescription</key>
<string>매장 내 위치를 파악하는 데 사용합니다.</string>
```

---

## Step 2: SDK 초기화

앱 시작 시 1회 호출합니다. 키를 검증하고, 백엔드 도달 여부를 확인하고, 테넌트 설정을
받아옵니다.

```swift
import OneS1ght

try await OneS1ght.initialize(sdkKey: "ock_sdk_…", geoSdkKey: "gsk_…")
```

⚠️ `initialize` 는 건물·층을 **조회하지 않습니다.** 공간 선택은 별도 단계(Step 5)입니다 —
어느 층을 쓸지는 앱만 알기 때문입니다.

**예상 로그**

```
[I1001] 초기화 완료 — tenant=itoku
verify 통과 (tenant: itoku)
```

### 기기 지원 여부 먼저 확인

```swift
switch OneS1ght.deviceAvailability {
case .available:          break
case .osVersionTooLow:    showNotice("iOS 27 이상에서 사용할 수 있습니다")
case .deviceNotSupported: showNotice("iPhone 12 이상에서 사용할 수 있습니다")
}
```

throw 하지 않고 `initialize` 전에도 호출할 수 있어, 네트워크를 타기 전에 안내 UI를
분기할 수 있습니다.

---

## Step 3: 권한

```swift
switch await OneS1ght.permissions() {
case .authorized:  break
case .denied:      showSettingsGuide()      // 재요청 불가 — 설정 앱으로 안내
case .unsupported: showUnsupportedNotice()
}
```

⚠️ **호출하는 순간 시스템 팝업이 뜹니다.** NearbyInteraction 에는 상태만 읽는 API가 없어
확인과 요청이 분리되지 않습니다. SDK가 시점을 정하지 않으니 앱 흐름에 맞는 자리에서
불러야 합니다.

⚠️ 한 번 거부되면 **앱에서 다시 물을 수 없습니다.** 설정 앱으로 유도하세요.

```swift
UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
```

---

## Step 4: 프로필

서버가 `profileId` 를 발급합니다. **앱이 보관해 재사용해야 합니다** — 방문·동선 데이터가
이 키로 귀속됩니다.

```swift
let profileId = savedProfileId ?? (try await OneS1ght.createProfile([
    "gender":   "F",
    "ageBand":  "20s",        // 정확한 나이가 아니라 연령대
    "interest": "cosmetics",
]))
OneS1ght.identify(profileId: profileId)
```

고객사 회원 ID는 OneS1ght에 오지 않습니다. `profileId` 만 오고, 그 매핑은 고객사만
보관합니다.

⚠️ 나이는 **연령대**로 넣기를 권합니다. 성별 + 정확한 나이 + 관심사 + 동선이 조합되면
재식별 가능성이 생깁니다.

| 함수 | 용도 |
|---|---|
| `createProfile(_:)` | 생성 — `profileId` 반환 |
| `getProfile(_:)` | 조회 |
| `putProfile(_:_:)` | 속성 전체 교체 |
| `deleteProfile(_:)` | 삭제 |
| `identify(profileId:)` | 연결 — 측위 전에 필수 |

---

## Step 5: 공간 선택

```swift
let buildings = try await OneS1ght.buildings()
let floors    = try await OneS1ght.floors(buildings[0].id)

try await OneS1ght.setFloorMap(floors[0], buildingID: buildings[0].id)
```

`setFloorMap` 은 로케이터·UWB 세션 ID·존을 받아 엔진에 주입합니다. 실행 중에 다시 호출하면
층이 전환되고 세션은 유지됩니다.

### 지도 그리기

```swift
let floor = try await OneS1ght.floor(buildings[0].id, floors[0].id)
mapView.setBackground(floor.image,
                      bounds: (floor.minX, floor.minY, floor.maxX, floor.maxY))
```

⚠️ `floors(_:)` 는 목록을 가볍게 유지하려고 `image == nil` 로 돌려줍니다. 그릴 층만 단건으로
받으면 캐시에서 나오므로 추가 요청이 발생하지 않습니다.

**예상 로그**

```
[I3001] 층 지정 — building=B1 floor=9f3a1c2e locators=4 zones=3
```

빠진 것이 있으면 코드가 대신 나옵니다.

```
[E3003] 층에 UWB 세션 없음 — floor=9f3a1c2e
```

---

## Step 6: 측위 시작

```swift
let session = try OneS1ght.floorSession()

session.onZoneEnter = { zone in showCoupon(zone) }
session.onZoneExit  = { zone in hideCoupon(zone) }
session.onZoneDwell = { zone, seconds in … }
session.onPosition  = { coord in mapView.moveMarker(coord) }
session.onTriggers  = { zoneId, triggers in handle(triggers) }

try await session.begin()
…
await session.end()
```

`floorSession()` 은 항상 같은 인스턴스를 돌려줍니다 — UWB 라디오·판정 엔진·좌표 버퍼가
기기당 하나뿐이라 세션이 여럿이면 물리적으로 충돌합니다.

**예상 로그**

```
[I4001] 측위 시작 — visitor=v-20260820-001
🎯 IN  · 화장품
좌표 240건 전송 → 서버 accepted 240
```

---

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

⚠️ `empty()` 는 쌓인 좌표를 **전송하지 않고 버립니다.** 전송은 `send()` 입니다.

---

## 부록

### 데이터가 흐르는 경로

```
initialize ─→ begin ─→ [UWB 좌표] ─┬─→ onPosition            (앱)
                                    ├─→ 버퍼 → 서버          (배치)
                                    └─→ 존 판정 ─┬─→ onZoneEnter/Exit
                                                 └─→ 서버 → onTriggers
```

`onZoneEnter` 는 온디바이스 판정 즉시 발화합니다. `onTriggers` 는 서버 응답 후에
도착하므로, 네트워크가 끊기면 앞의 것만 오고 뒤는 오지 않습니다.

### 배치 정책

| 트리거 | 값 |
|---|---|
| 건수 | 300건 |
| 주기 | 60초 |
| 백그라운드 전환 | 측위 정지 + 잔여 전송 |
| `end()` | 잔여 전송 |

⚠️ iOS의 UWB는 **포그라운드 전용**입니다. 백그라운드에서는 측위가 멈추고 복귀 시
재개됩니다 — 플랫폼 제약이라 우회할 수 없습니다.

⚠️ 버퍼는 인메모리입니다. 앱이 강제 종료되면 미전송 좌표는 유실됩니다.

---

## 트러블슈팅

모든 실패에는 코드가 붙습니다. 문의 시 함께 알려주세요.

| 증상 | 코드 | 첫 확인 |
|---|---|---|
| 앱은 도는데 좌표가 안 나온다 | `E3001` · `E3003` · `E4002` | 층 지정 여부 → UWB 세션 → 로케이터 배치 |
| 존 이벤트가 안 뜬다 | `E3004` | 콘솔에 존이 등록됐는지 |
| 특정 기기에서만 안 된다 | `E2001` · `E2002` | iOS 27 / iPhone 12 이상인지 |
| 권한 팝업이 다시 안 뜬다 | `E2003` | 이미 거부됨 — 설정 앱 유도 |
| 연동 직후 401 | `E1002` | 키 상태·환경(production/development) |
| 콘솔에 데이터가 안 보인다 | `E5001` · `E5006` | 네트워크 → 배치 주기 |

| 코드 | 의미 |
|---|---|
| `E1001` | SDK 미초기화 |
| `E1002` | SDK 키 무효 또는 폐기 |
| `E1003` | 테넌트에서 측위 비활성 |
| `E1004` | 프로필 미연결 |
| `E2001` | iOS 버전 미달 |
| `E2002` | UWB 미지원 기기 |
| `E2003` | 측위 권한 거부 |
| `E3001` | 층 미지정 |
| `E3002` | 층에 로케이터 없음 |
| `E3003` | 층에 UWB 세션 없음 |
| `E3004` | 층에 존 없음 |
| `E4001` | UWB 세션 실패 |
| `E4002` | 좌표 미산출 |
| `E4003` | 로케이터 일부 미수신 |
| `E5001` | 네트워크 실패 |
| `E5002` | 서버 오류 |
| `E5003` | 요청 형식 불일치 |
| `E5004` | 권한 없는 자원 접근 |
| `E5005` | 응답 해석 실패 |
| `E5006` | 미전송 좌표 유실 |

에러는 콘솔 로그 분석기로도 올라가므로, 테넌트 관리자가 앱을 거치지 않고 확인할 수
있습니다.

### 개발 중 SDK 로그 보기

```swift
OneS1ght.onDebugLog = { line in print(line) }
```

⚠️ 운영에서는 등록하지 않는 것을 권합니다.

---

## 문의

onesight-support@onecheck.co.kr
