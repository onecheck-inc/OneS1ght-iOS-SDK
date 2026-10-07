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
| Building · floor · locator setup | Your platform administrator (done at install) |
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
    .package(url: "https://github.com/onecheck-inc/OneS1ght-iOS-SDK", from: "0.2.0")
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

**All four** keys are required. Without the first three the app is terminated the moment
permission is requested.

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Used to determine your position inside the store.</string>
<key>NSNearbyInteractionUsageDescription</key>
<string>Used for precise UWB positioning.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover nearby positioning hardware.</string>
<key>NSLocationTemporaryUsageDescriptionDictionary</key>
<dict>
    <key>Positioning</key>
    <string>Used to compute your precise indoor position.</string>
</dict>
```

> ⚠️ The key inside `NSLocationTemporaryUsageDescriptionDictionary` **must be
> `Positioning`** — it has to match, character for character, the purpose key the SDK
> uses when it asks for full-accuracy location. If it differs, the request is **ignored
> with no error and no log**.
>
> The SDK requests the permissions itself — your app does not need to call
> `CLLocationManager`. If the user picks "Approximate Location" or denies the
> permission, positioning does not start and `E2003` is emitted to `onDebugLog`.

### iOS 27.2 and later: "Always" location is required

**On iOS 27.2 and later, location access must be "Always" for the floor to be detected.** The positioning
engine picks the floor with BLE beacon region monitoring (`CLBeaconRegion`); from iOS 27.2 the system keeps
reporting that region as "outside" under "While Using" — the floor is never found (`E3007`) and no
coordinates arrive. iOS 27.1 and earlier work with "While Using".

| Add | Value |
|---|---|
| Info.plist `NSLocationAlwaysAndWhenInUseUsageDescription` | Purpose string |
| Runtime permission | `CLLocationManager.requestAlwaysAuthorization()` once, right after "While Using" is granted (called by the app) |

```swift
func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if manager.authorizationStatus == .authorizedWhenInUse {
        manager.requestAlwaysAuthorization()   // iOS shows this prompt only once per app
    }
}
```

> The SDK does not request "Always". If the user declines, the SDK still starts — it just cannot find the
> floor on iOS 27.2 and later; guide the user to Settings.
>
> ⚠️ **Do not add `bluetooth-central` to `UIBackgroundModes`.** The SDK stops positioning in the background,
> so the mode is never used, and App Store review may reject an unused background mode (Guideline 2.5.4).
> Explain the "Always" request in your review notes (iBeacon region monitoring needs it from iOS 27.2).

---

## Step 2: SDK Initialization

Call this once at app start. It verifies the key, confirms the backend is reachable, and
receives tenant settings.

```swift
import OneS1ght

