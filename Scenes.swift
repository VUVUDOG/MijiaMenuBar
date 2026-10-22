import AppKit
import SwiftUI

// Custom scenes: a name plus target states for several devices, run with one click.
// They are stored in this Mac's preferences and sent through the same queue as the panel,
// so they are merged into one parallel batch with optimistic display and revert on failure.

enum SceneValue: Codable, Hashable {
    case bool(Bool)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { self = .number(try container.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }
    var any: AnyHashable {
        switch self {
        case .bool(let value): return AnyHashable(value)
        case .number(let value): return AnyHashable(value)
        }
    }
    var boolValue: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    var numberValue: Double? { if case .number(let value) = self { return value } else { return nil } }
}

struct SceneStep: Codable, Identifiable, Hashable {
    var id: String                      // device id (an air conditioner or an accessory)
    var values: [String: SceneValue]    // property address (or air-conditioner field) -> target
}

struct SceneDef: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var steps: [SceneStep]
    static func blank() -> SceneDef { SceneDef(id: UUID().uuidString, name: "", steps: []) }
}

struct SceneDevice: Identifiable {
    let id: String
    let name: String
    let room: String
}

extension AppModel {
    static func loadScenes() -> [SceneDef] {
        UserDefaults.standard.data(forKey: "scenes").flatMap { try? JSONDecoder().decode([SceneDef].self, from: $0) } ?? []
    }

    func persistScenes() {
        UserDefaults.standard.set(try? JSONEncoder().encode(scenes), forKey: "scenes")
    }

    func saveScene(_ scene: SceneDef) {
        var scene = scene
        scene.name = scene.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scene.name.isEmpty, !scene.steps.isEmpty else { return }
        if let index = scenes.firstIndex(where: { $0.id == scene.id }) { scenes[index] = scene } else { scenes.append(scene) }
        persistScenes()
    }

    func deleteScene(_ id: String) {
        scenes.removeAll { $0.id == id }
        persistScenes()
    }

    // MARK: Devices that can be part of a scene

    // Air conditioners and accessories; cookers are left out (starting one needs a person on site).
    var sceneDevices: [SceneDevice] {
        rooms.map { SceneDevice(id: $0.id, name: $0.name, room: $0.area) }
            + accessories.filter { $0.kind != "cooker" }.map { SceneDevice(id: $0.id, name: $0.name, room: $0.room) }
    }

    // The property that switches a device on or off (an air conditioner uses its "on" field).
    func stepOnKey(_ id: String) -> String? {
        if rooms.contains(where: { $0.id == id }) { return "on" }
        guard let item = accessories.first(where: { $0.id == id }) else { return nil }
        return item.primary ?? (item.prop("light.on")?.writable == true ? "light.on" : nil)
    }

    // Record a device's current state. A device that is off is recorded as just "off".
    func captureStep(_ id: String) -> SceneStep? {
        if let room = rooms.first(where: { $0.id == id }).map(overlaid) {
            guard let power = room.power else { return nil }
            var values: [String: SceneValue] = ["on": .bool(power)]
            if power {
                if let target = room.target { values["target-temperature"] = .number(target) }
                if let mode = room.mode { values["mode"] = .number(Double(mode)) }
                if let fan = room.fan { values["fan-level"] = .number(Double(fan)) }
            }
            return SceneStep(id: id, values: values)
        }
        guard let item = accessories.first(where: { $0.id == id }).map(overlaid), item.kind != "cooker" else { return nil }
        var values: [String: SceneValue] = [:]
        for prop in item.props where prop.writable && prop.address != "curtain.motor-control" {
            guard let raw = item.values[prop.address] else { continue }
            if prop.isBool, let flag = raw.base as? Bool { values[prop.address] = .bool(flag) }
            else if let number = raw.base as? Double { values[prop.address] = .number(number) }
        }
        if let primary = item.primary, values[primary]?.boolValue == false { values = [primary: .bool(false)] }
        if values["light.on"]?.boolValue == false {
            values = values.filter { !$0.key.hasPrefix("light.") || $0.key == "light.on" }
        }
        return values.isEmpty ? nil : SceneStep(id: id, values: values)
    }

    // Everything that is on right now (outlets and curtains included, cookers not).
    func capturableRunning() -> [SceneStep] {
        sceneDevices.compactMap { device in
            guard let step = captureStep(device.id) else { return nil }
            let key = stepOnKey(device.id)
            let on = key.flatMap { step.values[$0]?.boolValue } ?? (accessories.first { $0.id == device.id }.map(overlaid)?.isOn ?? false)
            return on ? step : nil
        }
    }

