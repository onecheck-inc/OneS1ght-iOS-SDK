# SDK 테스트판·정식판 내는 법

**한 줄 요약** — 테스트판은 `release/버전` 브랜치에 올리면 자동으로 나오고, 정식판은 그 브랜치를 `main` 에
머지하면 자동으로 나옵니다. 사람이 태그를 달지 않습니다.

| | 테스트판 | 정식판 |
|---|---|---|
| 이름 | `v0.1.24-rc.1`, `-rc.2` … | `v0.1.24` |
| 누가 받나 | 온보딩 앱 등 **우리 테스트 앱만** (고객 앱엔 절대 안 감) | **고객 앱** (Xcode 가 자동으로 받음) |
| 어떻게 나오나 | `release/0.1.24` 브랜치에 푸시·머지될 때마다 | `release/0.1.24` → `main` PR 이 머지될 때 |
| 어디서 보나 | [Releases 페이지](https://github.com/onecheck-inc/OneS1ght-iOS-SDK/releases) **Pre-release** 딱지 | 같은 페이지 **Latest** 딱지 |

---

## A. 테스트판 내기 (예: 0.1.24)

### 1. 브랜치 만들기
```bash
git fetch origin
git checkout -b release/0.1.24 origin/main
```
브랜치 이름은 반드시 `release/` + 버전. 이 이름의 숫자와 소스의 버전이 다르면 CI 가 멈춥니다.

### 2. 버전 올리기 — 파일 네 개
| 파일 | 고칠 곳 |
|---|---|
| `Sources/OneS1ght/OneS1ght.swift` | `public static let sdkVersion = "0.1.24"` |
| `Snippets/ios.json` | `"sdkVersion": "0.1.24"` |
| `Migrations/ios.json` | `"currentVersion": "0.1.24"` 로 바꾸고, `migrations` 배열 **맨 끝**에 칸 하나 추가 ↓ |
| `CHANGELOG.md` | 맨 위에 `## [0.1.24] — 2026-09-16` 항목과 내용. 이 내용이 그대로 릴리스 노트가 됩니다 |

`Migrations/ios.json` 에 추가할 칸 (앱 코드 고칠 게 없어도 넣습니다 — "최신으로 가는 길" 이 있어야 합니다):
```json
{
  "from": "0.1.23",
  "to": "0.1.24",
  "breaking": false,
  "summary": "무엇이 바뀌었는지 한두 문장.",
  "action": "앱 코드에서 할 일. 없으면: 의존성 해석만 다시 하면 된다. 코드는 고칠 것이 없다.",
  "changes": []
}
```

네 곳이 맞는지 푸시 전에 확인:
```bash
SKIP_TESTS=1 Scripts/check-release.sh
```
`0.1.24 내보낼 수 있음.` 이 뜨면 됩니다. ✗ 가 뜨면 그 줄이 말하는 파일을 고칩니다.

### 3. 푸시
```bash
git add -A
git commit -m "chore: 0.1.24"
git push -u origin release/0.1.24
```

### 4. 3분쯤 기다리기
[Actions](https://github.com/onecheck-inc/OneS1ght-iOS-SDK/actions) 의 `prerelease` 가 초록이 되면
[Releases](https://github.com/onecheck-inc/OneS1ght-iOS-SDK/releases) 에 **`v0.1.24-rc.1` (Pre-release)** 가 생깁니다.
빨강이면 → 아래 "CI 가 빨강일 때".

### 5. 테스트 앱에서 받기
Xcode → 프로젝트 → **Package Dependencies** 탭 → `OneS1ght-iOS-SDK` 더블클릭 →
Dependency Rule 을 **Exact Version** 으로, 값 `0.1.24-rc.1`.
(`Package.swift` 라면 `.package(url: "https://github.com/onecheck-inc/OneS1ght-iOS-SDK", exact: "0.1.24-rc.1")`)

테스트가 끝나면 규칙을 원래대로(**Up to Next Major**) 되돌려 둡니다.

### 6. 고칠 게 나오면
```bash
git checkout -b fix/무엇 release/0.1.24
# 고치고 커밋
git push -u origin fix/무엇
```
GitHub 에서 PR — **base 를 `release/0.1.24`** 로. 머지되면 `v0.1.24-rc.2` 가 자동으로 나옵니다. 반복.

---

## B. 정식판 내기

### 1. PR 만들기
GitHub 에서 PR — base **`main`** ← compare **`release/0.1.24`**. `test` 체크가 초록인지 확인.

### 2. 머지

### 3. 3분쯤 기다리기
Actions 의 `release` 가 초록이 되면 Releases 에 **`v0.1.24` (Latest)** 가 생깁니다. 이 순간부터 고객 Xcode 가 이 판을 받습니다.

### 4. 콘솔 값 올리기 (이건 손으로)
`console` 레포 `backend-spring/src/main/resources/sdk/codes-ios.json` 의 `"minSdkVersion"` 을 `"0.1.24"` 로 → PR → 배포.
코딩 에이전트(MCP)가 이 값으로 새 판의 스니펫을 가리킵니다. 콘솔 배포는 서버 재시작이므로 시점은 조율해서.
(릴리스 노트 맨 아래에도 이 안내가 자동으로 적혀 있습니다.)

### 5. 브랜치 지우기
```bash
git push origin --delete release/0.1.24
```

---

## C. 급한 수정 (핫픽스)
똑같이 A → B 를 다음 번호(`release/0.1.25`)로. rc 한 번은 거칩니다.
정말 급하면 `main` 으로 바로 PR 을 내고 2번의 네 파일을 올려도 됩니다 — 단, 테스트판 없이 바로 고객에게 나갑니다.

---

## CI 가 빨강일 때

| 메시지 | 뜻 | 할 일 |
|---|---|---|
| `브랜치는 release/0.1.24 인데 소스 sdkVersion 은 0.1.23` | A-2 를 안 함 | 네 파일 올리고 다시 푸시 |
| `Snippets/ios.json 이 0.1.23` / `Migrations/ios.json 이 0.1.23` | 그 파일만 안 올림 | 그 파일 고침 |
| `마이그레이션 마지막 칸의 to 가 0.1.23` | Migrations 에 칸 추가 안 함 | 칸 추가 |
| `CHANGELOG.md 에 [0.1.24] 항목이 없다` | CHANGELOG 안 씀 | 항목 추가 |
| `swift test 실패` | 테스트 깨짐 | 로컬에서 `swift test` |
| `v0.1.24 은 이미 정식 배포된 판입니다` | 이미 나간 번호에 rc 를 더 달려 함 | `release/0.1.25` 로 새로 |

## 규칙 (지키지 않으면 고객이 다칩니다)
- **태그는 절대 지우거나 옮기지 않습니다.** 잘못 나갔으면 다음 번호로 다시 냅니다.
- **고객 코드를 고쳐야 하는 변경이면 `1.0.0` 으로 올립니다.** 고객 Xcode 는 `0.x` 안에서 `0.1 → 0.2` 도 자동으로 받기 때문에, `0.2.0` 에 깨지는 변경을 넣으면 고객 앱이 어느 날 갑자기 안 됩니다.
- `main` 에 문서·CI 만 고친 PR 을 머지하면 **아무 일도 일어나지 않습니다** (버전을 안 올렸으니 정상).

## CI 자체가 죽었을 때
`main` 에서 `Scripts/release.sh 0.1.24` — CI 가 하는 검사·태그·확인·Release 를 사람 손으로 똑같이 밟습니다.
