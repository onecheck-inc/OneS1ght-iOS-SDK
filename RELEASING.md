# 릴리스 절차

SPM 라이브러리의 배포 실체는 **git 태그**다. 고객 Xcode 의 `from:` 은 태그 목록에서 고르고,
콘솔 MCP 는 태그 URL(`…/v0.1.23/Snippets/ios.json`)을 읽는다. 브랜치는 그 태그를 **누가 언제
다는지**를 정하는 절차일 뿐이다. 태그는 CI 가 단다 — 사람은 브랜치에 머지만 한다.

```
feature/*  ──PR──▶  release/x.y.z  ──PR──▶  main
                     │                       │
                     ▼ 머지마다               ▼ 머지 시 (버전이 새 번호일 때만)
                     v x.y.z-rc.N            v x.y.z
                     Pre-release             Release (Latest)
                     내부 테스트 앱만 받음     고객 from: 이 받음
```

| 브랜치 | 뜻 | CI 가 하는 일 |
|---|---|---|
| `release/x.y.z` | 이 판을 내부 테스트 중 | 푸시마다 검사 → `v x.y.z-rc.N` 태그 → **Pre-release** ([prerelease.yml](.github/workflows/prerelease.yml)) |
| `main` | 배포된 판 + 다음 판 준비 | 소스 `sdkVersion` 이 **태그 없는 번호**면 검사 → `v x.y.z` 태그 → **Release** ([release.yml](.github/workflows/release.yml)). 이미 태그된 번호면 아무것도 안 함 |
| 모든 PR | — | `swift test` + 릴리스 가능 상태 검사 ([test.yml](.github/workflows/test.yml)) |

## 1. 판올림 — `release/x.y.z` 를 딴다

```bash
git checkout -b release/0.2.0 origin/main
```

첫 커밋에서 **네 곳**을 같은 번호로 맞춘다. 하나라도 어긋나면 CI 가 멈춘다
([check-release.sh](Scripts/check-release.sh)).

| 파일 | 고칠 곳 |
|---|---|
| `Sources/OneS1ght/OneS1ght.swift` | `sdkVersion = "0.2.0"` — **단일 출처** |
| `Snippets/ios.json` | `sdkVersion` |
| `Migrations/ios.json` | `currentVersion` + 마지막에 `to: "0.2.0"` 인 칸 하나 (변경이 없어도 빈 칸을 둔다 — "최신으로 가는 길") |
| `CHANGELOG.md` | `## [0.2.0] — YYYY-MM-DD` 항목. 이 본문이 그대로 Release 노트가 된다 |

푸시하면 `v0.2.0-rc.1` 이 생긴다. 이후 고칠 것은 `release/0.2.0` 을 대상으로 PR — 머지마다 rc.2, rc.3 …

## 2. 내부 테스트 — 테스트 앱에서 rc 를 받는다

```swift
.package(url: "https://github.com/onecheck-inc/OneS1ght-iOS-SDK", exact: "0.2.0-rc.3")
```

고객은 `from: "0.1.0"` 같은 범위로 받는데, **SPM 은 범위 해석에서 프리릴리즈 태그를 제외한다**
(실측: `v1.0.0`·`v1.1.0-rc.1` 이 함께 있을 때 `from: "1.0.0"` 은 1.0.0 을 고른다).
rc 는 `exact:` 로만 받을 수 있으므로 고객 앱엔 절대 흘러가지 않는다.

## 3. 정식 배포 — `release/x.y.z` → `main` PR 을 머지한다

머지되면 CI 가 `v0.2.0` 태그를 달고 Release 를 만든다. Release 노트 끝에 **다음 단계**가 적힌다:
콘솔 `codes-ios.json` 의 `minSdkVersion` 을 올려 배포해야 MCP 가 새 판의 스니펫을 가리킨다
(콘솔 머지 = 배포 = 재시작이므로 자동화하지 않는다).

## 규칙

- **태그는 옮기지 않는다.** 빠진 게 있으면 다음 번호로 다시 릴리스한다. CI 도 기존 태그 위에는 아무것도 안 한다.
- **깨지는 변경이면 메이저를 올린다.** 고객이 전부 `from:`(= upToNextMajor) 이라 `0.x` 안에서는
  `0.1 → 0.2` 도 자동으로 따라간다. SemVer 는 0.x 마이너의 파괴적 변경을 허용하지만 SPM 은 안 가린다.
  CHANGELOG 의 **Breaking** 표시가 곧 "1.0.0 으로" 신호다.
- **문서·CI PR 은 main 직행이어도 된다.** 버전을 안 올리면 릴리스가 아니다.
- **핫픽스**도 같은 길이다 — `release/0.2.1` 을 main 에서 따서 rc 한 번 거친다. 급하면 main 직행 PR 로
  판올림 네 곳을 올려도 되지만, 그러면 내부 테스트 없이 바로 고객에게 나간다.
- **release 브랜치는 정식 배포 뒤 지운다.** 이미 정식 태그가 있는 번호의 release 브랜치에 푸시하면 CI 가 거절한다.

## CI 가 죽었을 때

[Scripts/release.sh](Scripts/release.sh) `<버전>` 이 같은 검사·태그·확인·Release 를 사람 손으로 밟는다.
CI 와 같은 스크립트([check-release.sh](Scripts/check-release.sh) · [verify-tag.sh](Scripts/verify-tag.sh) ·
[changelog-section.sh](Scripts/changelog-section.sh))를 쓴다 — 사람과 CI 가 다른 길을 타면 그 차이가 곧 사고다.
