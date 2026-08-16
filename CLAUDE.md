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
| `Core/` | 位置・検索・経路計算・進捗計算・状態管理・目的地の保存・音声案内・音声入力 | UI 非依存。CarPlay も SwiftUI も import しない |
| `CarPlay/` | `CPxxx` テンプレート ↔ `NavigationController` の変換。センターディスプレイ・Dashboard・メーター内の 3 画面と、車そのものへの受け渡し | 案内ロジックを持たない |
| `Phone/` | SwiftUI 画面 | 同上 |

共有シングルトンは 14 個: `NavigationController.shared` / `LocationService.shared` /
`SearchService.shared` / `DestinationStore.shared` / `VoiceGuidance.shared` /
`SpeechInput.shared` / `DrivingSideLocator.shared` / `RoutePreferences.shared` /
`NetworkMonitor.shared` / `RestReminder.shared` / `RangeAdvisor.shared` /
`RouteWeather.shared` / `ParkingAdvisor.shared` / `TrafficAdvisor.shared`。
特に `LocationService` を共有することで **GPS は常に 1 本しか動かない**。

後ろ 5 つ（`RestReminder` / `RangeAdvisor` / `RouteWeather` / `ParkingAdvisor` /
`TrafficAdvisor`）は**助言を出すだけの層**で、
`NavigationController` を購読して `PassthroughSubject` で知らせるところまでしか持たない。
出すかどうか・どう見せるかは各 UI が決める。案内そのものには一切触らないので、
足しても状態遷移は変わらない。`AppDelegate` から `start()` を呼ぶ（`VoiceGuidance` と同じ理由で、
シーンの寿命ではなくアプリの寿命に合わせる必要がある）。

### `GuidanceEngine`（経路上の進捗計算）

ルート 1 本につき 1 インスタンス。位置更新のたびに `RouteProgress` を作る。

- 距離計算は `MKMapPoint`（メルカトル平面）上で行い、最後にメートル換算する。
- 現在地は経路への最近傍投影で吸着させる。探索は **前回区間の周辺（`-5 ... +30`）を優先**し、
  そこで見つからなければ全体を探し直す。この優先探索がループ路・折り返しで経路の別の場所へ
  飛びつくのを防いでいるので、単純な全体探索に置き換えないこと。
- **測位が途切れているあいだは推測で進める**（`extrapolate(elapsed:)`）。トンネルの中では
  GPS が来ないので、位置更新のたびに動く作りのままだと入った瞬間の案内で止まり、
  出口の分岐に気づけない。最後の速度で経路上を等速に進める。
  **逸脱と到着はここでは判定しない。** どちらも「実際にどこにいるか」の話で、推測で
  言い切ってよいものではない。推測でリルートすれば道なりに走っているのに経路が入れ替わり、
  推測で到着すれば案内がトンネルの中で終わる。動かすのは表示と、次の指示を出す時刻だけ。
  回しているのは `NavigationController` の 1 秒ごとの時計で、**案内が終わったら必ず止める**
  （止めないと `guidance` を掴んだまま回り続ける）。
- 逸脱判定 = 中心線から 50m 超が **3 回連続**（GPS の跳ねでの誤リルート防止）。到着判定 = 残り 30m。
  ただし **`horizontalAccuracy` がしきい値より悪い測位は数えない**。誤差 100m の位置で
  「50m 以上離れている」とは言えず、ビルの谷間やトンネル前後でリルートが連発する。
  戻り（`offRouteStreak = 0`）は精度に関係なく効かせる。安全側に倒すため。
- **経路に一度も乗っていないうちは逸脱を数えない**（`hasJoinedRoute`）。**MapKit は経路の
  始点を最寄りの車道へ寄せる**ので、駐車場・駅・施設の中から案内を始めると動く前から
  中心線の外に居る（実測: Apple Park 中央から 312m、東京駅から 228m、代々木公園から 426m。
  しきい値の 50m どころではない）。ここを数えると**止まったまま引き直しが走り、しかも
  引き直しても始点は同じ車道へ寄るので何も変わらず**、「再検索中」のカードと
  「ルートを再検索しました」の読み上げが数秒おきに繰り返される（2026-08-16 まで
  そうなっていた）。ただし「乗るまで数えない」だけでは、駐車場から経路とは別の道へ
  出たときに**最後まで一度も引き直せなくなる**ので、出発地から 100m 離れたら
  乗っていなくても数え始める（`departureThreshold`）。
  なお現在地から経路の始点までを破線でつなぐ表示は入れていない。Apple・Google の
  地図はどちらもそれを出して「離れているのは承知のうえ」と示している。
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
- 経路が入れ替わったことは `phase` の `NavRoute.signature` が変わったことで判定する。
  専用のイベントは足していない。
- **最初のひと言は「なぜ入れ替わったか」で変わる**（`RouteChangeReason`）。開始・引き直し・
  立ち寄り先の追加・利用者が選んだ切り替えの 4 つ。**利用者が押して切り替えたのに
  「ルートを再検索しました」と言うと、押したことが効いたのか分からない。**
  - 理由は `NavigationController.lastRouteChange` に置く。**`Phase` には入れない**
    （あちらは「いまどの段階か」で、`Phase ==` に理由が混ざると同じ経路の出し直しが
    別物になる）。
  - **`phase` を動かす前に代入すること。** `@Published` は `willSet` で流れるので、
    購読側が `.navigating` を受け取った時点でもう新しい値でなければならない。
- **オーディオセッションは鳴らす瞬間だけ有効にする**。カテゴリ設定
  （`.playback` / `.voicePrompt` / `[.interruptSpokenAudioAndMixWithOthers, .duckOthers]`）は
  1 度きり、読み上げごとに切り替えるのは有効・無効だけ。終わったら
  `notifyOthersOnDeactivation` 付きで即座に手放す。**有効なままにすると音楽がダックされ続け、
  ポッドキャストは一時停止したままになる。**
- `session.promptStyle` はセッションを有効化する**前**に見る。`none`（通話中・Siri 中）なら
  何もせず返るので、「鳴らす音が無いのにセッションを有効化しない」というガイドラインの
  要求も同時に満たす。`short` のときは音声ファイルを同梱せずに済ませるため、16bit PCM の
  WAV をその場で組み立ててトーンを鳴らす。

### 音声入力（`SpeechInput` / `DestinationIntent`）

**走行中はキーボードが塞がれる**ので、これが「新しい行き先をその場で決める」唯一の道。
お気に入り・履歴・周辺カテゴリは、あらかじめ知っている場所にしか届かない。
2 段に分けてある: 音を文字にする（`SpeechInput`）と、文を検索語にする（`DestinationIntent`）。

- **認可はマイクだけ**。旧 `SFSpeechRecognizer` は `NSSpeechRecognitionUsageDescription` と
  `requestAuthorization` を要求するが、**iOS 26 の `SpeechAnalyzer` には認可 API が無い**
  （Speech のバイナリを見ても認可のシンボルは `SFSpeechRecognizer` にしか無い）。
  要らない許可を運転中に求めない。
- **認識モデルは端末に入っていないことがある**。初回は `AssetInventory` 経由で取得が要る
  （日本語は対応済み。`SpeechTranscriber.supportedLocales` に `ja_JP` がある）。
  **`reserve(locale:)` を先に呼ぶこと。** 予約は寿命確保ではなく購読そのもので、
  予約せずに取得を頼むと
  `Cannot check the download status, ... is not subscribed to transcription.ja`
  で弾かれる。予約した瞬間に状態が `supported` から `installed` へ変わることもある
  （実体はあって、こちらが繋がっていなかっただけ）。予約は 5 ロケールまで。
- **読み上げを止めるのはマイクを取る直前**。モデルの取得はその手前で終わらせる。
  取得ごと `suspend()` の内側に入れると、初回だけ案内音声が長々と途切れる。
- **マイクの形式と認識モデルの形式は違う**ので `AVAudioConverter` を挟む。変換器は
  音声スレッドの中でしか触らない。
- **`VoiceGuidance` を止めてから聞く**。自分の声が回り込むうえ、オーディオセッションの
  カテゴリが `.playback` から `.playAndRecord` へ差し替わる。`suspend()` が
  `isSessionConfigured` を倒すので、次の読み上げでカテゴリが入れ直される。
  **止める位置に意味がある**: 予告は `handle(progress:)` で、スケジューラに渡す**前**に
  止める。`prompt(for:on:)` は返した時点でそのしきい値を読み上げ済みとして記録するので、
  受け取ってから捨てるとその予告は二度と出てこない。いっぽう到着・経由地通過は
  `PassthroughSubject` の 1 回きりの出来事なので、捨てずに抱えて `resume()` で読む。
- **話し終わりは自分で決める**。1.4 秒黙ったら終わり、上限 15 秒。CarPlay の音声画面には
  閉じるボタンを置けない（`CPBarButtonProviding` 準拠も `actionButtons` も iOS 26.4 以降）ので、
  自動で切り上げる以外に終わる道が無い。
- **お気に入りと履歴の地名を認識のヒントに渡す**（`AnalysisContext.contextualStrings`）。
  固有名詞は一般の言語モデルが落としやすく、地名は落とされるといちばん困る。
- **言語モデルが使えなくても止めない**。`DestinationIntent.parse` は Foundation Models で
  「東京駅に行きたい」から検索語と扱い（目的地／立ち寄り先）を取り出すが、Apple Intelligence は
  対応機種かつ利用者が有効にしている場合しか動かない。使えないときは**話した文をそのまま
  検索語にする**（`fallback`）。効きは落ちるが、口で言えること自体は保たれる。
