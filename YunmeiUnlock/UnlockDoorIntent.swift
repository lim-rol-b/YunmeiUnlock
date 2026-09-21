import AppIntents

@available(iOS 16.0, *)
struct DoorAppEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "门锁")
    static var defaultQuery = DoorAppEntityQuery()

    let id: String
    let name: String
    let lockNumber: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "编号：\(lockNumber)")
    }

    init(configuration: DoorConfiguration) {
        id = configuration.id
        name = configuration.name
        lockNumber = configuration.lockNumber
    }
}

@available(iOS 16.0, *)
struct DoorAppEntityQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [DoorAppEntity.ID]) async throws -> [DoorAppEntity] {
        let identifierSet = Set(identifiers)
        let configurations = await DoorConfigurationStorage.loadConfigurations()
        return configurations
            .filter { identifierSet.contains($0.id) }
            .map(DoorAppEntity.init)
    }

    func suggestedEntities() async throws -> [DoorAppEntity] {
        let configurations = await DoorConfigurationStorage.loadConfigurations()
        return configurations.map(DoorAppEntity.init)
    }
}

@available(iOS 16.0, *)
struct UnlockDoorIntent: AppIntent {
    static var title: LocalizedStringResource = "解锁门锁"
    static var description = IntentDescription("选择并通过蓝牙打开指定门锁；不选择时会在运行时询问。")
    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(
        title: "门锁",
        description: "留空时，运行快捷指令后选择要打开的门锁",
        requestDisambiguationDialog: "请选择要打开的门锁"
    )
    var door: DoorAppEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("打开 \(\.$door)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let configurations = DoorConfigurationStorage.loadConfigurations()
        guard !configurations.isEmpty else {
            throw BLEUnlockManager.UnlockError.notConfigured
        }

        let selectedDoor: DoorAppEntity
        if let door {
            selectedDoor = door
        } else {
            selectedDoor = try await $door.requestDisambiguation(
                among: configurations.map(DoorAppEntity.init),
                dialog: "请选择要打开的门锁"
            )
        }

        guard let configuration = configurations.first(where: { $0.id == selectedDoor.id }) else {
            throw BLEUnlockManager.UnlockError.notConfigured
        }
        let manager = BLEUnlockManager(configuration: configuration)
        try await manager.unlock(showsLiveActivity: false, prefersCachedPeripheral: true)
        return .result(dialog: "已向\(configuration.name)发送开门指令")
    }
}

@available(iOS 16.0, *)
struct YunmeiUnlockShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UnlockDoorIntent(),
            phrases: [
                "用 \(.applicationName) 解锁门锁",
                "在 \(.applicationName) 中开门",
                "让 \(.applicationName) 打开门锁",
                "用 \(.applicationName) 打开 \(\.$door)"
            ],
            shortTitle: "解锁门锁",
            systemImageName: "lock.open"
        )
    }
}
