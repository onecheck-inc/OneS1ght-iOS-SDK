#!/usr/bin/env bash
#
# CHANGELOG.md 에서 한 버전의 본문만 뽑는다 — GitHub Release 의 릴리스 노트가 된다.
# `## [x.y.z] — 날짜` 헤더 다음 줄부터, 다음 `## [` 헤더(또는 파일 끝의 `[x.y.z]: url` 링크
# 참조 목록) 직전까지. 앞뒤 빈 줄은 뗀다.
#
# 사용:  Scripts/changelog-section.sh 0.1.23
#
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?사용법: changelog-section.sh <버전>}"
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md 에 [$VERSION] 항목이 없다" >&2; exit 1; }
awk -v v="$VERSION" '
    /^## \[/            { if (found) exit; if (index($0, "## [" v "]") == 1) { found = 1; next } }
    /^\[[0-9.]+\]: /    { if (found) exit }
    found               { lines[n++] = $0 }
    END {
        s = 0; e = n - 1
        while (s <= e && lines[s] ~ /^[[:space:]]*$/) s++
        while (e >= s && lines[e] ~ /^[[:space:]]*$/) e--
        for (i = s; i <= e; i++) print lines[i]
    }
' CHANGELOG.md