- **候補を並べない**。読み上げた語にいちばん近い 1 件を取って、そのままルートの提示へ渡す。
  提示画面が確認を兼ねる。運転中にリストから選ばせない。
- **iPhone 側には音声入力を出していない**。あちらはキーボードが使えるので、この機能が
  埋めている穴が無い。`SpeechInput` は `Core/` にあるので、必要になれば足せる。
- **声で受けるのは目的地だけではない**（`VoiceCommand`）。案内終了・読み直し・全体表示も
  同じ経路で拾う。走行中に押せるボタンの数は物理的に限られるので、入口を作った以上は
  声の側を厚くするほうが安い。ただし**どれもボタンでもできることに揃えてある**。
  声でしかできない操作を作ると、認識が外れたときに手段が無くなる。
- **fallback は決まった言い回しだけを拾い、当てはまらなければ行き先として扱う**。
  取りこぼしても検索に落ちるだけなので、無理に拾って誤爆させるより漏らすほうがよい
  （「終わり」だけで案内を切ると同乗者との会話でも切れる）。**Apple Intelligence が
  無い環境ではこれが唯一走る経路**なので、判定を変えるときは誤爆の側を先に確かめること。

### 助言を出す層（`RestReminder` / `RangeAdvisor` / `RouteWeather` / `ParkingAdvisor` / `TrafficAdvisor`）

どれも「案内は変えず、知らせるだけ」。`NavigationController` を購読して
`PassthroughSubject` を流し、出すかどうかは各 UI が決める。

- **連続運転は案内している時間だけを数える**。位置や速度から「走っているか」を判定する手も
  あるが、渋滞と停車が区別できず、案内を切って寄り道した時間も運転として数えてしまう。
  案内の開始と終了は利用者がはっきり示した区切りなので、そちらに乗る。案内が途切れて
  15 分以上経っていたら休んだものとして数え直す。**保存していない**ので、アプリを終了させると
  数えはじめに戻る。外したときに「休んだのに催促される」ほうが害が大きいので安全側に倒した。
- **航続距離の助言は車から来る要求と対**。ルート共有では EV の側が「充電に寄れ」と経由地を
  送ってくるが、それは対応した車でしか起きない。届く範囲は目一杯まで使わず手前 8 割で探し、
  **いちばん近いものではなく届く範囲でいちばん先のもの**を選ぶ（手前で入れると次の補給が早く来る）。
- **天気は雨・雪・凍結の 3 つだけ**。気温や湿度を並べても運転は変わらないので、「知っていたら
  支度や速度が変わるもの」に絞る。凍結は 0℃ ちょうどではなく 3℃ から言う（気温は路面温度より
  高く出るし、橋の上は先に凍る）。**問い合わせ点を増やさないこと**。WeatherKit には
  呼び出し数の上限があり、経路 1 本ごとにこの数だけ叩く。
- **駐車場は目的地の手前 1km で 1 件だけ出す**。着いてから探すと、探しはじめる時点でもう
  目的地の前にいるので、周りを回りながら探すことになる。選ぶのは**目的地にいちばん近い 1 件**で、
  補給先とちょうど逆（あちらは走り続けるための寄り道、こちらは降りて歩いて戻る場所）。
  範囲を 500m に切っているのも同じ理由で、広げると「空いているが 1km 歩く」が上位に来る。
  **自宅と職場では出さない**（いつも停める場所があるので邪魔にしかならない）。
  受けたときは経由地として挟まず**行き先そのものを差し替える**。挟むと、停めたあとも
  案内が元の目的地へ向かって続く。
  - **「近所への案内では出さない」を経路の全長で判定しないこと**（`Trip.hasBeenFar`）。
    引き直しで返る経路は残りぶんだけの長さなので、目的地の近くで外れると短い案内と
    見分けが付かず、いちばん出したい場面で黙る。しきい値より遠い状態を一度でも見たか、で見る。
  - 数えるのは `NavRoute.id` ではなく**目的地**。`id` は引き直すたびに変わるので、
    そちらで数えると外れるたびに提案が出る。
  - **`.parking` には駐輪場・ロータリー・乗降場が混ざる**ので、名前で落とす（`ParkingName`）。
    `MKPointOfInterestCategory` にそれらの区分は無く、全部 `.parking` として返ってくる。
    数のうえでは 5% でしかないが、**駅前ではそれが最寄りに来る**（駐輪場もロータリーも
    駅の真ん前にあるので、「いちばん近い 1 件」という作りと最悪の相性になる）。
    2026-08-16 に 14 地点・430 件で実測したところ、**6 地点で停められない場所が 1 位**
    だった（東京・みなとみらい・大阪・名古屋・京都・那覇）。**落としすぎる側に倒す**こと。
    本物を 1 件落としても次に近いものへ移るだけで、実測では最大 30m 遠くなっただけ。
    逆に駐輪場を出すと、そこまで案内を引き直したうえで停められない。
- **迂回の提案に問い合わせを足さない**。`refreshTravelTimeIfNeeded` が 3 分おきに
  「いま引き直すとどうなるか」を計算しているので、材料はもう揃っている。捨てていた経路を
  `travelTimeMeasured` で流して `TrafficAdvisor` に判断させる。**用途ごとに投げ直さないこと**
  （経由地があると区間の数だけ `MKDirections` を投げるので、問い合わせが倍になる）。
  - **同じ道かどうかは `signature` では見分けられない。** あちらは距離まで見るので、
    途中から引き直した経路とは必ず食い違う（走行中の区間だけが短くなる）。指示の並びで
    比べる（`NavRoute.instructions(from:)`）。**走っている区間の次から**比べること。
  - **しきい値を下げないこと**（5 分）。比べているのは「いま測った時間」と「距離按分で
    見込んでいた時間」で、後者には誤差がある。誤差と渋滞を取り違えない幅が要る。
  - 続けて出さない間隔（10 分）と、**断られた道を繰り返さない**記録の両方が要る。
    渋滞は数分では消えないので、3 分ごとの測り直しに合わせて毎回出すと催促になる。
  - **押すまでに走った距離は織り込めない。** 渡す経路は測った時点の位置から引いてある。
    同じ道の上にいるかぎり `GuidanceEngine` が吸着するので実害は無く、外れていれば
    逸脱判定が引き直す。
  - 切り替えたときの読み上げは「ルートを再検索しました」のまま。`VoiceGuidance` は
    経路が変わったことしか見ていないので、利用者が選んだ切り替えと逸脱による引き直しを
    区別していない。**直すなら意図を渡す口が要る**ので、そこは手を付けていない。
- **催促は `CPNavigationAlert` で出す**（`CPAlertTemplate` ではない）。あちらは画面を覆って
  操作を求めるので、催促のために運転者の手を止めさせることになる。

### ルートの引き方（`RoutePreferences`）

有料道路・高速の回避、曲がりくねった道の優先、航続距離と補給先。iPhone と CarPlay で同じものを見る。

- **見た目の設定ではなく経路計算の入力**なので `Core/` にある。`MapOrientation` を
  CarPlay 側に置いているのと分かれるのはここ。あちらは同じ経路の見せ方が変わるだけだが、
  こちらは返ってくる経路そのものが変わる。
- **変えても走っている案内は引き直さない**。次に計算するときから効く。走行中に経路が
  丸ごと入れ替わると、音声もカードも追随できない。
- **回避は要望であって指示ではない**。避けようがない区間（離島の有料橋など）では MapKit が
  そのまま有料道路を含む経路を返す。返ってきた経路を弾いてはいけない。
- **曲がりくねった道の優先は候補の並べ替えでしかない**（`RouteCharacter.sortedByCurvature`）。
  MapKit に「曲がりくねった道を引いて」と頼む手段は無いので、返ってきた 2〜3 本から
  選び直すだけ。平野では何も変わらない。
- **航続距離は残量ではない**。車の残量を読む手段がこちらに無い（CarPlay は充電状態を
  渡してこない）ので、利用者が一度入れた数字で判断する。

### 候補ルートの見分け（`RouteCharacter` / `ManeuverDirection`）

MapKit の候補は「12分・8.2km」と「14分・7.1km」のように、数字だけでは何が違うのか
読み取れない。運転中に選ばせるなら違いを一言にしないと選べないので、比較して分かる
特徴を付ける。

- **出す語は必ず候補どうしの比較から決める**。「右折が少ない」は他より少ないから
  意味があるので、単独のルートに付けても情報にならない。候補が 1 本のときも、
  同点のときも出さない。
- **カーブの多さは距離で割る**。割らずに比べると、遠回りのルートが必ず「カーブが多い」になる。
- **指示文からの向きの推測は `ManeuverDirection`（`Core/`）にある**。`ManeuverKind`
  （`CarPlay/`）は向き → アイコンと `CPManeuverType` の読み替えだけ。右折の数を数えるのは
  案内の見た目とは無関係な計算で、そのために CarPlay を `Core/` へ持ち込みたくない。
  **文言マッチの並び順（長い語を先に）は `ManeuverDirection` の 1 か所にしかない。**

### 目的地の保存（`DestinationStore`）

履歴・お気に入り・自宅と職場・**車をとめた場所**を UserDefaults に置くだけの薄い層。
履歴は案内開始時に、駐車位置は到着時に自動で積む。

**自宅・職場（`Pinned`）をお気に入りで代用しない**。お気に入りは件数が増えるほど 1 件
あたりが遠くなるが、この 2 つは実際のカーナビでいちばん押される行き先で、しかも数が
増えない。走行中はキーボードが塞がれるので、「検索を使わずに目的地へ届く経路を残す」
という要件の中でいちばん短い経路になる。CarPlay では目的地リストのいちばん上に出す。