    // MARK: Describing a step in words

    func describe(_ step: SceneStep) -> String {
        var parts: [String] = []
        if let room = rooms.first(where: { $0.id == step.id }) {
            if let on = step.values["on"]?.boolValue { parts.append(on ? "开" : "关") }
            if let target = step.values["target-temperature"]?.numberValue { parts.append("\(Int(target))°") }
            if let mode = step.values["mode"]?.numberValue, let label = room.modes.first(where: { $0.id == Int(mode) })?.label { parts.append(label) }
            if let fan = step.values["fan-level"]?.numberValue, let label = room.fans.first(where: { $0.id == Int(fan) })?.label { parts.append("风量 " + label) }
            return parts.joined(separator: " · ")
        }
        guard let item = accessories.first(where: { $0.id == step.id }) else { return "设备已不存在" }
        let key = stepOnKey(step.id)
        for prop in item.props {
            guard let value = step.values[prop.address] else { continue }
            if let flag = value.boolValue {
                let label = AccessoryDetail.label(prop)
                parts.append(prop.address == item.primary ? (flag ? "开" : "关") : label + (flag ? "开" : "关"))
            } else if let number = value.numberValue {
                if let option = prop.options.first(where: { Double($0.id) == number }) { parts.append(AccessoryDetail.label(prop) + " " + option.label) }
                else if prop.address.hasSuffix("brightness") { parts.append("亮度 \(Int(number))%") }
                else if prop.address.hasSuffix("color-temperature") { parts.append("\(Int(number))K") }
                else if prop.address.hasSuffix("target-temperature") { parts.append("\(Int(number))°") }
                else if prop.address.hasSuffix("target-position") { parts.append("开合 \(Int(number))%") }
                else { parts.append("\(AccessoryDetail.label(prop)) \(Int(number))") }
            }
        }
        _ = key
        return parts.joined(separator: " · ")
    }

    // MARK: Running a scene

    func runScene(_ scene: SceneDef) {
        var done = 0
        var skipped: [String] = []
        for step in scene.steps {
            let label = displayName(step.id) ?? "设备"
            if rooms.contains(where: { $0.id == step.id }) {
                for (field, value) in step.values.sorted(by: { $0.key < $1.key }) {
                    // Air-conditioner modes and fan levels are integers, like the panel's own buttons.
                    let sent: AnyHashable = ["mode", "fan-level"].contains(field) ? AnyHashable(Int(value.numberValue ?? 0)) : value.any
                    setClimate(step.id, field, value: sent)
                }
                done += 1
            } else if let item = accessories.first(where: { $0.id == step.id }) {
                guard item.online else { skipped.append(label + "（离线）"); continue }
                for (address, value) in step.values.sorted(by: { $0.key < $1.key }) { setAccessory(step.id, address, value: value.any) }
                done += 1
            } else {
                skipped.append(label + "（已不存在）")
            }
        }
        sceneNote = (scene.name, done, skipped)
        if pending.isEmpty && inFlight == nil {
            finishScene(success: true)
        } else {
            message = "正在执行场景「\(scene.name)」…"
        }
    }

    // Called when the queue drains: report the outcome in the footer.
    func finishScene(success: Bool) {
        guard let note = sceneNote else { return }
        sceneNote = nil
        guard success else { return }
        var text = "场景「\(note.name)」已执行（\(note.done) 个设备）"
        if !note.skipped.isEmpty { text += "，已跳过：" + note.skipped.joined(separator: "、") }
        message = text
    }
}

// MARK: Scenes row

struct ScenesSection: View {
    @ObservedObject var model: AppModel
    var onEdit: (SceneDef) -> Void
    var onNew: () -> Void
    static let chipHeight: CGFloat = 30
    static func height(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = CGFloat((count + 2) / 3)
        return 12 + 6 + rows * chipHeight + (rows - 1) * 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("场景").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onNew) { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Color.primary.opacity(0.6)).help("新建场景")
            }.frame(height: 12)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(model.scenes) { scene in
                    Button { model.runScene(scene) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text(scene.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        }.foregroundStyle(Color.primary.opacity(0.78)).frame(maxWidth: .infinity).frame(height: Self.chipHeight)
                            .modifier(Surface(radius: 10))
                    }.buttonStyle(.plain)
                        .help(scene.steps.map { (model.displayName($0.id) ?? "设备") + "：" + model.describe($0) }.joined(separator: "\n"))
                        .contextMenu {
                            Button("编辑…") { onEdit(scene) }
                            Button("删除") { model.deleteScene(scene.id) }
                        }
                }
            }
        }
    }
}

