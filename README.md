# OneS1ght SDK — iOS (Swift)

**English** | [한국어](README.ko.md) | [日本語](README.ja.md)

Indoor location intelligence SDK. Add it to your app to collect visit and movement data
through UWB (DL-TDoA) indoor positioning, and receive zone enter / exit / dwell events
on device.

---

## Requirements

| Item | Requirement |
|---|---|
| Positioning | **iOS 27.0+** · **iPhone 12 or later** (UWB chip) |
| Package | iOS 15.0+ — the app runs normally on unsupported devices, only the SDK stays inactive |
| Build | Xcode 26.6+ |

You also need keys and a configured space before the SDK does anything useful:

| Prerequisite | Where |
|---|---|
| SDK key (`ock_sdk_…`) | OneS1ght Console → **Mobile SDK** |
| GeoSpace key (`gsk_…`) | GeoSpace partner console |
| Building · floor · locator setup | GeoSpace |
| Zones | OneS1ght Console → **Space** |

---

## Step 1: Project Setup

Xcode → **File → Add Package Dependencies…** and enter:

```
https://github.com/onecheck-inc/OneS1ght-iOS-SDK
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/onecheck-inc/OneS1ght-iOS-SDK", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "OneS1ght", package: "OneS1ght-iOS-SDK")
    ])
]
```

The positioning engine and zone-judgement engine are pulled in automatically — you only
add this one package.

### Info.plist

**Both** keys are required. Without them the app is terminated the moment permission is
requested.

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Used to determine your position inside the store.</string>
<key>NSNearbyInteractionUsageDescription</key>
<string>Used for precise UWB positioning.</string>
```

---

## Step 2: SDK Initialization

Call this once at app start. It verifies the key, confirms the backend is reachable, and
receives tenant settings.

```swift
import OneS1ght

try await OneS1ght.initialize(sdkKey: "ock_sdk_…", geoSdkKey: "gsk_…")
```

⚠️ `initialize` does **not** look up buildings or floors. Space selection is a separate
step (Step 5) — only your app knows which floor to use.

**Expected logs**

```
[I1001] Initialized — tenant=itoku
verify passed (tenant: itoku)
```

### Check device support first

```swift
switch OneS1ght.deviceAvailability {
case .available:          break
case .osVersionTooLow:    showNotice("Requires iOS 27 or later")
case .deviceNotSupported: showNotice("Requires iPhone 12 or later")
}
```

This never throws and works before `initialize`, so you can branch your UI before
touching the network.

---

## Step 3: Permissions

### Location — a prerequisite for UWB

Ask for location permission first. The UWB session cannot start without it.

```swift
import CoreLocation

let locationManager = CLLocationManager()
locationManager.requestWhenInUseAuthorization()
```

⚠️ **Start positioning only after the user has answered.** Location permission is a
prerequisite of the UWB session, so calling `begin()` before the user responds fails the
session with `INVALID_CONFIGURATION`. Confirm the authorized state through
`CLLocationManagerDelegate`'s `locationManagerDidChangeAuthorization`, then start.

### Nearby Interaction

```swift
switch await OneS1ght.permissions() {
case .authorized:  break
case .denied:      showSettingsGuide()      // cannot re-prompt — send to Settings
case .unsupported: showUnsupportedNotice()
}
```

⚠️ **Calling this shows the system prompt.** NearbyInteraction has no "read status only"
API, so checking and requesting cannot be separated. The SDK does not pick the moment
for you — call it where it fits your flow.

⚠️ Once denied, **the app cannot ask again.** Guide the user to Settings:

```swift
UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
```

---

## Step 4: Profile

The server issues a `profileId`. **Store it in your app and reuse it** — it is the key
that visit and movement data is attributed to.

```swift
let profileId = savedProfileId ?? (try await OneS1ght.createProfile([
    "gender":   "F",
    "ageBand":  "20s",        // age band, not exact age
    "interest": "cosmetics",
]))
OneS1ght.identify(profileId: profileId)
```

Your member ID never reaches OneS1ght — only `profileId` does. You keep the mapping.

⚠️ Use **age bands** rather than exact ages. Gender + exact age + interests + movement
paths combined can become re-identifiable.

| Function | Purpose |
|---|---|
| `createProfile(_:)` | Create, returns `profileId` |
| `getProfile(_:)` | Read |
| `putProfile(_:_:)` | Replace all attributes |
| `deleteProfile(_:)` | Delete |
| `identify(profileId:)` | Attach — required before positioning |

---

## Step 5: Select Space

```swift
let buildings = try await OneS1ght.buildings()
let floors    = try await OneS1ght.floors(buildings[0].id)

try await OneS1ght.setFloorMap(floors[0], buildingID: buildings[0].id)
```

`setFloorMap` fetches locators, the UWB session ID and zones, then injects them into the
engines. Calling it again while running switches floors — the session stays.

### Drawing the map

```swift
let floor = try await OneS1ght.floor(buildings[0].id, floors[0].id)
mapView.setBackground(floor.image,
                      bounds: (floor.minX, floor.minY, floor.maxX, floor.maxY))
