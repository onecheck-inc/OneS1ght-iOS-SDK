#!/usr/bin/env bash
#
# 다음 내부 테스트 태그 이름을 정한다: v<버전>-rc.<N>, N = 있는 rc 중 최대 + 1.
# 개수 세기가 아니라 최댓값이다 — 중간 rc 가 지워졌어도 이미 쓴 번호를 다시 쓰지 않는다.
# 정식 태그 v<버전> 이 이미 있으면 실패한다: 배포된 판에 rc 를 더 달 이유가 없다.
#
# 사용:  Scripts/next-rc-tag.sh 0.2.0   →  v0.2.0-rc.3
#
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?사용법: next-rc-tag.sh <버전>}"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "v$VERSION 은 이미 정식 배포된 판입니다 — 다음 버전으로 release 브랜치를 새로 따세요." >&2
    exit 1
fi
LAST=$(git tag -l "v$VERSION-rc.*" | sed -n 's/.*-rc\.\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)
echo "v$VERSION-rc.$(( ${LAST:-0} + 1 ))"