**設定できるのは iPhone 側だけ**。どこを自宅にするかを決めるには検索が要り、走行中は
その検索が使えない。CarPlay に空の枠を出すと「押しても何も起きない導線」になるので、
あちらは設定済みのものだけを出す。逆に iPhone 側は**設定していなくても枠を出す**
（空の枠がそのまま設定の入口になり、「どこで設定するのか」を探さずに済む）。

**いまの時間帯によく行く場所を引き上げる**（`frequentDestinations(at:)`）。案内を始めた
時刻を場所ごとに 10 件まで覚えて、平日／休日が一致し、時刻が前後 2 時間以内の訪問が
**2 回以上**あるものを「この時間の行き先」として履歴の上に出す。ピンの 2 枠に入らないが
決まった時間に行く場所（送り迎え・買い物）が、走行中でも届く高さに来る。

- **お気に入りは並べ替えない。** あちらは利用者が自分で並べたもので、位置が動くと
  「どこにあるか」を覚え直すことになる。履歴はもともと最近順で動き続けるので無理がない。
- **順序を入れ替えず、別の節にする。** なぜ並びが変わったのかが見て分かる。引き上げた
  ぶんは履歴から抜く（同じ行が 2 か所に出ると、どちらでも同じだと分かるまで一瞬迷う）。
- **1 回では引き上げない。** たまたま寄った場所が毎日その時刻に先頭へ出てくると、
  履歴そのものが信用できなくなる。
- **時刻の比較は分まで見る**（`minuteDistance`）。時の成分だけで比べると 23:30 と 21:00 が
  「23 と 21 で 2 時間差」になり、窓が実質 3 時間近くまで広がる。日付は見ない
  （「毎日この時刻」を拾いたいので）。時計は 24 時間で一周するので 23:30 と 0:30 は 1 時間差。
- 曜日は平日と休日だけで見る。曜日ごとに分けると 1 曜日あたりの回数が減って、
  2 回に届くまで何週間もかかる。
- **記録は履歴に載っているものだけ**残す。`clearRecents` で一緒に消える。独立して
  増えると、消したはずの行き先が並べ替えにだけ効き続ける。

駐車位置は**目的地の座標ではなく実際に着いた座標**を使う。施設が目的地なら、車は入口では
なく駐車場にある。「到着＝降りる」と決め打ちしていて、降りずに走り出せば次の案内で
上書きされるので、外れても害が残らない。**そこへの案内はこのアプリでやらない**
（歩いて戻る場面なので徒歩の経路を持つマップへ渡す）。CarPlay にも出していない。
車に戻ってから見る画面ではないため。

`Place` の同一性がこの土台になっているので、**`Place.id` を init で振り直さないこと**。
`MKMapItem` の識別子、無ければ名前と座標（小数 5 桁 ≒ 1m に丸め）から組み立てる。
UUID に戻すと同じ場所が毎回別物になり、重複排除もお気に入り判定も壊れる。丸めるのは
測位のわずかな揺れで別物にしないため。

### MapKit の制約と、その回避策

`RouteProviding` プロトコルの裏に経路計算を隔離してあるのは、以下を将来消せるようにするため。

1. **step ごとの所要時間を返さない** → 経路全体の平均速度で距離按分している
   （`GuidanceEngine.update` と `CarPlayCoordinator.estimatedTime` の 2 か所）。
   **按分の基準は出発時の見積もりのままにしない。** そのままだと渋滞に入っても
   到着予定が動かず、運転者がいちばん見る数字がいちばん当たらなくなる。
   `NavigationController.refreshTravelTimeIfNeeded` が 3 分おきに
   `currentBestRoute(from:via:to:)`（`arrivalDate` を渡さない＝いまの交通量）で測り直し、
   `GuidanceEngine.applyMeasuredTimeRemaining` が基準点を置き直す。以降はそこからの
   距離比で減る。**動かすのは数字だけで、経路は差し替えない**（走行中に経路が
   入れ替わると音声も案内カードも追随できない。`RoutePreferences` を変えても
   引き直さないのと同じ判断）。**間隔を詰めないこと**。経由地があると区間の数だけ
   `MKDirections` を投げるので、引き直しと同じ重さの問い合わせが走り続ける。
2. **maneuver type（曲がる向きの列挙）を返さない** → `ManeuverKind` が
   「右折します」等の**指示文の文言マッチ**で推測する（表そのものは `ManeuverDirection`）。
   日英どちらも見る。**ここで決めた型は画面のアイコンだけでなく、`CPManeuver.maneuverType`
   として車のメーター・HUD にも送られる**（後述）ので、外すと両方が同時にずれる。
   表を触るときの規則は 2 つ。
   - **長い語を短い語より先に置く。** 「斜め右」は「右」より先、「ロータリー」は「出口」より
     先。逆にすると「2 番目の出口で出る」が高速の出口になる。**車線の指示（「右車線」）は
     曲がる指示より先**で、これを逆にすると分岐の手前でハンドルを切らせることになる。
     ただし高速の入口・出口よりは後ろ（「池尻ランプで右車線を走行 首都高速入口へ」は入口が主）。
   - **道路名に現れる語を入れない。** 「環状」を入れていたときは「環状1号を右方向」が
     ロータリー扱いになり、`.enterRoundabout` が車の HUD へ送られていた（2026-08-16 に
     横浜で実測）。日本の道路名には「環状八号線」「内環状」のように普通に入る。
     **取りこぼすほうがまだ良い**ので「環状交差点」に絞ってある。
3. **指示文が長い** → `instructionVariants` に**短縮形を足して長い順に並べる**
   （`ManeuverDirection.shortInstruction`）。CarPlay は先頭から見て**入るものを選ぶ**ので、
   1 件しか渡さないと省略される。Dashboard と通知バナーはさらに狭いので、
   `dashboardInstructionVariants` / `notificationInstructionVariants` では短いほうを先にする。
   地名と道路名は落ちるが**曲がる向きだけは必ず残る**。
   - **`rules` と `shortInstruction` は役割が逆**。前者は MapKit から来る文を読む表なので
     訳さず日英を並べる。後者は利用者に見せる文なので `String(localized:)` で訳す。
   - 2026-08-16 に実路 5 本・64 件で確かめて、短縮できないのは徒歩の step だけになった
     （それも `drivingSteps` が落とすので、実際には CPManeuver まで来ない）。
     「駐車を準備」を到着に寄せているのは、**徒歩ぶんを落としたいまこれが最後の指示に
     なるから**。
4. **道路番号が指示文の中に埋もれている** → `RoadNumber` が拾い、`RoadShieldImage` が
   標識に描いて `attributedInstructionVariants` へ差し込む（「国道156号を右方向」→
   「[156] を右方向」）。日本の運転者は道路を**番号で追う**ので、文字列のままより一瞥で
   拾える。実路 60 件のうち当たるのは 2 割ほどで、残りは番号を持たない道
   （環八通り・百万石通り）。それらは実際の標識にも番号が無いので、出ないのが正しい。
   - **添付できるのはテキストアタッチメントだけ**で、ほかの属性は CarPlay が剥がす。
     画像の上限は 64×25pt。
   - **見つかったときだけ渡す。** `attributedInstructionVariants` は `instructionVariants`
     より優先されるので、常に渡すと短縮形の落とし先が効かなくなる。短縮形も同じ配列に
     入れて並びを保つ。
   - **この表だけは訳さない理由が違う。** `ManeuverDirection` や `VoiceCommand` は
     「端末の言語で入力が変わる」から日英を並べるが、こちらは**標識そのものが国ごとに
     違う**。日本の国道は青い逆三角（おにぎり）で、同じ形を US Route に付けたら誤りになる。
     日本語の指示文だけを拾い、英語では標識を出さずに元の文を見せる。
   - **白い縁を付ける。** 標識の紺は案内カードの `systemBlue` と近く、縁が無いと形が溶ける
     （実測）。実際の案内標識も白で縁取られている。
   - **国道だけ寸法が別。** 逆三角は下へ向かって細くなるので、ほかと同じ幅にすると 3 桁の
     数字が斜めの縁に当たる。幅を広げ、字を上寄せにし、3 桁は字を落とす。
     **これも絵なので、決めるのは画面で**（2026-08-16 に PNG に描いて 2 回直した）。
5. **交差点のデータが無い**（形も、通らない側の道も、車線も返さない）→ `JunctionImage` が
   **経路そのものの形**を曲がる地点の前後 100m だけ拡大して描き、`CPManeuver.junctionImage`
   に渡す。矢印アイコンでは「右折」としか分からないところが、30 度の分岐なのか直角なのか、
   曲がった直後にまた曲がるのかまで出る。**でっち上げた交差点ではなく実際にたどる線**なので、
   データが無いことを理由に外すことがない。交わる側の道や信号は**描かない**
   （それらしく描くと「そこに道がある」と誤解させる）。
   - **上限は 140×100pt**（ヘッダに明記）。超えると縮小されるので最初からこの寸法で描く。
     `dashboardJunctionImage` は渡さない。指定しなければ CarPlay がこれを使う。
   - **進行方向が上を向くように回す。** 北上げのままだと、同じ右折でも走っている向きで
     絵が変わって見比べられない。
   - **曲がりが 20 度未満なら描かない。** ほぼまっすぐな線の図は矢印アイコン以上のことを
     何も言わないので、カードの場所だけ取る。実路 28 か所のうち 13 か所がここで落ちた
     （ほとんどが車線を寄せるだけの指示）。
   - **図の中で明暗を完結させる。** 案内カードは `guidanceBackgroundColor` で `systemBlue` に
     しているので、経路と同じ青で線を引くと見えない。Dashboard のカードは CarPlay が
     昼夜で塗り分けるうえ、こちらから色を渡す口が無い。半透明の黒を敷いて白い線を引く。
   - **縮尺には下限が要る**（`minimumExtent`）。前後がまっすぐ並ぶと横幅がほぼ 0 になり、
     そこへ画面いっぱいまで拡大しようとして発散する。
   - **絵が合っているかはバイナリでもログでも分からない。** 回転の符号と y の向きを
     取り違えても、それらしい絵が出る。2026-08-16 は実経路 28 か所を macOS 側で
     PNG に描き出して目で確かめた（`UIGraphicsImageRenderer` は原点が左上・y が下向き、
     macOS の `CGContext` は左下なので、写して確かめるときは反転が要る）。
