//
//  PositioningMode.swift
//  측위 모드 — 층을 누가 정하고 로케이터 정보를 어디서 받는가.
//
//  · automatic — 측위 엔진이 근처 로케이터 신호로 층을 스스로 정하고, 로케이터·세션 정보도
//                엔진이 자기 서버에서 받는다. 앱은 begin() 만 부른다. (기본값)
//  · manual    — 앱이 건물·층을 고른다. `setFloorMap(_:buildingID:)` 로 넣은 층의 로케이터
//                좌표·세션 ID(콘솔 값)로 SDK 가 UWB 측위를 직접 돌린다. 엔진 쪽에 층·로케이터가
//                등록(프로비저닝)돼 있지 않은 현장에서도 콘솔 정보만 있으면 측위가 된다.
//                이 모드에서는 Nearby Interaction 권한을 사용자에게 묻는다.
//
//  모드는 `OneS1ght.positioningMode` 로 고르고, `begin()` 시점의 값이 그 세션에 적용된다.
//  세션 중에 바꾸면 다음 begin() 부터 반영된다.
//

import Foundation

public enum PositioningMode: String, Sendable, CaseIterable {
    /// 엔진이 층을 정한다 (기본). 앱은 층을 고르지 않는다.
    case automatic
    /// 앱이 건물·층을 고른다. begin() 전에 setFloorMap 이 끝나 있어야 한다.
    case manual
}
