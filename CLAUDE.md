# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MichiNavi は CarPlay 対応のカーナビ iOS アプリ。地図・検索・経路計算はすべて MapKit で、
外部依存（SPM パッケージ）はゼロ。

## ビルドと実行

```bash
# ビルド（動作確認済みの destination）
xcodebuild -scheme MichiNavi -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# 実機向け（署名まで通す）
xcodebuild -scheme MichiNavi -destination 'generic/platform=iOS' build

# Xcode で開く
xed .
```

- **`IPHONEOS_DEPLOYMENT_TARGET = 26.0`**。iOS 26 のランタイムを持つ機種しか destination に指定できない。
  `iPhone 16 Pro` などは古いランタイムにしか存在せず "destination is not valid" で落ちる。
  迷ったら `xcodebuild -scheme MichiNavi -showdestinations` で候補を出す。
- **テストターゲットは存在しない**。追加するまで `xcodebuild test` は使えない。
- **CarPlay 画面の確認**: シミュレータ起動後、メニューの I/O → External Displays → CarPlay。
  `com.apple.developer.carplay-maps` は 2026-08-15 に Apple の承認が下りたので、実機の
  CarPlay でも動かせる。
- **制限付き entitlement は、アカウントへの承認だけでは足りない**。App ID 側でケイパビリティを
  有効化しないとプロビジョニングプロファイルに含まれず、承認前とまったく同じ
  `Entitlement com.apple.developer.carplay-maps not found and could not be included in profile.`
  で実機ビルドが落ちる。`jp.hibiki.michinavi` では設定済み。バンドル ID を増やすときは同じ作業が要る。
- **ファイル追加は `MichiNavi/` に置くだけ**。`PBXFileSystemSynchronizedRootGroup` を使っているので
  ターゲットへの登録は自動。`project.pbxproj` を手で編集しない。

## アーキテクチャ

### 状態は `NavigationController.shared` の 1 か所だけ

iPhone 画面（SwiftUI）と CarPlay 画面（UIKit + CarPlay テンプレート）は、どちらも
`NavigationController.shared` を購読するだけの表示層。案内ロジックは一切持たない。
**この分離が崩れると、iPhone で操作したときと CarPlay で操作したときで挙動が分岐する。**
新機能を足すときは、まず「状態は NavigationController、見た目は各 UI」に割り振る。

```
idle ──requestRoutes──> calculating ──> previewing ──startNavigation(with:)──> navigating
 ^                                                                                 │
 └──────────────── cancelNavigation / 到着 ────────────────────────────────────────┘
```

案内へ入る道は 2 本ある。`requestRoutes(to:)` は previewing で止まり、どのルートで行くかを
利用者が選ぶ。`startNavigation(to:)` は計算からそのまま navigating へ入る（先頭のルートを使う）。
後者は CarPlay Dashboard のショートカットのように、**提示画面を見てもらえない場所**からの入口。

Combine の使い分けにも意味がある:

- `@Published`（`phase` / `progress` / `lastError` / `isRerouting`）= **いまの状態**。
  購読側は再描画すればよい。
- `PassthroughSubject`（`maneuverChanged` / `arrived`）= **その瞬間の出来事**。
  `CPManeuver` の差し替えのように、1 回だけ起こしたい副作用に使う。
  音声案内はこれではなく `progress` を見ている（後述）。

### レイヤの責務

| ディレクトリ | 責務 | 制約 |
| --- | --- | --- |
| `Core/` | 位置・検索・経路計算・進捗計算・状態管理・目的地の保存・音声案内 | UI 非依存。CarPlay も SwiftUI も import しない |
| `CarPlay/` | `CPxxx` テンプレート ↔ `NavigationController` の変換。センターディスプレイと Dashboard の 2 画面ぶん | 案内ロジックを持たない |
| `Phone/` | SwiftUI 画面 | 同上 |

共有シングルトンは 5 つ: `NavigationController.shared` / `LocationService.shared` /
`SearchService.shared` / `DestinationStore.shared` / `VoiceGuidance.shared`。
特に `LocationService` を共有することで **GPS は常に 1 本しか動かない**。

### `GuidanceEngine`（経路上の進捗計算）

ルート 1 本につき 1 インスタンス。位置更新のたびに `RouteProgress` を作る。

- 距離計算は `MKMapPoint`（メルカトル平面）上で行い、最後にメートル換算する。
- 現在地は経路への最近傍投影で吸着させる。探索は **前回区間の周辺（`-5 ... +30`）を優先**し、
  そこで見つからなければ全体を探し直す。この優先探索がループ路・折り返しで経路の別の場所へ
  飛びつくのを防いでいるので、単純な全体探索に置き換えないこと。
