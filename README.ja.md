# OneS1ght SDK — iOS (Swift)

[English](README.md) | [한국어](README.ko.md) | **日本語**

屋内位置インテリジェンス SDK です。アプリに組み込むと UWB（DL-TDoA）屋内測位により
訪問・動線データを収集し、ゾーンの入場・退場・滞在イベントを端末上で受け取れます。

---

## 動作要件

| 項目 | 要件 |
|---|---|
| 測位 | **iOS 27.0 以上** ・ **iPhone 12 以降**（UWB チップ搭載） |
| パッケージ導入 | iOS 15.0 以上 — 非対応端末でもアプリは正常に動作し、SDK のみ無効になります |
| ビルド環境 | Xcode 26.6 以上 |

SDK が実際に動作するには、キーと空間設定が先に用意されている必要があります。

| 事前準備 | 取得場所 |
|---|---|
| SDK キー (`ock_sdk_…`) | OneS1ght コンソール → **モバイル SDK** |
| GeoSpace キー (`gsk_…`) | GeoSpace パートナーコンソール |
| 建物・フロア・ロケーターの設置 | GeoSpace |
| ゾーン | OneS1ght コンソール → **空間管理** |

---

## Step 1: プロジェクト設定

Xcode → **File → Add Package Dependencies…** で以下の URL を入力します。

```
https://github.com/onecheck-inc/OneS1ght-iOS-SDK
```

`Package.swift` で追加する場合:

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

測位エンジンとゾーン判定エンジンは自動的に一緒に取得されるため、このパッケージを
追加するだけで済みます。

### Info.plist

**両方**必要です。無いと権限を要求した瞬間にアプリが終了します。

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>店舗内での位置を把握するために使用します。</string>
<key>NSNearbyInteractionUsageDescription</key>
<string>UWB による精密測位に使用します。</string>
```

---

## Step 2: SDK の初期化

アプリ起動時に 1 回呼び出します。キーを検証し、バックエンドへの到達を確認し、
テナント設定を受け取ります。

```swift
import OneS1ght

try await OneS1ght.initialize(sdkKey: "ock_sdk_…", geoSdkKey: "gsk_…")
```

⚠️ `initialize` は建物・フロアを**取得しません**。空間の選択は別ステップ（Step 5）です —
どのフロアを使うかはアプリだけが知っているためです。

**想定されるログ**

```
[I1001] 初期化完了 — tenant=itoku
verify 通過 (tenant: itoku)
```

### 端末の対応可否を先に確認

```swift
switch OneS1ght.deviceAvailability {
case .available:          break
case .osVersionTooLow:    showNotice("iOS 27 以上でご利用いただけます")
case .deviceNotSupported: showNotice("iPhone 12 以降でご利用いただけます")
}
```

throw せず `initialize` の前でも呼べるため、ネットワークにアクセスする前に案内 UI を
分岐できます。

---

## Step 3: 権限

### 位置情報の権限 — 測位の前提条件

先に位置情報の権限を取得してください。これが無いと UWB セッションは開始できません。

```swift
import CoreLocation

let locationManager = CLLocationManager()
locationManager.requestWhenInUseAuthorization()
```

⚠️ **ユーザーが応答してから測位を開始してください。** 位置情報の権限は UWB セッションの
前提条件のため、応答前に `begin()` を呼ぶとセッションが `INVALID_CONFIGURATION` で
失敗します。`CLLocationManagerDelegate` の `locationManagerDidChangeAuthorization` で
許可状態を確認してから開始してください。

### Nearby Interaction の権限

```swift
switch await OneS1ght.permissions() {
case .authorized:  break
case .denied:      showSettingsGuide()      // 再要求は不可 — 設定アプリへ誘導
case .unsupported: showUnsupportedNotice()
}
```

⚠️ **呼び出した時点でシステムのダイアログが表示されます。** NearbyInteraction には
状態のみを読み取る API がなく、確認と要求を分離できません。SDK はタイミングを決めない
ため、アプリのフローに合う場所で呼び出してください。

⚠️ 一度拒否されると、**アプリから再度尋ねることはできません。** 設定アプリへ誘導してください。

```swift
UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
```

---

## Step 4: プロフィール

サーバーが `profileId` を発行します。**アプリで保存して再利用してください** —
訪問・動線データはこのキーに紐づきます。

```swift
let profileId = savedProfileId ?? (try await OneS1ght.createProfile([
    "gender":   "F",
    "ageBand":  "20s",        // 正確な年齢ではなく年代
    "interest": "cosmetics",
]))
OneS1ght.identify(profileId: profileId)
```

貴社の会員 ID が OneS1ght に送られることはありません。送られるのは `profileId` のみで、
その対応関係は貴社のみが保持します。

⚠️ 年齢は**年代**で入力することを推奨します。性別・正確な年齢・関心事・動線が組み合わ
さると再識別の可能性が生じます。

| 関数 | 用途 |
|---|---|
| `createProfile(_:)` | 作成 — `profileId` を返す |
| `getProfile(_:)` | 取得 |
| `putProfile(_:_:)` | 属性の全置換 |
| `deleteProfile(_:)` | 削除 |
| `identify(profileId:)` | 紐づけ — 測位前に必須 |

---

## Step 5: 空間の選択

```swift
let buildings = try await OneS1ght.buildings()
let floors    = try await OneS1ght.floors(buildings[0].id)

