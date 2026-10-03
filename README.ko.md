# OneS1ght SDK for iOS

[English](README.md) | **한국어** | [日本語](README.ja.md)

OneS1ght SDK for iOS는 iOS 모바일 환경에서 UWB 통신을 통해 실시간으로 정확도가 높은 측위 데이터를 제공하고 제공된 데이터를 통해 세밀한 마케팅 인사이트를 제공합니다. 

SDK 에 대해 
- GitHub: https://github.com/onecheck-inc/OneS1ght-iOS-SDK
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
| 건물·층·로케이터 설치 | 통합관리자 (설치 시 함께 진행) |
| 구역(Zone) | OneS1ght 콘솔 → **공간 관리** |

---

## Step 1: 프로젝트 설정

Xcode → **File → Add Package Dependencies…** 에서 아래 주소를 입력합니다.

```
https://github.com/onecheck-inc/OneS1ght-iOS-SDK
```

`Package.swift` 로 붙이는 경우:

```swift
dependencies: [
    .package(url: "https://github.com/onecheck-inc/OneS1ght-iOS-SDK", from: "0.2.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "OneS1ght", package: "OneS1ght-iOS-SDK")
    ])
]
```

측위 엔진과 진출입 판정 엔진은 자동으로 함께 받아오므로 이 패키지 하나만 추가하면 됩니다.

### Info.plist

**네 개 모두** 필요합니다. 앞의 세 개는 없으면 권한을 요청하는 순간 앱이 종료됩니다.

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>매장 내 위치를 파악하는 데 사용합니다.</string>
<key>NSNearbyInteractionUsageDescription</key>
<string>UWB 정밀 측위에 사용합니다.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>주변 측위 장비를 찾는 데 사용합니다.</string>
<key>NSLocationTemporaryUsageDescriptionDictionary</key>
<dict>
    <key>Positioning</key>
    <string>정확한 실내 위치를 계산하는 데 사용합니다.</string>
</dict>
```

> ⚠️ `NSLocationTemporaryUsageDescriptionDictionary` 안의 키는 **`Positioning` 이어야
> 합니다.** SDK 가 정밀 위치 승격을 요청할 때 쓰는 이름과 글자까지 같아야 하며,
> 어긋나면 요청이 **오류도 로그도 없이 무시**됩니다.
>
> 권한 요청은 SDK 가 합니다 — 앱에서 `CLLocationManager` 를 따로 부를 필요가 없습니다.
> 사용자가 "대략적인 위치" 를 고르거나 권한을 거부하면 측위가 시작되지 않고
> `onDebugLog` 에 `E2003` 이 남습니다.

---

## Step 2: SDK 초기화

앱 시작 시 1회 호출합니다. 키를 검증하고, 백엔드 도달 여부를 확인하고, 테넌트 설정을
받아옵니다.

```swift
import OneS1ght

