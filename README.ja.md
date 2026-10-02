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
| 建物・フロア・ロケーターの設置 | 統合管理者（導入時に実施） |
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
    .package(url: "https://github.com/onecheck-inc/OneS1ght-iOS-SDK", from: "0.2.0")
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

**4つすべて**必要です。最初の3つは無いと権限を要求した瞬間にアプリが終了します。

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>店舗内での位置を把握するために使用します。</string>
<key>NSNearbyInteractionUsageDescription</key>
<string>UWB による精密測位に使用します。</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>周辺の測位機器を検出するために使用します。</string>
<key>NSLocationTemporaryUsageDescriptionDictionary</key>
<dict>
    <key>Positioning</key>
    <string>正確な屋内位置を算出するために使用します。</string>
</dict>
```

> ⚠️ `NSLocationTemporaryUsageDescriptionDictionary` の中のキーは **`Positioning`**
> でなければなりません。SDK が正確な位置情報への一時的な昇格を要求する際に使う名前と
> 一字一句同じである必要があり、異なると要求は**エラーもログも無く無視されます**。
>
> 権限の要求は SDK が行います — アプリ側で `CLLocationManager` を呼ぶ必要はありません。
> ユーザーが「おおよその位置」を選ぶか権限を拒否した場合、測位は開始されず
> `onDebugLog` に `E2003` が残ります。

---

## Step 2: SDK の初期化

アプリ起動時に 1 回呼び出します。キーを検証し、バックエンドへの到達を確認し、
テナント設定を受け取ります。

```swift
import OneS1ght

