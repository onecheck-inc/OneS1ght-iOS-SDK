// swift-tools-version: 5.9
//
//  OneS1ghtSDK — OneS1ght 실내 위치 인텔리전스 SDK (iOS / Swift)
//
//  · 측위(gpi-dltdoa)·판정(gpi-prm) 엔진은 Geoplan 의 공개 릴리스 레포를 SPM 으로 참조한다.
//    둘 다 public 이므로 고객은 이 패키지 하나만 추가하면 엔진이 함께 따라온다.
//    (~2026-08-20 까지는 gpi-dltdoa 를 xcframework 로 이 레포에 복사해 품었으나,
//     2.1.0 바이너리가 gpi-logger 를 참조하면서 복사본으로는 그 링크 전파가 끊긴다.)
//  · 측위 어댑터(UwbPositioningProvider)는 iOS 27 심볼 필요 → #if os(iOS) 가드.
//    맥에서는 해당 파일이 비워져 코어(통신·판정) 테스트가 그대로 돈다.
//  · Geoplan 엔진 2종은 iOS 전용 바이너리 → iOS 타깃에만 조건부 링크.
//  · 정식 태그로 고정(exact) — 브랜치·범위 참조는 상대 커밋에 따라 빌드가 조용히 바뀐다.
//
import PackageDescription

let package = Package(
    name: "OneS1ghtSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v14),          // swift test를 맥에서 돌리기 위함
    ],
    products: [
        .library(name: "OneS1ghtSDK", targets: ["OneS1ghtSDK"]),
    ],
    dependencies: [
        // 측위 엔진 (Geoplan UWB DL-TDoA) — 공개 릴리스 레포(binaryTarget + gpi-logger carrier).
        // 2.1.0: 멀티클러스터 블록 병합 측위 추가, 측위 후처리 정합화. 공개 API 는 2.0.0 과 동일
        // (DLTDoAPositioner(minRssi:) · sdkVersion · $estimatedPosition 그대로).
        .package(url: "https://github.com/Geoplan-Mobile/gpi-dltdoa", exact: "2.1.0"),
        // 진출입 판정 엔진 (Geoplan PRM) — 서버 존 파라미터(in_dist 등)를 소비하는 공식 판정.
        // 2.0.0: 멀티 인스턴스(Prm.create) · AreaInfo.Builder · 겹침 영역 IN/OUT 독립 판정 ·
        //        이탈 타이머 영역별 독립. 시책 다중 실행으로 존이 겹치는 구성에서 특히 유효.
        // ⚠️ 판정 감도가 1.1.0 과 다르다 — 누적 중인 영역 밖 좌표가 오면 카운트를 1 감소시켜
        //    IN 확정이 늦어진다. 실기기 재검증 전까지는 그 차이를 전제로 볼 것.
        .package(url: "https://github.com/Geoplan-Mobile/gpi-prm", exact: "2.0.0"),
    ],
    targets: [
        .target(
            name: "OneS1ghtSDK",
            dependencies: [
                .product(name: "gpi-dltdoa", package: "gpi-dltdoa",
                         condition: .when(platforms: [.iOS])),
                .product(name: "gpi-prm", package: "gpi-prm",
                         condition: .when(platforms: [.iOS])),   // 맥 테스트는 자체 ZoneEngine 경로
            ],
            path: "Sources/OneS1ghtSDK",
            resources: [
                .process("Resources/i18n/SdkLocalization.json"),   // SDK 로그 다국어 (Bundle.module)
            ]
        ),
        .testTarget(
            name: "OneS1ghtSDKTests",
            dependencies: [
                "OneS1ghtSDK",
                // PRM 판정 규칙 실측 프로브(iOS 시뮬레이터 전용)에서 엔진을 직접 호출
                .product(name: "gpi-prm", package: "gpi-prm", condition: .when(platforms: [.iOS])),
            ],
            path: "Tests/OneS1ghtSDKTests"
        ),
    ]
)