6. **SA/PA のカテゴリが無い**（`MKPointOfInterestCategory` に無い）→ 休憩は
   トイレ・カフェ・ガソリンスタンドを束ねて代用している。
7. **経由地を扱えない** → `MapKitRouteProvider` が区間ごとに `MKDirections` を投げ、
   結果を 1 本の `NavRoute` に繋いでいる。**経由地があるときは候補ルートを求めない**。
   区間の数だけ組み合わせが増えて、運転中に選べる形にならないため。
8. **`.automobile` で頼んでも、末尾に徒歩の step が付いてくる** → `NavRoute` の組み立てで
   落とす（`MKRoute.drivingSteps`）。目的地が施設のとき、MapKit は「駐車を準備」で車を
   降ろし、そこから入口まで歩かせる経路を返す。**`route.transportType` は `.automobile` の
   ままなので、`step.transportType` を見ないと区別できない。** 2026-08-16 の実測では
   6 目的地中 4 つで発生し、62〜215m（全体の 1〜7%）。落とさないと次の 3 つが同時に壊れる。
   - **案内が終わらない。** 到着判定は残り 30m なので、車が徒歩ぶん手前で止まると成立
     しない。`DestinationStore.rememberParking` も走らず、`RestReminder` は運転時間を
     数え続ける。
   - **「階段を上がる」「エスカレータで下りる」を運転中に読み上げる**（`VoiceGuidance`）。
     `ManeuverKind` はそれを `CPManeuver` にして車のメーター・HUD へも送る。
   - **距離と所要時間に歩くぶんが混ざる。** `MKRoute.distance` は step の合計と一致する
     （実測: 7486m ＝ 車 7270m + 徒歩 215m）ので、残した step から数え直す。
     `expectedTravelTime` にも入っていて、**引くには歩く速さを決めるしかない**
     （step ごとの所要時間が返らないため）。実測から 1.2 m/s（金沢 62m/55秒 → 1.13、
     東京タワー 75m/59秒 → 1.27）。効くのは 52〜179 秒。
   - 裏返しとして、**案内は目的地ピンの 65〜141m 手前で終わる**。線もそこで止める
     （`MKRoute.polyline` をそのまま使うと線だけが建物の入口まで伸びる）。
     Apple のマップも車の案内は駐車地点で終えて、そこから先は徒歩に切り替える。

Mapbox / Valhalla などに差し替えるときは `RouteProviding` の実装を足すだけで、
CarPlay 層は触らずに済む設計。

## 踏み抜きやすい前提

- **Swift 並行性**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。既定で全部が MainActor。
  そのため `CLLocationManagerDelegate` / `MKLocalSearchCompleterDelegate` は
  `nonisolated` + `MainActor.assumeIsolated {}` で受けている。この形を崩さない。
  - **初期化子を関数として `map` へ渡さない**。`routes.map(Profile.init(route:))` と書くと
    `(NavRoute) -> Profile` という**隔離情報の落ちた関数値**になり、nonisolated な
    `map` へ渡すことになる。`routes.map { Profile(route: $0) }` ならクロージャが
    MainActor の文脈で作られて隔離を引き継ぐ。中身は同じで、書き方だけの違い。
    `SWIFT_VERSION = 5.0` のうちは警告だが、Swift 6 モードではエラー。
  - **AVFoundation の Sendable 警告を `@preconcurrency import` で黙らせない**。
    ファイル全体で検査が外れ、本当に危ないものまで見えなくなる。効く範囲を
    その 1 か所に絞れる `nonisolated(unsafe)` な局所定数で受けて、**なぜ安全かを
    その場に書く**（`SpeechInput.convert` の `source` がその例。SDK が `@Sendable` と
    宣言している変換ブロックは、実際には `convert` の中から同期に呼ばれて戻る前に
    用済みになる）。なお `AVAudioConverter` は iOS 26 の SDK で Sendable になったので、
    そちらに `nonisolated(unsafe)` を付けると「不要」と警告される。
    **Sendable は「スレッド安全」ではなく「境界を越えて渡してよい」の意味**なので、
    音声スレッドに閉じ込める約束そのものは変わらず要る。
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
- **`CPManeuver.trafficSide` は現在地の国から決めている**（`DrivingSideLocator`）。
  効くのはロータリーの回り方で、**既定は右側通行**。渡さないと日本のロータリーが逆に描かれる。
  MapKit は経路にも地点にも走行国を付けてこない（履歴から戻した `MKMapItem` は座標だけ）ので、
  iOS 26 の `MKReverseGeocodingRequest` で現在地から引き、
  `MKAddressRepresentations.region` を見る。**走行側を教えてくれる API は無い**ので、
  左側通行の国は表で持つしかない。判定は「表に載っていれば左、それ以外は右」に倒してある。
  - `regionCode` の Swift 名は **`region`**（`Locale.Region?`）。`NS_REFINED_FOR_SWIFT` なので
    ヘッダの名前では引けない。`__regionCode` なら文字列で取れる。
  - **逆ジオコーディングは連打しない**。国境をまたがない限り変わらないので、
    前回引いた地点から 100km 動いたときだけ引き直す。測位が来るまでは端末の地域で代用する
    （自分の国で運転するのが大半なので、既定の右側通行よりは当たる）。
  - **すでに作った `CPManeuver` には後から反映されない**。案内の途中で国が判明・変化しても、
    その経路のぶんは作り直さない。国境をまたぐ運転は稀で、引き直せば `resumeTrip` から
    作り直しになるため。
- **`MKMapView` は中心座標を `bounds` の中心ではなく安全領域の中心に置く**（`layoutMargins`
  が既定で安全領域を含むため）。CarPlay ではそれを作るのが上部バーと案内カードなので、
  案内中は縦にも横にもずれる。**`bounds` の中心で座標を読んで `setCenter` へ渡さないこと。**
  読んだ点と置かれる点が違うので、渡すたびにその差ぶん地図が飛ぶ。指を止めていても飛び、
  ドラッグは毎秒 60 回来るので積み上がる。基準は必ず
  `convert(centerCoordinate, toPointTo:)` で聞き直す（`CarPlayMapViewController.centerPoint`）。
  2026-08-16 までここを `bounds.midX/midY` にしていて、**iPhone の 14pt ぶんでも
  指を置いたまま 1 秒で 250m 走り、240pt のドラッグが 4.5 倍動いていた**
  （iOS 26.2 で実測。傾けているとさらに増える）。
  - 裏返すと **`setCamera(lookingAtCenter:)` と `setVisibleMapRect(edgePadding:)` は
    こちらが何もしなくても安全領域に収めてくれる**。`follow` の中心合わせは既に
    安全領域基準で正しく、**全体表示の `edgePadding` に `safeAreaInsets` を足しては
    いけない**（`overviewPadding`）。足すと二重になり、`left + right` が画面幅を
    超えたところで**当て込みが破綻する**。実測（幅 800pt・左 300pt・右 90pt の安全領域）:
    足すと余白の合計が 812pt になり、経路が **x 604…616 の 12pt に潰れて右へ寄る**。
    足さなければ 316…694 に収まる。**余白を増やすほど経路が大きくなる**という逆の
    効き方をするので、「全体表示なのに右で見切れる」から原因を辿りにくい。
    2026-08-16 まで足していた。
  - **当て込みは一度きりで、あとから追随しない。** `setVisibleMapRect` は中心と縮尺を
    決めるだけなので、**ルート提示の一覧が出て使える幅が変わっても経路はそのまま**
    （実測: 余白なしで当て込むと経路が x 16…784、そこへ左 300pt の一覧が出ても 16…784 の
    まま＝一覧の裏に入る）。`apply(phase:)` は当て込みのあとに `showTripPreviews` を
    呼ぶので必ずこの順序になる。テンプレートの出入りを知る手段は
    `viewSafeAreaInsetsDidChange` しかない（`CPMapTemplateDelegate` に提示の合図は無い）
    ので、そこで合わせ直している。**利用者が地図を動かしたら追随をやめる**こと
    （`abandonOverview`）。残すと、動かした先からテンプレートの出入りだけで引き戻される。
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
- **ドラッグは開始・終了も受ける**（`mapTemplateDidBeginPanGesture` /
  `didEndPanGestureWithVelocity`）。**追従を切るのは開始の側**で、最初のデルタを待たない。
  待つと、直前の位置更新で始まった `follow` のアニメーション（0.3 秒ほど）と頭が
  殴り合い、動きだしが引っかかってから飛ぶ。指を置いたまま動かさないあいだも地図が
  自車を追って逃げる。**終了で渡される速度から惰性を自分で作る**（`startGlide`）。
  指を離したあとも CarPlay は何も送ってこないので、押しっぱなしのパンと同じ形の穴。
  ただし**中断（着信・Siri）では終了が来ない**（ホスト側が `.cancelled` を素通りする）
  ので、惰性を始めそこねる経路がある。掴んだままの状態は残らないので実害は無い。
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
  ただし**定数の完全一致には賭けない**。値の意味は逆アセンブルからの推測で、実機が
  0.9999999 を送ってきたら判定が裏返る。裏返ったタップはピンチとして扱われ、基準
  （`zoomBaseDistance`）を持たないので**黙って何も起きない**。幅で見たうえで、
  **基準が無ければピンチの更新ではありえない**（ピンチは必ず開始から始まる）ことも根拠に足してある。
