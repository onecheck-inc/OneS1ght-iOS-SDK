//
//  GeospaceBuildingsResponse.swift
//  GeoSpace 건물 트리 응답 — 경계에서 층 ID 를 문자열로 정규화한다.
//
//  ⚠️ GeoSpace 는 floorId 를 **숫자로** 보낸다. 2026-08-20 에 같은 원인으로 콘솔 GCH 화면이
//     전부 500 이 났고(PR#461 에서 같은 방식으로 수습), SDK 에는 결함이 남아 있었다 —
//     String 으로 선언해 두면 JSON 디코딩이 통째로 실패하고, 호출부가 try? 로 감싸고 있어
//     오류가 사라진 채 빈 목록만 남는다. 증상은 "층이 안 뜬다" 뿐이라 원인에 닿기 어렵다.
//
//  숫자로 오든 문자열로 오든 **문자열로 받는다.** 콘솔 /floors 가 주는 형태와 같아야
//  두 경로에서 온 층 ID 를 같은 값으로 다룰 수 있다.
//

import Foundation

struct GeospaceBuildingsResponse: Decodable {
    let buildings: [BuildingDTO]

    struct BuildingDTO: Decodable {
        let buildingId: String
        let buildingName: String
        let floors: [FloorDTO]
    }

    struct FloorDTO: Decodable {
        let floorId: String
        let floorName: String
        let hasPlan: Bool

        private enum CodingKeys: String, CodingKey {
            case floorId, floorName, hasPlan
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            floorId = try Self.idString(from: c, forKey: .floorId)
            floorName = try c.decode(String.self, forKey: .floorName)
            hasPlan = try c.decodeIfPresent(Bool.self, forKey: .hasPlan) ?? false
        }

        /// 숫자·문자열 어느 쪽으로 와도 문자열로 돌려준다.
        ///
        /// 그 둘이 아니면 **던진다** — 그 층만 조용히 버리면 이번 같은 증상(빈 목록)이
        /// 다시 원인을 숨긴다. 형태가 또 바뀌면 시끄럽게 깨지는 편이 낫다.
        private static func idString(from c: KeyedDecodingContainer<CodingKeys>,
                                     forKey key: CodingKeys) throws -> String {
            if let s = try? c.decode(String.self, forKey: key) { return s }
            if let i = try? c.decode(Int.self, forKey: key) { return String(i) }
            throw DecodingError.typeMismatch(String.self, .init(
                codingPath: c.codingPath + [key],
                debugDescription: "floorId 가 문자열도 숫자도 아닙니다 — GeoSpace 응답 형태가 바뀌었는지 확인하세요"))
        }
    }
}
