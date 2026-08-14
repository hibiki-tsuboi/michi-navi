# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MichiNavi は CarPlay 対応のカーナビ iOS アプリ。地図・検索・経路計算はすべて MapKit で、
外部依存（SPM パッケージ）はゼロ。

## ビルドと実行

```bash
# ビルド（動作確認済みの destination）
xcodebuild -scheme MichiNavi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Xcode で開く
xed .
```

- **`IPHONEOS_DEPLOYMENT_TARGET = 26.0`**。iOS 26 のランタイムを持つ機種しか destination に指定できない。
  `iPhone 16 Pro` などは古いランタイムにしか存在せず "destination is not valid" で落ちる。
  迷ったら `xcodebuild -scheme MichiNavi -showdestinations` で候補を出す。
- **テストターゲットは存在しない**。追加するまで `xcodebuild test` は使えない。
- **CarPlay 画面の確認**: シミュレータ起動後、メニューの I/O → External Displays → CarPlay。
  実機の CarPlay は `com.apple.developer.carplay-maps` の Apple 承認と専用プロビジョニング
  プロファイルが必要で、承認前は実機ビルドが署名で通らない。
- **ファイル追加は `MichiNavi/` に置くだけ**。`PBXFileSystemSynchronizedRootGroup` を使っているので
  ターゲットへの登録は自動。`project.pbxproj` を手で編集しない。

## アーキテクチャ

### 状態は `NavigationController.shared` の 1 か所だけ

iPhone 画面（SwiftUI）と CarPlay 画面（UIKit + CarPlay テンプレート）は、どちらも
`NavigationController.shared` を購読するだけの表示層。案内ロジックは一切持たない。
**この分離が崩れると、iPhone で操作したときと CarPlay で操作したときで挙動が分岐する。**
新機能を足すときは、まず「状態は NavigationController、見た目は各 UI」に割り振る。

```
idle ──requestRoutes──> calculating ──> previewing ──startNavigation──> navigating
 ^                                                                          │
 └──────────────── cancelNavigation / 到着 ─────────────────────────────────┘
```

Combine の使い分けにも意味がある:

- `@Published`（`phase` / `progress` / `lastError`）= **いまの状態**。購読側は再描画すればよい。
- `PassthroughSubject`（`maneuverChanged` / `arrived`）= **その瞬間の出来事**。
  音声読み上げや `CPManeuver` の差し替えのように、1 回だけ起こしたい副作用に使う。

### レイヤの責務

| ディレクトリ | 責務 | 制約 |
| --- | --- | --- |
| `Core/` | 位置・検索・経路計算・進捗計算・状態管理 | UI 非依存。CarPlay も SwiftUI も import しない |
| `CarPlay/` | `CPxxx` テンプレート ↔ `NavigationController` の変換 | 案内ロジックを持たない |
| `Phone/` | SwiftUI 画面 | 同上 |

共有シングルトンは 3 つ: `NavigationController.shared` / `LocationService.shared` /
`SearchService.shared`。特に `LocationService` を共有することで **GPS は常に 1 本しか動かない**。

### `GuidanceEngine`（経路上の進捗計算）

ルート 1 本につき 1 インスタンス。位置更新のたびに `RouteProgress` を作る。

- 距離計算は `MKMapPoint`（メルカトル平面）上で行い、最後にメートル換算する。
- 現在地は経路への最近傍投影で吸着させる。探索は **前回区間の周辺（`-5 ... +30`）を優先**し、
  そこで見つからなければ全体を探し直す。この優先探索がループ路・折り返しで経路の別の場所へ
  飛びつくのを防いでいるので、単純な全体探索に置き換えないこと。
- 逸脱判定 = 中心線から 50m 超が **3 回連続**（GPS の跳ねでの誤リルート防止）。到着判定 = 残り 30m。
- 前提として `NavRoute` は、steps の座標を連結した `coordinates` と、各 step の終端添字
  `stepEndIndices` を持つ。この 2 つが進捗計算の土台。

### MapKit の制約と、その回避策

`RouteProviding` プロトコルの裏に経路計算を隔離してあるのは、以下 2 つを将来消せるようにするため。

1. **step ごとの所要時間を返さない** → 経路全体の平均速度で距離按分している
   （`GuidanceEngine.update` と `CarPlayCoordinator.estimatedTime` の 2 か所）。
2. **maneuver type（曲がる向きの列挙）が非公開** → `ManeuverSymbol` が
   「右折します」等の**指示文の文言マッチ**でアイコンを決めている。日英どちらも見る。
   ルールは上から順に評価するため、長い語（「斜め右」）を短い語（「右」）より必ず先に置く。

Mapbox / Valhalla などに差し替えるときは `RouteProviding` の実装を足すだけで、
CarPlay 層は触らずに済む設計。

## 踏み抜きやすい前提

- **Swift 並行性**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。既定で全部が MainActor。
  そのため `CLLocationManagerDelegate` / `MKLocalSearchCompleterDelegate` は
  `nonisolated` + `MainActor.assumeIsolated {}` で受けている。この形を崩さない。
- **`AppDelegate` に `configurationForConnecting` を実装しない**。CarPlay シーンは Info.plist の
  シーンマニフェストが作る。実装するとマニフェストより優先され、SwiftUI の `WindowGroup` が
  生成されなくなる。
- **`allowsBackgroundLocationUpdates` は `authorizedAlways` でないと例外**になる。
  `LocationService.setNavigating` がガード済み。「常に許可」は Apple の推奨順序に従い、
  案内を開始してから初めて求める。
- **CarPlay の `upcomingManeuvers` は 2 件までしか表示されない**ので 2 件で切っている。
- **CarPlay の地図では中心合わせ・全体表示で `view.safeAreaInsets` を必ず差し引く**。
  テンプレート（上部バー・案内カード）が地図の上に重なるため、引かないと自車位置が裏に隠れる。
- **`CarPlayCoordinator.beginSessionIfNeeded` の二重開始ガードを外さない**。
  iPhone 側で案内を始めた場合も同じ経路を通る。
- リルートは失敗しても案内を止めない（次の位置更新で再試行）。`isRerouting` で多重計算を防ぐ。

## 記述の慣習

- **コメント・UI 文言・コミットメッセージはすべて日本語**。コメントは「何を」ではなく「なぜ」を書く。
- 距離・時間・到着時刻の表示は `Formatters` に集約。両画面で表記がずれないよう、直に文字列を組まない。

## 未実装

- **音声案内**: `maneuverChanged` と `UIBackgroundModes` の `audio` は用意済みだが、
  読み上げ本体はまだ無い。
- **履歴・お気に入り**: `Place` は共通の目的地型として設計済みだが、保存層は無い。
