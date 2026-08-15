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
| `CarPlay/` | `CPxxx` テンプレート ↔ `NavigationController` の変換。センターディスプレイ・Dashboard・メーター内の 3 画面ぶん | 案内ロジックを持たない |
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
  ただし **`horizontalAccuracy` がしきい値より悪い測位は数えない**。誤差 100m の位置で
  「50m 以上離れている」とは言えず、ビルの谷間やトンネル前後でリルートが連発する。
  戻り（`offRouteStreak = 0`）は精度に関係なく効かせる。安全側に倒すため。
- **逸脱判定はいったん成立すると経路に戻るまで下りない**。つまり外れているあいだ
  `NavigationController.handle` は位置更新のたびにリルートを呼ぶ。呼ばれる側で必ず間隔を
  空けること（後述）。
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

`RouteProviding` プロトコルの裏に経路計算を隔離してあるのは、以下 3 つを将来消せるようにするため。

1. **step ごとの所要時間を返さない** → 経路全体の平均速度で距離按分している
   （`GuidanceEngine.update` と `CarPlayCoordinator.estimatedTime` の 2 か所）。
2. **maneuver type（曲がる向きの列挙）を返さない** → `ManeuverKind` が
   「右折します」等の**指示文の文言マッチ**で推測する。日英どちらも見る。
   ルールは上から順に評価するため、長い語（「斜め右」）を短い語（「右」）より必ず先に置く。
   「ロータリー」が「出口」より先なのも同じ理由で、逆にすると「2 番目の出口で出る」が
   高速の出口になる。**ここで決めた型は画面のアイコンだけでなく、`CPManeuver.maneuverType`
   として車のメーター・HUD にも送られる**（後述）ので、外すと両方が同時にずれる。
3. **経由地を扱えない** → `MapKitRouteProvider` が区間ごとに `MKDirections` を投げ、
   結果を 1 本の `NavRoute` に繋いでいる。**経由地があるときは候補ルートを求めない**。
   区間の数だけ組み合わせが増えて、運転中に選べる形にならないため。

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
- **案内の内容は車のメーター・HUD にも送っている**（ガイド p.56）。
  `mapTemplateShouldProvideNavigationMetadata` が true を返すことで有効になり、
  `CPManeuver.maneuverType` と `CPNavigationSession.maneuverState` が車へ渡る。
  デジタルメーターの無い車でも受け取れる。`upcomingManeuvers` に載せるものは先に
  `add(_:)` でセッションへ渡す決まりなので、`routeManeuvers` に全区間を作ってから
  そこを切り出している。**別インスタンスを混ぜない**こと（`updateEstimates(for:)` の
  宛先が食い違う）。
- **`CPManeuver.trafficSide` は設定していない**。ロータリーの回転方向に効くが、走行国を
  MapKit は教えてくれず、`Place` も国コードを持たない（履歴から戻した `MKMapItem` は
  座標だけ）。既定の右側通行のままなので、日本のロータリーでは向きが逆になる。
- **CarPlay の地図では中心合わせ・全体表示で `view.safeAreaInsets` を必ず差し引く**。
  テンプレート（上部バー・案内カード）が地図の上に重なるため、引かないと自車位置が裏に隠れる。
- **地図のベースビューにタッチは届かない**（ガイド p.36「Your app won't receive direct tap or
  drag events in the base view」）。`MKMapView` に自前のジェスチャを付ける手は使えず、入力は
  すべて `CPMapTemplateDelegate` 経由。指のドラッグは `didUpdatePanGestureWithTranslation`
  で来るが、**届くかどうかは車次第**（ノブ／トラックパッドしか無い車がある）。
- **ジェスチャはパン UI に入っていなくても届く**。パン UI（`showPanningInterface`）は
  ドラッグできない車のための代替手段で、ジェスチャの前提条件ではない（ガイド p.33 が
  パンボタンを必須にする理由を「drag gestures are not available in all vehicles」と
  書いているのがその裏付け）。Apple Developer Forums の thread/730949 にある
  「これらはビルトインのパンコントロール関連」という回答は、パン**ボタン**
  （`panWith:`）とドラッグを混同しているので、そのまま信じないこと。
  実際の出し分けは CarPlay ホスト側の `_updatePanGestureForHiFiTouch` が
  `traitCollection.touchLevel`（車が申告するタッチ精度）で決めていて、1 本指のパンだけは
  高精度タッチの車にしか認識器が付かない。ヘッダの「May not be called when connected to
  some CarPlay systems」はこれを指す。ピンチ・回転・ピッチにこのゲートは無い。