try await OneS1ght.initialize(sdkKey: "ock_sdk_…")
```

> アプリが渡すキーはこれ一つだけです。測位と地図に必要な残りのキーは**コンソールが配信します** —
> アプリに埋め込む必要はなく、値を変更してもアプリを再配布する必要はありません。
> 統合管理者がコンソールで設定します。

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

### 位置情報の権限 — SDK が要求します

UWB セッションには位置情報の権限（と正確な位置情報）が必要です。**`begin()` がエンジンを起動するとき、
SDK が両方を自ら要求します** — アプリ側で `CLLocationManager` を呼ぶ必要はありません。アプリが行うのは
Step 1 の Info.plist キー 4 つを入れることだけです。

⚠️ `NSLocationWhenInUseUsageDescription` が無いと、iOS は要求を応答なしで無視します。SDK はこのキーを
先に確認し、無ければ待ち続けずに開始を取りやめ、`E2003`（`Info.plist missing …`）を出力します。

ユーザーが位置情報を拒否すると測位は開始されません — `E2003` が出力され、セッションが閉じて `onStopped`
が `.engineFailed` で呼ばれます（Step 6）。設定アプリへ誘導したあと、`begin()` を再度呼んでください。

### Nearby Interaction の権限

```swift
switch await OneS1ght.requestPermission() {
case .authorized:  break
case .denied:      showSettingsGuide()      // 再要求は不可 — 設定アプリへ誘導
case .unsupported: showUnsupportedNotice()
@unknown default:  break
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
// ⚠️ `savedProfileId ?? (try await ...)` はコンパイルできません —
//    `??` の右辺は autoclosure のため try/await を含められません。
let profileId: String
if let saved = savedProfileId {
    profileId = saved
} else {
    profileId = try await OneS1ght.createProfile([
        "gender":   "F",
        "ageBand":  "20s",        // 正確な年齢ではなく年代
        "interest": "cosmetics",
    ])
}
OneS1ght.identify(profileId: profileId)
```

貴社の会員 ID が OneS1ght に送られることはありません。送られるのは `profileId` のみで、
その対応関係は貴社のみが保持します。`identify` は `initialize` の前でも後でも呼べます。

⚠️ 年齢は**年代**で入力することを推奨します。性別・正確な年齢・関心事・動線が組み合わ
さると再識別の可能性が生じます。

| 関数 | 用途 |
|---|---|
| `createProfile(_:)` | 作成 — `profileId` を返す |
| `fetchProfile(_:)` | 属性の取得 |
| `replaceProfile(_:attributes:)` | 属性の**全**置換 — 渡さなかった属性は削除されます |
| `deleteProfile(_:)` | 削除 |
| `identify(profileId:)` | 紐づけ — 測位前に必須 |

---

## Step 5: 空間の選択（任意）

省略できます。更新済みのロケーターは BLE で自分のフロアを知らせるため、エンジンは `begin()` の 1〜2 秒後に
フロアを自ら見つけます。人がフロアを選ぶ必要がある場合や、測位前に地図を描きたい場合だけ指定してください。

```swift
let buildings = try await OneS1ght.buildings()
let floors    = try await OneS1ght.floors(buildingId: buildings[0].id)

try await OneS1ght.setFloorMap(floors[0], buildingId: buildings[0].id)
```

`setFloorMap` はロケーター・UWB セッション ID・ゾーンを取得してエンジンに注入します。
実行中に再度呼び出すとフロアが切り替わり、セッションはそのまま維持されます。

### エンジンが見つけたフロアに追従する

```swift
let session = try OneS1ght.floorSession()
session.onFloorDetected = { floorId in
    guard let floorId else { return }              // nil = フロアを見失った
    // floorId は Floor.id と同じ値 — そのフロアを描画するか setFloorMap する。
}
```

⚠️ フロアを切り替えるために測位を止め**ないでください。** 実行中の `setFloorMap` は安全でセッションを
維持します — 止めるとエンジンがロケーターを最初から探し直します。

### 地図の描画

```swift
let floor = try await OneS1ght.floor(buildingId: buildings[0].id, floorId: floors[0].id)
mapView.setBackground(floor.image,
                      bounds: (floor.minX, floor.minY, floor.maxX, floor.maxY))
```

⚠️ `floors(buildingId:)` は一覧を軽く保つため `image == nil` で返します。描画するフロアのみ単体で
取得してください。図面はキャッシュされ、コンソールで図面が変わると（`.planChanged`）破棄されます。

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
session.onStopped   = { reason in
    switch reason {
    case .ended:        break
    case .engineFailed: showRetry()   // 原因（権限・Bluetooth）を解消して begin() を再度呼ぶ
    @unknown default:   break
    }
}

try await session.begin()
…
await session.end()
```

`floorSession()` は常に同じインスタンスを返します — UWB 無線・判定エンジン・座標バッファ
は端末ごとに 1 つのため、セッションが複数あると物理的に競合します。

エンジンが自ら停止すると、SDK が再起動します（3・10・30 秒後、アプリが画面に表示されている間のみ）。
それでも戻らない場合や、人が解消すべき原因（位置情報の権限・Bluetooth・ライセンス）の場合は、SDK が
**セッションを閉じます** — `isRunning` が `false` になり `onStopped(.engineFailed)` が呼ばれるため、
`begin()` を再度呼べます。

`onZoneDwell` はゾーンの `dwellSeconds` が経過すると訪問ごとに 1 回届きます。`dwellSeconds` の無い
ゾーンは入退出のみです。

### 一時停止は終了ではありません

```swift
session.pause()      // 表示・収集だけを止める — エンジンは動き続ける
session.resume()
session.isPaused
```

| | `pause()` | `end()` |
|---|---|---|
| 座標コールバック | 停止 | 停止 |
| ゾーン入退出 | 停止 | 停止 |
| サーバー送信 | 停止 | 残りを送信して停止 |
| エンジン・フロア・ロケーター | **維持** | 解放 |
| 再開のコスト | 即時 | ロケーターを最初から探す |

「少しの間、自分の位置を隠す」には `pause()` を使います。`end()` は空間を離れるときに使います。
一時停止はバックグラウンドに行って戻っても維持され、`resume()`・`end()`・`begin()` でのみ解除されます。
再開すると判定状態をクリアするため、停止中に出たゾーンの古い退出イベントは届きません。

### コンソールの変更を受け取る

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

リアルタイム接続は**フロアを指定しているか、測位中の間**つながっています。連続して届いたら 1 秒ほど
まとめてから再取得してください — ゾーンを取り直すたびに判定が最初から始まります。

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
| 初期化 | `initialize(sdkKey:baseURL:)` · `requestPermission()` · `reset()` · `defaultBaseURL` |
| プロフィール | `createProfile(_:)` · `fetchProfile(_:)` · `replaceProfile(_:attributes:)` · `deleteProfile(_:)` · `identify(profileId:)` |
| 空間取得 | `buildings()` · `building(id:)` · `floors(buildingId:)` · `floor(buildingId:floorId:)` · `zones(buildingId:floorId:)` · `zone(buildingId:floorId:zoneId:)` · `locators(buildingId:floorId:)` |
| フロア指定 | `setFloorMap(_:buildingId:)` · `refreshZones()` |
| 測位 | `floorSession()` → `begin()` · `end()` · `pause()` · `resume()` · `isPaused` · `isRunning` |
| セッションコールバック | `onZoneEnter` · `onZoneExit` · `onZoneDwell` · `onPosition` · `onTriggers` · `onFloorDetected` · `onStopped` · `onConfigChanged` |
| バッファ | `uploadPendingPositions()` · `discardPendingPositions()` |
| 状態 | `isInitialized` · `isDeviceAvailable` · `deviceAvailability` · `onDebugLog` · `setLanguage(_:)` · `sdkVersion` |
| コンソール提供値 | `googleMapKey` |

⚠️ `discardPendingPositions()` はバッファ内の座標を**送信せずに破棄します。** 送信は
`uploadPendingPositions()` です。

⚠️ アプリが直接扱うコンソール値は `googleMapKey` の一つだけです。測位ライセンスと空間
サービスのアドレスは SDK 内部でのみ使用し、外部には公開しません — アプリが知る必要も、
扱う理由もありません。

0.1.24 以降に変わった旧名（`floor(_:_:)`・`permissions()`・`send()`・`empty()`・`getProfile`・`putProfile`・
`setFloorMap(_:buildingID:)`・`Trigger.trigger_id` …）は deprecated 警告が出るだけで、そのままコンパイル
できます — [CHANGELOG](CHANGELOG.md) を参照してください。

### SDK の enum を switch するとき

SDK の enum はマイナーリリースでケースが増えることがあります。`ConfigChange`・`SdkErrorCode`・`ZoneEvent`・
`FloorSession.StopReason`・`PermissionStatus`・`OneS1ght.DeviceAvailability`・`LogLevel` を switch するときは
`@unknown default` を置いてください — 新しいケースでビルドが壊れません。

```swift
switch change {                 // ConfigChange
case .zonesChanged, .resyncNeeded: Task { await OneS1ght.refreshZones() }
case .planChanged:                 reloadPlan()
case .rulesChanged, .sdkConfigChanged: break
@unknown default:                  break    // 後から増えたケースはビルドを壊さずここに来る
}
```

無い場合、網羅的な `switch` は新しいケースでコンパイルエラーになります。

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

### ゾーン判定はどこで行われるか

測位エンジンは、起動時に空間サービスから取得した**自身のジオフェンス**で入退出を判定します。
`zones(buildingId:floorId:)` で取得するゾーンは名前・ID の対応付け用で、コンソールで判定パラメータを
変えても判定は変わりません。

SDK は `refreshZones()` のたびにゾーンの集合が実際に変わったか（追加・削除・描き直し）を確認し、変わった
ときだけエンジンに読み直させます。エンジンが再起動するため、**座標が 1 秒ほど途切れます。** その間隔を
「信号断」として扱う UI がある場合は、猶予をそれより長くしてください。

### バッチ送信

| トリガー | 値 |
|---|---|
| 件数 | 300 件（バッファが達した時点） |
| 間隔 | 60 秒（失敗した送信もこのとき再送） |
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
| アプリは動くが座標が出ない | `E3007` · `E3003` · `E4002` | フロア検出(BLE) → UWB セッション → ロケーター配置 |
| 空間一覧が空で `floor()` が `notInitialized` | `E1007` | コンソールの測位キー設定、`/config` への到達 |
| ゾーンイベントが発火しない | `E3004` · `E3009` | コンソールにゾーンがあるか、ゾーン名がエンジンのエリアと一致するか |
| データが別のフロアに蓄積される | `E3008` | エンジンのフロアとコンソールのフロアが異なる |
| 特定の端末でのみ動作しない | `E2001` · `E2002` | iOS 27 / iPhone 12 以降か |
| `begin()` 直後に測位が閉じる | `E2003` · `E2004` | 位置情報・Bluetooth の権限、Bluetooth のオン、Info.plist キー |
| 連携直後に 401 | `E1002` | キーの状態・環境（production/development） |
| コンソールにデータが表示されない | `E5001` · `E5006` | ネットワーク → バッチ間隔 |

| コード | 意味 |
|---|---|
| `E1001` | SDK が未初期化 |
| `E1002` | SDK キーが無効または失効 |
| `E1003` | テナントで測位が無効 |
| `E1004` | プロフィール未連携 |
| `E1007` | 測位キーを取得できない（コンソールに無い、または取得失敗） |
| `E2001` | iOS バージョン不足 |
| `E2002` | UWB 非対応端末 |
| `E2003` | 測位権限が拒否された（または Info.plist キーが無い） |
| `E2004` | Bluetooth がオフ |
| `E3001` | フロア未指定 — `onDebugLog` のみ。サーバーには送らない（エンジンがフロアを探す通常経路） |
| `E3002` | フロアにロケーターがない |
| `E3003` | フロアに UWB セッションがない |
| `E3004` | フロアにゾーンがない |
| `E3006` | ロケーターの取得に失敗 — 地図はそのまま開く |
| `E3007` | フロア未検出（BLE） |
| `E3008` | エンジンのフロアとコンソールのフロアが不一致 |
| `E3009` | エンジンのエリア名に合うコンソールのゾーンがない |
| `E4001` | UWB セッション失敗 / エンジン停止 |
| `E4002` | 座標が算出されない |
| `E4003` | 一部のロケーターが受信できない — **WARN、測位は継続します** |
| `E4004` | エリア判定に失敗（その回のみ） |
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
OneS1ght.onDebugLog = { level, line in print("[\(level)] \(line)") }
```

⚠️ 本番環境では登録しないことを推奨します。

---

## お問い合わせ

onesight-support@onecheck.co.kr
