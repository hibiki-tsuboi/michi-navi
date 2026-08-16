import AppIntents
import CoreLocation

/// Siri とショートカットからの入口。
///
/// 音声入力（`SpeechInput`）と役割が分かれている。あちらは**アプリを開いたあと**、
/// 運転中にキーボードが使えない穴を埋めるもの。こちらは**アプリを開く前**、
/// 「乗る前に一言で走り出す」ためのもの。どちらも `NavigationController` を
/// 呼ぶだけなので、案内の挙動は変わらない。
struct DestinationEntity: AppEntity {
    let id: String
    let name: String
    let subtitle: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "目的地" }
    static var defaultQuery = DestinationQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    init(place: Place) {
        id = place.id
        name = place.name
        subtitle = place.subtitle
    }
}

/// Siri に見せる候補。
///
/// **お気に入りと履歴からしか出さない。** 任意の地名を受けるには検索が要り、
/// Siri の側で候補を確定できないと会話が長くなる。行き先を口で言いたいときは
/// アプリ内の音声入力のほうが早い。
struct DestinationQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DestinationEntity] {
        Self.places.filter { identifiers.contains($0.id) }.map(DestinationEntity.init(place:))
    }

    @MainActor
    func suggestedEntities() async throws -> [DestinationEntity] {
        Self.places.map(DestinationEntity.init(place:))
    }

    @MainActor
    fileprivate static var places: [Place] {
        let store = DestinationStore.shared
        var seen = Set<Place>()
        return (store.favorites + store.recents).filter { seen.insert($0).inserted }
    }
}

// MARK: - 案内の開始

struct StartNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "案内を開始"
    static var description = IntentDescription("お気に入りや履歴の目的地へ案内を始めます。")
    /// 案内には地図と位置情報が要るので、必ずアプリを前面に出す。
    static var openAppWhenRun = true

    @Parameter(title: "目的地")
    var destination: DestinationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let place = DestinationQuery.places.first(where: { $0.id == destination.id }) else {
            throw $destination.needsValueError("どこへ向かいますか")
        }
        // **ルートの提示を挟まずに走り出す。** 声で頼んだ時点で行き先は決まっており、
        // 車に乗り込む前後に候補を選ばせても見てもらえない。
        // `CarPlay` の Dashboard ショートカットと同じ入口。
        NavigationController.shared.startNavigation(to: place)
        return .result()
    }
}

// MARK: - 案内の終了

struct EndNavigationIntent: AppIntent {
    static var title: LocalizedStringResource = "案内を終了"
    static var description = IntentDescription("走っている案内をやめます。")
    /// 止めるだけなので画面は要らない。
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        NavigationController.shared.cancelNavigation()
        return .result()
    }
}

// MARK: - 読み上げ直し

struct RepeatGuidanceIntent: AppIntent {
    static var title: LocalizedStringResource = "案内をもう一度読む"
    static var description = IntentDescription("いまの指示をもう一度読み上げます。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceGuidance.shared.repeatCurrentGuidance()
        return .result()
    }
}

// MARK: - 言い回し

struct MichiNaviShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartNavigationIntent(),
                    phrases: [
                        "\(.applicationName)で案内を開始",
                        "\(.applicationName)で\(\.$destination)へ行く",
                        "\(.applicationName)で\(\.$destination)まで案内",
                    ],
                    shortTitle: "案内を開始",
                    systemImageName: "car.fill")

        AppShortcut(intent: EndNavigationIntent(),
                    phrases: ["\(.applicationName)の案内を終了"],
                    shortTitle: "案内を終了",
                    systemImageName: "xmark.circle")

        AppShortcut(intent: RepeatGuidanceIntent(),
                    phrases: ["\(.applicationName)でもう一度案内"],
                    shortTitle: "もう一度読む",
                    systemImageName: "speaker.wave.2.fill")
    }
}
