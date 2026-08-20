//
//  IdentityStore.swift
//  식별자 규약 (사양서 §4)
//
//  · profile_id      : SDK 가 만들지 않는다. 고객사가 identify(profileId:) 로 넘긴다.
//                   이 SDK 가 놓이는 자리(근태·매장·행사)는 전부 인증이 앞에 있어,
//                   기기 단위 익명 ID 를 따로 두면 같은 사람이 기기 수만큼 갈라진다.
//  · visitor_id   : 방문 1건마다 "v-YYYYMMDD-NNN" (NNN = 그날 방문 카운터, 001부터)
//
//  Keychain은 SecureStore 프로토콜 뒤로 — 테스트는 인메모리 가짜 주입, 실기기는 KeychainSecureStore.
//

import Foundation
import os

// MARK: - 저장 추상화

/// 영속 문자열 저장 계약 (Keychain 자리)
public protocol SecureStore {
    func read(_ key: String) -> String?
    func write(_ key: String, _ value: String)
}

// MARK: - IdentityStore

public final class IdentityStore {

    private enum Key {
        static let visitorDate = "onesight.visitor.date"     // UserDefaults
        static let visitorSeq  = "onesight.visitor.seq"      // UserDefaults
    }

    private let secure: SecureStore
    private let defaults: UserDefaults
    private let now: () -> Date          // 주입 가능한 시계 (날짜 리셋 테스트용)

    public init(secure: SecureStore = KeychainSecureStore(),
                defaults: UserDefaults = .standard,
                now: @escaping () -> Date = Date.init) {
        self.secure = secure
        self.defaults = defaults
        self.now = now
    }

    /// 방문 ID 발급 — "v-YYYYMMDD-NNN". 호출할 때마다 그날 카운터 +1, 날짜 바뀌면 001부터
    public func newVisitorId() -> String {
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

// MARK: - Keychain 구현 (실기기용 — kSecClassGenericPassword)

/// 표준 Keychain 래퍼. 권한·팝업 불필요 (카카오·Firebase 동일 관행).
/// 재설치 후 유지는 사실상 동작이나 OS 보증은 아님 — 날아가면 새 익명 유저로 시작해도 무해.
public final class KeychainSecureStore: SecureStore {

    private let service = "co.onecheck.ones1ght.sdk"
    private let log = Logger(subsystem: "co.onecheck.ones1ght", category: "Keychain")

    public init() {}

    public func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {          // "없음"은 정상 (최초 실행)
                log.error("keychain read 실패: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        // add 먼저 → 중복이면 update (상태코드 확인 — 조용한 실패 금지)
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key,
            ]
            status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        if status != errSecSuccess {
            log.error("keychain write 실패: \(status) — 영속 안 됨 (다음 실행 시 새 ID)")
        }
    }
}