- **`didUpdatePanGestureWithTranslation` の `translation` は累積値ではなく前回からの差分**。
  CarPlay ホストが送るのは `clientPanGestureWithDeltaPoint:velocity:` で、実体は
  「いまの点 − 前回の点」（iOS 18.6 でも 26.5 でも同じ）。`UIPanGestureRecognizer` と
  同じつもりで差分を取るとデルタの微分になり、**等速でドラッグしても地図が動かない**。
  そのまま `pan(by:)` へ渡す。2026-08-16 まで逆に実装していた。
- **iOS 26 のタッチジェスチャは、同じ callback でも値の意味が揃っていない**（ガイド p.49）。
  ここを取り違えても**コンパイルは通り、黙って効かなくなる**（`CPMapTemplateDelegate` は
  全メソッドが任意なので、名前を間違えても素通りする。追加時は
  `#selector(CPMapTemplateDelegate.xxx)` が解決するかで確かめること）。
  - ピンチの `scale` と回転の `rotation` は**ジェスチャ開始からの累積値**（パンだけ差分）。
    開始時の高度・方位を基準に取り直して割る／引く。
  - **ダブルタップ（拡大）と 2 本指タップ（縮小）は、ズームの callback に相乗りしてくる**。
    開始も終了も無しに更新が 1 回だけ来て、`scale` は 1.0 のまま、向きは `velocity` の
    符号にしか入っていない。`scale` だけ見ていると無反応になる。中心もタップ位置ではなく
    安全領域の中心が渡ってくる。
  - **ピッチは動かした量を渡してこない**（`pitchWithCenter:` は中心座標のみ、開始側に
    中心すら無い）。連続する中心の差から自分で作るしかない。
  - ピンチの更新には CarPlay 側で時間の間引きが入っている。
- **中断されたジェスチャに終了は来ない**。CarPlay 側のハンドラは
  `UIGestureRecognizerState` を began / changed / ended の 3 つでしか分岐しておらず、
  `.cancelled`（着信・Siri・`CPAlertTemplate` の提示などでタッチが取り消される）と
  `.failed` は素通りする。**「開始を受け取ったか」を状態の判別に使わないこと。**
  ピンチとタップの見分けは、タップが必ず持つ定数（`scale` が 1.0、`velocity` が ±1.0）で行う。
- **ピンチと回転は同時に認識される**。`CPSMapTemplateViewController` の
  `gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:` が YES を
  返すのはこの組み合わせだけ。つまり**縮尺を変えるだけのつもりのピンチでも回転が始まる**ので、
  回転の開始で追従を切ると、ズームでは避けたはずの「縮小しただけで自車を見失う」が起きる。
  追従を切るのは、はっきり回した（`minimumRotationToStopFollowing`）と分かってから。
  ピッチも同じ理屈で、実際に傾ける段になってから切る。
- **`recenter()` は指が触れている最中にも呼ばれる**。`apply(phase:)` がリルートの成功・
  到着・案内開始で呼ぶため。進行中の回転・傾けの基準を捨てないと、指を離すまで
  ジェスチャと `follow` が 1 秒ごとに殴り合う。ズームの基準は捨てない（追従したまま
  効かせる操作なので、捨てるとピンチの続きをタップと取り違える）。
- **回転とピッチは追従を切ってからでないと効かない**。`follow` が位置更新のたびに
  向きと傾きを `MapOrientation` から作り直すため。パンと同じく現在地ボタンで戻す。
  ズームは中心を動かさないので追従したまま効かせている（拡大・縮小ボタンと同じ扱い。
  ここで追従を切ると、縮小しただけで自車を見失う）。
- **パンボタンは外せない**（ガイド p.33）。タッチでドラッグできる車があっても、ノブしか無い
  車のために「パン UI へ入るボタン」を必ず 1 つ置くことが要件。
