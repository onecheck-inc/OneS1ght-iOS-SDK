// swift-tools-version: 5.9
//
//  OneS1ght — OneS1ght 실내 위치 인텔리전스 SDK (iOS / Swift)
//
//  ⚠️ **로컬 검증용 사본**이다 (OneS1ght-SDK-ihub). 측위를 Geoplan 턴키 `gpi-ihub` 로
//     갈아끼운 실험 가지로, 원본 레포(OneS1ght-iOS-SDK)는 손대지 않았다.
//
//  · 측위·판정을 gpi-ihub 하나로 대체한다. dltdoa·prm·logger 직접 의존은 걷어냈다 —
//    ihub 가 그 셋을 자기 의존으로 이미 싣고 오므로 프레임워크 자체는 계속 임베드된다.
//  · **최소 버전이 iOS 27 로 올라간다.** gpi-ihub 1.0.0 의 Package.swift 가 iOS 27 을
//    선언하고 바이너리도 minos 27 로 구워져 있다. 조건부 의존(.when)은 OS 종류만 고를 수
//    있고 버전으로는 못 고른다 — 그래서 여기서 낮출 방법이 없다.
//    실측(2026-09-08): iOS 18.5 에서 앱이 dyld 단계에서 즉시 죽는다
//    (Symbol not found: _OBJC_CLASS_$_NIDLTDOAConfiguration). iOS 26 은 로드는 되지만
//    ihub 가 iOS 27 전용 clusterInitiatorAddress 를 호출해 위험하고, 실기기에서
//    NISession 이 NIERROR_INVALID_CONFIGURATION_DESCRIPTION 으로 거절됐다.
//    → Geoplan 이 배포 타깃을 낮춰 재빌드해 주면 `platforms` 만 되돌리면 된다.
//      코드의 `@available(iOS 27.0, *)`·`#available` 가드는 그때를 위해 남겨 두었다.
//  · Geoplan 엔진은 iOS 전용 바이너리 → iOS 타깃에만 조건부 링크. 맥에서는 코어(통신·판정)
//    테스트가 그대로 돈다.
//  · 정식 태그로 고정(exact) — 브랜치·범위 참조는 상대 커밋에 따라 빌드가 조용히 바뀐다.
//
import PackageDescription

let package = Package(
    name: "OneS1ght",
    platforms: [
        // ⚠️ 지금 이 값으로는 **iOS 빌드가 되지 않는다** (2026-09-08 실측).
        //    swift build(맥)는 통과한다 — gpi-ihub 가 iOS 조건부라 맥에서는 링크되지 않기 때문.
        //    iOS 로 빌드하면 SwiftPM 이 해석 단계에서 막는다:
        //
        //      error: The package product 'gpi-ihub-product' requires minimum platform
        //             version 27.0 for the iOS platform, but this target supports 15.0
        //
        //    조건부 의존(.when)은 OS 종류만 고를 수 있고 버전으로는 못 고른다. 코드에
        //    #available 가드를 아무리 두어도 이 검사는 그 앞에서 끝난다.
        //    → iOS 를 빌드하려면 이 줄을 .iOS("27.0") 로 되돌려야 한다.
        //      Geoplan 이 ihub 배포 타깃을 낮춰 재빌드해 주면 그때 .v15 가 실제로 통한다.
        //    ↓ .v15 로 바꾸면 위 에러가 난다. 확인하려면 이 줄과 아래 줄을 맞바꿔라.
        // .iOS(.v15),
        .iOS("27.0"),
        .macOS(.v14),          // swift test를 맥에서 돌리기 위함
    ],
    products: [
        .library(name: "OneS1ght", targets: ["OneS1ght"]),
    ],
    dependencies: [
        // Geoplan 턴키 측위 — BLE 로 층을 고르고, 자기 서버에서 앵커·셀을 받아 NISession 을
        // 돌리고, 좌표와 영역 진출입(IN/OUT)까지 준다.
        // 공개 API 는 IntelligenceHub 7개 + HubListener 7개가 전부다 —
        // 앵커 목록·앵커별 수신 상태·세션ID·zone_id 는 노출하지 않는다(진단 한계).
        // 이 패키지가 gpi-dltdoa 2.1.0 · gpi-prm 2.0.0 · gpi-logger 를 캐리어 타깃으로 싣고 온다.
        .package(url: "https://github.com/Geoplan-Mobile/gpi-ihub", exact: "1.0.0"),
    ],
    targets: [
        .target(
            name: "OneS1ght",
            dependencies: [
                .product(name: "gpi-ihub", package: "gpi-ihub",
                         condition: .when(platforms: [.iOS])),   // 맥 테스트는 자체 ZoneEngine 경로
            ],
            path: "Sources/OneS1ght",
            resources: [
                .process("Resources/i18n/SdkLocalization.json"),   // SDK 로그 다국어 (Bundle.module)
            ]
        ),
        .testTarget(
            name: "OneS1ghtTests",
            dependencies: ["OneS1ght"],
            path: "Tests/OneS1ghtTests"
        ),
    ]
)
