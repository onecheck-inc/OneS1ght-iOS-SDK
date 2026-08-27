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

    /// 앱이 지정한 언어를 담아 두는 상자. 여러 스레드에서 읽히므로 잠금을 건다.
    private final class LanguageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        var code: String? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); defer { lock.unlock() }; value = newValue }
        }
    }
    private static let box = LanguageBox()

    /// SDK 가 로그·안내에 쓸 언어를 앱이 지정한다. `nil` 이면 기기 언어를 따른다.
    ///
    /// 앱이 자체 언어 설정을 가지고 있으면 기기 언어와 어긋난다 — 그때 SDK 만 기기 언어로
    /// 남아 로그 창에 다른 말이 섞인다. 앱이 자기 선택을 알려줄 길이 필요하다.
    /// 아는 언어(ko·ja·en) 밖의 값은 무시하고 기기 언어로 돌아간다.
    static func setLanguage(_ code: String?) {
        box.code = code.flatMap { ["ko", "ja", "en"].contains($0) ? $0 : nil }
    }

    /// 현재 언어 코드 — "ja" · "en" · "ko"(기본).
    /// 앱이 지정했으면 그 값을, 아니면 기기 언어를 쓴다.
    ///
    /// ⚠️ `static let` 으로 한 번만 계산하던 값이었다. 그러면 앱이 실행 중에 언어를 바꿔도
    /// SDK 문구만 처음 값에 묶인 채 남는다(실기기 확인).
    static var language: String {
        if let chosen = box.code { return chosen }
        let code = (Locale.preferredLanguages.first ?? "ko").prefix(2).lowercased()
        switch code {
        case "ja": return "ja"
        case "en": return "en"
        default:   return "ko"
        }
    }

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
