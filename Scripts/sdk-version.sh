#!/usr/bin/env bash
#
# 소스의 버전 한 줄을 찍는다 — OneS1ght.sdkVersion 이 판올림의 단일 출처다.
# CI 와 다른 스크립트가 이 값을 기준으로 태그·검사를 한다.
#
set -euo pipefail
cd "$(dirname "$0")/.."
grep -o 'sdkVersion = "[^"]*"' Sources/OneS1ght/OneS1ght.swift | head -1 | sed 's/.*"\(.*\)"/\1/'