- **`mapButtons` は 4 つまで。パン UI に入ると先頭 2 つしか残らない**（超過ぶんは配列の
  末尾から CarPlay が勝手に隠す）。**並び順まかせにしないこと**。4 つ置いた状態でパン UI に
  入ると 2 つ落ちる。`mapTemplateDidShowPanningInterface` で拡大・縮小の 2 つに差し替え、
  `mapTemplateDidDismissPanningInterface` で元へ戻している。パン中に意味があるのは
  拡大・縮小だけで、現在地へ戻すのは「完了」が担う。
- **`CarPlayCoordinator.beginSessionIfNeeded` の二重開始ガードを外さない**。
  iPhone 側で案内を始めた場合も同じ経路を通る。
- **経由地は `NavRoute` を 1 本に繋いだ時点で見えなくなる**。`GuidanceEngine` も
  `VoiceGuidance` も経由地を知らないまま動く。残っているのは `waypoints` と
  `waypointStepIndices` だけで、用途は 2 つ。**引き直しのときに未通過ぶんを引き継ぐ**
  （落とすと、経路を外れた拍子に立ち寄り先が消える）のと、通過を知らせること。
  追加した経由地はいちばん後ろに入る。位置関係から順番を組み替えるのは
  巡回セールスマン問題で、MapKit にその機能は無い。
- リルートは失敗しても案内を止めない（間隔を空けて再試行）。多重計算は
  `isCalculatingReroute` で防ぐ。**公開している `isRerouting` と混同しない**。前者は計算が
  走っているあいだだけ、後者は経路に戻るまで（失敗して再試行している最中も）立ち続ける。
  分けてあるのは、再試行のたびに CarPlay の「再検索中」カードが点滅するのを避けるため。
- **リルートの間隔（`minimumRerouteInterval` と失敗ごとの倍化）を外さない**。逸脱判定は
  経路に戻るまで下りず、位置更新は毎秒来る（`LocationService` に `distanceFilter` は無い）。
  「計算中か」だけで抑えると 1 回終わるそばから次を投げることになり、失敗すれば MapKit に
  絞られてまた失敗し、成功すれば数秒ごとにルートが入れ替わって音声とカードが暴れる。
  **1 回目は待たない**（`lastRerouteFinished` が nil）ので、わざと別の道へ入ったときの
  反応は鈍らない。効くのは 2 回目以降だけ。
- **リルート中も `CPNavigationSession` は張り替えず、`pauseTrip` / `resumeTrip` で繋ぐ**。
  作り直すと `CPTrip` から組み直しになり、到着予定の表示が一度途切れる。再開に使う
  `resumeTrip(updatedRouteInformation:)` は iOS 26.4 で非推奨になったが、後継
  （`CPRouteSegment` を経由地ごとに積むモデル）は目的地 1 つの現状では得るものが無く、
  デプロイメントターゲットが 26.0 のうちは `#available` 分岐が要って古い実装も消せない。
  26.0 が下限なら非推奨の警告も出ないので、当面は乗り換えない。
- **`CPMapTemplate.guidanceBackgroundColor` はあえて設定していない**。経路の線が青
  （`systemBlue`）なのに案内まわりの色が違って見えても、車と CarPlay の既定に任せた結果で
  正しい。**赤く見えたときは、それが案内カードなのか `pauseTrip(for: .rerouting)` の
  「再検索中」カードなのかを先に切り分けること。** 後者が警告色で出るのは妥当で、色を
  直す話ではない（2026-08-15 に一度これを取り違えて `guidanceBackgroundColor` を
  青に固定しかけ、戻した）。色を渡すと `pauseTrip` のカードも `turnCardColor` の
  フォールバック先としてそちらに従うので、**両方まとめて青くなる**点にも注意。
- **走行中はキーボードが塞がれる**。`CPSessionConfiguration.limitedUserInterfaces` に
  `.keyboard` が入っている間、`CarPlayDestinationBrowser` は検索ボタンを出さない。
  押しても何も起きない導線を運転中に見せないため。**検索が使えない前提で目的地に
  たどり着ける経路（お気に入り・履歴・周辺カテゴリ）を必ず残す。**