```

⚠️ `floors(_:)` returns floors with `image == nil` to keep the list light. Fetch the
single floor you are drawing — it comes from cache, so no extra round trip.

**Expected logs**

```
[I3001] Floor set — building=B1 floor=9f3a1c2e locators=4 zones=3
```

If something is missing you get a code instead:

```
[E3003] No UWB session on floor — floor=9f3a1c2e
```

---

## Step 6: Start Positioning

```swift
let session = try OneS1ght.floorSession()

session.onZoneEnter = { zone in showCoupon(zone) }
session.onZoneExit  = { zone in hideCoupon(zone) }
session.onZoneDwell = { zone, seconds in … }
session.onPosition  = { coord in mapView.moveMarker(coord) }
session.onTriggers  = { zoneId, triggers in handle(triggers) }

try await session.begin()
…
await session.end()
```

`floorSession()` always returns the same instance — the UWB radio, judgement engine and
coordinate buffer are one per device, so multiple sessions would physically collide.

**Expected logs**

```
[I4001] Positioning started — visitor=v-20260820-001
🎯 IN  · Cosmetics
coordinates 240 sent → server accepted 240
```

---

## API Reference

| Group | API |
|---|---|
| Setup | `initialize(sdkKey:geoSdkKey:)` · `permissions()` · `reset()` |
| Profile | `createProfile(_:)` · `getProfile(_:)` · `putProfile(_:_:)` · `deleteProfile(_:)` · `identify(profileId:)` |
| Space | `buildings()` · `building(_:)` · `floors(_:)` · `floor(_:_:)` · `zones(_:_:)` · `zone(_:_:_:)` · `locators(_:_:)` |
| Floor | `setFloorMap(_:buildingID:)` · `refreshZones()` |
| Positioning | `floorSession()` → `begin()` · `end()` |
| Session callbacks | `onZoneEnter` · `onZoneExit` · `onZoneDwell` · `onPosition` · `onTriggers` |
| Buffer | `send()` (upload now) · `empty()` (discard) |
| Status | `isInitialized` · `isDeviceAvailable` · `deviceAvailability` · `onDebugLog` · `sdkVersion` |

⚠️ `empty()` **discards** buffered coordinates without sending. Use `send()` to upload.

---

## Appendix

### How data flows

```
initialize ─→ begin ─→ [UWB coordinates] ─┬─→ onPosition            (your app)
                                           ├─→ buffer → server      (batched)
                                           └─→ zone judgement ─┬─→ onZoneEnter/Exit
                                                               └─→ server → onTriggers
```

`onZoneEnter` fires immediately from on-device judgement. `onTriggers` arrives after the
server responds — if the network is down you get the former but not the latter.

### Batching

| Trigger | Value |
|---|---|
| Count | 300 points |
| Interval | 60 seconds |
| Background | pause + flush |
| `end()` | flush remainder |

⚠️ UWB is **foreground only** on iOS. Positioning stops in the background and resumes
when you return — this is a platform limit.

⚠️ The buffer is in memory. Coordinates not yet uploaded are lost if the app is killed.

---

## Troubleshooting

Every failure carries a code. Include it when contacting support.

| Symptom | Codes | First check |
|---|---|---|
| App runs but no coordinates | `E3001` · `E3003` · `E4002` | Floor set? → UWB session? → locator placement |
| Zone events never fire | `E3004` | Are zones registered in Console? |
| Fails on specific devices | `E2001` · `E2002` | iOS 27 / iPhone 12 or later? |
| Permission prompt never returns | `E2003` | Denied once — guide to Settings |
| 401 right after integration | `E1002` | Key status and environment (production/development) |
| Data missing in Console | `E5001` · `E5006` | Network → batching |

| Code | Meaning |
|---|---|
| `E1001` | SDK not initialized |
| `E1002` | Invalid or revoked SDK key |
| `E1003` | Positioning disabled for tenant |
| `E1004` | No profile attached |
| `E2001` | iOS version too low |
| `E2002` | Device does not support UWB |
| `E2003` | Positioning permission denied |
| `E3001` | No floor set |
| `E3002` | No locators on floor |
| `E3003` | No UWB session on floor |
| `E3004` | No zones on floor |
| `E4001` | UWB session failed |
| `E4002` | No position fix |
| `E4003` | Some locators not received — **WARN, positioning continues** |
| `E5001` | Network failure |
| `E5002` | Server error |
| `E5003` | Payload mismatch |
| `E5004` | Forbidden resource |
| `E5005` | Response decoding failed |
| `E5006` | Pending coordinates dropped |

Errors are also uploaded to the Console log analyzer, where tenant administrators can
see them without touching the app.

### Seeing SDK logs during development

```swift
OneS1ght.onDebugLog = { line in print(line) }
```

⚠️ Leave this unset in production.

---

## Support

onesight-support@onecheck.co.kr
