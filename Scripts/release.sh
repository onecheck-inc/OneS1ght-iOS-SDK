#!/usr/bin/env bash
#
# 릴리스 — 버전 일치를 확인하고 태그를 단 뒤, **태그가 실제로 무엇을 담았는지 확인한다.**
#
# 이 스크립트가 있는 이유는 같은 실수가 두 번 났기 때문이다.
#
#   v0.1.0 을 달고 → Snippets/ios.json 을 추가   → 태그에 파일이 없어 MCP 가 404
#   v0.1.1 을 달고 → Migrations/ios.json 을 추가 → 같은 일이 반복
#
# 테스트는 "파일들의 버전이 서로 맞는가" 는 잡지만, "태그가 그 파일을 담았는가" 는
# 태그를 단 뒤에만 알 수 있다. 그래서 마지막 단계에서 실제 URL 을 두드려 본다.
#
# 사용:  Scripts/release.sh 0.1.2
#
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "사용법: Scripts/release.sh <버전>   (예: 0.1.2)" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "버전 형식이 올바르지 않습니다: $VERSION (x.y.z)" >&2
    exit 1
fi

cd "$(dirname "$0")/.."
REPO="onecheck-inc/onesight-mobile-swift"
TAG="v$VERSION"
FAIL=0

note() { printf '  %s\n' "$1"; }
bad()  { printf '  ✗ %s\n' "$1" >&2; FAIL=1; }
ok()   { printf '  ✓ %s\n' "$1"; }

echo "▸ 버전 일치 확인"

SRC_VERSION=$(grep -o 'sdkVersion = "[^"]*"' Sources/OneS1ght/OneS1ght.swift | head -1 | sed 's/.*"\(.*\)"/\1/')
SNIPPET_VERSION=$(python3 -c 'import json;print(json.load(open("Snippets/ios.json"))["sdkVersion"])')
MIGRATION_VERSION=$(python3 -c 'import json;print(json.load(open("Migrations/ios.json"))["currentVersion"])')

[[ "$SRC_VERSION" == "$VERSION" ]] || bad "OneS1ght.sdkVersion 이 $SRC_VERSION (기대: $VERSION)"
[[ "$SNIPPET_VERSION" == "$VERSION" ]] || bad "Snippets/ios.json 이 $SNIPPET_VERSION"
[[ "$MIGRATION_VERSION" == "$VERSION" ]] || bad "Migrations/ios.json 이 $MIGRATION_VERSION"
[[ $FAIL -eq 0 ]] && ok "세 곳 모두 $VERSION"

# 마이그레이션의 마지막 칸이 이 버전으로 끝나야 "최신으로 가는 길" 이 있다.
LAST_TO=$(python3 -c 'import json;m=json.load(open("Migrations/ios.json"))["migrations"];print(m[-1]["to"] if m else "")')
[[ "$LAST_TO" == "$VERSION" ]] || bad "마이그레이션 마지막 칸의 to 가 $LAST_TO — $VERSION 로 가는 경로가 없다"

grep -q "^## \[$VERSION\]" CHANGELOG.md || bad "CHANGELOG.md 에 [$VERSION] 항목이 없다"

echo "▸ 작업 트리 확인"
[[ -z "$(git status --porcelain)" ]] || bad "커밋되지 않은 변경이 있다"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
note "브랜치: $CURRENT_BRANCH"

echo "▸ 테스트"
if swift test >/dev/null 2>&1; then ok "swift test 통과"; else bad "swift test 실패"; fi

if [[ $FAIL -ne 0 ]]; then
    echo >&2
    echo "릴리스를 중단합니다. 위 항목을 고친 뒤 다시 실행하세요." >&2
    exit 1
fi

echo "▸ 태그 $TAG"
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "  ✗ $TAG 이 이미 있습니다." >&2
    echo "    태그는 옮기지 마세요 — 그 태그로 고정해 둔 쪽이 조용히 다른 코드를 받게 됩니다." >&2
    echo "    다음 판올림 번호로 다시 시도하세요." >&2
    exit 1
fi

git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"
ok "태그를 올렸습니다"

echo "▸ 태그가 실제로 담은 것 확인"
sleep 3   # raw.githubusercontent 반영을 잠깐 기다린다
for path in Snippets/ios.json Migrations/ios.json; do
    url="https://raw.githubusercontent.com/$REPO/$TAG/$path"
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url")
    if [[ "$code" == "200" ]]; then
        ok "$path"
    else
        bad "$path 가 태그에 없습니다 (HTTP $code) — MCP 가 이 파일을 못 읽습니다"
    fi
done

if [[ $FAIL -ne 0 ]]; then
    echo >&2
    echo "⚠️ 태그는 올라갔지만 파일이 빠졌습니다. 태그를 옮기지 말고" >&2
    echo "   빠진 파일을 더해 다음 번호로 다시 릴리스하세요." >&2
    exit 1
fi

echo
echo "$TAG 릴리스 완료."
echo "다음: 콘솔의 codes-<platform>.json minSdkVersion 을 $VERSION 로 올리고 배포하세요"
echo "      (MCP 가 그 값으로 스니펫·마이그레이션 URL 을 만듭니다)."
