#!/usr/bin/env bash
#
# 수동 릴리스 (비상용) — 평소엔 CI 가 한다.
#
#   release/x.y.z 에 머지  →  .github/workflows/prerelease.yml 이 v x.y.z-rc.N 태그 + Pre-release
#   main 에 머지           →  .github/workflows/release.yml    이 v x.y.z 태그 + Release
#
# 이 스크립트는 CI 가 죽었을 때 사람이 같은 절차를 밟기 위한 것이다. 검사는
# Scripts/check-release.sh, 태그 확인은 Scripts/verify-tag.sh 를 그대로 쓴다 —
# CI 와 사람이 다른 길을 타면 그 차이가 곧 사고다.
#
# 사용:  Scripts/release.sh 0.1.2
#
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "사용법: Scripts/release.sh <버전>   (예: 0.1.2)" >&2
    exit 1
fi
cd "$(dirname "$0")/.."
TAG="v$VERSION"

Scripts/check-release.sh "$VERSION"

echo "▸ 작업 트리 확인"
[[ -z "$(git status --porcelain)" ]] || { echo "  ✗ 커밋되지 않은 변경이 있다" >&2; exit 1; }
echo "  브랜치: $(git rev-parse --abbrev-ref HEAD)"

echo "▸ 태그 $TAG"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "  ✗ $TAG 이 이미 있습니다." >&2
    echo "    태그는 옮기지 마세요 — 그 태그로 고정해 둔 쪽이 조용히 다른 코드를 받게 됩니다." >&2
    echo "    다음 판올림 번호로 다시 시도하세요." >&2
    exit 1
fi
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"
echo "  ✓ 태그를 올렸습니다"

echo "▸ 태그가 실제로 담은 것 확인"
Scripts/verify-tag.sh "$TAG"

echo "▸ GitHub Release"
if command -v gh >/dev/null; then
    Scripts/changelog-section.sh "$VERSION" > "/tmp/release-$TAG.md"
    gh release create "$TAG" --title "$TAG" --notes-file "/tmp/release-$TAG.md" --latest
else
    echo "  gh 가 없어 Release 는 만들지 않았습니다 — 웹에서 $TAG 로 만들고 CHANGELOG [$VERSION] 을 붙이세요."
fi

echo
echo "$TAG 릴리스 완료."
echo "다음: 콘솔의 codes-<platform>.json minSdkVersion 을 $VERSION 로 올리고 배포하세요"
echo "      (MCP 가 그 값으로 스니펫·마이그레이션 URL 을 만듭니다)."
