import AppKit
import SwiftUI
import Darwin
import Security
import CryptoKit
import ServiceManagement
import UserNotifications

// Hold this lease for the application's lifetime. Opening a second copy must
// not create another independent Keychain authorization or refresh loop.
final class ApplicationLease {
    let descriptor: Int32
    init?(runtime: URL) {
        let fd = Darwin.open(runtime.appendingPathComponent("application.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); return nil }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

struct ControlOption: Identifiable { let id: Int; let label: String }
struct RoomReading: Identifiable {
    let id: String
    let name: String
    var power: Bool?
    var target: Double?
    var mode: Int?
    var fan: Int?
    let modes: [ControlOption]
    let fans: [ControlOption]
    let writable: Set<String>
    let minimum: Double
    let maximum: Double
    let step: Double
    let message: String?
    var indoor: Double? = nil
    var humidity: Double? = nil
    var room: String? = nil
    var area: String { room ?? name.replacingOccurrences(of: "空调", with: "") }
}

// A whitelisted MiJia device property, addressed as "service-kind.property-kind".
struct AccessoryProp {
    let address: String
    let format: String
    let readable: Bool
    let writable: Bool
    let range: [Double]?
    let options: [ControlOption]
    var isBool: Bool { format == "bool" }
}

// Lights, curtains, outlets, fans, purifiers and bath heaters in the same MiJia home.
struct Accessory: Identifiable {
    let id: String
    let name: String
    let room: String
    let kind: String
    let group: Bool
    let online: Bool
    let props: [AccessoryProp]
    var values: [String: AnyHashable]

    static let primaryAddress = ["light": "light.on", "outlet": "switch.on", "fan": "fan.on", "air-purifier": "air-purifier.on",
                                 "hood": "hood.on"]
    var primary: String? { Self.primaryAddress[kind].flatMap { address in props.contains { $0.address == address } ? address : nil } }
    var isOn: Bool? {
        if let primary = primary { return values[primary]?.base as? Bool }
        if kind == "bath-heater" {
            let mode = (values["ptc-bath-heater.mode"]?.base as? Double).map { $0 != 0 }
            let vent = values["ptc-bath-heater.ventilation"]?.base as? Bool
            return mode == nil && vent == nil ? nil : (mode ?? false) || (vent ?? false)
        }
        if kind == "curtain" { return (values["curtain.current-position"]?.base as? Double).map { $0 > 0 } }
        return nil
    }
    func prop(_ address: String) -> AccessoryProp? { props.first { $0.address == address } }
    func number(_ address: String) -> Double? { values[address]?.base as? Double }
}

final class AppModel: ObservableObject {
    // The running app's model, used by Shortcuts actions.
    static var shared: AppModel?
    @Published var phase = "idle"
    @Published var message = "请先扫码登录米家"
    @Published var qr: NSImage?
    @Published var rooms: [RoomReading] = []
    @Published var selectedID = UserDefaults.standard.string(forKey: "selectedRoom") ?? ""
    @Published var accessories: [Accessory] = []
    @Published var selectedArea = UserDefaults.standard.string(forKey: "selectedArea") ?? ""
    var scopedReads: [String: Date] = [:]
    @Published var readAt: Date?
    @Published var active = false {
        didSet { if oldValue && !active { DispatchQueue.main.async { [weak self] in self?.workerFinished() } } }
    }
    // Optimistic control state: the UI shows these values immediately. `pending`
    // collects the latest intent per room and field; `inFlight` is being sent.
    @Published var pending: [String: [String: AnyHashable]] = [:]
    // Device id -> changes currently being sent (several devices go out together).
    @Published var inFlight: [String: [String: AnyHashable]]?
    var failedIDs: Set<String>?
    var cancelledRefresh: Process?
    @Published var favorites: [String] = UserDefaults.standard.stringArray(forKey: "favorites") ?? []
    // Flood sensors: polled in the background, notify on change and every 30 minutes while wet.
    @Published var alarms: [Accessory] = []
    var alarmNotices: [String: Date] = [:]
    // Sleep timers (device id -> time to switch off), kept by this app across restarts.
    @Published var timers: [String: Date] = (UserDefaults.standard.dictionary(forKey: "timers") as? [String: Double] ?? [:])
        .mapValues { Date(timeIntervalSince1970: $0) }
    var notifier: (String, String) -> Void = AppModel.postNotification
    var flushWork: DispatchWorkItem?
    @Published var authState = "legacy"
    let runtime: URL
    let worker: URL
    var process: Process?
    var timer: Timer?
    var lastStatus = Data()
    var lastReport = Data()
    var titleChanged: ((String) -> Void)?
    var generation: String?
    var startedAt: Date?
    var sessionData: Data?
    var sessionGeneration: String?
    var automaticRefreshSuspended = false
    var authorizationID: UUID?
    let credentialReader: (String) -> (OSStatus, Data?)
    var keychainReads = 0
    var workerRequests = 0
    var memoryRequests = 0
    var diagnosticEvents: [[String: Any]] = []

    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development" }
    static var defaultRuntime: URL {
        ProcessInfo.processInfo.environment["HITACHI_RUNTIME_PATH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HitachiMenuBar")
    }

    static func readKeychain(account: String) -> (OSStatus, Data?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "HitachiMenuBar.CloudWorker", kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true]
        var result: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &result)
        return (code, result as? Data)
    }

    init(worker: URL, runtime overrideRuntime: URL? = nil,
         credentialReader: @escaping (String) -> (OSStatus, Data?) = AppModel.readKeychain) {
        self.worker = worker
        self.credentialReader = credentialReader
        runtime = overrideRuntime ?? Self.defaultRuntime
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        poll()
        recordDiagnostic("launch")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
    }

    var displayRooms: [RoomReading] { rooms.map(overlaid) }
    var selected: RoomReading? { (rooms.first { $0.id == selectedID } ?? rooms.first).map(overlaid) }

    func overlaid(_ reading: RoomReading) -> RoomReading {
        var room = reading
        var changes = inFlight?[room.id] ?? [:]
        changes.merge(pending[room.id] ?? [:]) { $1 }
        if let value = changes["on"]?.base as? Bool { room.power = value }
        if let value = changes["target-temperature"]?.base as? Double { room.target = value }
        if let value = changes["mode"]?.base as? Int { room.mode = value }
        if let value = changes["fan-level"]?.base as? Int { room.fan = value }
        return room
    }
    var hasDevices: Bool { !rooms.isEmpty || !accessories.isEmpty }

    // Rooms with air conditioners first (in their usual order), then the busiest other rooms.
    var areas: [String] {
        var names: [String] = []
        for room in rooms where !names.contains(room.area) { names.append(room.area) }
        let counts = Dictionary(grouping: accessories, by: \.room).mapValues(\.count)
        for name in counts.keys.sorted(by: { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : $0 < $1 })
            where !names.contains(name) { names.append(name) }
        return names
    }
    var area: String { areas.contains(selectedArea) ? selectedArea : (selected?.area ?? areas.first ?? "") }
    // The air conditioner card shows only when the selected room has one.
    var areaRoom: RoomReading? { rooms.first { $0.area == area }.map(overlaid) }

    static let kindOrder = ["light", "curtain", "bath-heater", "hood", "air-purifier", "fan", "outlet"]
    var areaAccessories: [Accessory] {
        accessories.filter { $0.room == area }.map(overlaid).sorted {
            if $0.group != $1.group { return $0.group }
            let a = Self.kindOrder.firstIndex(of: $0.kind) ?? 9, b = Self.kindOrder.firstIndex(of: $1.kind) ?? 9
            return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func areaActive(_ name: String) -> Bool {
        rooms.contains { $0.area == name && overlaid($0).power == true } ||
            accessories.contains { $0.room == name && $0.kind != "curtain" && overlaid($0).isOn == true }
    }
    func areaTemperature(_ name: String) -> Double? { rooms.first { $0.area == name }?.indoor }

    func selectArea(_ name: String) {
        selectedArea = name
        UserDefaults.standard.set(name, forKey: "selectedArea")
        if let room = rooms.first(where: { $0.area == name }) { selectedID = room.id }
        updateTitle()
        // Accessory states are read per room; refresh a room that has not been read recently.
        if accessories.contains(where: { $0.room == name }), Date().timeIntervalSince(scopedReads[name] ?? .distantPast) > 15 {
            refresh(automatic: true)
        }
    }

    // Keyboard ← / → moves between rooms.
    func stepArea(_ offset: Int) {
        let names = areas
        guard let index = names.firstIndex(of: area), !names.isEmpty else { return }
        selectArea(names[(index + offset + names.count) % names.count])
    }

    func overlaid(_ accessory: Accessory) -> Accessory {
        var item = accessory
        var changes = inFlight?[item.id] ?? [:]
        changes.merge(pending[item.id] ?? [:]) { $1 }
        for (address, value) in changes where address != "curtain.motor-control" { item.values[address] = value }
        return item
    }

    func displayName(_ id: String) -> String? {
        rooms.first { $0.id == id }?.name ?? accessories.first { $0.id == id }?.name
    }

    var busy: Bool { active || ["starting", "authenticating", "awaiting_scan", "reading", "controlling"].contains(phase) }
    var controlling: Bool { active && process?.arguments?.contains("--field") == true }
    var canLogout: Bool { authState == "authenticated" || authState == "pending" || hasDevices }

    static func translated(_ text: String) -> String {
        let map = ["cool": "制冷", "heat": "制热", "dry": "除湿", "fan": "送风", "auto": "自动",
                   "low": "低风", "medium": "中风", "high": "高风"]
        return map[text.lowercased()] ?? text
    }

    func poll(forceStatus: Bool = false) {
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("auth.json")),
           let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            authState = auth["state"] as? String ?? "logged_out"
            generation = auth["generation"] as? String
        }
        let authenticated = authState == "legacy" || authState == "authenticated"
        if !authenticated || sessionGeneration != generation { forgetSession() }
        if !authenticated {
            rooms = []; accessories = []; alarms = []; readAt = nil; selectedID = ""
            if !active && phase != "error" { qr = nil; phase = "logged_out"; message = authState == "pending" ? "上次扫码未完成，请重新登录" : "请扫码登录米家" }
        }
        if let data = try? Data(contentsOf: runtime.appendingPathComponent("status.json")), forceStatus || data != lastStatus,
           let status = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           generation == nil || status["generation"] == generation {
            lastStatus = data
            phase = status["phase"] ?? "error"
            message = status["message"] ?? "未收到连接状态"
            automaticRefreshSuspended = status["reason"] == "keychain_access"
            failedIDs = status["failed"].map { Set($0.split(separator: ",").map(String.init)) }
            qr = active && phase == "awaiting_scan" ? NSImage(contentsOf: runtime.appendingPathComponent("login.png")) : nil
            if !active && ["starting", "authenticating", "reading", "awaiting_scan", "controlling"].contains(phase) {
                phase = authenticated ? "complete" : "logged_out"
                message = authenticated ? "点击刷新，获取最新状态" : "上次扫码未完成，请重新登录"
            }
        }
        if authenticated, let data = try? Data(contentsOf: runtime.appendingPathComponent("report.json")), data != lastReport,
           let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let devices = report["devices"] as? [[String: Any]] {
            lastReport = data
            readAt = (report["read_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            rooms = devices.compactMap { item in
                guard let device = item["device"] as? [String: Any], let did = device["did"] as? String else { return nil }
                let spec = item["spec"] as? [String: Any] ?? [:]
                let states = item["state"] as? [[String: Any]] ?? []
                var properties: [String: [String: Any]] = [:]
                var values: [String: Any] = [:]
                var writable = Set<String>()
                for service in spec["services"] as? [[String: Any]] ?? [] {
                    let siid = service["iid"] as? Int
                    for prop in service["properties"] as? [[String: Any]] ?? [] {
                        guard let type = prop["type"] as? String,
                              let field = ["on", "mode", "target-temperature", "fan-level"].first(where: { type.contains(":\($0):") }),
                              let piid = prop["iid"] as? Int else { continue }
                        properties[field] = prop
                        if let state = states.first(where: { ($0["siid"] as? Int) == siid && ($0["piid"] as? Int) == piid }),
                           (state["code"] as? Int) == 0, let value = state["value"] {
                            values[field] = value
                            if (prop["access"] as? [String] ?? []).contains("write") { writable.insert(field) }
                        }
                    }
                }
                func options(_ field: String) -> [ControlOption] {
                    (properties[field]?["value-list"] as? [[String: Any]] ?? []).compactMap { option in
                        guard let id = option["value"] as? Int else { return nil }
                        return ControlOption(id: id, label: Self.translated(option["description"] as? String ?? "\(id)"))
                    }
                }
                let limits = properties["target-temperature"]?["value-range"] as? [Double] ?? [16, 32, 1]
                return RoomReading(id: did, name: device["name"] as? String ?? "空调",
                    power: values["on"] as? Bool, target: values["target-temperature"] as? Double,
                    mode: values["mode"] as? Int, fan: values["fan-level"] as? Int,
                    modes: options("mode"), fans: options("fan-level"), writable: writable,
                    minimum: limits[0], maximum: limits[1], step: limits[2], message: item["message"] as? String,
                    indoor: (item["climate"] as? [String: Any])?["temperature"] as? Double,
                    humidity: (item["climate"] as? [String: Any])?["humidity"] as? Double,
                    room: item["room"] as? String)
            }
            accessories = (report["accessories"] as? [[String: Any]] ?? []).compactMap(Self.accessory)
            alarms = (report["alarms"] as? [[String: Any]] ?? []).compactMap(Self.accessory)
            evaluateAlarms()
            if !rooms.contains(where: { $0.id == selectedID }) { selectedID = rooms.first?.id ?? "" }
        }
        if let room = rooms.first(where: { $0.area == area }), room.id != selectedID { selectedID = room.id }
        UserDefaults.standard.set(selectedID, forKey: "selectedRoom")
        checkTimers()
        if active && phase == "authenticating", let startedAt = startedAt, Date().timeIntervalSince(startedAt) > 12 {
            message = "请允许系统钥匙串访问，或从设置重新扫码登录"
        }
        updateTitle()
    }

    static func accessory(_ item: [String: Any]) -> Accessory? {
        guard let device = item["device"] as? [String: Any], let did = device["did"] as? String,
              let kind = item["kind"] as? String else { return nil }
        let props: [AccessoryProp] = (item["props"] as? [[String: Any]] ?? []).compactMap { prop in
            guard let address = prop["address"] as? String else { return nil }
            let options = (prop["options"] as? [[String: Any]] ?? []).compactMap { option -> ControlOption? in
                guard let value = option["value"] as? Int else { return nil }
                return ControlOption(id: value, label: Self.optionLabel(option["description"] as? String ?? "\(value)"))
            }
            return AccessoryProp(address: address, format: prop["format"] as? String ?? "",
                                 readable: prop["readable"] as? Bool ?? false, writable: prop["writable"] as? Bool ?? false,
                                 range: (prop["range"] as? [NSNumber])?.map(\.doubleValue), options: options)
        }
        var values: [String: AnyHashable] = [:]
        for (address, raw) in item["state"] as? [String: Any] ?? [:] {
            guard let prop = props.first(where: { $0.address == address }), let number = raw as? NSNumber else { continue }
            values[address] = prop.isBool ? AnyHashable(number.boolValue) : AnyHashable(number.doubleValue)
        }
        return Accessory(id: did, name: device["name"] as? String ?? "设备", room: item["room"] as? String ?? "其他",
                         kind: kind, group: item["group"] as? Bool ?? false, online: device["isOnline"] as? Bool ?? true,
                         props: props, values: values)
    }

    static func optionLabel(_ text: String) -> String {
        let map = ["idle": "待机", "fan": "吹风", "heat": "暖风", "dry": "干燥", "defog": "除雾", "disinfect": "消毒",
                   "auto": "自动", "sleep": "睡眠", "strong": "强力", "none": "手动", "low": "低", "medium": "中",
                   "high": "高", "quiet": "静音", "straight wind": "直吹风", "natural wind": "自然风",
                   "level1": "1 档", "level2": "2 档", "level3": "3 档", "level4": "4 档",
                   "open": "打开", "close": "关闭", "pause": "暂停", "turbo": "爆炒"]
        return map[text.lowercased()] ?? text
    }

    func updateTitle() {
        if !wetAlarms.isEmpty { titleChanged?(" ⚠︎ 漏水"); return }
        if let room = selected, let temp = room.target {
            titleChanged?(room.power == true ? " \(Int(temp))°" : " 米家")
        } else { titleChanged?(" 米家") }
    }

    func run(arguments: [String], label: String) {
        guard !busy else { return }
        poll()
        guard !busy else { return }
        if arguments.contains("--login") || arguments.contains("--logout") || sessionData != nil ||
            (authState != "authenticated" && authState != "legacy") {
            launchWorker(arguments: arguments, label: label)
            return
        }
        guard let auth = authenticationSnapshot(createLegacy: authState == "legacy"),
              auth["state"] as? String == "authenticated",
              let id = auth["generation"] as? String, let account = auth["account"] as? String else {
            pauseAuthorization(code: errSecDecode)
            return
        }
        generation = id; authState = "authenticated"
        active = true; phase = "authenticating"; startedAt = Date()
        message = "正在读取钥匙串中的登录会话…"
        let request = UUID()
        authorizationID = request
        keychainReads += 1
        recordDiagnostic("keychain_read")
        let reader = credentialReader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (code, data) = reader(account)
            DispatchQueue.main.async {
                guard let self = self, self.authorizationID == request else { return }
                self.authorizationID = nil
                self.recordDiagnostic("keychain_result", code: code)
                self.poll()
                guard self.generation == id, self.authState == "authenticated" else {
                    self.active = false
                    self.phase = self.authState == "authenticated" ? "complete" : "logged_out"
                    self.message = "登录状态已变化，请手动刷新或重新登录"
                    return
                }
                if code == errSecItemNotFound {
                    _ = self.invalidateSession()
                    self.message = "登录会话不存在，请重新扫码登录"
                    return
                }
                guard code == errSecSuccess, let data = data,
                      let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let envelope = try? JSONSerialization.data(withJSONObject: ["generation": id, "session": session]) else {
                    self.pauseAuthorization(code: code == errSecSuccess ? errSecDecode : code)
                    return
                }
                self.rememberSession(envelope)
                guard self.sessionData != nil, self.sessionGeneration == id else {
                    self.pauseAuthorization(code: errSecDecode)
                    return
                }
                self.launchWorker(arguments: arguments, label: label)
            }
        }
    }

    // File locks protect login generations, but are released before a system
    // authorization dialog can block. Never resurrect a revoked login here.
    func authenticationSnapshot(createLegacy: Bool = false) -> [String: Any]? {
        let fd = Darwin.open(runtime.appendingPathComponent("auth.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return nil }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return nil }
        let url = runtime.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        guard createLegacy else { return nil }
        let auth: [String: Any] = ["generation": UUID().uuidString, "state": "authenticated", "account": "session"]
        guard let data = try? JSONSerialization.data(withJSONObject: auth),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return auth
    }

    func pauseAuthorization(code: OSStatus) {
        active = false; automaticRefreshSuspended = true; phase = "error"
        message = "钥匙串访问未完成，自动刷新已暂停；请手动刷新或重新登录"
        recordDiagnostic("authorization_paused", code: code)
        let fd = Darwin.open(runtime.appendingPathComponent("auth.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0,
              let data = try? Data(contentsOf: runtime.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = generation, auth["generation"] as? String == id else { return }
        let status = ["generation": id, "phase": "error", "message": message, "reason": "keychain_access"]
        if let data = try? JSONSerialization.data(withJSONObject: status) {
            try? data.write(to: runtime.appendingPathComponent("status.json"), options: .atomic)
            lastStatus = data
        }
    }

    func launchWorker(arguments: [String], label: String) {
        active = true
        startedAt = Date()
        phase = "starting"
        message = label
        automaticRefreshSuspended = false
        let task = Process()
        task.executableURL = worker
        let session = sessionGeneration == generation ? sessionData : nil
        task.arguments = arguments + ["--session-output", "--require-session"] + (session == nil ? [] : ["--session-stdin"])
        workerRequests += 1
        if session != nil { memoryRequests += 1 }
        recordDiagnostic(session == nil ? "worker_without_session" : "worker_memory_session")
        var environment = ProcessInfo.processInfo.environment
        environment["HITACHI_RUNTIME_PATH"] = runtime.path
        if let generation = generation { environment["HITACHI_AUTH_GENERATION"] = generation }
        task.environment = environment
        let output = Pipe()
        let input = session == nil ? nil : Pipe()
        task.standardOutput = output
        if let input = input { task.standardInput = input }
        else { task.standardInput = FileHandle.nullDevice }
        task.standardError = FileHandle.nullDevice
        let previous = lastStatus
        task.terminationHandler = { [weak self] process in
            let payload = output.fileHandleForReading.readDataToEndOfFile()
            try? output.fileHandleForReading.close()
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.process === process else { return }
                self.rememberSession(payload)
                if self.cancelledRefresh === process {
                    // A read-only refresh stopped so that a tap can go out right away.
                    self.cancelledRefresh = nil
                    self.phase = "complete"; self.message = "设备状态已更新"
                    self.active = false
                    return
                }
                self.active = false
                self.poll(forceStatus: true)
                if (process.terminationStatus != 0 && self.lastStatus == previous && self.phase != "error") || self.busy {
                    self.phase = "error"
                    self.message = "云端连接未完成，请刷新或重新扫码登录。"
                }
            }
        }
        process = task
        do {
            try task.run()
            try? output.fileHandleForWriting.close()
            if let input = input, let session = session {
                try? input.fileHandleForReading.close()
                try input.fileHandleForWriting.write(contentsOf: session)
                try input.fileHandleForWriting.close()
            }
        } catch {
            try? output.fileHandleForWriting.close()
            try? input?.fileHandleForWriting.close()
            if task.isRunning { task.terminate() }
            process = nil; active = false; phase = "error"; message = "无法启动连接工具，请重新打开应用。"
        }
    }

    func forgetSession() { sessionData = nil; sessionGeneration = nil }

    var diagnosticSummary: String {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let value: [String: Any] = ["version": Self.version, "architecture": architecture,
            "process_id": ProcessInfo.processInfo.processIdentifier,
            "keychain_reads": keychainReads, "worker_requests": workerRequests,
            "memory_requests": memoryRequests, "phase": phase, "auth_state": authState,
            "events": diagnosticEvents]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func recordDiagnostic(_ event: String, code: OSStatus? = nil) {
        var entry: [String: Any] = ["time": Date().timeIntervalSince1970, "event": event]
        if let code = code { entry["code"] = code }
        diagnosticEvents.append(entry)
        diagnosticEvents = Array(diagnosticEvents.suffix(24))
        // Only fixed event names and numeric OSStatus values are recorded.
        // No account, generation, arguments, URLs, or credentials are included.
        try? Data(diagnosticSummary.utf8).write(to: runtime.appendingPathComponent("diagnostics.json"), options: .atomic)
    }

    func rememberSession(_ payload: Data) {
        guard let envelope = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = envelope["generation"] as? String,
              let session = envelope["session"] as? [String: String],
              ["user_id", "ssecurity", "service_token"].allSatisfy({ session[$0]?.isEmpty == false }),
              let marker = try? Data(contentsOf: runtime.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: marker) as? [String: Any],
              auth["state"] as? String == "authenticated", auth["generation"] as? String == id,
              let encoded = try? JSONSerialization.data(withJSONObject: session) else { return }
        sessionGeneration = id
        sessionData = encoded
    }

    // Persist revocation before launching any asynchronous worker. This also
    // invalidates a cancelled QR login if the app exits immediately afterwards.
    func invalidateSession() -> Bool {
        guard !controlling else { return false }
        let previousProcess = process
        flushWork?.cancel(); flushWork = nil
        pending = [:]; inFlight = nil; accessories = []; alarms = []; alarmNotices = [:]
        authorizationID = nil
        process = nil
        active = false
        if previousProcess?.isRunning == true { previousProcess?.terminate() }
        forgetSession()
        recordDiagnostic("session_revoked")
        let fd = Darwin.open(runtime.appendingPathComponent("auth.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { phase = "error"; message = "无法清理登录状态，请重试"; return false }
        defer { flock(fd, LOCK_UN); Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return false }
        let url = runtime.appendingPathComponent("auth.json")
        let previous = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var retired = Set(previous["retired_accounts"] as? [String] ?? [])
        retired.insert(previous["account"] as? String ?? "session")
        let next = UUID().uuidString
        let auth: [String: Any] = ["generation": next, "state": "logged_out", "retired_accounts": Array(retired).sorted()]
        do {
            let data = try JSONSerialization.data(withJSONObject: auth)
            try data.write(to: url, options: .atomic)
            for name in ["report.json", "devices.json", "status.json", "login.png"] {
                let file = runtime.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
        } catch { phase = "error"; message = "无法清理登录状态，请重试"; return false }
        generation = next; authState = "logged_out"
        active = false; phase = "logged_out"; qr = nil
        rooms = []; readAt = nil; selectedID = ""
        lastReport = Data(); lastStatus = Data()
        UserDefaults.standard.removeObject(forKey: "selectedRoom")
        titleChanged?(" 米家")
        return true
    }

    func login() {
        guard invalidateSession() else { return }
        run(arguments: ["--login"], label: "正在生成登录二维码…")
    }
    func logout() {
        guard invalidateSession() else { return }
        run(arguments: ["--logout"], label: "正在退出登录…")
    }
    func refresh(automatic: Bool = false) {
        guard !automatic || (!automaticRefreshSuspended && pending.isEmpty && inFlight == nil) else { return }
        guard hasDevices else { run(arguments: [], label: "正在刷新状态…"); return }
        // Air conditioners and thermometers are always read; accessories only for the room on screen.
        let scope = area
        guard !busy else { return }
        run(arguments: ["--refresh"] + (scope.isEmpty ? [] : ["--scope", scope]), label: "正在刷新状态…")
        if active { scopedReads[scope] = Date() }
    }
    func resync() { run(arguments: [], label: "正在同步房间列表…") }
    // Record the intent immediately; repeated taps replace the queued value
    // instead of being dropped while an earlier command is still running.
    func set(_ field: String, value: AnyHashable, delay: TimeInterval = 0.05) {
        guard let room = selected else { return }
        setClimate(room.id, field, value: value, delay: delay)
    }

    // Any air conditioner by id (the panel uses the selected one; Shortcuts may name another).
    func setClimate(_ id: String, _ field: String, value: AnyHashable, delay: TimeInterval = 0.05) {
        guard let room = rooms.first(where: { $0.id == id }), room.writable.contains(field) else { return }
        var changes = pending[room.id] ?? [:]
        let reported = rooms.first { $0.id == room.id }.map(reportedValue(field)) ?? nil
        if inFlight?[room.id]?[field] == nil, reported == value {
            changes[field] = nil
        } else {
            changes[field] = value
        }
        pending[room.id] = changes.isEmpty ? nil : changes
        updateTitle()
        scheduleFlush(after: delay)
    }

    // Accessories share the optimistic queue with air conditioners, keyed by device id.
    func setAccessory(_ id: String, _ address: String, value: AnyHashable, delay: TimeInterval = 0.05) {
        guard let item = accessories.first(where: { $0.id == id }), item.online,
              item.prop(address)?.writable == true else { return }
        var changes = pending[id] ?? [:]
        let reported = item.values[address]
        let action = address == "curtain.motor-control"
        if !action, inFlight?[id]?[address] == nil, reported == value {
            changes[address] = nil
        } else {
            changes[address] = value
        }
        pending[id] = changes.isEmpty ? nil : changes
        scheduleFlush(after: delay)
    }

    func reportedValue(_ field: String) -> (RoomReading) -> AnyHashable? {
        { room in
            switch field {
            case "on": return room.power.map(AnyHashable.init)
            case "target-temperature": return room.target.map(AnyHashable.init)
            case "mode": return room.mode.map(AnyHashable.init)
            default: return room.fan.map(AnyHashable.init)
            }
        }
    }

    func scheduleFlush(after delay: TimeInterval) {
        cancelRefresh()
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // A running refresh only reads; stop it so a tap does not wait up to a second behind it.
    func cancelRefresh() {
        guard let task = process, task.isRunning, cancelledRefresh == nil,
              let arguments = task.arguments, arguments.contains("--refresh") || arguments.contains("--alarms"),
              !arguments.contains("--field"), !arguments.contains("--batch") else { return }
        cancelledRefresh = task
        task.terminate()
    }

    static func json(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func flush() {
        flushWork = nil
        guard inFlight == nil, !busy, !pending.isEmpty else { return }
        let batch = pending.filter { displayName($0.key) != nil }
        pending = [:]
        guard !batch.isEmpty else { return }
        var arguments: [String]
        if batch.count == 1, let (id, changes) = batch.first {
            arguments = ["--room", id]
            let order = ["on", "mode", "target-temperature", "fan-level"]
            for field in order + changes.keys.filter({ !order.contains($0) }).sorted() {
                guard let value = changes[field], let json = Self.json(value.base) else { continue }
                arguments += ["--field", field, "--value", json]
            }
        } else {
            // Several devices (e.g. turning everything off) are controlled in one parallel run.
            guard let json = Self.json(batch.mapValues { $0.mapValues(\.base) }) else { return }
            arguments = ["--batch", json]
        }
        inFlight = batch
        failedIDs = nil
        let label = batch.count == 1 ? "正在同步到\(displayName(batch.keys.first!) ?? "设备")…" : "正在同步 \(batch.count) 个设备…"
        run(arguments: arguments, label: label)
        if !active { workerFinished() }
    }

    // Success keeps the cloud reading; failure drops the optimistic values so
    // the panel returns to the last confirmed state. Newer intents still go out.
    func workerFinished() {
        guard !active else { return }
        if let batch = inFlight {
            inFlight = nil
            if phase != "complete" {
                // The worker names the devices that failed; otherwise treat the whole batch as failed.
                let failed = failedIDs ?? Set(batch.keys)
                for id in failed {
                    guard let sent = batch[id] else { continue }
                    pending[id] = pending[id]?.filter { sent[$0.key] == nil || $0.value != sent[$0.key] }
                    if pending[id]?.isEmpty == true { pending[id] = nil }
                }
                if failed.count == 1, let name = displayName(failed.first!), !message.contains(name) {
                    message = "\(name)未调整成功，已恢复原状态：\(message)"
                } else if failed.count > 1, !message.contains("已恢复") {
                    message = "\(failed.count) 个设备未调整成功，已恢复原状态：\(message)"
                }
            }
            updateTitle()
        }
        if !pending.isEmpty { scheduleFlush(after: 0.05) }
    }

    // MARK: Turn everything off

    // Lights, fans, purifiers, bath heaters and air conditioners; never outlets or curtains.
    func offChanges(_ item: Accessory, includeOutlet: Bool = false) -> [String: AnyHashable] {
        guard item.online else { return [:] }
        var changes: [String: AnyHashable] = [:]
        if includeOutlet, item.kind == "outlet", item.values["switch.on"]?.base as? Bool == true { return ["switch.on": false] }
        for address in ["hood.on", "light.on", "fan.on", "air-purifier.on"] where item.prop(address)?.writable == true {
            if item.values[address]?.base as? Bool == true { changes[address] = false }
        }
        if item.prop("ptc-bath-heater.mode")?.writable == true, let mode = item.number("ptc-bath-heater.mode"), mode != 0 {
            changes["ptc-bath-heater.mode"] = 0.0
        }
        if item.prop("ptc-bath-heater.ventilation")?.writable == true, item.values["ptc-bath-heater.ventilation"]?.base as? Bool == true {
            changes["ptc-bath-heater.ventilation"] = false
        }
        return item.kind == "outlet" || item.kind == "curtain" ? [:] : changes
    }

    func offTargets(_ name: String?) -> [String: [String: AnyHashable]] {
        var targets: [String: [String: AnyHashable]] = [:]
        for room in rooms where name == nil || room.area == name {
            if overlaid(room).power == true, room.writable.contains("on") { targets[room.id] = ["on": false] }
        }
        for item in accessories where name == nil || item.room == name {
            let changes = offChanges(overlaid(item))
            if !changes.isEmpty { targets[item.id] = changes }
        }
        return targets
    }

    @discardableResult
    func turnOff(area name: String?) -> Int {
        let targets = offTargets(name)
        for (id, changes) in targets { pending[id, default: [:]].merge(changes) { $1 } }
        if !targets.isEmpty { updateTitle(); scheduleFlush(after: 0.05) }
        return targets.count
    }

    // MARK: Flood alarms

    static let wetAddress = "submersion-sensor.submersion-state"
    var wetAlarms: [Accessory] { alarms.filter { $0.values[Self.wetAddress]?.base as? Bool == true } }

    func evaluateAlarms(now: Date = Date()) {
        for sensor in alarms {
            guard let wet = sensor.values[Self.wetAddress]?.base as? Bool else { continue }
            let place = "\(sensor.room) · \(sensor.name)"
            if wet {
                if let last = alarmNotices[sensor.id], now.timeIntervalSince(last) < 30 * 60 { continue }
                notifier("检测到漏水", "\(place) 检测到漏水，请尽快查看。")
                alarmNotices[sensor.id] = now
            } else if alarmNotices.removeValue(forKey: sensor.id) != nil {
                notifier("漏水已恢复", "\(place) 已恢复正常。")
            }
        }
        updateTitle()
    }

    // A tiny background read; the normal refresh already includes the sensors.
    func checkAlarms() {
        guard !alarms.isEmpty, !busy, !automaticRefreshSuspended, pending.isEmpty, inFlight == nil else { return }
        run(arguments: ["--alarms"], label: message)
    }

    // Only a real app bundle may use the notification centre (tests run as a bare executable).
    static var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    static func requestNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postNotification(_ title: String, _ body: String) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Sleep timers

    static func timerEligible(_ item: Accessory) -> Bool {
        item.kind != "curtain" && ["hood.on", "light.on", "fan.on", "air-purifier.on", "switch.on", "ptc-bath-heater.mode"]
            .contains { item.prop($0)?.writable == true }
    }

    func setTimer(_ id: String, hours: Double, now: Date = Date()) {
        timers[id] = now.addingTimeInterval(hours * 3600)
        saveTimers()
    }
    func cancelTimer(_ id: String) {
        timers[id] = nil
        saveTimers()
    }
    func saveTimers() {
        UserDefaults.standard.set(timers.mapValues(\.timeIntervalSince1970), forKey: "timers")
    }

    // Runs every second from poll(). A timer missed by more than two hours (Mac asleep or the
    // app closed) is dropped instead of switching things off long after it was meant to.
    func checkTimers(now: Date = Date()) {
        guard hasDevices else { return }
        var fired: [String] = []
        for (id, due) in timers where due <= now {
            timers[id] = nil
            guard now.timeIntervalSince(due) < 2 * 3600 else { continue }
            var changes: [String: AnyHashable] = [:]
            if let room = rooms.first(where: { $0.id == id }), overlaid(room).power == true { changes = ["on": false] }
            if let item = accessories.first(where: { $0.id == id }) { changes = offChanges(overlaid(item), includeOutlet: true) }
            guard !changes.isEmpty else { continue }
            pending[id, default: [:]].merge(changes) { $1 }
            fired.append(displayName(id) ?? "设备")
        }
        guard !fired.isEmpty || timers.count != (UserDefaults.standard.dictionary(forKey: "timers")?.count ?? 0) else { return }
        saveTimers()
        if !fired.isEmpty {
            notifier("定时关闭", "已关闭 " + fired.joined(separator: "、"))
            updateTitle()
            scheduleFlush(after: 0.05)
        }
    }

    static func remaining(_ due: Date, now: Date = Date()) -> String {
        let minutes = Int(ceil(due.timeIntervalSince(now) / 60))
        return minutes <= 1 ? "即将关闭" : String(format: "%d:%02d 后关闭", minutes / 60, minutes % 60)
    }

    // MARK: Favourites

    var favoriteAccessories: [Accessory] {
        favorites.compactMap { id in accessories.first { $0.id == id }.map(overlaid) }
    }
    func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.removeAll { $0 == id } } else { favorites.append(id) }
        UserDefaults.standard.set(favorites, forKey: "favorites")
    }
    // One click on a favourite: switch it, or open / close a curtain.
    func quickToggle(_ item: Accessory) {
        if let primary = item.primary {
            setAccessory(item.id, primary, value: !(item.values[primary]?.base as? Bool ?? false))
        } else if item.kind == "curtain" {
            let open = (item.number("curtain.current-position") ?? 0) > 0
            setAccessory(item.id, "curtain.motor-control", value: open ? 2.0 : 1.0)
        } else if item.prop("light.on")?.writable == true {
            setAccessory(item.id, "light.on", value: !(item.values["light.on"]?.base as? Bool ?? false))
        }
    }
}

// Launch at login and in-app updates from the project's GitHub releases.
final class Updater: ObservableObject {
    static let shared = Updater()
    static let repository = "VUVUDOG/MijiaMenuBar"
    #if arch(arm64)
    static let assetSuffix = "arm64"
    #else
    static let assetSuffix = "intel"
    #endif

    @Published var latest: String?
    @Published var state = "idle"   // idle, checking, downloading, installing
    @Published var note: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var asset: URL?
    var checksums: URL?
    var timer: Timer?
    var noteWork: DispatchWorkItem?

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parse = { (text: String) in text.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parse(candidate), b = parse(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // The release page redirect (…/releases/latest → …/releases/tag/vX.Y.Z) is not
    // subject to the 60-requests-per-hour API limit shared by everyone behind one IP.
    // Test hook: HITACHI_UPDATE_BASE points at a local mirror of that layout, and
    // HITACHI_UPDATE_INSTALL=1 installs whatever it finds. Unset for normal users.
    static let base = ProcessInfo.processInfo.environment["HITACHI_UPDATE_BASE"]
        ?? "https://github.com/\(repository)"

    func start() {
        check(manual: false)
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in self?.check(manual: false) }
    }

    func show(_ text: String?, for seconds: TimeInterval? = nil) {
        noteWork?.cancel()
        note = text
        guard let seconds = seconds else { return }
        let work = DispatchWorkItem { [weak self] in self?.note = nil }
        noteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("开机自动启动设置未成功，请在系统设置的“登录项”中调整", for: 6)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if enabled && SMAppService.mainApp.status == .requiresApproval {
            show("请在系统设置的“登录项”中允许米家", for: 6)
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func check(manual: Bool) {
        guard state == "idle" else { return }
        state = "checking"
        if manual { show("正在检查更新…") }
        var request = URLRequest(url: URL(string: Self.base + "/releases/latest")!)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let final = response as? HTTPURLResponse
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.state = "idle"
                guard final?.statusCode == 200, let url = final?.url,
                      url.deletingLastPathComponent().lastPathComponent == "tag",
                      url.lastPathComponent.hasPrefix("v") else {
                    if manual { self.show("检查更新失败，请稍后再试", for: 5) }
                    return
                }
                let tag = url.lastPathComponent
                let version = String(tag.dropFirst())
                if Self.isNewer(version, than: AppModel.version) {
                    let download = Self.base + "/releases/download/" + tag + "/"
                    self.latest = version
                    self.asset = URL(string: download + "MijiaMenuBar-\(version)-\(Self.assetSuffix).zip")
                    self.checksums = URL(string: download + "SHA256SUMS.txt")
                    if manual { self.show(nil) }
                    if ProcessInfo.processInfo.environment["HITACHI_UPDATE_INSTALL"] == "1" { self.install() }
                } else {
                    self.latest = nil
                    if manual { self.show("已是最新版本 \(AppModel.version)", for: 4) }
                }
            }
        }.resume()
    }

    func install() {
        guard state == "idle", let version = latest, let asset = asset, let checksums = checksums else {
            if latest != nil { show("新版本缺少校验文件，已取消更新", for: 6) }
            return
        }
        state = "downloading"
        show("正在下载 \(version)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Self.prepare(asset: asset, checksums: checksums, version: version) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let app):
                    self.state = "installing"
                    self.show("正在安装并重新打开…")
                    do { try Self.replaceAndRelaunch(with: app) } catch {
                        self.state = "idle"
                        self.show("安装未完成：\(error.localizedDescription)", for: 8)
                    }
                case .failure(let error):
                    self.state = "idle"
                    self.show("更新未完成：\(error.localizedDescription)", for: 8)
                }
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    static func fetch(_ url: URL) throws -> Data {
        var result: Result<Data, Error> = .failure(UpdateError("下载超时"))
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data = data, (response as? HTTPURLResponse)?.statusCode == 200 { result = .success(data) }
            else { result = .failure(error ?? UpdateError("下载失败")) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 180)
        return try result.get()
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // Download, verify the published SHA-256, unpack and check the bundle before touching the installed app.
    static func prepare(asset: URL, checksums: URL, version: String) throws -> URL {
        let archive = try fetch(asset)
        let sums = String(decoding: try fetch(checksums), as: UTF8.self)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        let expected = sums.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts.last.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) }) == asset.lastPathComponent else { return nil }
            return String(parts[0]).lowercased()
        }.first
        guard expected == digest else { throw UpdateError("安装包校验未通过") }
        let installed = Bundle.main.bundleURL
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: installed, create: true)
        let zip = staging.appendingPathComponent(asset.lastPathComponent)
        try archive.write(to: zip)
        guard try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path]) == 0 else { throw UpdateError("无法解压安装包") }
        let app = staging.appendingPathComponent("MijiaMenuBar.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else { throw UpdateError("安装包内容与版本不符") }
        guard try run("/usr/bin/codesign", ["--verify", "--deep", app.path]) == 0 else { throw UpdateError("安装包签名校验未通过") }
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    // Swap the bundle in place, then reopen it once this process has exited (the
    // single-instance lease would otherwise make the new copy quit immediately).
    static func replaceAndRelaunch(with app: URL) throws {
        let installed = Bundle.main.bundleURL
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: app)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\" --args --show",
                              "relaunch", String(ProcessInfo.processInfo.processIdentifier), installed.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }
}

extension Color {
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

// Light / dark / follow macOS. Applied app-wide so the panel, glass and menus all match.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    static let choices: [(id: String, label: String)] = [("system", "跟随系统"), ("light", "浅色"), ("dark", "深色")]
    @Published var appearance: String {
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); apply() }
    }
    init() {
        let saved = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        appearance = Self.choices.contains { $0.id == saved } ? saved : "system"
    }
    static func nsAppearance(_ id: String) -> NSAppearance? {
        switch id {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil   // follow the system, including automatic day / night switching
        }
    }
    func apply() { NSApp?.appearance = Self.nsAppearance(appearance) }
}

struct Surface: ViewModifier {
    var selected = false
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content.background(selected ? ControlView.accent.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(selected ? ControlView.accent.opacity(0.32) : Color.primary.opacity(0.065), lineWidth: 1))
    }
}

struct QuietIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(Color.primary.opacity(0.8))
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.045), in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct ControlView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updater = Updater.shared
    @ObservedObject var preferences = Preferences.shared
    @State private var detailID: String?
    @State private var climateExpanded = false
    @State private var confirmOffAll = false
    static let accent = Color.adaptive(light: NSColor(red: 0.04, green: 0.53, blue: 0.46, alpha: 1),
                                       dark: NSColor(red: 0.45, green: 0.84, blue: 0.77, alpha: 1))
    // Text on an accent-filled button.
    static let onAccent = Color.adaptive(light: .white, dark: NSColor(red: 0.07, green: 0.16, blue: 0.14, alpha: 1))
    static let alarm = Color.adaptive(light: NSColor(red: 0.78, green: 0.13, blue: 0.1, alpha: 1),
                                      dark: NSColor(red: 1, green: 0.55, blue: 0.5, alpha: 1))

    func roomIcon(_ name: String) -> String {
        if name.contains("卧") { return "bed.double" }
        if name.contains("书") { return "desktopcomputer" }
        if name.contains("厨") || name.contains("餐") { return symbol("fork.knife", fallback: "house") }
        if name.contains("卫") || name.contains("浴") { return symbol("shower", fallback: "drop") }
        if name.contains("阳台") { return symbol("sun.horizon", fallback: "sun.max") }
        if name.contains("走廊") || name.contains("玄关") { return symbol("door.left.hand.closed", fallback: "house") }
        return "sofa"
    }
    func modeIcon(_ label: String) -> String {
        ["自动": "arrow.triangle.2.circlepath", "制冷": "snowflake", "除湿": "drop", "送风": "wind", "制热": "sun.max"][label] ?? "air.conditioner.horizontal"
    }

    var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "house.fill").font(.system(size: 17))
                .foregroundStyle(Self.accent).frame(width: 38, height: 38)
                .background(Self.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text("米家").font(.system(size: 16, weight: .semibold))
                Text(!model.hasDevices ? "让舒适触手可及" : "\(model.areas.count) 个房间 · 空调 \(model.displayRooms.filter { $0.power == true }.count) 台 · \(model.accessories.map(model.overlaid).filter { $0.kind != "curtain" && $0.isOn == true }.count) 个设备开着")
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasDevices {
                let count = model.offTargets(nil).count
                Button {
                    if confirmOffAll {
                        confirmOffAll = false
                        model.turnOff(area: nil)
                    } else {
                        confirmOffAll = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmOffAll = false }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                        if confirmOffAll { Text("确认全关 \(count) 个").font(.system(size: 11, weight: .semibold)) }
                    }.foregroundStyle(confirmOffAll ? Color.orange : Color.primary.opacity(count > 0 ? 0.65 : 0.25))
                        .frame(minWidth: 34, minHeight: 34).padding(.horizontal, confirmOffAll ? 10 : 0)
                        .background((confirmOffAll ? Color.orange.opacity(0.14) : Color.primary.opacity(0.045)), in: Capsule())
                }.buttonStyle(.plain).disabled(count == 0)
                    .help(count > 0 ? "全屋全关：灯、风扇、净化器、浴霸和空调（不含插座、窗帘）" : "没有开着的设备")
                    .accessibilityLabel("全屋全关")
            }
            Menu {
                Button("同步房间") { model.resync() }.disabled(model.busy || (!model.hasDevices && model.authState != "authenticated"))
                Button(!model.hasDevices ? "扫码登录米家" : "重新登录米家") { model.login() }.disabled(model.controlling)
                Divider()
                Button("退出登录") { model.logout() }.disabled(model.controlling || !model.canLogout)
                Divider()
                Picker("外观", selection: Binding(get: { preferences.appearance }, set: { preferences.appearance = $0 })) {
                    ForEach(Preferences.choices, id: \.id) { choice in Text(choice.label).tag(choice.id) }
                }
                Toggle("开机自动启动", isOn: Binding(get: { updater.launchAtLogin }, set: { updater.setLaunchAtLogin($0) }))
                Button(updater.latest.map { "更新到 \($0)" } ?? "检查更新") {
                    if updater.latest != nil { updater.install() } else { updater.check(manual: true) }
                }.disabled(updater.state != "idle")
                Text("版本 \(AppModel.version)")
                Button("复制诊断信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.diagnosticSummary, forType: .string)
                }
                Divider()
                Button("退出应用") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.65)).frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.045), in: Circle())
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("设置")
        }
    }

    // MARK: Layout constants (fixed heights keep the scroll area's size exact)

    static let tileHeight: CGFloat = 52
    static let gridSpacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 12

    static func pairs(_ items: [Accessory]) -> [[Accessory]] {
        stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
    }

    static func gridHeight(_ items: [Accessory], detail: String?) -> CGFloat {
        guard !items.isEmpty else { return 0 }
        let rows = CGFloat(pairs(items).count)
        var height = rows * tileHeight + (rows - 1) * gridSpacing
        if let id = detail, let item = items.first(where: { $0.id == id }), item.online {
            height += gridSpacing + AccessoryDetail.height(item)
        }
        return height
    }

    static func climateHeight(_ room: RoomReading, expanded: Bool) -> CGFloat {
        var height: CGFloat = 32 + 20
        if room.indoor != nil { height += 6 + 14 }
        if expanded {
            var parts: [CGFloat] = []
            if !room.modes.isEmpty { parts.append(44) }
            if !room.fans.isEmpty { parts.append(28) }
            if room.writable.contains("on") { parts.append(TimerRow.height) }
            height += 4 + 6 + parts.reduce(0, +) + CGFloat(max(parts.count - 1, 0)) * 8
        }
        return height
    }

    // MARK: Favourites

    var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("常用").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(height: 12)
            tileGrid(model.favoriteAccessories, favorites: true)
        }
    }
    var favoritesHeight: CGFloat {
        let items = model.favoriteAccessories
        return items.isEmpty ? 0 : 12 + 6 + Self.gridHeight(items, detail: nil)
    }

    // MARK: Rooms — every room visible at once (one row, or two when there are many)

    static let roomChipHeight: CGFloat = 28
    static func roomColumns(_ count: Int) -> Int { count <= 7 ? max(count, 1) : min(5, (count + 1) / 2) }
    static func roomRowsHeight(_ count: Int) -> CGFloat {
        let rows = CGFloat((count + roomColumns(count) - 1) / max(roomColumns(count), 1))
        return rows * roomChipHeight + max(rows - 1, 0) * 6
    }

    var roomTabs: some View {
        let names = model.areas
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: Self.roomColumns(names.count)), spacing: 6) {
            ForEach(names, id: \.self) { name in
                let selected = model.area == name
                Button { model.selectArea(name) } label: {
                    Text(name).font(.system(size: 11.5, weight: selected ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(selected ? Self.accent : Color.primary.opacity(0.72))
                        .frame(maxWidth: .infinity).frame(height: Self.roomChipHeight)
                        .modifier(Surface(selected: selected, radius: 9))
                        .overlay(alignment: .topTrailing) {
                            if model.areaActive(name) {
                                Circle().fill(Self.accent).frame(width: 5, height: 5).padding(4)
                            }
                        }
                }.buttonStyle(.plain)
                    .help(model.areaTemperature(name).map { "\(name) · 室温 " + String(format: "%.1f°", $0) } ?? name)
            }
        }.frame(height: Self.roomRowsHeight(names.count))
    }

    // MARK: Air conditioner — one line, expand for mode and fan

    func climateSummary(_ room: RoomReading) -> String {
        guard let power = room.power else { return "状态暂不可用" }
        let target = room.target.map { "设定 \(Int($0))°" }
        if !power { return ["已关机", target].compactMap { $0 }.joined(separator: " · ") }
        let mode = room.modes.first { $0.id == room.mode }?.label
        let fan = room.fans.first { $0.id == room.fan }?.label
        return [target, mode, fan].compactMap { $0 }.joined(separator: " · ")
    }

    // Lets the native layout tests render the card in either state.
    func climateCardForTesting(_ room: RoomReading, expanded: Bool) -> some View {
        var view = self
        view._climateExpanded = State(initialValue: expanded)
        return view.climateCard(room)
    }

    func climateCard(_ room: RoomReading) -> some View {
        let on = room.power == true
        let modeLabel = room.modes.first { $0.id == room.mode }?.label ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: on ? modeIcon(modeLabel) : "air.conditioner.horizontal").font(.system(size: 13))
                        .foregroundStyle(on ? Self.accent : Color.primary.opacity(0.55)).frame(width: 28, height: 28)
                        .background(on ? Self.accent.opacity(0.14) : Color.primary.opacity(0.05), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(room.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Color.primary.opacity(0.4)).rotationEffect(.degrees(climateExpanded ? 180 : 0))
                        }
                        TimelineView(.periodic(from: .now, by: 20)) { context in
                            let timer = model.timers[room.id].map { "⏱ " + AppModel.remaining($0, now: context.date) + " · " } ?? ""
                            Text(timer + climateSummary(room)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle()).onTapGesture { climateExpanded.toggle() }
                let writable = room.writable.contains("target-temperature")
                Button { model.set("target-temperature", value: max(room.minimum, (room.target ?? 26) - room.step), delay: 0.6) } label: {
                    Image(systemName: "minus").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                }.buttonStyle(QuietIconStyle()).help("降低温度").accessibilityLabel("降低温度")
                    .disabled(!writable || (room.target ?? room.minimum) <= room.minimum)
                Text(room.target.map { "\(Int($0))°" } ?? "—").font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit().frame(width: 32)
                Button { model.set("target-temperature", value: min(room.maximum, (room.target ?? 26) + room.step), delay: 0.6) } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26)
                }.buttonStyle(QuietIconStyle()).help("提高温度").accessibilityLabel("提高温度")
                    .disabled(!writable || (room.target ?? room.maximum) >= room.maximum)
                Button { model.set("on", value: !(room.power ?? false)) } label: {
                    Image(systemName: "power").font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 30)
                        .foregroundStyle(on ? Self.accent : Color.primary.opacity(0.6))
                        .background(on ? Self.accent.opacity(0.16) : Color.primary.opacity(0.055), in: Circle())
                }.buttonStyle(.plain).disabled(!room.writable.contains("on"))
                    .help(on ? "关闭空调" : "开启空调").accessibilityLabel(on ? "关闭空调" : "开启空调")
            }.frame(height: 32)
            if let indoor = room.indoor {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium").font(.system(size: 9))
                    Text("室温 " + String(format: "%.1f°", indoor) + (room.humidity.map { " · 湿度 \(Int($0.rounded()))%" } ?? ""))
                        .font(.system(size: 10)).monospacedDigit()
                }.foregroundStyle(Color.primary.opacity(0.6)).frame(height: 14).padding(.leading, 36)
            }
            if climateExpanded {
                VStack(spacing: 8) {
                    if !room.modes.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(room.modes) { option in
                                let selected = room.mode == option.id
                                Button { model.set("mode", value: option.id) } label: {
                                    VStack(spacing: 3) {
                                        Image(systemName: modeIcon(option.label)).font(.system(size: 12))
                                        Text(option.label).font(.system(size: 10, weight: .medium))
                                    }.foregroundStyle(selected ? Self.accent : Color.primary.opacity(0.6))
                                        .frame(maxWidth: .infinity).frame(height: 44).modifier(Surface(selected: selected, radius: 9))
                                }.buttonStyle(.plain).disabled(!room.writable.contains("mode"))
                            }
                        }
                    }
                    if !room.fans.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(room.fans) { option in
                                let selected = room.fan == option.id
                                Button { model.set("fan-level", value: option.id) } label: {
                                    Text(option.label).font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(selected ? Self.accent : Color.primary.opacity(0.6))
                                        .frame(maxWidth: .infinity).frame(height: 28).modifier(Surface(selected: selected, radius: 8))
                                }.buttonStyle(.plain).disabled(!room.writable.contains("fan-level"))
                            }
                        }
                    }
                    if room.writable.contains("on") { TimerRow(model: model, id: room.id) }
                }.padding(.top, 4)
            }
        }.padding(.horizontal, 10).padding(.vertical, 10).modifier(Surface(radius: 12))
    }

    // MARK: Devices — two-column tiles; click switches, the slider icon opens controls

    func tile(_ item: Accessory, favorites: Bool) -> some View {
        let on = item.isOn == true
        let hasControls = item.online && (!AccessoryDetail.controls(item).isEmpty || AppModel.timerEligible(item))
        let key = (favorites ? "fav-" : "") + item.id
        return HStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: AccessoryDetail.icon(item)).font(.system(size: 12))
                    .foregroundStyle(on ? Self.accent : Color.primary.opacity(0.55)).frame(width: 26, height: 26)
                    .background(on ? Self.accent.opacity(0.14) : Color.primary.opacity(0.05), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Text(item.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        if !favorites && model.favorites.contains(item.id) {
                            Image(systemName: "star.fill").font(.system(size: 7)).foregroundStyle(Self.accent.opacity(0.8))
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 20)) { context in
                        let timer = model.timers[item.id].map { "⏱ " + AppModel.remaining($0, now: context.date) + " · " } ?? ""
                        Text(timer + (favorites && item.online ? "\(item.room) · \(AccessoryDetail.summary(item))" : AccessoryDetail.summary(item)))
                            .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }.contentShape(Rectangle()).onTapGesture { if item.online { model.quickToggle(item) } }
            if hasControls && !favorites {
                Button { detailID = detailID == key ? nil : key } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(detailID == key ? Self.accent : Color.primary.opacity(0.5)).frame(width: 22, height: 22)
                        .background(Color.primary.opacity(detailID == key ? 0.1 : 0.04), in: Circle())
                }.buttonStyle(.plain).help("调节")
            }
        }.padding(.horizontal, 8).frame(height: Self.tileHeight)
            .modifier(Surface(selected: on, radius: 11)).opacity(item.online ? 1 : 0.5)
            .contextMenu {
                Button(model.favorites.contains(item.id) ? "移出常用" : "加入常用") { model.toggleFavorite(item.id) }
                if hasControls && !favorites { Button("调节…") { detailID = key } }
            }
    }

    func tileGrid(_ items: [Accessory], favorites: Bool) -> some View {
        VStack(spacing: Self.gridSpacing) {
            ForEach(Self.pairs(items), id: \.first!.id) { pair in
                HStack(spacing: Self.gridSpacing) {
                    ForEach(pair) { item in tile(item, favorites: favorites).frame(maxWidth: .infinity) }
                    if pair.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
                if !favorites, let open = pair.first(where: { $0.id == detailID }), open.online {
                    AccessoryDetail(item: open, model: model)
                }
            }
        }
    }

    // Everything below the room row scrolls once the panel would pass 80% of the screen.
    var middleHeight: CGFloat {
        let items = model.areaAccessories
        var height: CGFloat = 0
        if let room = model.areaRoom {
            height += Self.climateHeight(room, expanded: climateExpanded)
            if room.message != nil { height += Self.sectionSpacing + 16 }
        }
        if !items.isEmpty {
            if height > 0 { height += Self.sectionSpacing }
            height += 20 + 8 + Self.gridHeight(items, detail: detailID)
        }
        return height
    }

    var middleCap: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        let top: CGFloat = 10 + 38 + Self.sectionSpacing + floodHeight + (favoritesHeight > 0 ? favoritesHeight + Self.sectionSpacing : 0)
            + Self.roomRowsHeight(model.areas.count) + Self.sectionSpacing
        let bottom: CGFloat = Self.sectionSpacing + 1 + Self.sectionSpacing + 36 + 10
            + (updater.latest != nil || updater.note != nil ? 46 : 0)
        return max(160, screen * 0.8 - top - bottom)
    }

    var middleSection: some View {
        let items = model.areaAccessories
        return ScrollView(.vertical, showsIndicators: middleHeight > middleCap) {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                if let room = model.areaRoom {
                    climateCard(room)
                    if let message = room.message { Text(message).font(.caption).foregroundStyle(.secondary).frame(height: 16) }
                }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("设备").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            Text(model.favorites.isEmpty ? "\(items.count) 个 · 右键加入常用" : "\(items.count) 个")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer()
                            let count = model.offTargets(model.area).count
                            if count > 0 {
                                Button { model.turnOff(area: model.area) } label: {
                                    Label("全关", systemImage: "power").font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.primary.opacity(0.7)).padding(.horizontal, 9).frame(height: 20)
                                        .modifier(Surface(radius: 10))
                                }.buttonStyle(.plain).help("关闭本房间的灯、风扇、净化器、浴霸和空调（不含插座、窗帘）")
                            }
                        }.frame(height: 20)
                        tileGrid(items, favorites: false)
                    }
                }
            }
        }.frame(height: min(middleHeight, middleCap))
    }

    var loginContent: some View {
        VStack(spacing: 16) {
            if let qr = model.qr {
                VStack(spacing: 6) {
                    Text("用米家 App 扫码登录").font(.system(size: 16, weight: .semibold))
                    Text("扫码后，在手机上确认登录").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Image(nsImage: qr).resizable().interpolation(.none).frame(width: 232, height: 232)
                    .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14))
                Text("请使用设备所在的米家账号").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("取消登录") { model.logout() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
            } else if model.busy {
                ProgressView().controlSize(.small)
                Text(model.message).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 32, weight: .light)).foregroundStyle(Self.accent).padding(.top, 8)
                VStack(spacing: 7) {
                    Text(model.authState == "authenticated" ? "已连接米家" : "连接家中的舒适").font(.system(size: 17, weight: .semibold))
                    Text(model.authState == "authenticated" ? "同步房间，获取家中设备和状态" : "登录米家，在菜单栏控制家中设备").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Button { if model.authState == "authenticated" { model.resync() } else { model.login() } } label: {
                    Text(model.authState == "authenticated" ? "同步房间" : "扫码登录米家").font(.system(size: 12, weight: .semibold)).foregroundStyle(Self.onAccent)
                        .padding(.horizontal, 24).padding(.vertical, 11).background(Self.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 22).modifier(Surface(radius: 18))
    }

    var floodBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(model.wetAlarms) { sensor in
                HStack(spacing: 7) {
                    Image(systemName: "drop.triangle.fill").font(.system(size: 12))
                    Text("\(sensor.room) · \(sensor.name) 检测到漏水").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }.frame(height: 16)
            }
        }.foregroundStyle(Self.alarm).padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.red.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red.opacity(0.35)))
    }
    var floodHeight: CGFloat {
        let count = CGFloat(model.wetAlarms.count)
        return count == 0 ? 0 : count * 16 + (count - 1) * 3 + 18 + Self.sectionSpacing
    }

    var updateBanner: some View {
        HStack(spacing: 9) {
            if updater.state != "idle" { ProgressView().controlSize(.mini).frame(width: 12) }
            else { Image(systemName: "arrow.down.circle").font(.system(size: 13)).foregroundStyle(Self.accent) }
            Text(updater.note ?? "发现新版本 \(updater.latest ?? "")").font(.system(size: 11))
                .foregroundStyle(Color.primary.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if updater.latest != nil && updater.state == "idle" {
                Button { updater.install() } label: {
                    Text("更新").font(.system(size: 11, weight: .semibold)).foregroundStyle(Self.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 5).background(Self.accent, in: Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 12).padding(.vertical, 9).modifier(Surface(radius: 12))
    }

    var footer: some View {
        HStack(spacing: 9) {
            if model.busy || !model.pending.isEmpty { ProgressView().controlSize(.mini).frame(width: 12) }
            else { Circle().fill(model.phase == "error" ? Color.orange : Self.accent.opacity(0.75)).frame(width: 5, height: 5) }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.message).font(.system(size: 11)).foregroundStyle(model.phase == "error" ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let date = model.readAt { Text("更新于 \(date.formatted(date: .omitted, time: .standard))").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 4)
            if model.hasDevices {
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 13)).frame(width: 30, height: 30) }
                    .buttonStyle(QuietIconStyle()).disabled(model.busy).help("刷新空调状态").accessibilityLabel("刷新空调状态")
            }
        }.padding(.top, 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            header
            if !model.wetAlarms.isEmpty { floodBanner }
            if model.hasDevices {
                if !model.favoriteAccessories.isEmpty { favoritesSection }
                roomTabs
                if model.areaRoom != nil || !model.areaAccessories.isEmpty { middleSection }
            } else { loginContent }
            if updater.latest != nil || updater.note != nil { updateBanner }
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            footer
        }.padding(.horizontal, 16).padding(.vertical, 10)
            .frame(width: 376, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .onChange(of: model.area) { _ in detailID = nil; climateExpanded = false }
    }
}

func symbol(_ name: String, fallback: String) -> String {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? fallback : name
}

// "Switch off in 1 / 2 / 4 hours", or the countdown with a cancel button.
struct TimerRow: View {
    @ObservedObject var model: AppModel
    let id: String
    static let height: CGFloat = 26

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "timer").font(.system(size: 10)).foregroundStyle(.secondary)
            if let due = model.timers[id] {
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    Text(AppModel.remaining(due, now: context.date)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(ControlView.accent)
                }
                Spacer()
                Button { model.cancelTimer(id) } label: {
                    Text("取消定时").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.primary.opacity(0.7))
                        .padding(.horizontal, 10).frame(height: 22).modifier(Surface(radius: 8))
                }.buttonStyle(.plain)
            } else {
                Text("定时关闭").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ForEach([1.0, 2.0, 4.0], id: \.self) { hours in
                    Button { model.setTimer(id, hours: hours) } label: {
                        Text("\(Int(hours)) 小时").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.primary.opacity(0.7))
                            .padding(.horizontal, 8).frame(height: 22).modifier(Surface(radius: 8))
                    }.buttonStyle(.plain)
                }
            }
        }.frame(height: Self.height)
    }
}