// MARK: Scene editor (replaces the room view while open)

struct SceneEditor: View {
    @ObservedObject var model: AppModel
    @Binding var draft: SceneDef
    var onClose: () -> Void

    static let rowHeight: CGFloat = 44
    static func listHeight(_ count: Int) -> CGFloat {
        count == 0 ? rowHeight : CGFloat(count) * rowHeight + CGFloat(count - 1) * 6
    }
    // Title, list, add row and save row, plus three gaps.
    static let fixedHeight: CGFloat = 30 + 28 + 28 + 3 * 8

    var viewport: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        let reserved: CGFloat = 10 + 38 + ControlView.sectionSpacing + 2 * ControlView.sectionSpacing + 1 + 36 + 10 + Self.fixedHeight
        return min(Self.listHeight(draft.steps.count), max(120, screen * 0.8 - reserved))
    }

    func devices(in room: String) -> [SceneDevice] {
        let used = Set(draft.steps.map(\.id))
        return model.sceneDevices.filter { $0.room == room && !used.contains($0.id) }
    }

    func add(_ device: SceneDevice) {
        guard let step = model.captureStep(device.id) else { return }
        draft.steps.append(step)
    }

    func setOn(_ index: Int, _ on: Bool) {
        let id = draft.steps[index].id
        guard let key = model.stepOnKey(id) else { return }
        if on {
            // Switching on keeps what was recorded; if only "off" was recorded, take the current settings.
            var values = model.captureStep(id)?.values ?? [:]
            values[key] = .bool(true)
            draft.steps[index].values = draft.steps[index].values.count > 1 ? draft.steps[index].values.merging([key: .bool(true)]) { $1 } : values
        } else {
            draft.steps[index].values = [key: .bool(false)]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("场景名称，例如：洗澡", text: $draft.name).textFieldStyle(.plain).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10).frame(height: 30).modifier(Surface(radius: 9))
            ScrollView(.vertical, showsIndicators: Self.listHeight(draft.steps.count) > viewport) {
                VStack(spacing: 6) {
                    if draft.steps.isEmpty {
                        Text("先添加设备，或点“录制开着的设备”把现在开着的都放进来")
                            .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity).frame(height: Self.rowHeight)
                    }
                    ForEach(Array(draft.steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName(step.id) ?? "设备").font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(model.describe(step)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            if let key = model.stepOnKey(step.id) {
                                Toggle("", isOn: Binding(get: { step.values[key]?.boolValue ?? false }, set: { setOn(index, $0) }))
                                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(ControlView.accent)
                            }
                            Button { draft.steps.remove(at: index) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                            }.buttonStyle(.plain).help("移出场景")
                        }.padding(.horizontal, 10).frame(height: Self.rowHeight).modifier(Surface(radius: 11))
                    }
                }
            }.frame(height: viewport)
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.areas, id: \.self) { room in
                        let items = devices(in: room)
                        if !items.isEmpty {
                            Menu(room) { ForEach(items) { device in Button(device.name) { add(device) } } }
                        }
                    }
                } label: {
                    Label("添加设备", systemImage: "plus").font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28)
                }.menuStyle(.borderlessButton).modifier(Surface(radius: 9))
                Button {
                    for step in model.capturableRunning() where !draft.steps.contains(where: { $0.id == step.id }) { draft.steps.append(step) }
                } label: {
                    Label("录制开着的设备", systemImage: "record.circle").font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 28)
                }.buttonStyle(.plain).modifier(Surface(radius: 9))
            }.frame(height: 28)
            HStack(spacing: 8) {
                Button(action: onClose) {
                    Text("取消").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 28)
                }.buttonStyle(.plain).modifier(Surface(radius: 9))
                let valid = !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.steps.isEmpty
                Button {
                    model.saveScene(draft)
                    onClose()
                } label: {
                    Text("保存").font(.system(size: 12, weight: .semibold)).foregroundStyle(valid ? ControlView.onAccent : Color.primary.opacity(0.4))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(valid ? ControlView.accent : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).disabled(!valid)
            }.frame(height: 28)
        }
    }
}
