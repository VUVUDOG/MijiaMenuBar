import AppIntents
import Foundation

// Shortcuts / Siri actions. They run inside the menu bar app (launched in the
// background if needed) and go through the same optimistic queue as the panel.

struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let text: String
    init(_ text: String) { self.text = text }
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: text) }
}

@MainActor
enum IntentBridge {
    // The app may have just been launched for this action: wait briefly for its model.
    static func model() async throws -> AppModel {
        for _ in 0..<60 {
            if let model = AppModel.shared, model.hasDevices { return model }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw IntentFailure("请先在菜单栏中登录米家并同步房间")
    }

    // Wait until the commands for these devices have been sent and confirmed.
    static func finish(_ model: AppModel, ids: [String]) async throws {
        let deadline = Date().addingTimeInterval(25)
        func waiting() -> Bool { ids.contains { model.pending[$0] != nil || model.inFlight?[$0] != nil } }
        while waiting() && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if waiting() { throw IntentFailure("指令仍在发送，请稍后在菜单栏查看结果") }
        if model.phase == "error", model.failedIDs.map({ !$0.isDisjoint(with: ids) }) ?? true {
            throw IntentFailure(model.message)
        }
    }

    static func devices() -> [DeviceEntity] {
        guard let model = AppModel.shared else { return [] }
        let climates = model.rooms.map { DeviceEntity(id: $0.id, name: $0.name, room: $0.area) }
        let items = model.accessories.map { DeviceEntity(id: $0.id, name: $0.name, room: $0.room) }
        return (climates + items).sorted { ($0.room, $0.name) < ($1.room, $1.name) }
    }

    static func switchChanges(_ item: Accessory, _ action: SwitchAction) -> [String: AnyHashable]? {
        if item.kind == "curtain" {
            let open = (item.number("curtain.current-position") ?? 0) > 0
            let target = action == .toggle ? !open : action == .on
            return ["curtain.motor-control": target ? 1.0 : 2.0]
        }
        guard let address = item.primary ?? (item.prop("light.on")?.writable == true ? "light.on" : nil) else { return nil }
        let current = item.values[address]?.base as? Bool ?? false
        return [address: action == .toggle ? !current : action == .on]
    }
}

// MARK: Entities

struct DeviceEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "米家设备"
    static let defaultQuery = DeviceQuery()
    let id: String
    let name: String
    let room: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(room) · \(name)") }
}

struct DeviceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DeviceEntity] {
        await MainActor.run { IntentBridge.devices().filter { identifiers.contains($0.id) } }
    }
    func suggestedEntities() async throws -> [DeviceEntity] {
        await MainActor.run { IntentBridge.devices() }
    }
}

struct RoomEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "房间"
    static let defaultQuery = RoomQuery()
    static let wholeHome = "*"
    let id: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: id == Self.wholeHome ? "全屋" : id))
    }
}

struct RoomQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [RoomEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [RoomEntity] {
        await MainActor.run { [RoomEntity(id: RoomEntity.wholeHome)] + (AppModel.shared?.areas ?? []).map { RoomEntity(id: $0) } }
    }
}

struct ClimateEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "空调"
    static let defaultQuery = ClimateQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
}

struct ClimateQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ClimateEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ClimateEntity] {
        await MainActor.run { (AppModel.shared?.rooms ?? []).map { ClimateEntity(id: $0.id, name: $0.name) } }
    }
}

enum SwitchAction: String, AppEnum {
    case on, off, toggle
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "操作"
    static let caseDisplayRepresentations: [SwitchAction: DisplayRepresentation] = [.on: "打开", .off: "关闭", .toggle: "切换"]
}

// MARK: Actions

struct SwitchDeviceIntent: AppIntent {
    static let title: LocalizedStringResource = "开关米家设备"
    static let description = IntentDescription("打开、关闭或切换一个米家设备；窗帘为打开或合上。")
    @Parameter(title: "设备") var device: DeviceEntity
    @Parameter(title: "操作", default: .toggle) var action: SwitchAction
    static var parameterSummary: some ParameterSummary { Summary("\(\.$action)\(\.$device)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.model()
        let label = "\(device.room) · \(device.name)"
        if let room = model.rooms.first(where: { $0.id == device.id }) {
            let current = model.overlaid(room).power ?? false
            let target = action == .toggle ? !current : action == .on
            model.setClimate(room.id, "on", value: target)
            try await IntentBridge.finish(model, ids: [room.id])
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "已\(target ? "打开" : "关闭")\(label)")))
        }
        guard let item = model.accessories.first(where: { $0.id == device.id }).map(model.overlaid) else {
            throw IntentFailure("没有找到这个设备，请在菜单栏中同步房间")
        }
        guard item.online else { throw IntentFailure("\(label) 当前离线") }
        guard let changes = IntentBridge.switchChanges(item, action) else { throw IntentFailure("\(label) 不支持开关") }
        for (address, value) in changes { model.setAccessory(item.id, address, value: value) }
        try await IntentBridge.finish(model, ids: [item.id])
        let opened = changes.values.first.map { ($0.base as? Bool) ?? (($0.base as? Double) == 1) } ?? false
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "已\(opened ? "打开" : "关闭")\(label)")))
    }
}

struct TurnOffRoomIntent: AppIntent {
    static let title: LocalizedStringResource = "关闭房间"
    static let description = IntentDescription("关闭房间（或全屋）里开着的灯、风扇、净化器、浴霸和空调，不含插座和窗帘。")
    @Parameter(title: "房间") var room: RoomEntity
    static var parameterSummary: some ParameterSummary { Summary("关闭\(\.$room)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.model()
        let area: String? = room.id == RoomEntity.wholeHome ? nil : room.id
        let name = area ?? "全屋"
        let ids = Array(model.offTargets(area).keys)
        guard model.turnOff(area: area) > 0 else {
            return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "\(name)没有开着的设备")))
        }
        try await IntentBridge.finish(model, ids: ids)
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "已关闭\(name)的 \(ids.count) 个设备")))
    }
}

struct SetClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "设置空调温度"
    static let description = IntentDescription("设置空调的温度，可同时开机。")
    @Parameter(title: "空调") var climate: ClimateEntity
    @Parameter(title: "温度", default: 26, inclusiveRange: (16, 32)) var temperature: Int
    @Parameter(title: "同时开机", default: true) var powerOn: Bool
    static var parameterSummary: some ParameterSummary {
        Summary("把\(\.$climate)设为\(\.$temperature)°") { \.$powerOn }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentBridge.model()
        guard let room = model.rooms.first(where: { $0.id == climate.id }) else {
            throw IntentFailure("没有找到这台空调，请在菜单栏中同步房间")
        }
        let value = min(max(Double(temperature), room.minimum), room.maximum)
        if powerOn, model.overlaid(room).power != true { model.setClimate(room.id, "on", value: true) }
        model.setClimate(room.id, "target-temperature", value: value)
        try await IntentBridge.finish(model, ids: [room.id])
        let suffix = powerOn ? "，已开机" : ""
        return .result(dialog: IntentDialog(LocalizedStringResource(stringLiteral: "\(room.name)已设为 \(Int(value))°\(suffix)")))
    }
}