- **ピンチと回転は同時に認識される**。`CPSMapTemplateViewController` の
  `gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:` が YES を
  返すのはこの組み合わせだけ。つまり**縮尺を変えるだけのつもりのピンチでも回転が始まる**ので、
  回転の開始で追従を切ると、ズームでは避けたはずの「縮小しただけで自車を見失う」が起きる。
  追従を切るのは、はっきり回した（`minimumRotationToStopFollowing`）と分かってから。
  ピッチも同じ理屈で、実際に傾ける段になってから切る。
- **追従へ勝手に戻さない**。地図を触ったら追従が切れ、戻すのは現在地ボタンとパン UI の
  「完了」だけ、というのが狙いの手触り。`apply(phase:)` は**段階そのものが変わったときだけ**
  中心へ戻す（`lastPhaseKind`）。`phase` はリルートが成功するたびに
  `NavigationController.startNavigation(with:)` を通って `.navigating` のまま経路だけ
  入れ替わるので、見分けないと**先を眺めているあいだにリルートのたびに引き戻される**。
  なお `@Published` は `willSet` で流れるので、`apply(phase:)` の中で `navigation.phase` を
  読むとまだ 1 つ前の値。段階を見たいところでは `lastPhaseKind` を使う。
- **`recenter()` は指が触れている最中にも呼ばれる**（現在地ボタン・案内の開始と終了）。
  進行中の回転・傾けの基準を捨てないと、指を離すまで
  ジェスチャと `follow` が 1 秒ごとに殴り合う。ズームの基準は捨てない（追従したまま
  効かせる操作なので、捨てるとピンチの続きをタップと取り違える）。
  **捨てたあとの回転・傾けは指を離すまで無反応**になるので、そのままだとログには
  「入力は届いているのに動かない」＝係数を間違えたときと同じ行が並ぶ。`rotate` /
  `pitch` / `zoom` が `GestureOutcome` を返し、`recenter()` を呼ぶ側が
  `CarPlayGestureLog.camera(_:)` を残しているのはこれを切り分けるため。
- **ズームの基準に実カメラを読まない**。`baseCameraDistance` が実カメラから取るのは
  全体表示の直後だけ（`setVisibleMapRect` はカメラを引いて `cameraDistance` を更新しない）。
  **追従の有無で分けてはいけない。** パン UI に入ると追従が切れたうえで拡大・縮小ボタンだけが
  残るので、追従していないことがズームボタンにとっての通常の状態になる。そこで実カメラを
  読むと `animated: true` で飛んでいる最中の途中の値を掴み、連打するほど 1 回ぶんの
  効きが小さくなる（500 → 250 の途中で 420 を読み、125 ではなく 210 を狙う）。
  ログに出す距離も同じ理由で実カメラではなく保存値。読むと、効いているダブルタップが
  「動く前の値」を並べて無反応に見える。
- **回転とピッチは追従を切ってからでないと効かない**。`follow` が位置更新のたびに
  向きと傾きを `MapOrientation` から作り直すため。パンと同じく現在地ボタンで戻す。
  ズームは中心を動かさないので追従したまま効かせている（拡大・縮小ボタンと同じ扱い。
  ここで追従を切ると、縮小しただけで自車を見失う）。
- **パンボタンは外せない**（ガイド p.33）。タッチでドラッグできる車があっても、ノブしか無い
  車のために「パン UI へ入るボタン」を必ず 1 つ置くことが要件。**案内中も同じ**で、
  2026-08-16 まで案内中の 4 つ目を向きの切り替えに使っていて落ちていた（ノブしか無い車では
  案内中に地図を動かす手が無かった）。4 つが埋まっているので、**先頭の枠を追従の状態で
  分け合っている**（`followSlotButton`）。追従しているあいだはパンボタン、地図を動かして
  追従が外れたら現在地ボタン。押しても何も変わらない側を出さずに済み、この 1 枠が
  「いま追従しているか」の表示も兼ねる。**枠の位置は動かさない。**
- **パンボタンの callback は 3 つある**。`panWithDirection:` はヘッダのとおり
  **瞬間的に押したとき**だけで、押し続けると `panBeganWithDirection:` →（押しているあいだは
  無音）→ `panEndedWithDirection:` に変わる。**押しているあいだ CarPlay は何も送ってこない**
  ので、開始で自前の時計を回して終了で止める。`panWith:` だけ実装すると、**ノブしか無い車で
  押し続けたときに地図が 1px も動かない**。しかもログも出ないので「ジェスチャが届いていない」と
  まったく同じ見え方になる。ドラッグと違ってタッチ精度のゲートは無く、全部の車で必ず通る。
  終了が来ないことがある（押したままパン UI ごと閉じられる）ので、
  `mapTemplateDidDismissPanningInterface` と `stop()` でも止めている。
- **`mapButtons` は 4 つまで。パン UI に入ると先頭 2 つしか残らない**（超過ぶんは配列の
  末尾から CarPlay が勝手に隠す）。**並び順まかせにしないこと**。4 つ置いた状態でパン UI に
  入ると 2 つ落ちる。`mapTemplateDidShowPanningInterface` で拡大・縮小の 2 つに差し替え、
  `mapTemplateDidDismissPanningInterface` で元へ戻している。パン中に意味があるのは
  拡大・縮小だけで、現在地へ戻すのは「完了」が担う。
- **ナビゲーションバーのボタンは左右 2 つずつが上限**。マイクと読み直しをここへ置いて
  いるのは、`mapButtons` が 4 つで埋まっているうえ、パン UI に入ると 2 つ落ちるため。
  どちらも走行中に消えてはいけない導線なので、落ちる可能性のある側へ置かない。
  **案内中は左右とも埋まっている**（左＝マイク・全体表示、右＝読み直し・案内終了）ので、
  次に足すものがあれば何かを外すことになる。
- **CarPlay のリストにスイッチは無い**。入り／切りはチェックの有無で示し、押すたびに
  裏返してリストを作り直す（`CarPlayDestinationBrowser.avoidItem`）。走行中に何度も触る
  場所ではないので、作り直しの重さは問題にならない。
- **`CPVoiceControlTemplate` は、いまナビアプリだけが使える**。ガイド p.14 の対応表で、
  他のカテゴリには「iOS 27 以降」（driving task は 26.4）の注が付いている。
  使ううえでの約束が 3 つ: **提示してからでないと状態を切り替えられない**
  （先に `activateVoiceControlState` を呼んでも黙って無視される）、状態は 5 つまで、
  短い間に何度も切り替えると間引かれる。そして**音声サービスが動いているあいだは
  この画面を出しておく**こと（p.27）なので、聞き取りだけでなく検索が終わるまで畳まない。
- **音声画面とアラートを重ねない**。エラーを出すときは先に `dismissTemplate` してから。
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
- **停まっているあいだは引き直さない**（`NavigationController.canReroute(from:)`）。
  停まっている車に新しい経路を渡しても走り出す道は変わらないので得るものが無く、
  引き直しは必ず「ルートを再検索しました」の読み上げと「再検索中」のカードを連れてくる。
  **間隔だけでは足りない**。逸脱判定は経路に戻るまで下りないので、外れた場所に停めると
  5 秒ごとに引き直しが走り続け、しかも入力が同じなので MapKit は毎回まったく同じ経路を返す。
  中心線から 50m 前後（`offRouteThreshold` の境目）に停めるとさらに悪く、測位の揺れで
  `hasJoinedRoute` の成立と逸脱の成立を往復するため何度でも引き直しが成立する。
  一般のカーナビが停車中に引き直さないのはこのため。判定は 2 段で、`speed` が取れるなら
  それで見て（取れないときは負が返る）、取れない端末と停車中に速度だけ跳ねた測位のために
  前回引いた地点からの移動距離（`minimumRerouteDistance`）でも受ける。**1 回目は通す**。
  **停車で見送ったときは `isRerouting` を下ろす**。`isRerouting` は失敗しても下ろさない
  （カードが点滅するため）作りなので、再試行そのものを止めるここで下ろさないと、
  検索していないのに「再検索中」の赤いカードだけが残る。動き出せばまた立つ。
  計算が走っている最中は触らない（終わらせ方はそちらに任せる。失敗しても、次の
  位置更新でここへ来て下りる）。
- **圏外のあいだは引き直さない**（`NetworkMonitor`）。MapKit の経路計算はすべてネットワーク
  越しなので、切れているあいだは必ず失敗する。投げれば失敗が数えられて間隔が伸び、
  **電波が戻ってからも最大 40 秒待たされる**。山間部やトンネルはいちばん引き直してほしい
  場面なので、そこで待たせない（戻った瞬間に `rerouteFailures` と `lastRerouteFinished` を捨てる）。
  - **停車のときと同じく `isRerouting` を下ろす**。検索していないのに赤いカードだけが
    残るのを避けるため。
  - **下ろしたら必ず知らせる**（`rerouteBlockedOffline` → `CPNavigationAlert`）。下ろすだけだと
    「再検索中が出っぱなし」が「経路を外れたまま何も起きない」に変わるだけになる。
    **圏外が続くあいだは 1 回だけ**。
  - **`NWPathMonitor` は「通信できる」の保証ではない。** 見ているのは経路が張れているか
    どうかで、電波 1 本でタイムアウトする状態でも `.satisfied` を返す。はっきり切れている
    ときを拾うだけで、それ以外の失敗は従来どおり再試行の間隔に任せる。
  - **判定が付くまでは通信できる扱い**にする。起動直後に圏外から始めると、まだ何も
    分かっていない時点で案内の開始そのものを止めてしまう。
