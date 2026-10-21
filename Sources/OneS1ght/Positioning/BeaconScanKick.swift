//
//  BeaconScanKick.swift
//  엔진이 층을 찾으려고 거는 비콘 영역을 iOS 가 실제로 스캔하게 만든다.
//

import Foundation
import os
#if canImport(CoreLocation)
import CoreLocation
#endif

private let klog = Logger(subsystem: "co.onecheck.ones1ght", category: "UWB")

/// 엔진 시작 직후 잠깐 같은 비콘 UUID 로 ranging 을 건다 — 층이 잡히거나 시간이 다 되면 푼다.
///
/// ⚠️ 2026-10-21 iPhone 17 · iOS 27.2: 배경에서 돌아와 엔진이 비콘 영역을 다시 걸면 locationd 가
///    **비콘 스캐너를 켜지 않고**(`@iB: Scanner starting for beacons` 없음) 8초 뒤 「밖」 으로 판정했다.
///    엔진은 그 판정만 보고 층 탐색(BLE)을 열지 않는다 — 로케이터 옆에서도 「신호를 찾을 수 없습니다」.
///    정상일 때는 영역을 건 직후 ranging 이 붙고 스캐너가 켜져 1초 안에 「안」 이었다.
///    엔진은 ranging 을 직접 걸 방법이 없어(공개 API 는 start/stop 뿐) SDK 가 대신 건다.
///    같은 기기에서 이걸 넣기 전 복귀 8회 전부 층 미탐지, 넣은 뒤 엔진 시작 13회 전부 1.8~3.0초 안에 층을 잡았다
///    (배경 8~165초 포함). 앞 화면에서만, 층을 잡거나 10초가 지나면 푼다.
@MainActor
final class BeaconScanKick: NSObject {
    /// 엔진 바이너리의 층 비콘 UUID(StaleEngineRegion 과 같은 영역).
    static let uuid = UUID(uuidString: "47500000-4253-428E-B095-A366AEA6CDDB")!
    static let duration: TimeInterval = 10

    #if canImport(CoreLocation)
    private var manager: CLLocationManager?
    private var stopTask: Task<Void, Never>?
    private var ranged = 0
    #endif

    func start() {
        #if canImport(CoreLocation)
        stop(reason: "restart")
        let m = CLLocationManager()
        m.delegate = self
        manager = m
        ranged = 0
        m.startRangingBeacons(satisfying: CLBeaconIdentityConstraint(uuid: Self.uuid))
        klog.notice("beacon kick: ranging started")
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.stop(reason: "timeout")
        }
        #endif
    }

    func stop(reason: String) {
        #if canImport(CoreLocation)
        stopTask?.cancel(); stopTask = nil
        guard let m = manager else { return }
        m.stopRangingBeacons(satisfying: CLBeaconIdentityConstraint(uuid: Self.uuid))
        m.delegate = nil
        manager = nil
        klog.notice("beacon kick: ranging stopped (\(reason, privacy: .public), ranged=\(self.ranged))")
        #endif
    }
}

#if canImport(CoreLocation)
extension BeaconScanKick: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon],
                                     satisfying constraint: CLBeaconIdentityConstraint) {
        let n = beacons.count
        Task { @MainActor in
            if self.ranged == 0, n > 0 { klog.notice("beacon kick: first ranged \(n) beacon(s)") }
            self.ranged += n
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailRangingFor constraint: CLBeaconIdentityConstraint,
                                     error: Error) {
        let msg = error.localizedDescription
        Task { @MainActor in klog.error("beacon kick: ranging failed \(msg, privacy: .public)") }
    }
}
#endif
