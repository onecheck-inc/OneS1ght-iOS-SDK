//
//  EngineLogRedirect.swift
//  측위 엔진의 파일 로그를 앱 Documents 밖으로 옮긴다
//
//  엔진은 릴리스 빌드에서도 파일 로그를 켜 두고 `Documents/<모듈>/yyyyMMdd.txt` 에 좌표까지 적는다.
//  Documents 는 기기 백업에 들어가고, 고객 앱이 파일 공유를 켜면 사용자에게도 보인다. 끄는 API 는 없다.
//  그래서 그 폴더 자리에 앱 tmp 로 가는 심볼릭 링크를 둔다 — 엔진은 그대로 쓰고, 파일은 tmp 에 쌓이며,
//  initialize 마다 지운다.
//
//  ⚠️ 폴더 자리에 빈 파일을 둬서 쓰기를 실패시키면 안 된다. 실패 경로에서 엔진 로거의 메모리가 샌다
//     (10만 줄에 약 65MB, 정상 경로는 약 12MB — 2026-11-04 시뮬레이터 실측).
//  ⚠️ 링크는 상대 경로여야 한다. 앱을 업데이트하면 컨테이너 절대 경로가 바뀐다.
//  ⚠️ 폴더는 지우지 않고 안의 파일만 지운다 — 엔진 로거는 폴더를 시작할 때 한 번만 만든다.
//

import Foundation

enum EngineLogRedirect {

    /// 파일 로그를 쓰는 엔진 모듈 — 폴더 이름이 곧 모듈 이름이다. 엔진을 올릴 때 다시 대조한다.
    static let moduleFolders = ["gpi-ihub", "gpi-dltdoa", "gpi-prm"]

    /// 앱 tmp 안에서 로그를 받는 폴더.
    static let holderFolder = "ones1ght-engine-log"

    /// 링크를 놓고 지난 로그를 지운다. 여러 번 불러도 된다.
    /// 실패해도 던지지 않는다 — 로그 위치 때문에 SDK 초기화가 막히면 안 된다.
    static func apply(documents: URL, fileManager fm: FileManager = .default) {
        let tmp = documents.deletingLastPathComponent().appendingPathComponent("tmp")
        for module in moduleFolders {
            let target = tmp.appendingPathComponent(holderFolder).appendingPathComponent(module)
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: file)
            }

            let link = documents.appendingPathComponent(module)
            let destination = "../tmp/\(holderFolder)/\(module)"
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) == destination { continue }
            // 이전 판이 남긴 진짜 폴더(지난 로그째)를 걷어낸다.
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: destination)
        }
    }
}