- **引き直しの切り分けは `NavigationLog`（category `route`）を見る**。ジェスチャと同じで、
  **画面を見ても何が起きたか分からない**（「逸脱と判断した」「判断したが見送った」
  「投げたが失敗した」が全部同じ見え方になる）。`off-route` の行に中心線からの距離・
  測位の精度・速度が揃って出るので、しきい値のどれを疑えばよいかもここで決まる。
  `reroute succeeded changed=false` は**引き直したのに前と同じ経路が返った**印。

  ```bash
  xcrun simctl spawn booted log stream --style compact --level info \
    --predicate 'subsystem == "jp.hibiki.michinavi" AND category == "route"'
  ```
- **引き直しの見分けは `NavRoute.id` ではなく `NavRoute.signature`**。`id` は生成のたびに
  変わる UUID なので、**同じ道を同じ順に曲がる経路でも別物になる**。`VoiceGuidance` は
  これでリルートを判定して「ルートを再検索しました」を読むため、`id` で見ていると
  停車中の引き直しで同じ経路を繰り返し読み上げることになる（上のゲートを入れたので
  そこは塞がったが、渋滞徐行など速度が出ない場面のための受け皿として残してある）。
  指紋は step の指示と距離から作る。座標列は数千点あって毎回舐めると重く、同じ道を
  たどるなら指示と距離も必ず一致する。**CarPlay 側の `maneuverRouteID` は `id` のまま**で
  よい。あちらが見ているのは「その `CPManeuver` がこの `NavRoute` から作られたか」という
  インスタンスの対応で、中身が同じかどうかとは別の話。
- **リルート中も `CPNavigationSession` は張り替えず、`pauseTrip` / `resumeTrip` で繋ぐ**。
  作り直すと `CPTrip` から組み直しになり、到着予定の表示が一度途切れる。再開の渡し方は
  デプロイメントターゲットが 26.0 なので 2 系統ある（`CarPlayCoordinator.resume`）。
  iOS 26.4 以降は `resumeTrip(updatedRouteSegments:currentSegment:rerouteReason:)`、
  それ以前は 17.4 からの `resumeTrip(updatedRouteInformation:)`。**新しい方に寄せている
  のは経由地の表現力のためではなく、ルート共有がそちらでしか成立しないから**（後述）。
  古い方は 26.4 で非推奨になったが、26.0 が下限のうちは警告も出ないので残してある。
- **経路が入れ替わったときは、必ず `pauseTrip` してから `resumeTrip` で渡し直す**
  （ガイド p.61）。止めずに渡すと車側が前の経路を掴んだままになる。逸脱による引き直しは
  `apply(isRerouting:)` が止めるところと再開するところの両方を持っているが、
  **立ち寄り先が増えたときは誰も止めていない**ので `replaceRoute` が自分で止めて再開する。
  `updateManeuvers` が「経路が変わった・なのに止まっていない」で見分けている。
- **車へは目的地とルートの 2 段階で渡している**（ガイド p.60-61、iOS 26.4）。
  目的地共有（`CPTrip.hasShareableDestination`、プロパティ自体は 26.1）は、車の純正ナビへ
  行き先だけを渡す。ルート共有（`mapTemplateShouldProvideRouteSharing`）は経路の形・指示・
  座標列まで預けるもので、先進運転支援を積んだ車が車線案内を出したり走り方を寄せたりする。
  **後者は `CPRouteSegment` を `addRouteSegments` で積んでおかないと成立しない**ので、
  `resumeTrip` の新旧はここに直結している。組み立ては `CarPlayRouteSharing` に隔離した。
- **`CPRouteSegment` は経由地の切れ目で区切った 1 区間**。`NavRoute` は経由地ごとの区間を
  1 本に繋いでしまっているので、`waypointStepIndices` を頼りに区切り直す。
  **最後の step に載っている経由地では区間を切らない**（目的地と区別できず空の区間ができる）。
  区間に入れる `CPManeuver` は `routeManeuvers` と**同じインスタンス**であること。
- **`currentSegment` は区間をまたいだときだけ代入する**。代入のたびに車側は区間の
  切り替わりとして受け取るので、毎回渡すと到着予定が区間の先頭へ巻き戻って見える。
  加えて**どの経路の区間かを照合してから代入する**。引き直しでは `CPManeuver` の作り直しが
  先に走るため、step の添字は新しいのに区間はまだ古い、という一瞬が必ずある。
- **新しい CarPlay の API は Swift 名が `__` 始まりになる**。`CPRouteSegment` と
  `CPNavigationWaypoint` の初期化子・座標プロパティは `NS_REFINED_FOR_SWIFT` なのに
  **CarPlay には Swift オーバーレイが無い**（SDK に `.swiftinterface` が無く、
  prebuilt-modules だけ）。`CPRouteSegment(__origin:...)`、`CPNavigationWaypoint(__mapItem:...)`
  のように呼ぶのが正解で、`__` の付かない版を探しても存在しない。
- **座標の配列に空配列のポインタを渡さない**。引数は nonnull なのに、Swift の空 `Array` から
  取れる `baseAddress` は nil になる。渡す座標が無いときは 1 要素だけ確保して個数に 0 を渡す
  （`CarPlayRouteSharing.withCoordinates`）。なお **API 側は座標を複製する**ので、
  `withUnsafeMutableBufferPointer` のスコープを抜けてから読み返しても壊れない
  （2026-08-16 にシミュレータ上で 5000 件を渡して確認）。
- **`CPRouteSource` の case 名は `.sourceVehicle` のように `source` が残る**。
  enum 名との共通接頭辞の削られ方が他と違い、`.vehicle` では通らない。
- **車から来た経由地は、完了ハンドラを呼ばないと確認カードが出ない**。
  `didRequestToInsert(_:into:completion:)` で所要時間を返して初めて CarPlay 既定の
  確認カードが出る仕組みで、**呼ばなければ何も出ない**（自前 UI を出す側の作法）。
  試算に失敗したときに黙って落としているのはこれを利用したもので、数字の入っていない
  カードを運転中に見せないため。受諾は `waypoint(accepted:forSegment:)` に別途来る。
- **車から目的地が来ても即発進させない**。`didReceiveRequestForDestination` は
  `requestRoutes(to:)` に流して提示で止める（ガイド p.61 が trip preview を求めている）。
  `startNavigation(to:)` にすると車の操作だけで走り出すことになる。
- **`CPMapTemplate.guidanceBackgroundColor` は必ず設定する**。**渡さないと案内カードが
  真っ赤に出る**（2026-08-16 に CarPlay で実測。曲がる指示は警告ではないので、
  そのままにはできない）。経路の線と揃えて `systemBlue` を渡している。
  - **色を渡す口は 3 つあり、`CPManeuver.cardBackgroundColor` → `guidanceBackgroundColor`
    → CarPlay の既定、の順に優先される**（前 2 つはヘッダに明記。3 つ目は
    `-[CPSNavigationCardViewController _updateCardBackgroundColors]` の分岐）。
    赤が出ていたときは前 2 つとも未設定だったので、**赤は CarPlay の既定そのもの**。
  - **逆アセンブルの読みは当てにしない。** 26.2 のランタイムでは既定の落とし先が
    `+[UIColor(CarPlayUIServices) crsui_consoleTurnCardETATrayBackgroundColor]`
    （ダーク＝黒 alpha 0.65 / ライト＝白 alpha 0.75、`setGlassTintColor:` へ渡る）に
    見えるが、**実機はそこを通っていない**。半透明の黒か白しか出ないはずが真っ赤だった。
    追っていない分岐が残っている。**色の話はバイナリではなくスクリーンショットで決めること。**
  - **`pauseTrip` のカードは `turnCardColor` で明示的に分ける**。渡さないと
    `guidanceBackgroundColor` に落ちて案内カードと同じ青になり、「いま案内が
    止まっている」ことが文言でしか分からなくなる（`CarPlayCoordinator.pausedCardColor`）。
  - **文言はどちらの側のものか必ず確かめる。** CarPlay 自身が出す日本語は
    `CarPlaySupport.framework/ja.lproj/Localizable.strings` にあり、
    `REROUTING = 経路の変更中…` / `LOADING = 読み込み中…` / `PROCEED_TO_ROUTE = 経路へ進む`。
    **「再検索中」はこのアプリの文字列**（`ルートを再検索中`）なので、それが出ていたら
    `isRerouting` が本当に立っている。書き手は `NavigationController.reroute` 1 か所しかない。
- **走行中はキーボードが塞がれる**。`CPSessionConfiguration.limitedUserInterfaces` に
  `.keyboard` が入っている間、`CarPlayDestinationBrowser` は検索ボタンを出さない。
  押しても何も起きない導線を運転中に見せないため。**検索が使えない前提で目的地に
  たどり着ける経路（お気に入り・履歴・周辺カテゴリ）を必ず残す。**
