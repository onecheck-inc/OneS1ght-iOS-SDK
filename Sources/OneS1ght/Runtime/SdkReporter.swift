//
//  SdkReporter.swift
//  SDK 로그의 두 갈래 — 화면 로그(onDebugLog)와 서버 로그(콘솔 로그 분석기).
//
//  SessionCoordinator 에서 떼어 냈다(2026-10-02 감사 K7). 코디네이터가 한 타입에 책임 13개를 지고
//  있었고, S13(프로필 전 로그 유실)·K9(같은 사건 두 줄) 같은 결함이 이 경계에 몰려 있었다.
//

import Foundation

@MainActor
final class SdkReporter {

    /// 화면 로그 훅 — OneS1ght.onDebugLog 로 이어진다.
    var onLog: ((LogLevel, String) -> Void)?

    private let api: ApiClient
    /// 서버 로그를 귀속할 프로필 — 코디네이터가 identify 때 넣는다. 없으면 보내지 않고 붙든다
    /// (SdkLogBuffer.canSend — 감사 S13).
    var profileId: String?
    private(set) var buffer: SdkLogBuffer!

    init(api: ApiClient) {
        self.api = api
        self.buffer = SdkLogBuffer(canSend: { [weak self] in self?.profileId != nil }) { [weak self] batch in
            await self?.send(batch) ?? false
        }
    }

    /// 흐름 기록. 등급을 안 적으면 `.log` — 대다수가 그것이라 생략할 수 있게 둔다.
    func log(_ msg: String) { onLog?(.log, msg) }
    func log(_ level: LogLevel, _ msg: String) { onLog?(level, msg) }

    /// 코드 붙은 사건을 남긴다 — 화면 로그 한 줄 + 서버(코드 + 문맥).
    ///
    /// 서버로는 문구를 보내지 않는다: 읽는 사람이 기기 사용자가 아니라 관리자라 콘솔이 관리자 화면 언어로
    /// 렌더링해야 한다. 화면 줄은 `[코드] 문구 — 문맥` 이고, 문구는 `message`(기기 언어)가 있으면 그것을,
    /// 없으면 코드 요약을 쓴다. 줄의 등급은 코드의 세기(ERROR·WARN·INFO)와 같다.
    ///
    /// ⚠️ 호출부가 문구 로그를 따로 또 남기지 않는다. 예전엔 report() 가 이미 한 줄을 남기는데 호출부가
    ///    번역 문구를 한 줄 더 찍어 같은 사건이 두 번 보였고, 오류·정보 코드용 report 가 두 벌이었다(감사 K9).
    ///    진입점이 두 벌인 것은 `.initialized` 같은 점 표기를 쓰기 위해서다(프로토콜 존재 타입은 점 표기가
    ///    안 된다). 하는 일은 record() 한 곳에 있다.
    func report(_ code: SdkErrorCode, _ context: String = "", message: String? = nil) {
        record(code, context, message: message)
    }
    func report(_ code: SdkInfoCode, _ context: String = "", message: String? = nil) {
        record(code, context, message: message)
    }

    /// 서버 통신 실패를 코드로 옮겨 남긴다. ApiError 가 아니면 network 로 본다.
    func reportApi(_ error: Error, _ context: String = "", message: String? = nil) {
        record((error as? ApiError)?.code ?? SdkErrorCode.network, context, message: message)
    }

    private func record(_ code: LogCode, _ context: String, message: String?) {
        let text = message ?? code.summary
        log(code.serverLevel.logLevel,
            "[\(code.rawValue)] \(text)\(context.isEmpty ? "" : " — \(context)")")
        buffer.add(SdkLogEntry(code: code.rawValue, level: code.serverLevel.rawValue,
                               message: context, at: SessionCoordinator.iso(Date())))
    }

    /// 붙들어 둔 로그를 지금 보낸다(세션 종료·프로필 연결).
    func flush() async { await buffer.flush() }

    private func send(_ batch: [SdkLogEntry]) async -> Bool {
        // 프로필이 없으면 귀속할 곳이 없다 — 버퍼가 canSend 로 미리 걸러 여기 오지 않는다.
        guard let profileId else { return false }
        let req = ReqSdkLogs(profile_id: profileId, platform_name: SdkPlatform.name,
                             sdk_version: OneS1ght.sdkVersion, entries: batch)
        return (try? await api.sendLogs(req)) != nil
    }
}
