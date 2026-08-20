//
//  SdkLocalized.swift  (SDK 로그/메시지 다국어)
//  OneS1ght
//
//  OS 언어가 일본어면 "ja", 영어면 "en", 그 외엔 "ko".
//  문구는 Resources/i18n/SdkLocalization.json 에 { "키": { "ko":…, "ja":…, "en":… } } 로 관리.
//  (앱과 독립 — SDK가 자기 리소스를 Bundle.module 로 읽어 스스로 변환. 추후 DB화 여지.)
//
//  사용:
//    SdkLocalized.text("provider.waiting")
//    SdkLocalized.format("provider.trackingStart", networkId)
//

import Foundation

enum SdkLocalized {

    /// 현재 언어 코드 — "ja" · "en" · "ko"(기본)
    static let language: String = {
        let code = (Locale.preferredLanguages.first ?? "ko").prefix(2).lowercased()
        switch code {
        case "ja": return "ja"
        case "en": return "en"
        default:   return "ko"
        }
    }()

    /// 로드된 문구 테이블: [키: [언어: 문구]]
    private static let table: [String: [String: String]] = {
        let url = Bundle.module.url(forResource: "SdkLocalization", withExtension: "json")
               ?? Bundle.module.url(forResource: "SdkLocalization", withExtension: "json", subdirectory: "i18n")
        guard let url,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return dict
    }()

    /// 키 → 현재 언어 문구 (없으면 한국어 기본, 그것도 없으면 키)
    static func text(_ key: String) -> String {
        table[key]?[language] ?? table[key]?["ko"] ?? key
    }

    /// 포맷 문구(%d/%@/%.2f …)에 인자를 채워 반환
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: text(key), arguments: args)
    }
}
