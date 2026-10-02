//
//  LocalizationKeysTests.swift
//  SDK 문구표(SdkLocalization.json)와 코드가 맞는가 — 쓰는 키는 다 있고(세 언어), 안 쓰는 키는 없다.
//
//  예전엔 110개 중 40여 개가 아무 데서도 안 쓰였다(옛 존 엔진·동의·자체 레인징 시절 문구 — 감사 K8).
//  안 쓰는 문구는 번역할 때마다 사람 시간을 먹고, 고칠 때 엉뚱한 키를 고치게 만든다.
//

import XCTest

final class LocalizationKeysTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)     // Tests/OneS1ghtTests/이 파일
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func table() throws -> [String: [String: String]] {
        let url = Self.root.appendingPathComponent("Sources/OneS1ght/Resources/i18n/SdkLocalization.json")
        return try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
    }

    private func sources() throws -> String {
        let dir = Self.root.appendingPathComponent("Sources/OneS1ght")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// 코드가 부르는 키(`SdkLocalized.text("…")`·`format("…"`)는 전부 있고, 세 언어가 다 있다.
    func testEveryUsedKeyExistsInAllLanguages() throws {
        let t = try table()
        let src = try sources()
        let regex = try NSRegularExpression(pattern: #"SdkLocalized\.(?:text|format)\("([A-Za-z0-9_.]+)""#)
        let used = regex.matches(in: src, range: NSRange(src.startIndex..., in: src))
            .compactMap { Range($0.range(at: 1), in: src).map { String(src[$0]) } }
        XCTAssertFalse(used.isEmpty)
        for key in Set(used) {
            XCTAssertEqual(Set(t[key]?.keys ?? [:].keys), ["ko", "ja", "en"], "문구표에 없거나 언어가 빠진 키: \(key)")
        }
    }

    /// 안 쓰는 키가 없다. 엔진 오류표(uwb.err1…12·errUnknown)는 번호로 조립해 부르므로 뺀다.
    func testNoUnusedKeys() throws {
        let src = try sources()
        let unused = try table().keys.filter { key in
            !src.contains("\"\(key)\"") && key.range(of: #"^uwb\.err(\d+|Unknown)$"#, options: .regularExpression) == nil
        }
        XCTAssertEqual(unused.sorted(), [], "아무도 안 쓰는 문구")
    }
}