try await OneS1ght.setFloorMap(floors[0], buildingID: buildings[0].id)
```

`setFloorMap` はロケーター・UWB セッション ID・ゾーンを取得してエンジンに注入します。
実行中に再度呼び出すとフロアが切り替わり、セッションはそのまま維持されます。

### 地図の描画

```swift
let floor = try await OneS1ght.floor(buildings[0].id, floors[0].id)
mapView.setBackground(floor.image,
                      bounds: (floor.minX, floor.minY, floor.maxX, floor.maxY))
```

⚠️ `floors(_:)` は一覧を軽く保つため `image == nil` で返します。描画するフロアのみ単体で
取得すればキャッシュから返るため、追加のリクエストは発生しません。

**想定されるログ**

```
[I3001] フロア指定 — building=B1 floor=9f3a1c2e locators=4 zones=3
```

不足しているものがある場合はコードが代わりに出力されます。

```
[E3003] フロアに UWB セッションがありません — floor=9f3a1c2e
```

---

## Step 6: 測位の開始

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

`floorSession()` は常に同じインスタンスを返します — UWB 無線・判定エンジン・座標バッファ
は端末ごとに 1 つのため、セッションが複数あると物理的に競合します。

**想定されるログ**

```
[I4001] 測位開始 — visitor=v-20260820-001
🎯 IN  · 化粧品
座標 240 件を送信 → サーバー accepted 240
```

---

## 主な API

| 区分 | API |
|---|---|
| 初期化 | `initialize(sdkKey:geoSdkKey:)` · `permissions()` · `reset()` |
| プロフィール | `createProfile(_:)` · `getProfile(_:)` · `putProfile(_:_:)` · `deleteProfile(_:)` · `identify(profileId:)` |
| 空間取得 | `buildings()` · `building(_:)` · `floors(_:)` · `floor(_:_:)` · `zones(_:_:)` · `zone(_:_:_:)` · `locators(_:_:)` |
| フロア指定 | `setFloorMap(_:buildingID:)` · `refreshZones()` |
| 測位 | `floorSession()` → `begin()` · `end()` |
| セッションコールバック | `onZoneEnter` · `onZoneExit` · `onZoneDwell` · `onPosition` · `onTriggers` |
| バッファ | `send()`（送信） · `empty()`（破棄） |
| 状態 | `isInitialized` · `isDeviceAvailable` · `deviceAvailability` · `onDebugLog` · `sdkVersion` |

⚠️ `empty()` はバッファ内の座標を**送信せずに破棄します。** 送信は `send()` です。

---

## 付録

### データの流れ

```
initialize ─→ begin ─→ [UWB 座標] ─┬─→ onPosition            (アプリ)
                                    ├─→ バッファ → サーバー   (バッチ)
                                    └─→ ゾーン判定 ─┬─→ onZoneEnter/Exit
                                                    └─→ サーバー → onTriggers
```

`onZoneEnter` は端末上の判定直後に発火します。`onTriggers` はサーバー応答後に届くため、
ネットワークが切断されている場合は前者のみ届きます。

### バッチ送信

| トリガー | 値 |
|---|---|
| 件数 | 300 件 |
| 間隔 | 60 秒 |
| バックグラウンド移行 | 測位停止 + 残りを送信 |
| `end()` | 残りを送信 |

⚠️ iOS の UWB は**フォアグラウンド専用**です。バックグラウンドでは測位が停止し、復帰時に
再開されます — プラットフォームの制約であり回避できません。

⚠️ バッファはメモリ上にあります。アプリが強制終了されると未送信の座標は失われます。

---

## トラブルシューティング

すべての失敗にはコードが付きます。お問い合わせの際に併せてお知らせください。

| 症状 | コード | 最初に確認すること |
|---|---|---|
| アプリは動くが座標が出ない | `E3001` · `E3003` · `E4002` | フロア指定 → UWB セッション → ロケーター配置 |
| ゾーンイベントが発火しない | `E3004` | コンソールにゾーンが登録されているか |
| 特定の端末でのみ動作しない | `E2001` · `E2002` | iOS 27 / iPhone 12 以降か |
| 権限ダイアログが再表示されない | `E2003` | 既に拒否済み — 設定アプリへ誘導 |
| 連携直後に 401 | `E1002` | キーの状態・環境（production/development） |
| コンソールにデータが表示されない | `E5001` · `E5006` | ネットワーク → バッチ間隔 |

| コード | 意味 |
|---|---|
| `E1001` | SDK が未初期化 |
| `E1002` | SDK キーが無効または失効 |
| `E1003` | テナントで測位が無効 |
| `E1004` | プロフィール未連携 |
| `E2001` | iOS バージョン不足 |
| `E2002` | UWB 非対応端末 |
| `E2003` | 測位権限が拒否された |
| `E3001` | フロア未指定 |
| `E3002` | フロアにロケーターがない |
| `E3003` | フロアに UWB セッションがない |
| `E3004` | フロアにゾーンがない |
| `E4001` | UWB セッション失敗 |
| `E4002` | 座標が算出されない |
| `E4003` | 一部のロケーターが受信できない — **WARN、測位は継続します** |
| `E5001` | ネットワーク失敗 |
| `E5002` | サーバーエラー |
| `E5003` | リクエスト形式の不一致 |
| `E5004` | 権限のないリソースへのアクセス |
| `E5005` | レスポンスの解析失敗 |
| `E5006` | 未送信の座標が失われた |

エラーはコンソールのログ分析にも送られるため、テナント管理者はアプリを介さずに確認
できます。

### 開発中に SDK ログを見る

```swift
OneS1ght.onDebugLog = { line in print(line) }
```

⚠️ 本番環境では登録しないことを推奨します。

---

## お問い合わせ

onesight-support@onecheck.co.kr
