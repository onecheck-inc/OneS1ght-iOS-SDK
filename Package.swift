// swift-tools-version: 5.9
//
//  OneS1ght — OneS1ght 실내 위치 인텔리전스 SDK (iOS / Swift)
//
//  · 측위·판정은 외부 엔진 하나에 맡긴다. 이전에 직접 물던 레인징·존 판정 패키지는
//    걷어냈다 — 그 엔진이 자기 의존으로 싣고 오므로 프레임워크 자체는 계속 임베드된다.
//  · 엔진은 iOS 전용 바이너리 → iOS 타깃에만 조건부 링크. 맥에서는 코어(통신·판정)
//    테스트가 그대로 돈다.
//  · 정식 태그로 고정(exact) — 브랜치·범위 참조는 상대 커밋에 따라 빌드가 조용히 바뀐다.
//
//  ⚠️ 여기 적힌 공급사 이름은 SPM 이 저장소 URL·프로덕트 이름을 요구하기 때문에 남아
//     있는 것이다. 고객이 읽는 API·로그·문서에는 나오지 않는다(SnippetsTests 가 지킨다).
//
import PackageDescription

let package = Package(
    name: "OneS1ght",
    platforms: [
        // 최소 iOS 18. 엔진 1.0.0 은 매니페스트가 .iOS("27.0") 이라 iOS 18~26 에서 SwiftPM 이
        // 해석 단계에서 막았고, 바이너리도 minos 27 로 구워져 dyld 가
        // _OBJC_CLASS_$_NIDLTDOAConfiguration 을 못 찾아 앱이 통째로 죽었다(2026-09-08 실측).
        // 1.0.1 이 둘 다 고쳤다 — 매니페스트 18.0, 바이너리 minos 18.0, NIDLTDOA* 는 weak 링크.
        //
        // ⚠️ 그래도 **빌드에는 iOS 27 SDK(Xcode 27)가 필요하다.** 우리 소스가
        //    NIDLTDOAConfiguration 같은 iOS 27 타입을 직접 참조하는데, iOS 26 SDK 에는 그
        //    타입 자체가 없어 #available 가드로도 컴파일을 통과시킬 수 없다.
        //    런타임 가드(#available)와 빌드용 SDK 는 서로를 대체하지 못한다 — 둘 다 필요하다.
        .iOS("18.0"),
        .macOS(.v14),          // swift test를 맥에서 돌리기 위함
    ],
    products: [
        .library(name: "OneS1ght", targets: ["OneS1ght"]),
    ],
    dependencies: [
        // 외부 측위 엔진 — BLE 로 층을 고르고, 자기 서버에서 앵커·셀을 받아 NISession 을
        // 돌리고, 좌표와 영역 진출입(IN/OUT)까지 준다.
        // 공개 API 는 진입 클래스 7개 + 리스너 7개가 전부다 —
        // 앵커 목록·앵커별 수신 상태·세션ID·zone_id 는 노출하지 않는다(진단 한계).
        // 레인징·존 판정·로거 프레임워크를 캐리어 타깃으로 싣고 온다.
        .package(url: "https://github.com/Geoplan-Mobile/gpi-ihub", exact: "1.0.1"),
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