// Controls shown under a tile, plus text helpers shared by tiles and favourites.
struct AccessoryDetail: View {
    let item: Accessory
    @ObservedObject var model: AppModel
    @State private var drafts: [String: Double] = [:]

    // Fixed element heights keep the scroll area's measured height exact.
    static func controls(_ item: Accessory) -> [AccessoryProp] {
        item.props.filter { $0.writable && $0.address != item.primary }
    }
    static func controlHeight(_ prop: AccessoryProp) -> CGFloat {
        if prop.isBool { return 26 }
        if prop.address == "curtain.motor-control" { return 28 }
        if !prop.options.isEmpty { return prop.options.count > 4 ? 66 : 44 }
        return 42
    }
    static func height(_ item: Accessory) -> CGFloat {
        let parts = controls(item)
        var heights = parts.map(controlHeight)
        if AppModel.timerEligible(item) { heights.append(TimerRow.height) }
        return 20 + heights.reduce(0, +) + CGFloat(max(heights.count - 1, 0)) * 8
    }

    static func icon(_ item: Accessory) -> String {
        switch item.kind {
        case "light": return item.group ? symbol("lightbulb.2", fallback: "lightbulb") : "lightbulb"
        case "curtain": return symbol("blinds.horizontal.closed", fallback: "rectangle.split.3x1")
        case "outlet": return symbol("powerplug", fallback: "bolt")
        case "fan": return symbol("fan", fallback: "wind")
        case "air-purifier": return symbol("air.purifier", fallback: "aqi.medium")
        case "hood": return symbol("wind", fallback: "fan")
        default: return symbol("heater.vertical", fallback: "flame")
        }
    }

