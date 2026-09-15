#!/usr/bin/env bash
#
# 올린 태그가 실제로 무엇을 담았는지 확인한다.
#
# v0.1.0 · v0.1.1 에서 같은 사고가 두 번 났다 — 태그를 먼저 달고 그 뒤에 Snippets/ios.json,
# Migrations/ios.json 을 추가해서 태그에 파일이 없어 MCP 가 404 를 받았다. 테스트는
# "파일들의 버전이 서로 맞는가" 는 잡지만 "태그가 그 파일을 담았는가" 는 태그를 단 뒤에만
# 알 수 있다. 그래서 MCP 가 읽는 바로 그 URL 을 두드려 본다.
#
# 사용:  Scripts/verify-tag.sh v0.1.23
#
set -euo pipefail
REPO="onecheck-inc/OneS1ght-iOS-SDK"
TAG="${1:?사용법: verify-tag.sh <태그>}"
FAIL=0
for path in Snippets/ios.json Migrations/ios.json; do
    url="https://raw.githubusercontent.com/$REPO/$TAG/$path"
    code=000
    for _ in 1 2 3 4 5 6; do            # raw.githubusercontent 반영이 몇 초 늦을 수 있다
        code=$(curl -s -o /dev/null -w '%{http_code}' "$url")
        [[ "$code" == "200" ]] && break
        sleep 5
    done
    if [[ "$code" == "200" ]]; then printf '  ✓ %s\n' "$path"
    else printf '  ✗ %s 가 태그에 없습니다 (HTTP %s) — MCP 가 이 파일을 못 읽습니다\n' "$path" "$code" >&2; FAIL=1; fi
done
if [[ $FAIL -ne 0 ]]; then
    echo >&2
    echo "⚠️ 태그는 올라갔지만 파일이 빠졌습니다. 태그를 옮기지 말고" >&2
    echo "   빠진 파일을 더해 다음 번호로 다시 릴리스하세요." >&2
    exit 1
fi
echo "$TAG 확인 완료."
