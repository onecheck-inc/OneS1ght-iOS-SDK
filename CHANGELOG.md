# Changelog

이 파일은 사람이 읽는 릴리스 기록입니다.
코딩 에이전트가 읽는 **버전 간 코드 수정 지침**은 [`Migrations/ios.json`](Migrations/ios.json)에 따로 있습니다.

버전은 [유의적 버전](https://semver.org/lang/ko/)을 따릅니다. `0.x` 동안은 마이너 판올림에도
깨지는 변경이 들어갈 수 있으며, 그때는 아래에 **Breaking** 으로 표시하고 마이그레이션 파일에
고치는 방법을 함께 싣습니다.

---

## [0.1.8] — 2026-08-25

**실시간 수신이 측위를 시작하기 전에도 붙습니다.**

### Fixed

- `onConfigChanged` 가 **측위 세션 구간에만** 연결돼 있었습니다. 그래서 초기화만 하고 층을 골라
  도면을 보는 동안에는 콘솔에서 무엇을 바꿔도 앱이 알지 못했고, 수동 새로고침이 유일한 수단이었습니다.

  이제 **층을 지정하면 그 시점부터** 연결됩니다(측위가 돌고 있으면 종전처럼 계속 유지). 측위를
  껐다고 끊지도 않습니다 — 층을 계속 보고 있다면 콘솔 변경을 받을 이유는 그대로입니다.

  > 동시 연결 수를 동시 체류 인원으로 묶으려던 처음 설계의 대가였습니다. 층을 띄워 둔 기기는
  > 이미 쓰고 있는 기기라, 연결 수는 여전히 유계입니다.

## [0.1.7] — 2026-08-24

**빌딩을 골라도 층이 뜨지 않던 것을 고쳤습니다.**

### Fixed

- GeoSpace 건물 트리는 층 ID 를 **숫자**로 보내는데(`"floorId": 14`) SDK 디코더가 문자열로
  선언돼 있어 JSON 디코딩이 통째로 실패했습니다. 호출부가 오류를 삼키고 있어 증상은
  "층 목록이 비어 있다" 뿐이었고 원인은 드러나지 않았습니다.

  콘솔이 층을 0개로 주는 건물에서만 이 경로를 타므로, 그런 건물에서는 층을 아예 고를 수
  없었습니다. 이제 숫자로 오든 문자열로 오든 받습니다.

  > 같은 원인으로 2026-08-20 에 콘솔 화면이 500 을 낸 적이 있습니다. 그때 서버는 고쳤지만
  > SDK 에는 수정이 오지 않았습니다.

## [0.1.6] — 2026-08-21

코드 변경 없음. **연동 예제가 컴파일되지 않던 것을 고쳤습니다.**

### Fixed
- 프로필 발급 예제가 그대로는 컴파일되지 않았습니다.

  ```swift
  let profileId = savedProfileId ?? (try await OneS1ght.createProfile([...]))
  // error: operator can throw but expression is not marked with 'try'
  // error: 'async' call in an autoclosure that does not support concurrency
  ```

  `??` 오른쪽은 autoclosure 라 `try`/`await` 를 담을 수 없습니다. `if let` 으로 풀어 씁니다.

  ```swift
  let profileId: String
  if let saved = savedProfileId {
      profileId = saved
  } else {
      profileId = try await OneS1ght.createProfile(["gender": "F", "ageBand": "20s"])
  }
  OneS1ght.identify(profileId: profileId)
  ```

  README 3개 언어와 코딩 에이전트용 스니펫 모두 고쳤습니다. 스니펫에 컴파일되지 않는 패턴이
  들어가면 테스트가 잡습니다.

---

## [0.1.5] — 2026-08-21

코드 변경 없음. **저장소 주소가 바뀌었습니다.**

```
onecheck-inc/onesight-mobile-swift  →  onecheck-inc/OneS1ght-iOS-SDK
```

### Changed
- `Package.swift` 의 의존성 주소를 새 저장소로 바꿔 주세요.

  ```swift
  .package(url: "https://github.com/onecheck-inc/OneS1ght-iOS-SDK", from: "0.1.0"),
  .product(name: "OneS1ght", package: "OneS1ght-iOS-SDK"),
  ```

  ⚠️ **`package:` 식별자도 함께 바꿔야 합니다.** SPM 은 패키지 식별자를 저장소 이름에서
  뽑으므로, URL 만 고치면 `unknown package 'onesight-mobile-swift'` 로 빌드가 깨집니다.

  Xcode 프로젝트라면 패키지 의존성을 지웠다가 새 주소로 다시 추가하세요.

### 알아둘 것
옛 주소는 GitHub 이 리다이렉트해 주므로 당장 깨지지는 않습니다. 다만 그 이름으로 누가 새
저장소를 만들면 리다이렉트가 끊기므로, 지금 옮겨 두시는 편이 안전합니다.

---

## [0.1.4] — 2026-08-21

공개 API 변경 없음. 코드는 고칠 것이 없습니다.

### Fixed
- **서버 설정 때문에 초기화가 실패하던 문제.** `/auth/verify` 응답의 `remote_config` 를
  `[String: String]` 로 좁게 읽고 있어, 서버가 정수·불리언 설정을 담는 순간
  **응답 전체 디코드가 실패해 `initialize` 가 통째로 막혔습니다.**

  ```
  remote_config: { "logLevel": "INFO", "dataCollectionInterval": 30, "enableSpatialSensing": true }
                                                                ^^                        ^^^^
  ```

  이제 이 자루는 **최선노력**으로 읽습니다 — 값 종류가 섞여 있으면 문자열로 접고,
  아예 못 읽으면 비운 채 넘어갑니다. 설정 자루 하나 때문에 앱이 서지 않습니다.

- **디코드 실패가 무엇 때문인지 남습니다.** 예전에는 화면에 `decoding` 넉 자만 떠서
  어느 응답의 어느 필드인지 알 길이 없었습니다.

  ```
  응답 해석 실패 — ResVerify: remote_config.enableAiPrediction 의 타입이 다름 (기대 String)
  ```

  `ApiError` 가 사람이 읽을 문장을 내도록 바뀌었습니다(`ApiError.decoding` 에 사유가 붙습니다).

### 알아둘 것
⚠️ **0.1.3 이하는 현재 서버와 초기화되지 않습니다.** 서버가 이미 정수·불리언 설정을 내려주고
있어서, 0.1.4 로 올려야 합니다.

---

## [0.1.3] — 2026-08-21

공개 API 변경 없음. 코드는 고칠 것이 없습니다.

### Added
- **로케이터 수신 진단** — 측위 시작 7초 뒤 한 번, 등록한 로케이터 중 신호가 잡히지 않는 것이
  있으면 로그로 남깁니다. 로케이터가 죽어도 앱에서는 "좌표가 그냥 안 나온다"로만 보이는데,
  원인을 현장에서 특정할 유일한 온디바이스 단서입니다.

  ```
  [E4003] 로케이터 일부 미수신 — registered=4 received=3 missing=0x9DD7
  ```

- `PositioningProvider.positioningDiagnostic` (선택 채택, 기본 `nil`) —
  커스텀 provider 를 쓰고 있다면 구현하지 않아도 그대로 동작합니다.

### 알아둘 것
⚠️ `E4003` 은 **WARN 이고 측위를 막지 않습니다.** 앵커 세트는 마스터 1대와 서브 여러 대로
이루어지고, 마스터가 살아 있는 한 서브가 빠져도 측위는 계속됩니다 — 감도가 떨어질 뿐입니다.
고장이 아니라 **유지보수 신호**로 읽으세요.

마스터가 빠졌는지 서브가 빠졌는지는 SDK 가 알 수 없습니다(주소만 압니다). 그래서 판정하지 않고
사실만 남깁니다 — 판단은 현장에서 기기 라벨과 대조해야 합니다.

신호는 3대 이상 잡히는데 좌표가 안 나오면 `E4002`(ERROR)입니다. 등록 좌표와 실제 배치가
어긋났을 가능성이 큽니다. 잡힌 것이 3대 미만이면 좌표가 없는 게 당연하므로 이 코드를 내지 않습니다.

---

## [0.1.2] — 2026-08-20

공개 API 변경 없음. 의존성 해석만 다시 하면 됩니다.

### Added
- `Migrations/ios.json` — 버전 간 코드 수정 지침. 코딩 에이전트(MCP)가 읽어
  "지금 0.1.0 인데 최신으로 올리려면" 에 답합니다.
- `CHANGELOG.md` — 이 파일.
- `Scripts/release.sh` — 태그를 단 뒤 **그 태그가 실제로 무엇을 담았는지 확인**합니다.

### Fixed
- `v0.1.1` 태그가 마이그레이션 파일보다 먼저 만들어져 그 파일을 담고 있지 않았습니다.
  v0.1.0 → v0.1.1 과 같은 일이 반복된 것이라, 이번에는 릴리스 스크립트로 절차를 고정했습니다.

---

## [0.1.1] — 2026-08-20

공개 API 변경 없음. 의존성 해석만 다시 하면 됩니다.

### Added
- `Snippets/ios.json` — 연동 10단계의 실제 코드. 각 단계에 그 자리에서 날 수 있는 에러 코드,
  조용히 실패하는 지점의 경고, 성공 시 찍히는 로그를 함께 실었습니다.
  코딩 에이전트(MCP)가 이 파일을 받아 고객사 코드에 씁니다.
- `Migrations/ios.json` — 버전 간 코드 수정 지침.
- 스니펫이 SDK 와 어긋나면 빌드가 깨지는 테스트(`SnippetsTests`).

### Fixed
- `v0.1.0` 태그가 스니펫 파일보다 먼저 만들어져 그 파일을 담고 있지 않았습니다.
  태그를 옮기지 않고 이 판을 새로 냅니다 — 이미 나간 태그의 내용이 바뀌면
  그 태그로 고정해 둔 쪽이 조용히 다른 코드를 받게 됩니다.

---

## [0.1.0] — 2026-08-20

첫 공개 릴리스. UWB(DL-TDoA) 실내 측위 SDK 입니다.

### Added
- **공개 API** — 정적 파사드(`OneS1ght`)와 층 세션(`FloorSession`)으로 갈랐습니다.
  `initialize` 는 키 검증과 기기 게이트까지만 하고, 공간 선택은 `setFloorMap` 이 맡습니다.
- **프로필** — 서버가 `profileId` 를 발급하고 앱이 보관해 재사용합니다.
  기기마다 익명 ID 를 만들지 않으므로 같은 사람이 기기 수만큼 갈라지지 않습니다.
  고객사 회원 ID 는 서버로 오지 않습니다.
- **에러 코드 26개**(E 20 · I 6) — 실패마다 고정된 식별자가 남고, 콘솔 로그 분석기로 올라가
  관리자가 앱에 붙지 않고도 원인을 봅니다.
- **측위 엔진** — `gpi-dltdoa` 2.1.0 · `gpi-prm` 2.0.0 을 SPM 으로 참조합니다.
  바이너리를 이 레포에 품지 않으므로 엔진 갱신이 곧바로 따라옵니다.
- **배치 전송** — 좌표 300건 또는 60초. 서버가 정한 초당 측위 횟수(기본 4Hz)를 받아
  전송량만 줄이고, 구역 판정은 원래 속도 그대로 돕니다.
- README 3개 언어(en/ko/ja).

### 요구 사항
| 항목 | 값 |
|---|---|
| 측위 동작 | iOS 27.0+ · iPhone 12 이상(UWB) |
| 패키지 | iOS 15.0+ — 미지원 기기에서도 앱은 정상 동작하고 SDK 만 비활성 |
| 빌드 | Xcode 26.6+ |

### 알아둘 것
- iOS 의 UWB 는 **포그라운드 전용**입니다. 백그라운드에서는 측위가 멈춥니다.
- 좌표 버퍼는 메모리에 있습니다. 앱이 강제 종료되면 미전송분이 사라집니다(`E5006`).
- **위치 권한이 측위의 전제 조건**입니다. 없으면 세션이 `INVALID_CONFIGURATION` 으로 실패합니다.
- LICENSE 는 아직 없습니다. 사용 조건은 별도 계약을 따릅니다.

[0.1.3]: https://github.com/onecheck-inc/OneS1ght-iOS-SDK/releases/tag/v0.1.3
[0.1.2]: https://github.com/onecheck-inc/OneS1ght-iOS-SDK/releases/tag/v0.1.2
[0.1.1]: https://github.com/onecheck-inc/OneS1ght-iOS-SDK/releases/tag/v0.1.1
[0.1.0]: https://github.com/onecheck-inc/OneS1ght-iOS-SDK/releases/tag/v0.1.0