    func label(_ prop: AccessoryProp) -> String {
        // The range hood's purifier service is its smoke purification, not a second power switch.
        if item.kind == "hood" && prop.address == "air-purifier.on" { return "净化" }
        return Self.label(prop)
    }
    static func label(_ prop: AccessoryProp) -> String {
        let (service, field) = { () -> (String, String) in
            let parts = prop.address.split(separator: ".", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }()
        if field == "on" { return ["light": "照明", "fan": "风扇", "switch": "电源", "air-purifier": "电源", "hood": "电源"][service] ?? "开关" }
        return ["brightness": "亮度", "color-temperature": "色温", "target-position": "开合", "fan-level": "风速",
                "mode": "模式", "ventilation": "换气", "horizontal-swing": "摇头", "target-temperature": "目标温度", "motor-control": "窗帘"][field] ?? field
    }

    func formatted(_ prop: AccessoryProp, _ value: Double) -> String {
        if prop.address.hasSuffix("color-temperature") { return "\(Int(value))K" }
        if prop.address.hasSuffix("target-temperature") { return "\(Int(value))°" }
        return "\(Int(value))%"
    }

    static func option(_ item: Accessory, _ address: String) -> String? {
        guard let prop = item.prop(address), let value = item.number(address) else { return nil }
        return prop.options.first { Double($0.id) == value }?.label
    }

    static func summary(_ item: Accessory) -> String {
        guard item.online else { return "离线" }
        if item.values.isEmpty { return "等待读取" }
        switch item.kind {
        case "light":
            guard item.isOn == true else { return "已关闭" }
            return [item.number("light.brightness").map { "亮度 \(Int($0))%" },
                    item.number("light.color-temperature").map { "\(Int($0))K" },
                    item.values["fan.on"]?.base as? Bool == true ? "风扇开" : nil].compactMap { $0 }.joined(separator: " · ")
        case "curtain":
            return (item.number("curtain.current-position") ?? item.number("curtain.target-position")).map { "开合 \(Int($0))%" } ?? "—"
        case "outlet":
            let power = item.number("power-consumption.electric-power").map { String(format: "%.1fW", $0) }
            return [item.isOn == true ? "已开启" : "已关闭", item.isOn == true ? power : nil].compactMap { $0 }.joined(separator: " · ")
        case "air-purifier":
            let pm = item.number("environment.pm2.5-density").map { "PM2.5 \(Int($0))" }
            return [item.isOn == true ? option(item, "air-purifier.mode") ?? "已开启" : "已关闭", pm].compactMap { $0 }.joined(separator: " · ")
        case "hood":
            let pm = item.number("environment.pm2.5-density").map { "PM2.5 \(Int($0))" }
            guard item.isOn == true else {
                return [item.values["light.on"]?.base as? Bool == true ? "照明开" : "已关闭", pm].compactMap { $0 }.joined(separator: " · ")
            }
            let light = item.values["light.on"]?.base as? Bool == true ? "照明开" : nil
            return [option(item, "fan-control.fan-level").map { "风速 " + $0 } ?? "运行中", light, pm].compactMap { $0 }.joined(separator: " · ")
        case "fan":
            guard item.isOn == true else { return "已关闭" }
            return [option(item, "fan.mode"), option(item, "fan.fan-level"), item.values["fan.horizontal-swing"]?.base as? Bool == true ? "摇头" : nil]
                .compactMap { $0 }.joined(separator: " · ")
        default:
            let light = item.values["light.on"]?.base as? Bool == true ? "照明开" : nil
            let temp = item.number("environment.temperature").map { String(format: "%.0f°", $0) }
            let vent = item.values["ptc-bath-heater.ventilation"]?.base as? Bool == true ? "换气" : nil
            return [option(item, "ptc-bath-heater.mode") ?? "—", vent, light, temp].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.controls(item), id: \.address) { prop in control(prop).frame(height: Self.controlHeight(prop)) }
            if AppModel.timerEligible(item) { TimerRow(model: model, id: item.id) }
        }.padding(.horizontal, 10).padding(.vertical, 10)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(ControlView.accent.opacity(0.25)))
    }

    @ViewBuilder func control(_ prop: AccessoryProp) -> some View {
        if prop.isBool {
            HStack {
                Text(label(prop)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(get: { item.values[prop.address]?.base as? Bool ?? false },
                                         set: { model.setAccessory(item.id, prop.address, value: $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(ControlView.accent)
            }
        } else if prop.address == "curtain.motor-control" {
            HStack(spacing: 6) {
                ForEach([1, 0, 2], id: \.self) { value in
                    if let option = prop.options.first(where: { $0.id == value }) {
                        Button { model.setAccessory(item.id, prop.address, value: Double(value)) } label: {
                            Text(option.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.primary.opacity(0.75))
                                .frame(maxWidth: .infinity).frame(height: 26).modifier(Surface(radius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }
        } else if !prop.options.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(label(prop)).font(.system(size: 11)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: min(prop.options.count, 4)), spacing: 5) {
                    ForEach(prop.options) { option in
                        let selected = item.number(prop.address) == Double(option.id)
                        Button { model.setAccessory(item.id, prop.address, value: Double(option.id)) } label: {
                            Text(option.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                .foregroundStyle(selected ? ControlView.accent : Color.primary.opacity(0.65))
                                .frame(maxWidth: .infinity).frame(height: 22).modifier(Surface(selected: selected, radius: 7))
                        }.buttonStyle(.plain)
                    }
                }
            }
        } else if let range = prop.range, range.count == 3, range[1] > range[0] {
            let step = prop.address.hasSuffix("color-temperature") ? max(range[2], 100) : range[2]
            let current = drafts[prop.address] ?? item.number(prop.address) ?? range[0]
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(label(prop)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(formatted(prop, current)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.primary.opacity(0.75))
                }
                Slider(value: Binding(get: { min(max(current, range[0]), range[1]) }, set: { drafts[prop.address] = $0 }),
                       in: range[0]...range[1], step: step) { editing in
                    guard !editing, let value = drafts[prop.address] else { return }
                    model.setAccessory(item.id, prop.address, value: value.rounded(), delay: 0.3)
                    drafts[prop.address] = nil
                }.tint(ControlView.accent).controlSize(.small)
            }
        }
    }
}

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
    // SwiftUI invalidates the intrinsic size whenever content is added or removed
    // (rooms, QR code, update banner). The panel follows it from here.
    var onSizeChange: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

// The backdrop and SwiftUI content share the exact same bounds. Measure the
// hosting view, never the material container, to avoid empty bands on resize.
final class PanelContentView: NSView {
    let content: NSView
    let backdrop: NSView
    let usesLiquidGlass: Bool

    init(content: NSView, useLiquidGlass: Bool = true) {
        self.content = content
        if #available(macOS 26.0, *), useLiquidGlass {
            let glass = NSGlassEffectView(frame: content.frame)
            glass.style = .regular
            glass.cornerRadius = 20
            glass.contentView = content
            backdrop = glass
            usesLiquidGlass = true
        } else {
            let material = NSVisualEffectView(frame: content.frame)
            material.material = .menu
            material.blendingMode = .behindWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.cornerRadius = 20
            material.layer?.masksToBounds = true
            material.layer?.borderWidth = 1
            material.layer?.borderColor = Self.borderColor(for: material.effectiveAppearance)
            material.addSubview(content)
            backdrop = material
            usesLiquidGlass = false
        }
        super.init(frame: content.frame)
        autoresizingMask = [.width, .height]
        backdrop.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        addSubview(backdrop)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isOpaque: Bool { false }

    static func borderColor(for appearance: NSAppearance) -> CGColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.16).cgColor : NSColor.black.withAlphaComponent(0.08).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !usesLiquidGlass { backdrop.layer?.borderColor = Self.borderColor(for: effectiveAppearance) }
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        content.frame = bounds
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var applicationLease: ApplicationLease?
    var showObserver: NSObjectProtocol?
    var item: NSStatusItem!
    var panel: MenuPanel!
    var model: AppModel!
    var refreshTimer: Timer?
    var alarmTimer: Timer?
    var clickMonitor: Any?
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let resources = Bundle.main.resourceURL else { NSApp.terminate(nil); return }
        let runtime = AppModel.defaultRuntime
        try? FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let lease = ApplicationLease(runtime: runtime) else {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.hitachi.menubar.show"), object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        applicationLease = lease
        if let forced = CommandLine.arguments.first(where: { $0.hasPrefix("--appearance=") }) {
            NSApp.appearance = Preferences.nsAppearance(String(forced.dropFirst("--appearance=".count)))
        } else {
            Preferences.shared.apply()
        }
        model = AppModel(worker: resources.appendingPathComponent("CloudWorker/CloudWorker"))
        AppModel.shared = model
        showObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.hitachi.menubar.show"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.panel != nil, !self.panel.isVisible else { return }
            self.toggle()
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "house", accessibilityDescription: "米家")
        item.button?.title = " 米家"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        model.titleChanged = { [weak self] title in self?.item.button?.title = title }
        panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: 376, height: 100),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "米家"
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let host = TransparentHostingView(rootView: ControlView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        host.onSizeChange = { [weak self, weak host] in
            DispatchQueue.main.async { if let host = host { self?.resizePanel(height: host.fittingSize.height) } }
        }
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = PanelContentView(content: host)
        resizePanel(height: host.fittingSize.height)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.panel.orderOut(nil) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.panel.orderOut(nil); return nil }
            if event.keyCode == 123 || event.keyCode == 124, let model = self?.model, self?.panel.isVisible == true,
               !(self?.panel.firstResponder is NSSlider) {
                model.stepArea(event.keyCode == 124 ? 1 : -1)
                return nil
            }
            return event
        }
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.toggle() }
        }
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--preview=") }) {
            let path = String(argument.dropFirst("--preview=".count))
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                self?.resizePanel(height: host.fittingSize.height)
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    if let panel = self?.panel {
                        let dimensions: [String: Double] = ["window_height": panel.contentRect(forFrameRect: panel.frame).height,
                            "content_height": host.bounds.height, "natural_height": host.fittingSize.height]
                        if let data = try? JSONSerialization.data(withJSONObject: dimensions) {
                            try? data.write(to: URL(fileURLWithPath: path + ".layout.json"))
                        }
                    }
                }
            }
        }
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--preview=") }) { Updater.shared.start() }
        AppModel.requestNotifications()
        alarmTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self, !self.panel.isVisible else { return }
            self.model.checkAlarms()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self, self.panel.isVisible, !self.model.busy, self.model.hasDevices else { return }
            self.model.refresh(automatic: true)
        }
    }

    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil) }
        else {
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            if model.hasDevices && !model.busy { model.refresh(automatic: true) }
        }
    }

    func resizePanel(height: CGFloat) {
        guard height > 0 else { return }
        let size = NSSize(width: 376, height: ceil(height))
        if abs(panel.frame.height - size.height) > 0.5 {
            panel.setContentSize(size)
            positionPanel()
        }
        // The glass material fills the measured content, including after login
        // or room-count changes. There is no independent minimum panel height.
        let frame = NSRect(origin: .zero, size: size)
        if panel.contentView?.frame != frame { panel.contentView?.frame = frame }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
    }

    func positionPanel() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let width = panel.frame.width
        let x = min(max(anchor.midX - width / 2, screen.minX + 8), screen.maxX - width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - panel.frame.height - 8))
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Finish any already-sent HVAC command and save the readback before worker exit.
        if model?.process?.isRunning == true && model?.process?.arguments?.contains("--field") != true { model.process?.terminate() }
        if let observer = showObserver { DistributedNotificationCenter.default().removeObserver(observer) }
        applicationLease = nil
    }
}