try await OneS1ght.initialize(sdkKey: "ock_sdk_…")
```

> 넣는 키는 이것 하나뿐입니다. 측위와 지도에 필요한 나머지 키는 **콘솔이 내려줍니다** —
> 앱에 심을 필요가 없고, 값을 바꿔도 앱을 다시 배포하지 않아도 됩니다. 통합관리자가
> 콘솔에서 설정합니다.

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

### 위치 권한 — SDK 가 묻습니다

UWB 세션에는 위치 권한(그리고 정밀 위치)이 필요합니다. **`begin()` 이 엔진을 켤 때 SDK 가 둘 다 직접
요청합니다** — 앱에서 `CLLocationManager` 를 부를 필요가 없습니다. 앱이 할 일은 Step 1 의 Info.plist 키 네 개를
넣는 것뿐입니다.

⚠️ `NSLocationWhenInUseUsageDescription` 이 없으면 iOS 는 요청을 답 없이 무시합니다. SDK 는 그 키를 먼저 확인해,
없으면 영영 기다리지 않고 시작을 접으며 `E2003`(`Info.plist missing …`)을 남깁니다.

사용자가 위치를 거부하면 측위가 시작되지 않습니다 — `E2003` 이 남고, 세션이 닫히며 `onStopped` 가
`.engineFailed` 로 옵니다(Step 6). 설정 앱으로 안내한 뒤 `begin()` 을 다시 부르세요.

### Nearby Interaction 권한

```swift
switch await OneS1ght.requestPermission() {
case .authorized:  break
case .denied:      showSettingsGuide()      // 재요청 불가 — 설정 앱으로 안내
case .unsupported: showUnsupportedNotice()
@unknown default:  break
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
// ⚠️ `savedProfileId ?? (try await ...)` 는 컴파일되지 않는다 —
//    `??` 오른쪽은 autoclosure 라 try/await 를 담을 수 없다.
let profileId: String
if let saved = savedProfileId {
    profileId = saved
} else {
    profileId = try await OneS1ght.createProfile([
        "gender":   "F",
        "ageBand":  "20s",        // 정확한 나이가 아니라 연령대
        "interest": "cosmetics",
    ])
}
OneS1ght.identify(profileId: profileId)
```

고객사 회원 ID는 OneS1ght에 오지 않습니다. `profileId` 만 오고, 그 매핑은 고객사만
보관합니다. `identify` 는 `initialize` 앞에 불러도, 뒤에 불러도 됩니다.

⚠️ 나이는 **연령대**로 넣기를 권합니다. 성별 + 정확한 나이 + 관심사 + 동선이 조합되면
재식별 가능성이 생깁니다.

| 함수 | 용도 |
|---|---|
| `createProfile(_:)` | 생성 — `profileId` 반환 |
| `fetchProfile(_:)` | 속성 조회 |
| `replaceProfile(_:attributes:)` | 속성 **전체** 교체 — 넘기지 않은 속성은 지워집니다 |
| `deleteProfile(_:)` | 삭제 |
| `identify(profileId:)` | 연결 — 측위 전에 필수 |

---

## Step 5: 공간 선택 (선택)

건너뛰어도 됩니다. 갱신된 로케이터는 BLE 로 자기 층을 알리므로, 엔진이 `begin()` 뒤 1~2초 안에 층을
스스로 찾습니다. 사람이 층을 골라야 하거나, 측위 전에 지도를 먼저 그리고 싶을 때만 직접 고르세요.

```swift
let buildings = try await OneS1ght.buildings()
let floors    = try await OneS1ght.floors(buildingId: buildings[0].id)

try await OneS1ght.setFloorMap(floors[0], buildingId: buildings[0].id)
```

`setFloorMap` 은 로케이터·UWB 세션 ID·존을 받아 엔진에 주입합니다. 실행 중에 다시 호출하면
층이 전환되고 세션은 유지됩니다.
처음에는 `buildingId` 를 함께 넘기세요 — 그 뒤로는 생략하면 직전 건물을 씁니다. 둘 다 없으면
`SdkError.floorNotSet`(`E3001`)을 던지고 지금 층은 그대로 둡니다. `setFloorMap(nil)` 은 층을 비웁니다.

### 엔진이 찾은 층 따라가기

```swift
let session = try OneS1ght.floorSession()
session.onFloorDetected = { floorId in
    guard let floorId else { return }              // nil = 층을 잃음
    // floorId 는 Floor.id 와 같은 값이다 — 그 층을 그리거나 setFloorMap 하면 된다.
}
```

⚠️ 층을 바꾸려고 측위를 끄지 **마세요.** 실행 중 `setFloorMap` 은 안전하고 세션을 유지합니다 —
끄면 엔진이 로케이터를 처음부터 다시 찾습니다.

### 지도 그리기

```swift
let floor = try await OneS1ght.floor(buildingId: buildings[0].id, floorId: floors[0].id)
mapView.setBackground(floor.image,
                      bounds: (floor.minX, floor.minY, floor.maxX, floor.maxY))
```

⚠️ `floors(buildingId:)` 는 목록을 가볍게 유지하려고 `image == nil` 로 돌려줍니다. 그릴 층만 단건으로
받으세요. 도면은 캐시해 두었다가 콘솔이 도면을 바꾸면(`.planChanged`) 버립니다.

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
session.onStopped   = { reason in
    switch reason {
    case .ended:        break
    case .engineFailed: showRetry()   // 원인(권한·Bluetooth)을 풀고 begin() 을 다시 부른다
    @unknown default:   break
    }
}

try await session.begin()
…
await session.end()
```

`floorSession()` 은 항상 같은 인스턴스를 돌려줍니다 — UWB 라디오·판정 엔진·좌표 버퍼가
기기당 하나뿐이라 세션이 여럿이면 물리적으로 충돌합니다.

엔진이 스스로 꺼지면 SDK 가 다시 켭니다(3·10·30초 뒤, 앱이 화면에 있을 때만). 그래도 안 되거나 사람이 풀어야
하는 원인(위치 권한·Bluetooth·라이선스)이면 SDK 가 **세션을 닫습니다** — `isRunning` 이 `false` 가 되고
`onStopped(.engineFailed)` 가 오므로 `begin()` 이 다시 먹습니다.

`onZoneDwell` 은 존의 `dwellSeconds` 가 지나면 방문당 한 번 옵니다. `dwellSeconds` 가 없는 존은 진입·이탈만
옵니다.

### 일시정지는 종료가 아닙니다

```swift
session.pause()      // 표시·수집만 멈춘다 — 엔진은 계속 돈다
session.resume()
session.isPaused
```

| | `pause()` | `end()` |
|---|---|---|
| 좌표 콜백 | 멈춤 | 멈춤 |
| 존 진입·이탈 | 멈춤 | 멈춤 |
| 서버 전송 | 멈춤 | 잔여 전송 후 멈춤 |
| 엔진 · 층 · 로케이터 | **유지** | 해제 |
| 돌아오는 비용 | 즉시 | 로케이터를 처음부터 찾음 |

"잠깐 내 위치를 숨긴다" 는 `pause()` 입니다. `end()` 는 공간을 떠날 때 씁니다. 일시정지는 백그라운드에
다녀와도 유지되고, `resume()`·`end()`·`begin()` 에서만 풀립니다. 재개하면 판정 상태를 비우므로, 멈춘 동안
걸어 나온 존의 늦은 이탈 이벤트는 오지 않습니다.

### 콘솔 변경 수신

```swift
session.onConfigChanged = { change in
    switch change {
    case .zonesChanged, .resyncNeeded: Task { await OneS1ght.refreshZones() }
    case .planChanged:                 reloadPlan()
    case .rulesChanged, .sdkConfigChanged: break
    @unknown default:                  break
    }
}
```

실시간 연결은 **층을 정했거나 측위가 도는 동안** 붙어 있습니다. 연달아 오면 1초쯤 접은 뒤 새로고침하세요 —
구역을 다시 받을 때마다 판정이 처음부터 시작됩니다.

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
| 초기화 | `initialize(sdkKey:baseURL:)` · `requestPermission()` · `reset()` · `defaultBaseURL` |
| 프로필 | `createProfile(_:)` · `fetchProfile(_:)` · `replaceProfile(_:attributes:)` · `deleteProfile(_:)` · `identify(profileId:)` |
| 공간 조회 | `buildings()` · `building(id:)` · `floors(buildingId:)` · `floor(buildingId:floorId:)` · `zones(buildingId:floorId:)` · `zone(buildingId:floorId:zoneId:)` · `locators(buildingId:floorId:)` |
| 층 지정 | `setFloorMap(_:buildingId:)` · `refreshZones()` |
| 측위 | `floorSession()` → `begin()` · `end()` · `pause()` · `resume()` · `isPaused` · `isRunning` |
| 세션 콜백 | `onZoneEnter` · `onZoneExit` · `onZoneDwell` · `onPosition` · `onTriggers` · `onFloorDetected` · `onStopped` · `onConfigChanged` |
| 버퍼 | `uploadPendingPositions()` · `discardPendingPositions()` |
| 조회 | `isInitialized` · `isDeviceAvailable` · `deviceAvailability` · `onDebugLog` · `setLanguage(_:)` · `sdkVersion` |
| 콘솔 제공 값 | `googleMapKey` |

⚠️ `discardPendingPositions()` 는 쌓인 좌표를 **전송하지 않고 버립니다.** 전송은 `uploadPendingPositions()` 입니다.

⚠️ 앱이 직접 쓰는 콘솔 값은 `googleMapKey` 하나입니다. 측위 라이선스·공간 서비스 주소는
SDK 가 내부에서만 쓰므로 밖으로 내주지 않습니다 — 앱이 알 필요도, 다룰 이유도 없습니다.

0.1.24 이후 바뀐 옛 이름(`floor(_:_:)`·`permissions()`·`send()`·`empty()`·`getProfile`·`putProfile`·
`setFloorMap(_:buildingID:)`·`Trigger.trigger_id` …)은 deprecated 경고만 내고 그대로 컴파일됩니다 —
[CHANGELOG](CHANGELOG.md) 참고.

### SDK enum 을 switch 할 때

SDK enum 은 마이너 판에서 케이스가 늘 수 있습니다. `ConfigChange`·`SdkErrorCode`·`ZoneEvent`·
`FloorSession.StopReason`·`PermissionStatus`·`OneS1ght.DeviceAvailability`·`LogLevel` 을 switch 할 때는
`@unknown default` 를 두세요 — 새 케이스가 빌드를 깨지 않습니다.

```swift
switch change {                 // ConfigChange
case .zonesChanged, .resyncNeeded: Task { await OneS1ght.refreshZones() }
case .planChanged:                 reloadPlan()
case .rulesChanged, .sdkConfigChanged: break
@unknown default:                  break    // 나중에 늘어난 케이스는 빌드를 깨지 않고 여기로 온다
}
```

없으면 빠짐없는 `switch` 가 새 케이스에서 컴파일 오류가 됩니다.

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

### 구역 판정은 어디서 하나

측위 엔진은 시작할 때 공간 서비스에서 받은 **자기 지오펜스**로 진입·이탈을 판정합니다.
`zones(buildingId:floorId:)` 로 받는 구역은 이름·ID 매핑용이라, 콘솔에서 판정 파라미터를 바꿔도 판정은
바뀌지 않습니다.

SDK 는 `refreshZones()` 때 구역 집합이 실제로 바뀌었는지(추가·삭제·다시 그림) 보고 바뀌었을 때만 엔진을
다시 읽힙니다. 엔진이 재시작되므로 **좌표가 1초 남짓 끊깁니다.** 그 간극을 「신호 끊김」으로 처리하는
UI 가 있다면 유예를 그보다 길게 두세요.

### 배치 정책

| 트리거 | 값 |
|---|---|
| 건수 | 300건 (버퍼가 닿는 순간) |
| 주기 | 60초 (실패한 전송도 이때 다시 보냄) |
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
| 앱은 도는데 좌표가 안 나온다 | `E3007` · `E3003` · `E4002` | 층 탐지(BLE) → UWB 세션 → 로케이터 배치 |
| 공간 목록이 비고 `floor()` 가 `notInitialized` | `E1007` | 콘솔의 측위 키 설정, `/config` 도달 여부 |
| 존 이벤트가 안 뜬다 | `E3004` · `E3009` | 콘솔에 존이 있는지, 존 이름이 엔진 영역과 같은지 |
| 데이터가 엉뚱한 층에 쌓인다 | `E3008` | 엔진 층과 콘솔 층이 다름 |
| 특정 기기에서만 안 된다 | `E2001` · `E2002` | iOS 27 / iPhone 12 이상인지 |
| `begin()` 직후 측위가 닫힌다 | `E2003` · `E2004` | 위치·Bluetooth 권한, Bluetooth 켜짐, Info.plist 키 |
| 연동 직후 401 | `E1002` | 키 상태·환경(production/development) |
| 콘솔에 데이터가 안 보인다 | `E5001` · `E5006` | 네트워크 → 배치 주기 |

| 코드 | 의미 |
|---|---|
| `E1001` | SDK 미초기화 |
| `E1002` | SDK 키 무효 또는 폐기 |
| `E1003` | 테넌트에서 측위 비활성 |
| `E1004` | 프로필 미연결 |
| `E1007` | 측위 키를 못 구함 (콘솔에 없음·조회 실패·측위 엔진이 거부) |
| `E2001` | iOS 버전 미달 |
| `E2002` | 측위 미지원 기기 (UWB 없음 또는 Bluetooth 미지원) |
| `E2003` | 측위 권한 거부 (또는 Info.plist 키 누락) |
| `E2004` | Bluetooth 꺼짐 |
| `E3001` | 건물 없이 `setFloorMap(floor)` 호출 (`SdkError.floorNotSet`). 층 없이 시작하는 것은 정상 경로라 올라가지 않음 |
| `E3002` | 층에 로케이터 없음 |
| `E3003` | 층에 UWB 세션 없음 |
| `E3004` | 층에 존 없음 |
| `E3006` | 로케이터 조회 실패 — 지도는 그대로 열림 |
| `E3007` | 층 미탐지 (BLE) |
| `E3008` | 엔진 층과 콘솔 층 불일치 |
| `E3009` | 엔진 영역 이름에 맞는 콘솔 존 없음 |
| `E4001` | UWB 세션 실패 / 엔진 정지 |
| `E4002` | 좌표 미산출 |
| `E4003` | 로케이터 일부 미수신 — **WARN, 측위는 계속됩니다** |
| `E4004` | 영역 판정 실패 (그 회차만) |
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
OneS1ght.onDebugLog = { level, line in print("[\(level)] \(line)") }
```

⚠️ 운영에서는 등록하지 않는 것을 권합니다.

---

## 문의

onesight-support@onecheck.co.kr