- **カテゴリ検索は案内中だけ探し方が変わる**。案内していなければ現在地のまわり
  （`SearchService.nearby`）、案内中は経路の先（`alongRoute`）。走行中に「近いが後ろにある店」
  を出しても選びようがないため。MapKit に経路沿い検索は無いので、経路上へ一定間隔で
  検索点を置いて束ねている。**検索点を増やさないこと**。MapKit のレート制限に近づくうえ、
  運転中に選べる件数を超える。
- **Dashboard とメーター内のシーンは来ないことがある**。CarPlay が必要と判断したとき、
  また対応した車のときだけ作られるので、接続されない前提で書く。とくにメーター内は
  窓が `CPInstrumentClusterController` の delegate 経由で**遅れて**渡ってくるので、
  シーン接続の時点ではまだ描けない。
- **Dashboard のショートカットは 2 つまで、かつ案内中は出せない**。案内カードの中身は
  `CPMapTemplate` + `CPNavigationSession` を使っていれば CarPlay が自前で描くため、
  Dashboard とメーター内が受け持つのは地図（と Dashboard のショートカット）だけ。
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
- **`CarPlayMapViewController` は 3 画面で共用**。`.compact`（Dashboard）と `.cluster`
  （メーター内）はカメラ高度を近づけ、目的地ピンを出さず、経路の線を細くする。
  狭い画面向けの差はこのクラスに集約する。`.cluster` だけは **進行方向を上に固定**し、
  全体表示にも切り替えない（ガイド p.55 の要件）。
- **地図の向き（`MapOrientation`）は CarPlay 専用の設定で、iPhone は追従しない**。
  センターディスプレイと Dashboard は同じ設定を見る（Dashboard は次の位置更新で揃う）。
  メーター内だけは要件で進行方向が上に固定されているので、設定に従わない。
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
- **2026-08-15 に足したぶんの実走確認**。ビルドは通っているが、実際に走らせて
  見た目や挙動を確かめたものは 1 つも無い。とくに次の 4 つは**実機かつ対応した車でないと
  確認しようがない**: 指でのドラッグ、メーター・HUD への案内メタデータ、メーター内の地図、
  リルート中の「再検索中」カード。経由地とルート沿い検索はシミュレータでも確かめられる。
- **タッチジェスチャの手触り**（2026-08-16 追加ぶん）。マルチタッチ対応の車が要るので
  Xcode のシミュレータでは確かめようがない（マウス 1 本ではピンチも 2 本指も作れない）。
  値の意味は CarPlay ホストの逆アセンブルで裏を取ったが、**係数と符号は推測のまま**。
  実車で最初に見るのは次の 3 つ: 回転の向き（逆なら
  `CarPlayMapViewController.rotate(byRadians:)` の符号）、傾きの重さ
  （`pitchDegreesPerPoint`）、ピンチの追従性（`scale` が累積でなかった場合、倍率が
  ほぼ 1 のままになって「効かない」形で失敗する）。
  切り分けには `CarPlayGestureLog` を見る。**「地図が動かない」は、ジェスチャが届いて
  いない場合と、届いたうえで効き方がおかしい場合の両方で同じ見え方になる**ので、
  まず行が出るかどうかを確かめる。行が出ないなら車の側（1 本指のパンはタッチ精度で
  認識器が付かない車がある）で、こちらに直すところは無い。

  ```bash
  xcrun simctl spawn booted log stream --style compact --level debug \
    --predicate 'subsystem == "jp.hibiki.michinavi" AND category == "gesture"'
  ```

  実機は `--device` を付けるか Console.app。`.debug` なので Xcode を繋いでいない
  ときは保存されない（走行中に置いたままでよい）。
- **安全領域を差し引いた中心合わせ**: `follow` は自車を**画面の**中心に置いており、
  安全領域の中心には置いていない（差し引いているのは全体表示の余白だけ）。
  3 画面とも同じで、テンプレートや計器の縁が重なるぶんだけ自車位置が寄る。
- **`CPLaneGuidance` は空のまま**。`resumeTrip` が必須で要求するので形だけ渡している。
  MapKit がレーン情報を返さないので、外部依存を足さない限り埋められない。