- **カテゴリ検索は案内中だけ探し方が変わる**。案内していなければ現在地のまわり
  （`SearchService.nearby`）、案内中は経路の先（`alongRoute`）。走行中に「近いが後ろにある店」
  を出しても選びようがないため。MapKit に経路沿い検索は無いので、経路上へ一定間隔で
  検索点を置いて束ねている。**検索点を増やさないこと**。MapKit のレート制限に近づくうえ、
  運転中に選べる件数を超える。
- **ルート提示中だけ「この経路について」を出す**（`CPInformationTemplate`、
  `CarPlayRouteInformation`）。**候補一覧に出せない情報を出すためにある。** CarPlay の
  候補一覧は名前と距離・時間しか並べられないので、**どれが有料か**が選ぶ時点で分からない。
  MapKit は経路ごとに `advisoryNotices` を返していて、そこが実際の決め手になる
  （実測: 渋谷→成城で候補 1・3 が「通行料の支払いが必要です」、候補 2 は無し。
  鹿児島の港では「経路案内は目的地に最も近い道路で終了します。」＝道が繋がっていない）。
  - **項目は決め手になる順に並べる。** 上限 10 件で、超えたぶんは後ろから切られる。
    注意と立ち寄り先を、候補一覧にも出ている距離・時間より先に置く。
  - **候補を切り替えたら対象も動かす**（`selectedPreviewFor` で `previewedRoute` を更新）。
    `phase` は `.previewing` のまま動かないので、追いかけないと先頭の詳細が出続ける。
    `advisoryNotices` は候補ごとに違うので、これは実害になる。
  - **案内が始まったら入口ごと消す**（`applyNavigatingButtons` に入れない）。走行中に
    読ませる画面ではないし、案内中はナビゲーションバーの左右とも埋まっている。
  - **営業時間は出せない。** `MKMapItem` が持つのは identifier / location / address / name /
    phoneNumber / url / timeZone だけで、営業時間を返す口が無い。電話番号は**出すだけ**で
    かける導線を付けていない（CarPlay から `tel:` が通るか確かめていないので、押しても
    何も起きないボタンを作らない）。
- **テンプレートはアプリ種別ごとに使える範囲が決まっている**（ガイド p.15）。
  **サポート外のものを push すると実行時に例外**なので、足す前に必ず表を見る。
  2026-08-16 に全 12 種を突き合わせた結果、ナビアプリで使えるのは次のとおり。

  | テンプレート | Navigation | このアプリ |
  | --- | --- | --- |
  | Map / List / Grid / Search | ● | 使用中 |
  | Alert / Action sheet / Voice control | ● | 使用中 |
  | Information | ● | 使用中（`CarPlayRouteInformation`） |
  | Tab bar / Contact | ● | 未使用 |
  | **Point of interest** | **×** | 使えない |
  | **Now playing** | **×** | 使えない |

  - **Point of interest が使えないのは意外に見える**（地図とカードで検索結果を出せる
    唯一のテンプレートで、いかにもナビ向き）。実際は Driving task / EV charging・給油・駐車 /
    Quick food / Public safety 用で、**Navigation の列だけが空白**。2026-08-16 に一度
    これで検索結果を作り、実機へ持っていく前に表で気づいて戻した。
  - **この表は PDF から素直には読めない。** テキスト抽出では丸印の列位置が落ちて
    「Information は 6 個」までしか分からず、どの列が空きかを判別できない。
    `PDFPage.characterBounds(at:)` も当てにならない（丸印の座標がずれて出る）。
    **確実なのはページを PNG に描いて画素から丸を拾うこと**（中間グレーで、縦横が
    ほぼ等しく、面積が箱の 6 割以上の塊）。63 個ちょうど拾えれば読めている。
  - 階層の上限はナビアプリで**5 段**（root を含む）。いまいちばん深いのは
    地図 → 目的地リスト → カテゴリ → 検索結果 の 4 段。
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
- **iOS 26.4 以降のシミュレータでは、CarPlay に地図を出した瞬間に CarPlay ホストが落ちる**
  （Apple 側のバグ）。**シミュレータで CarPlay を試すときは 26.2 以前を使う。**
  実機は 2026-08-15 に通しで動いているので、少なくともあの端末では起きていない。
  ただし確かめたのはシミュレータ用の CarPlaySupport だけで、実機側の実装は見ていない。
  26.0 が下限なので 26.0 / 26.1 / 26.2 が選べる。ジェスチャ関連の API は 26.0 から揃って
  いるので、これで確認できないものは無い。
  - `CPSMapTemplateViewController._updateShareButtonVisibility` が
    `destinationSharingDelegate`（実体は `CPSTemplateInstance`）へ
    `vehicleSupportsDestinationSharing` を `respondsToSelector:` も見ずに送る。
    このセレクタは CarPlaySupport のどこにも実装が無く、送っている箇所も
    ここ 1 つだけ（26.5 の逆アセンブルで確認）。受け手が nil でなく実装だけ無いので、
    `doesNotRecognizeSelector:` で必ず落ちる。
  - 経路は `_viewDidLoad` → `_configureNavigationBarShareButton` →
    `_updateShareButtonVisibility` で、**分岐が無い**。つまりアプリ側で避けようがなく、
    `CPMapTemplate` を push した全アプリが落ちる。共有ボタン自体に公開 API も無い。
  - `_updateShareButtonVisibility` は **26.4 で追加された**。26.2 以前のランタイムには
    メソッドごと存在しない（`nm` で全ランタイムを確認）。
  - **「アプリを再ビルドしたから道連れになった」ではない。** 2026-08-16 まではそう書いて
    いたが、実際は CarPlay に地図を出すたびに落ちていた。クラッシュログが溜まるのを
    再インストールのせいだと取り違えていた。
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

- **コメント・コミットメッセージは日本語**。コメントは「何を」ではなく「なぜ」を書く。
- 距離・時間・到着時刻の表示は `Formatters` に集約。両画面で表記がずれないよう、直に文字列を組まない。
- **UI 文言は必ず `String(localized:)` で包む**。キーは日本語そのもの。
  - 訳は `MichiNavi/en.lproj/Localizable.strings` と `ja.lproj/Localizable.strings`。
    **ja も必ず要る**。プロジェクトの `developmentRegion` が `en` なので、`ja.lproj` を
    置かないと日本語の端末でも英語に落ちる（キーが日本語なので気づきにくい）。
  - **文字列を `+` でつなげない**。「16:30 にとめました」を足し算で組むと、語順の違う言語で
    訳しようがなくなる。補間（`"\(time) にとめました"`）にして 1 つのキーにする。
  - **App Intents の文言は包まない**。`LocalizedStringResource` と `AppShortcutPhrase` が
    自前で localization を持っており、`String` を渡すと型が合わない。
  - キーの正確な形（補間が `%@` か `%lld` か）は、ビルドが吐く `.stringsdata`（JSON）で確かめる。
    `DerivedData/.../Objects-normal/arm64/*.stringsdata` に 1 ファイルずつ出ている。
- **文言マッチの表は訳さない。日英を同じ配列に並べる。** `ManeuverDirection`（MapKit の指示文）と
  `VoiceCommand`（話し言葉）がこれにあたる。どちらも**端末の言語で入力が変わる**ので、
  「いまの言語の表」を選ぶのではなく両方を持って両方を見る。

## 未実装

CarPlay entitlement（`com.apple.developer.carplay-maps`）は 2026-08-15 に承認され、当面の
ゴールだった申請は通った。同日に実機の CarPlay で画面の見た目・音声案内・目的地選択まで
通しで確認済み。残っているのは以下。

- **英語ローカライズの訳文そのもの**: 仕組みと 136 件の訳は入れたが、**英語圏の運転者に
  読んでもらったことは一度も無い**。とくに音声の読み上げ（`VoicePromptScheduler`）は
  文字で見て自然でも耳で聞くと不自然になりやすい。
  なお `knownRegions` への `ja` の追加は**ビルドシステムが自分で行った**（`ja.lproj` を
  置いてビルドしたら pbxproj に足された）。手で編集したものではない。
- **`com.apple.developer.weatherkit` を足していない**。`RouteWeather` のコードは入っているが、
  ケイパビリティが無いので問い合わせが失敗し、黙って何もしない状態。entitlements に
  先に書くと App ID 側で有効化されるまで実機ビルドが通らなくなるので、順序に注意
  （CarPlay entitlement で踏んだのと同じ罠）。
- **テストターゲットと Widget Extension が無い**。どちらもターゲット追加が要り、
  `project.pbxproj` を手で編集しない方針なので Xcode 上での作業になる。
  純ロジック（`RouteCharacter` の比較、`ManeuverDirection` の文言マッチ、`VoiceCommand` の
  fallback、`DrivingSide` の表、`CarPlayRouteSharing` の区間の切り出し）が増えたので、
  テストの置き場が無いのは実際に効いてきている。ウィジェットと Live Activity は
  iOS 26 の CarPlay で使えることが確認済み（`WidgetLocation.carPlay` / 
  `.supplementalActivityFamilies([.small])`）。
- **2026-08-15 に足したぶんの実走確認**。ビルドは通っているが、実際に走らせて
  見た目や挙動を確かめたものは 1 つも無い。とくに次の 3 つは**実機かつ対応した車でないと
  確認しようがない**: メーター・HUD への案内メタデータ、メーター内の地図、
  リルート中の「再検索中」カード。経由地とルート沿い検索はシミュレータでも確かめられる。
