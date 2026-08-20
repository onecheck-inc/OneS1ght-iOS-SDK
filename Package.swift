// swift-tools-version: 5.9
//
//  OneS1ghtSDK — OneS1ght 실내 위치 인텔리전스 SDK (iOS / Swift)
//
//  · gpi-dltdoa(측위 엔진)를 xcframework로 품어 재배포 — 고객은 이 패키지 하나만 추가.
//    (외부 URL 의존성 없음 — Geoplan 레포 접근 불필요)
//  · 측위 어댑터(UwbPositioningProvider)는 iOS 27 심볼 필요 → #if os(iOS) 가드.
//    맥에서는 해당 파일이 비워져 코어(통신·판정) 테스트가 그대로 돈다.
//  · gpi-dltdoa(iOS 전용 바이너리)는 iOS 타깃에만 링크.
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
        // 진출입 판정 엔진 (Geoplan PRM) — 서버 존 파라미터(in_dist 등)를 소비하는 공식 판정.
        // public 릴리스 레포(binaryTarget + GEOSwift carrier) — iOS 전용이라 조건부 링크.
        // 정식 태그로 고정 (재현성) — 브랜치 참조는 상대 커밋에 따라 빌드가 조용히 바뀐다.
        // 판정 동작은 1.1.1β 와 동일함을 교차 검증(08-06, inDist·이탈규칙 실측 일치).
        // 1.1.1β 대비 없는 것: 엔진 내부 파일 로그(gpi-logger), GEOSwift 심볼중복 경고 수정.
        // 판정 디버깅이 필요하면 일시적으로 branch: "beta" 로 올려 확인 후 되돌린다.
        .package(url: "https://github.com/Geoplan-Mobile/gpi-prm", exact: "1.1.0"),
    ],
    targets: [
        // 측위 엔진 (Geoplan) — xcframework 벤더링 (iOS 전용)
        .binaryTarget(
            name: "gpi-dltdoa",
            path: "Frameworks/gpi-dltdoa.xcframework"
        ),
        .target(
            name: "OneS1ghtSDK",
            dependencies: [
                .target(name: "gpi-dltdoa", condition: .when(platforms: [.iOS])),
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