- 逸脱判定 = 中心線から 50m 超が **3 回連続**（GPS の跳ねでの誤リルート防止）。到着判定 = 残り 30m。
- 前提として `NavRoute` は、steps の座標を連結した `coordinates` と、各 step の終端添字
  `stepEndIndices` を持つ。この 2 つが進捗計算の土台。

### 音声案内（`VoicePromptScheduler` / `VoiceGuidance`）

「どこで何を読むか」（純ロジック）と「実際に鳴らす」（オーディオセッション）を分けてある。
`VoiceGuidance.shared.start()` を `AppDelegate` から 1 回呼ぶだけで動きだし、あとは
`phase` / `progress` / `arrived` を購読して自走する。`NavigationController` 側は音声を知らない。

- 予告は 1km / 500m / 200m / まもなく の 4 段階。**区間がしきい値の 1.4 倍より長いときだけ**
  予告するので、300m の区間で「1キロ先」とは言わない。読んだしきい値は step ごとに記録し、
  GPS が飛んで一気に近づいても、通り過ぎた予告を後追いで読まない。
- リルートは `phase` のルート ID が変わったことで判定する。専用のイベントは足していない。
- **オーディオセッションは鳴らす瞬間だけ有効にする**。カテゴリ設定
  （`.playback` / `.voicePrompt` / `[.interruptSpokenAudioAndMixWithOthers, .duckOthers]`）は
  1 度きり、読み上げごとに切り替えるのは有効・無効だけ。終わったら
  `notifyOthersOnDeactivation` 付きで即座に手放す。**有効なままにすると音楽がダックされ続け、
  ポッドキャストは一時停止したままになる。**
- `session.promptStyle` はセッションを有効化する**前**に見る。`none`（通話中・Siri 中）なら
  何もせず返るので、「鳴らす音が無いのにセッションを有効化しない」というガイドラインの
  要求も同時に満たす。`short` のときは音声ファイルを同梱せずに済ませるため、16bit PCM の
  WAV をその場で組み立ててトーンを鳴らす。

### 目的地の保存（`DestinationStore`）

履歴とお気に入りを UserDefaults に置くだけの薄い層。履歴は案内開始時に自動で積む。
`Place` の同一性がこの土台になっているので、**`Place.id` を init で振り直さないこと**。
`MKMapItem` の識別子、無ければ名前と座標（小数 5 桁 ≒ 1m に丸め）から組み立てる。
UUID に戻すと同じ場所が毎回別物になり、重複排除もお気に入り判定も壊れる。丸めるのは
測位のわずかな揺れで別物にしないため。

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
- **地図のベースビューにタッチは届かない**（ガイド p.36「Your app won't receive direct tap or
  drag events in the base view」）。`MKMapView` に自前のジェスチャを付ける手は使えず、入力は
  すべて `CPMapTemplateDelegate` 経由。指のドラッグは `didUpdatePanGestureWithTranslation`
  で来るが、**届くかどうかは車次第**（ノブ／トラックパッドしか無い車がある）。
  `translation` は `UIPanGestureRecognizer` と同じくジェスチャ開始からの累積値なので、
  前回との差分にしてから地図へ渡す。そのまま渡すと動かすほど加速する。
- **パンボタンは外せない**（ガイド p.33）。タッチでドラッグできる車があっても、ノブしか無い
  車のために「パン UI へ入るボタン」を必ず 1 つ置くことが要件。
- **`mapButtons` は 4 つまで。パン UI に入ると先頭 2 つしか残らない**（超過ぶんは配列の
  末尾から順に隠される）。並び順が表示に直結するので、パン UI で用の無いものほど後ろへ置く。
- **`CarPlayCoordinator.beginSessionIfNeeded` の二重開始ガードを外さない**。
  iPhone 側で案内を始めた場合も同じ経路を通る。
- リルートは失敗しても案内を止めない（次の位置更新で再試行）。多重計算は
  `isCalculatingReroute` で防ぐ。**公開している `isRerouting` と混同しない**。前者は計算が
  走っているあいだだけ、後者は経路に戻るまで（失敗して再試行している最中も）立ち続ける。
  分けてあるのは、再試行のたびに CarPlay の「再検索中」カードが点滅するのを避けるため。