- **駐車場の提案の実走確認**（2026-08-16 追加ぶん）。**アプリを通して出したことは一度も無い。**
  ここだけは UI を叩く必要があり、テストターゲットが無いあいだは実走かシミュレータでの
  手動操作になる。切り分けは `ParkingLog`（category `parking`）を見る。**出なかったときに
  画面には何も出ない**ので、しきい値に届いていない・自宅職場で黙った・検索が失敗した・
  全部が駐輪場だった・遠すぎた、が全部同じ見え方になる。

  ```bash
  xcrun simctl spawn booted log stream --style compact --level info \
    --predicate 'subsystem == "jp.hibiki.michinavi" AND category == "parking"'
  ```

  **データ側と経路側の心配は 2026-08-16 に潰した**（MapKit を直接叩いて実測）。
  - コインパーキング（タイムズ・リパーク・NPC24H・名鉄協商など）は `.parking` で返る。
    14 地点で都心 24〜38 件／500m、白川郷のような山間の観光地でも 4 件。
  - **提案先へ経路は引ける**。5 経路すべてで `MKDirections` が成功した（建物内の座標で
    引けないのではという心配は外れ）。
  - **出るタイミングは市街地で残り 2.6〜5.3 分**（東京→渋谷 158 秒、横浜→みなとみらい
    318 秒、松本 189 秒、金沢 294 秒）。ただし**高速で目的地に近づくと 1 分を切る**
    （高山→白川郷 56 秒、しかも残る step は 0 個＝もう曲がるところが無い）。
    1km は距離なので、速度が上がるほど手前の時間が短くなる。時間で切る案もあるが、
    残り時間は距離按分でしか出せない（MapKit が step ごとの所要を返さない）ので、
    しきい値を時間にすると按分の誤差がそのまま発火位置の誤差になる。
- **タッチジェスチャの手触り**（2026-08-16 追加ぶん）。**1 本指のドラッグだけは
  CarPlay Simulator で確かめられる**（マウスのドラッグがそのまま 1 本指のパンとして届く。
  2026-08-16 に地図の暴走を直したときはこれで見た）。残るピンチ・回転・2 本指のピッチは
  マウス 1 本では作れないので、マルチタッチ対応の車が要る。
  値の意味は CarPlay ホストの逆アセンブルで裏を取ったが、**係数と符号は推測のまま**。
  実車で最初に見るのは次の 3 つ: 回転の向き（逆なら
  `CarPlayMapViewController.rotate(byRadians:)` の符号）、傾きの重さ
  （`pitchDegreesPerPoint`）、ピンチの追従性（`scale` が累積でなかった場合、倍率が
  ほぼ 1 のままになって「効かない」形で失敗する）。押しっぱなしのパンの速さ
  （`sustainedPanInterval` × `sustainedPanStep` ＝毎秒 240pt）と、指を離したあとの
  惰性の減衰（`glideDecay` / `glideCutoff`）も同じく当て推量。ただし**ドラッグの
  移動量そのものは実測で合わせた**（`centerPoint`）ので、そこはもう推測ではない。
  切り分けには `CarPlayGestureLog` を見る。**「地図が動かない」は、ジェスチャが届いて
  いない場合と、届いたが受け付けていない場合と、受け付けたうえで効き方がおかしい場合の
  3 つで同じ見え方になる。** 行末の `applied` / `pending` / `inactive` が真ん中を切り分け、
  `(clamped)` が「上限に張り付いているだけ」を切り分ける。読む順序は次のとおり。

  1. **行が出るか。** 出ないとき、**「車の側だから直すところは無い」で閉じないこと。**
     同じ見え方になる原因がこちら側に 4 つある: `CPMapTemplateDelegate` は全メソッドが
     任意なので**名前を 1 文字間違えても素通りする**（`#selector(CPMapTemplateDelegate.xxx)` が
     解決するかで確かめる）、述語の subsystem が実際のバンドル ID と食い違っている、
     捕捉レベルが足りない（`.info` を出す指定を忘れている）、`log stream` が取りこぼしている
     （2 本指ジェスチャはピンチと回転を同時に出すので `--ignore-dropped` を付けない）。
     これを潰してなお出ないなら車の側で、1 本指のパンはタッチ精度で認識器が付かない車がある。
  2. **`inactive` / `pending` か。** 係数の話ではない。`inactive` は受け付けていない
     （`recenter()` に基準を捨てられた・開始が届いていない・メーター内で禁じている）、
     `pending` は追従を切るしきい値の手前かピッチの最初の 1 点。直前に
     `camera recenter(...)` が挟まっていれば前者。
  3. **`applied` なのに `→` の右が動かないか。** ここで初めて係数と符号を疑う。
     ただし `(clamped)` が付いていたら上限（下限）に張り付いているだけで、正常。

  ドラッグだけは `applied` を出さない（カメラの要約では効いたか分からないので、
  代わりに `moved=` に動いた距離が入る）。読むところが 2 つある。`drag began` が
  出ずに `drag` が並んでいたら、そのドラッグは追従と綱引きしている。`glide` は
  **車から来た入力ではなくこちらが作った動き**なので、`drag` と混ぜて
  「入力が届いた」と読まない。

  **ログは `.info`。** `.debug` だと誰かが受け取っているあいだしか捕まらず、Mac を繋がずに
  走ったあとで吸い出しても何も残らない。この記録が要るのはまさにその場面なので、
  メモリバッファに載る `.info` にしてある。走り終えてから実機を Mac に繋いで取り出す:

  ```bash
  log collect --device --last 1h --output michinavi.logarchive
  log show michinavi.logarchive --style compact --info \
    --predicate 'subsystem == "jp.hibiki.michinavi" AND category == "gesture"'
  ```

  Mac を繋いだまま流し見るなら Console.app（Action → Include Info Messages を入れる）。
  **`log stream` に `--device` は無い**（`log stream --help` に出てこない）。`xcrun simctl
  spawn booted` はシミュレータ専用だが、そちらでも**パンボタン（`pan …`）と 1 本指の
  ドラッグ（`drag …`）は出る**。実機が要るのはピンチ・回転・ピッチの 3 つ。
- **車との目的地共有・ルート共有の動作確認**（2026-08-16 追加ぶん）。ビルドと、
  区間の切り出し・座標の受け渡しはシミュレータ上で確認済みだが、**車が受け取ったあとは
  一度も見ていない**。**これは CarPlay Simulator で確かめられる**（ガイド p.63。
  1 本指のドラッグと同じく、実車を待たずに見られる側）。
  `Additional Tools for Xcode` の DMG に入っている `Hardware/CarPlay Simulator.app` を使う。

  - 目的地共有: 車両設定の「Manage…」で **Share Route Destination Information** を入れると
    共有ボタンが出る。送った中身は「Destination Information」で読める。
  - ルート共有: プリセットの **Standard Navigation** / **Widescreen Navigation** を選ぶ。
    「Route Sharing」で車が受け取った経路が読め、**車から経由地を送り込むこともできる**
    （＝`didRequestToInsert` と `didReceiveRequestForDestination` を実際に起こせる）。

  こちら側は `CarPlayVehicleLog` を見る。ジェスチャと同じで、**対応していない車では
  何も起きないのが正常**なので、呼ばれているかどうかをログでしか切り分けられない。

  ```bash
  xcrun simctl spawn booted log stream --style compact --level info \
    --predicate 'subsystem == "jp.hibiki.michinavi" AND category == "vehicle"'
  ```

  こちらは CarPlay Simulator で起こせるのでシミュレータ相手でよい。実機から後で
  取り出すときはジェスチャと同じ `log collect --device`。

  なお **26.4 未満のシミュレータでは新しい経路がまるごと動かない**。既定で起動している
  端末が 26.2 などだと「実装したのに何も起きない」に見えるので、先に OS を確かめること。
- **音声入力の実地確認**（2026-08-16 追加ぶん）。読み上げ合成した音声を
  `SpeechAnalyzer` に流す形で認識の経路は通してあるが、**本物のマイクでは一度も試していない**。
  実車で見るのは次の 3 つ。

  - **走行ノイズでの認識率**。`AVAudioSession` のモードに `.measurement` を選んでいる
    （認識向けとして文書化されている設定）が、これは系の音声処理を切るので、
    ロードノイズの中では逆効果かもしれない。`.voiceChat` ならエコー除去が効くが、
    通話用の経路に切り替わって車ではなく iPhone のマイクを掴む恐れがある。**未検証**。
  - **話し終わりの 1.4 秒**。長い住所を言い切る前に切れないか。
  - **音楽との同居**。`.duckOthers` で下げているだけなので、音楽が乗ったままマイクに入る。
- **Foundation Models は開発機で一度も動いていない**。`SystemLanguageModel.default.availability`
  が `appleIntelligenceNotEnabled` を返す（2026-08-16 時点）。**つまり
  `DestinationIntent.parse` は今のところ常に fallback 側しか通っていない。**
  試すには対応機種で Apple Intelligence を有効にすること。
- **傾けているあいだのドラッグは指にぴたりとは付かない**。CarPlay が渡してくるのは
  デルタと速度だけで**指の位置が入っていない**ので、掴んだ地点を指の下に留める計算が
  できず、中心付近の縮尺で代用している。傾いた地図は 1pt あたりの距離が画面の上下で
  変わるため、pitch 45（`.heading` の既定）で 240pt のドラッグに対しておよそ 14%、
  pitch 60 で 25% の取りこぼしになる（iOS 26.2 で実測）。北上げ（pitch 0）では
  ぴたりと合う。直すなら地図座標系で計算することになるが、指の位置が無い以上
  完全には合わない。
- **`CPLaneGuidance` は空のまま**。`resumeTrip` も `CPRouteSegment` も必須で要求するので
  形だけ渡している。MapKit がレーン情報を返さないので、外部依存を足さない限り埋められない。
  **ルート共有をしていても埋まらない**（車が期待する情報のうち、ここだけ渡せていない）。
