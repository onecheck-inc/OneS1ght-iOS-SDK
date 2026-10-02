//
//  IdentityStore.swift
//  식별자 규약 (사양서 §4)
//
//  · profile_id   : SDK 가 만들지 않는다. 고객사가 identify(profileId:) 로 넘긴다.
//                   이 SDK 가 놓이는 자리(근태·매장·행사)는 전부 인증이 앞에 있어,
//                   기기 단위 익명 ID 를 따로 두면 같은 사람이 기기 수만큼 갈라진다.
//  · visitor_id   : 방문 1건마다 "v-YYYYMMDD-NNN" (NNN = 그날 방문 카운터, 001부터)
//
//  ⚠️ 0.1.24 까지 있던 Keychain 저장소(SecureStore·KeychainSecureStore)는 지웠다 — 익명 ID 를 없앤 뒤로
//     아무것도 쓰지도 읽지도 않았다(2026-10-02 감사 K8). 공개 타입이었으므로 CHANGELOG Breaking 에 적었다.
//

import Foundation

/// 방문 ID 발급기 — SDK 내부 전용.
final class IdentityStore {

    private enum Key {
        static let visitorDate = "onesight.visitor.date"     // UserDefaults
        static let visitorSeq  = "onesight.visitor.seq"      // UserDefaults
    }

    private let defaults: UserDefaults
    private let now: () -> Date          // 주입 가능한 시계 (날짜 리셋 테스트용)

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// 방문 ID 발급 — "v-YYYYMMDD-NNN". 호출할 때마다 그날 카운터 +1, 날짜 바뀌면 001부터
    func newVisitorId() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        let today = formatter.string(from: now())

        var seq = defaults.integer(forKey: Key.visitorSeq)
        if defaults.string(forKey: Key.visitorDate) != today {
            seq = 0                                          // 날짜 넘어감 → 카운터 리셋
            defaults.set(today, forKey: Key.visitorDate)
        }
        seq += 1
        defaults.set(seq, forKey: Key.visitorSeq)
        return String(format: "v-%@-%03d", today, seq)
    }
}