- **リルート中も `CPNavigationSession` は張り替えず、`pauseTrip` / `resumeTrip` で繋ぐ**。
  作り直すと `CPTrip` から組み直しになり、到着予定の表示が一度途切れる。再開に使う
  `resumeTrip(updatedRouteInformation:)` は iOS 26.4 で非推奨になったが、後継
  （`CPRouteSegment` を経由地ごとに積むモデル）は目的地 1 つの現状では得るものが無く、
  デプロイメントターゲットが 26.0 のうちは `#available` 分岐が要って古い実装も消せない。
  26.0 が下限なら非推奨の警告も出ないので、当面は乗り換えない。
- **走行中はキーボードが塞がれる**。`CPSessionConfiguration.limitedUserInterfaces` に
  `.keyboard` が入っている間、`CarPlayDestinationBrowser` は検索ボタンを出さない。
  押しても何も起きない導線を運転中に見せないため。**検索が使えない前提で目的地に
  たどり着ける経路（お気に入り・履歴・周辺カテゴリ）を必ず残す。**
- **Dashboard のシーンは来ないことがある**。CarPlay が必要と判断したときだけ作られるので、
  接続されない前提で書く。ショートカットは 2 つまで、かつ案内中は出せない。
  案内カードの中身は `CPMapTemplate` + `CPNavigationSession` を使っていれば CarPlay が自前で
  描くため、Dashboard 側が受け持つのは地図とショートカットだけ。
- **`shortcutButtons` に空配列を代入しない**。CarPlay ホスト
  （`CPSDashboardGuidanceViewController.setShortCutButtons:`）は「ちょうど 1 件」と「それ以外」で
  レイアウトを分けていて、0 件は後者に落ちる。そこで `firstObject` / `lastObject` が nil のまま
  制約に使われ、`NSArray` の生成で例外 → CarPlayTemplateUIHost が落ちる（iOS 26.5 で確認。
  履歴が空のまま Dashboard を繋ぐと必ず再現する）。**案内中に隠すのは CarPlay の仕事**で、
  `showManeuvers:` でショートカット欄を畳み `didEndTrip:` で戻すため、こちらから消さなくてよい。
- **アプリのプロセスが落ちると CarPlay ホストも道連れになる**（シミュレータ限定・Apple 側のバグ）。
  `CPSMapTemplateViewController._updateShareButtonVisibility` が
  `CPSTemplateInstance` の実装していない `vehicleSupportsDestinationSharing` を
  `respondsToSelector:` も見ずに呼ぶため。Xcode の再ビルド・再インストールのたびに
  CarPlayTemplateUIHost のクラッシュログが増えるが、**こちらのバグではない**ので追わないこと。
- **`CarPlayMapViewController` は 2 画面で共用**。`.compact`（Dashboard）はカメラ高度を
  近づけ、目的地ピンを出さず、経路の線を細くする。狭い画面向けの差はこのクラスに集約する。
- **地図の向き（`MapOrientation`）は CarPlay 専用の設定で、iPhone は追従しない**。
  センターディスプレイと Dashboard は同じ設定を見る（Dashboard は次の位置更新で揃う）。
  案内ロジックではなく見た目の設定なので、あえて `NavigationController` にも `Core/` にも
  置いていない。iPhone 側が常に進行方向を上にしているのは**意図した非対称**で、揃えるなら
  iPhone にも切り替えを出すところまでやること。片方だけ追従させると変えられない設定になる。
- **昼夜（`contentStyle`）を扱うのはセンターディスプレイ側だけ**。地図は
  `overrideUserInterfaceStyle` に流せば trait collection 経由で切り替わり、テンプレートは
  CarPlay が自前で切り替える。Dashboard のシーンに `contentStyle` は無く、渡される
  `UIWindow` の trait collection が昼夜をそのまま運んでくるので、あちらでは何もしない。

## 記述の慣習

- **コメント・UI 文言・コミットメッセージはすべて日本語**。コメントは「何を」ではなく「なぜ」を書く。
- 距離・時間・到着時刻の表示は `Formatters` に集約。両画面で表記がずれないよう、直に文字列を組まない。

## 未実装

CarPlay entitlement（`com.apple.developer.carplay-maps`）は 2026-08-15 に承認され、当面の
ゴールだった申請は通った。同日に実機の CarPlay で画面の見た目・音声案内・目的地選択まで
通しで確認済み。残っているのは以下。

- **英語ローカライズ**: UI 文言は日本語のみで、`.lproj` も `.xcstrings` も無い。
- **リルート中の一時停止の実走確認**: `pauseTrip` / `resumeTrip` は実装したが、
  実際に経路を外れて「再検索中」カードが出て消えるところまでは走らせていない。