try await OneS1ght.initialize(sdkKey: "ock_sdk_…")
```

> This is the only key you pass. Everything else positioning and maps need is **served by
> the console** — you do not embed it in the app, and changing it does not require a new
> app release. A platform administrator sets it in the console.

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

### Location — the SDK asks for you

The UWB session needs location permission (and full accuracy). **The SDK requests both
itself when `begin()` starts the engine** — your app does not call `CLLocationManager`.
What your app must do is ship the four Info.plist keys from Step 1.

⚠️ If `NSLocationWhenInUseUsageDescription` is missing, iOS ignores the request without an
answer. The SDK checks for the key, does not start, and emits `E2003`
(`Info.plist missing …`) instead of waiting forever.

If the user denies location, positioning does not start: `E2003` is emitted, the session
closes and `onStopped` fires with `.engineFailed` (Step 6). Guide the user to Settings, then
call `begin()` again.

### Nearby Interaction

```swift
switch await OneS1ght.requestPermission() {
case .authorized:  break
case .denied:      showSettingsGuide()      // cannot re-prompt — send to Settings
case .unsupported: showUnsupportedNotice()
@unknown default:  break
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
// ⚠️ `savedProfileId ?? (try await ...)` does not compile — the right-hand side of `??`
//    is an autoclosure and cannot carry try/await.
let profileId: String
if let saved = savedProfileId {
    profileId = saved
} else {
    profileId = try await OneS1ght.createProfile([
        "gender":   "F",
        "ageBand":  "20s",        // age band, not exact age
        "interest": "cosmetics",
    ])
}
OneS1ght.identify(profileId: profileId)
```

Your member ID never reaches OneS1ght — only `profileId` does. You keep the mapping.
`identify` may be called before or after `initialize`.

⚠️ Use **age bands** rather than exact ages. Gender + exact age + interests + movement
paths combined can become re-identifiable.

| Function | Purpose |
|---|---|
| `createProfile(_:)` | Create, returns `profileId` |
| `fetchProfile(_:)` | Read attributes |
| `replaceProfile(_:attributes:)` | Replace **all** attributes — omitted ones are removed |
| `deleteProfile(_:)` | Delete |
| `identify(profileId:)` | Attach — required before positioning |

---

## Step 5: Select Space (optional)

You can skip this step. Renewed locators advertise their floor over BLE, so the engine
finds the floor by itself a second or two after `begin()`. Pick a floor yourself only when
a person should choose it, or to draw the map before positioning starts.

```swift
let buildings = try await OneS1ght.buildings()
let floors    = try await OneS1ght.floors(buildingId: buildings[0].id)

try await OneS1ght.setFloorMap(floors[0], buildingId: buildings[0].id)
```

`setFloorMap` fetches locators, the UWB session ID and zones, then injects them into the
engines. Calling it again while running switches floors — the session stays.
Pass `buildingId` the first time; after that you may omit it and the last building is reused.
With neither, it throws `SdkError.floorNotSet` (`E3001`) and leaves the current floor as it
is. `setFloorMap(nil)` clears the floor.

### Following the floor the engine found

```swift
let session = try OneS1ght.floorSession()
session.onFloorDetected = { floorId in
    guard let floorId else { return }              // nil = lost the floor
    // floorId is the same value as Floor.id — draw that floor, or setFloorMap it.
}
```

⚠️ Do **not** stop positioning to switch floors. `setFloorMap` while running is safe and
keeps the session — stopping makes the engine hunt for locators from scratch.

### Drawing the map

```swift
let floor = try await OneS1ght.floor(buildingId: buildings[0].id, floorId: floors[0].id)
mapView.setBackground(floor.image,
                      bounds: (floor.minX, floor.minY, floor.maxX, floor.maxY))
```

⚠️ `floors(buildingId:)` returns floors with `image == nil` to keep the list light. Fetch
the single floor you are drawing. The plan image is cached and dropped when Console changes
the plan (`.planChanged`).

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
session.onStopped   = { reason in
    switch reason {
    case .ended:        break
    case .engineFailed: showRetry()   // fix the cause (permission, Bluetooth) and begin() again
    @unknown default:   break
    }
}

try await session.begin()
…
await session.end()
```

`floorSession()` always returns the same instance — the UWB radio, judgement engine and
coordinate buffer are one per device, so multiple sessions would physically collide.

If the engine stops by itself, the SDK restarts it (after 3, 10 and 30 seconds, only
while the app is on screen). If that does not help, or the cause needs a person
(location permission, Bluetooth, license), the SDK **closes the session**:
`isRunning` becomes `false` and `onStopped(.engineFailed)` fires, so `begin()` works again.

`onZoneDwell` fires once per visit, after the zone's `dwellSeconds`. Zones without
`dwellSeconds` produce only enter and exit.

### Pausing is not stopping

```swift
session.pause()      // stop showing/collecting — the engine keeps running
session.resume()
session.isPaused
```

| | `pause()` | `end()` |
|---|---|---|
| Position callbacks | stop | stop |
| Zone enter/exit | stop | stop |
| Upload to server | stop | flush, then stop |
| Engine · floor · locators | **kept** | released |
| Cost of coming back | instant | locators found from scratch |

Use `pause()` for "stop showing my position for a moment". `end()` is for leaving the
space. A pause survives going to the background and back; only `resume()`, `end()` and
`begin()` clear it. Resuming clears the judgement state, so the first zone event after
`resume()` re-establishes where you are — you will not get a stale exit for a zone you
walked out of while paused.

### Console changes

```swift
session.onConfigChanged = { change in
    switch change {
    case .zonesChanged, .resyncNeeded: Task { await OneS1ght.refreshZones() }
    case .planChanged:                 reloadPlan()
    case .rulesChanged, .sdkConfigChanged: break
    @unknown default:                  break
    }
}
```

The live connection is open **while a floor is set or positioning is running**. Coalesce
bursts (about one second) before refreshing — every zone reload restarts the judgement.

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
| Setup | `initialize(sdkKey:baseURL:)` · `requestPermission()` · `reset()` · `defaultBaseURL` |
| Profile | `createProfile(_:)` · `fetchProfile(_:)` · `replaceProfile(_:attributes:)` · `deleteProfile(_:)` · `identify(profileId:)` |
| Space | `buildings()` · `building(id:)` · `floors(buildingId:)` · `floor(buildingId:floorId:)` · `zones(buildingId:floorId:)` · `zone(buildingId:floorId:zoneId:)` · `locators(buildingId:floorId:)` |
| Floor | `setFloorMap(_:buildingId:)` · `refreshZones()` |
| Positioning | `floorSession()` → `begin()` · `end()` · `pause()` · `resume()` · `isPaused` · `isRunning` |
| Session callbacks | `onZoneEnter` · `onZoneExit` · `onZoneDwell` · `onPosition` · `onTriggers` · `onFloorDetected` · `onStopped` · `onConfigChanged` |
| Buffer | `uploadPendingPositions()` · `discardPendingPositions()` |
| Status | `isInitialized` · `isDeviceAvailable` · `deviceAvailability` · `onDebugLog` · `setLanguage(_:)` · `sdkVersion` |
| Console-provided values | `googleMapKey` |

⚠️ `discardPendingPositions()` **discards** buffered coordinates without sending. Use
`uploadPendingPositions()` to upload.

⚠️ `googleMapKey` is the only console value your app touches. The positioning license and
the space-service address are used inside the SDK only and are not exposed — your app
neither needs them nor has to manage them.

Names renamed after 0.1.24 (`floor(_:_:)`, `permissions()`, `send()`, `empty()`,
`getProfile`, `putProfile`, `setFloorMap(_:buildingID:)`, `Trigger.trigger_id` …) still
compile with a deprecation warning — see [CHANGELOG](CHANGELOG.md).

### Switching over SDK enums

SDK enums can gain cases in a minor release. Add `@unknown default` when you switch over
`ConfigChange`, `SdkErrorCode`, `ZoneEvent`, `FloorSession.StopReason`, `PermissionStatus`,
`OneS1ght.DeviceAvailability` or `LogLevel`, so a new case does not break your build:

```swift
switch change {                 // ConfigChange
case .zonesChanged, .resyncNeeded: Task { await OneS1ght.refreshZones() }
case .planChanged:                 reloadPlan()
case .rulesChanged, .sdkConfigChanged: break
@unknown default:                  break    // a case added later lands here instead of breaking the build
}
```

Without it, a new case is a compile error in your exhaustive `switch`.

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

### Where zone judgement happens

The positioning engine judges zone enter/exit against **its own geofences**, fetched from
the space service when it starts. The zones you get from `zones(buildingId:floorId:)` are
for naming and mapping ids — changing their parameters in Console does not change the
judgement.

The SDK watches for zone changes during `refreshZones()` and reloads the engine when the
set actually changes (a zone added, removed or redrawn). That reload restarts the engine,
so **positions pause for a second or so**. If your UI treats a gap as "signal lost", give
it a grace period longer than that.

### Batching

| Trigger | Value |
|---|---|
| Count | 300 points (when the buffer reaches it) |
| Interval | 60 seconds (also retries a failed upload) |
| Background | stop positioning + flush |
| `end()` | flush remainder |

⚠️ UWB is **foreground only** on iOS. Positioning stops in the background and resumes
when you return — this is a platform limit.

⚠️ The buffer is in memory. Coordinates not yet uploaded are lost if the app is killed.

---

## Troubleshooting

Every failure carries a code. Include it when contacting support.

| Symptom | Codes | First check |
|---|---|---|
| App runs but no coordinates | `E3007` · `E3003` · `E4002` | Floor detected (BLE)? → UWB session? → locator placement |
| Spaces are empty / `floor()` throws `notInitialized` | `E1007` | Positioning key not set in Console, or `/config` unreachable |
| Zone events never fire | `E3004` · `E3009` | Zones registered in Console? Zone names match the engine's areas? |
| Data lands on an unknown floor | `E3008` | Engine floor and Console floor differ |
| Fails on specific devices | `E2001` · `E2002` | iOS 27 / iPhone 12 or later? |
| Positioning closes right after `begin()` | `E2003` · `E2004` | Location / Bluetooth permission, Bluetooth on, Info.plist keys |
| 401 right after integration | `E1002` | Key status and environment (production/development) |
| Data missing in Console | `E5001` · `E5006` | Network → batching |

| Code | Meaning |
|---|---|
| `E1001` | SDK not initialized |
| `E1002` | Invalid or revoked SDK key |
| `E1003` | Positioning disabled for tenant |
| `E1004` | No profile attached |
| `E1007` | Positioning key unavailable (not in Console, lookup failed, or rejected by the positioning engine) |
| `E2001` | iOS version too low |
| `E2002` | Device does not support positioning (no UWB, or Bluetooth unsupported) |
| `E2003` | Positioning permission denied (or Info.plist key missing) |
| `E2004` | Bluetooth is off |
| `E3001` | `setFloorMap(floor)` without a building (`SdkError.floorNotSet`). Starting without a floor is normal and is not uploaded |
| `E3002` | No locators on floor |
| `E3003` | No UWB session on floor |
| `E3004` | No zones on floor |
| `E3006` | Locator lookup failed — the map still opens |
| `E3007` | Floor not detected (BLE) — on iOS 27.2+ check that location is "Always" |
| `E3008` | Engine floor differs from Console floor |
| `E3009` | No Console zone matches an engine area name |
| `E4001` | UWB session failed / engine stopped |
| `E4002` | No position fix |
| `E4003` | Some locators not received — **WARN, positioning continues** |
| `E4004` | Area judgement failed for one round |
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
OneS1ght.onDebugLog = { level, line in print("[\(level)] \(line)") }
```

⚠️ Leave this unset in production.

---

## Support

onesight-support@onecheck.co.kr
