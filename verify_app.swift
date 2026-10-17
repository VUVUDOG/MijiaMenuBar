// AppModel regression checks, compiled with the actual application source.
let testRuntime = URL(fileURLWithPath: CommandLine.arguments[1])
let fakeWorker = URL(fileURLWithPath: "/usr/bin/true")
func saveFixture(_ name: String, _ value: Any, runtime: URL = testRuntime) throws {
    try JSONSerialization.data(withJSONObject: value).write(to: runtime.appendingPathComponent(name))
}
func seedAuthenticated(runtime: URL = testRuntime) throws {
    try saveFixture("auth.json", ["generation": "old-session", "state": "authenticated", "account": "session"], runtime: runtime)
    try saveFixture("status.json", ["generation": "old-session", "phase": "complete", "message": "设备状态已更新"], runtime: runtime)
    try saveFixture("report.json", ["devices": [["device": ["did": "test-room", "name": "测试空调"], "state": []]]], runtime: runtime)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
try seedAuthenticated()
let original = AppModel(worker: fakeWorker, runtime: testRuntime)
expect(original.rooms.count == 1, "Existing authenticated login must load cached rooms")
original.login()
expect(original.rooms.isEmpty && original.selectedID.isEmpty && original.readAt == nil, "Relogin must immediately clear native state")
let revoked = try JSONSerialization.jsonObject(with: Data(contentsOf: testRuntime.appendingPathComponent("auth.json"))) as! [String: Any]
expect(revoked["state"] as? String == "logged_out", "Revocation must persist before the QR worker starts")
expect(revoked["generation"] as? String != "old-session", "Relogin must invalidate the previous generation")
expect(!FileManager.default.fileExists(atPath: testRuntime.appendingPathComponent("report.json").path), "Cached rooms must be deleted")
original.process?.waitUntilExit()
let restarted = AppModel(worker: fakeWorker, runtime: testRuntime)
expect(restarted.rooms.isEmpty && !restarted.busy && restarted.qr == nil, "Restart after cancelled relogin must stay signed out")

try seedAuthenticated()
let logout = AppModel(worker: fakeWorker, runtime: testRuntime)
logout.logout()
expect(logout.rooms.isEmpty && logout.authState == "logged_out", "Logout must clear native state synchronously")
logout.process?.waitUntilExit()
let afterLogout = AppModel(worker: fakeWorker, runtime: testRuntime)
expect(afterLogout.rooms.isEmpty && !afterLogout.canLogout, "Logout must survive restart")

try seedAuthenticated()
try saveFixture("auth.json", ["generation": "pending", "state": "pending", "account": "session.pending"])
try saveFixture("status.json", ["generation": "pending", "phase": "awaiting_scan", "message": "等待扫码"])
let interrupted = AppModel(worker: fakeWorker, runtime: testRuntime)
expect(interrupted.rooms.isEmpty && interrupted.qr == nil && !interrupted.busy, "Interrupted QR login must not revive stale rooms or remain busy")
print("Native login lifecycle: 3 regression scenarios passed")

// Exercise the actual SwiftUI intrinsic height for all three panel states.
let _ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
interrupted.rooms = [RoomReading(id: "layout-room", name: "测试空调", power: false, target: 26, mode: 1, fan: 0,
    modes: [ControlOption(id: 0, label: "自动"), ControlOption(id: 1, label: "制冷"), ControlOption(id: 2, label: "除湿"), ControlOption(id: 3, label: "送风"), ControlOption(id: 4, label: "制热")],
    fans: [ControlOption(id: 0, label: "自动"), ControlOption(id: 1, label: "低风"), ControlOption(id: 2, label: "中风"), ControlOption(id: 3, label: "高风")],
    writable: [], minimum: 16, maximum: 32, step: 1, message: nil)]
let hosting = NSHostingView(rootView: ControlView(model: interrupted))
hosting.sizingOptions = [.intrinsicContentSize]
hosting.frame = NSRect(x: 0, y: 0, width: 376, height: 100)
let controlHeight = hosting.fittingSize.height
let layoutRooms = interrupted.rooms
interrupted.rooms = []; interrupted.authState = "logged_out"
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
let signedOutHeight = hosting.fittingSize.height
interrupted.active = true; interrupted.phase = "awaiting_scan"; interrupted.qr = NSImage(size: NSSize(width: 232, height: 232))
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
let qrHeight = hosting.fittingSize.height
expect(controlHeight > 150 && abs(controlHeight - signedOutHeight) > 20, "Control panel must measure its natural height")
expect(qrHeight > signedOutHeight + 100, "QR panel must grow to fit its content")
expect(signedOutHeight > 200 && signedOutHeight < 450, "Signed-out panel must shrink without fixed-height padding")
print("Native layout: control \(Int(controlHeight)) / signed out \(Int(signedOutHeight)) / QR \(Int(qrHeight)) pt")

// Reproduce login/QR/room transitions inside the actual material container.
// Exercise the legacy branch even on macOS 26 to catch wrapper sizing regressions.
for useGlass in [true, false] {
    let host = TransparentHostingView(rootView: ControlView(model: interrupted))
    host.sizingOptions = [.intrinsicContentSize]
    host.frame = NSRect(x: 0, y: 0, width: 376, height: 100)
    let container = PanelContentView(content: host, useLiquidGlass: useGlass)
    let window = MenuPanel(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    for state in ["control", "signed-out", "qr", "control"] {
        interrupted.rooms = state == "control" ? layoutRooms : []
        interrupted.active = state == "qr"
        interrupted.phase = state == "qr" ? "awaiting_scan" : "logged_out"
        interrupted.qr = state == "qr" ? NSImage(size: NSSize(width: 232, height: 232)) : nil
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let height = ceil(host.fittingSize.height)
        window.setContentSize(NSSize(width: 376, height: height))
        container.layoutSubtreeIfNeeded()
        expect(abs(container.bounds.height - height) <= 1, "Material must fill the measured window")
        expect(host.frame == container.bounds && container.backdrop.frame == container.bounds,
               "Login transitions must not leave extra space above or below the material")
    }
    if #available(macOS 26.0, *), useGlass {
        expect(container.usesLiquidGlass && container.backdrop is NSGlassEffectView, "New Macs must use native Liquid Glass")
    } else {
        expect(!container.usesLiquidGlass && container.backdrop is NSVisualEffectView, "Older Macs must use the menu material")
    }
    window.close()
}
print("Native backdrop: Liquid Glass and legacy menu material follow all panel sizes")

// The panel height follows content added after launch, such as the update banner.
let bannerRuntime = testRuntime.appendingPathComponent("banner-test")
try FileManager.default.createDirectory(at: bannerRuntime, withIntermediateDirectories: true)
try seedAuthenticated(runtime: bannerRuntime)
let bannerModel = AppModel(worker: fakeWorker, runtime: bannerRuntime)
let bannerHost = TransparentHostingView(rootView: ControlView(model: bannerModel))
bannerHost.sizingOptions = [.intrinsicContentSize]
bannerHost.frame = NSRect(x: 0, y: 0, width: 376, height: 100)
var followed: [CGFloat] = []
bannerHost.onSizeChange = { DispatchQueue.main.async { followed.append(bannerHost.fittingSize.height) } }
let bannerWindow = MenuPanel(contentRect: bannerHost.frame, styleMask: .borderless, backing: .buffered, defer: false)
bannerWindow.isReleasedWhenClosed = false
bannerWindow.contentView = PanelContentView(content: bannerHost)
bannerWindow.orderFront(nil)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
let withoutBanner = bannerHost.fittingSize.height
Updater.shared.show("已是最新版本")
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
expect(followed.last.map { $0 > withoutBanner + 20 } == true, "Showing the update banner must report the taller panel height")
Updater.shared.show(nil)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
expect(followed.last.map { abs($0 - withoutBanner) < 1 } == true, "Hiding the update banner must report the original panel height")
bannerWindow.close()
print("Native layout: panel height follows the update banner")

let cacheRuntime = testRuntime.appendingPathComponent("cache-test")
try FileManager.default.createDirectory(at: cacheRuntime, withIntermediateDirectories: true)
try seedAuthenticated(runtime: cacheRuntime)
let testSession = ["user_id": "test", "ssecurity": "test-security", "service_token": "test-token"]
let testSessionData = try JSONSerialization.data(withJSONObject: testSession)
let cached = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: cacheRuntime,
    credentialReader: { _ in (errSecSuccess, testSessionData) })
func finish(_ model: AppModel) {
    let deadline = Date(timeIntervalSinceNow: 5)
    while model.active && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
    expect(!model.active, "Worker must complete and its private session pipe must close")
}
func requests() throws -> [[String: Bool]] {
    let lines = try String(contentsOf: cacheRuntime.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
    return try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Bool] }
}
cached.refresh(); finish(cached)
expect(cached.sessionData != nil, "First authorized read must cache the session in memory")
cached.refresh(); finish(cached)
let initialRequests = try requests()
expect(initialRequests.count == 2 && initialRequests.allSatisfy { $0["memory"] == true }, "Every GUI refresh, including the first, must use the private pipe instead of worker Keychain reads")
expect(cached.keychainReads == 1 && cached.memoryRequests == 2, "Main app must authorize once and reuse its session")
expect(!cached.diagnosticSummary.contains("test-token") && !cached.diagnosticSummary.contains("test-security"), "Diagnostics must not include credentials")
cached.logout()
expect(cached.sessionData == nil && cached.sessionGeneration == nil, "Logout must immediately erase the in-memory login")
finish(cached)
let restartCache = AppModel(worker: fakeWorker, runtime: cacheRuntime)
expect(restartCache.sessionData == nil, "Memory cache must not persist across app restarts")

try seedAuthenticated(runtime: cacheRuntime)
try Data().write(to: cacheRuntime.appendingPathComponent("deny-keychain"))
let denied = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: cacheRuntime,
    credentialReader: { _ in
        FileManager.default.fileExists(atPath: cacheRuntime.appendingPathComponent("deny-keychain").path)
            ? (errSecAuthFailed, nil) : (errSecSuccess, testSessionData)
    })
denied.refresh(); finish(denied)
expect(denied.automaticRefreshSuspended && !denied.busy, "Denied Keychain access must stop automatic attempts and leave controls responsive")
let countBefore = try requests().count
let readsBefore = denied.keychainReads
denied.refresh(automatic: true)
let countAutomatic = try requests().count
expect(!denied.active && countAutomatic == countBefore && denied.keychainReads == readsBefore, "Automatic refresh must not prompt again after denial")
denied.refresh(); finish(denied)
let countAfter = try requests().count
expect(countAfter == countBefore && denied.keychainReads == readsBefore + 1, "Manual refresh may retry main-app authorization, but must not launch another Keychain-reading worker")
expect(denied.automaticRefreshSuspended, "Repeated identical denials must still suspend automatic refresh")
denied.refresh(automatic: true)
let countRepeated = try requests().count
expect(!denied.active && countRepeated == countAfter, "Identical denial responses must not restart the automatic prompt loop")
let restartDenied = AppModel(worker: fakeWorker, runtime: cacheRuntime)
restartDenied.refresh(automatic: true)
expect(restartDenied.automaticRefreshSuspended && !restartDenied.active, "Restart must not automatically repeat a previously denied authorization")
try FileManager.default.removeItem(at: cacheRuntime.appendingPathComponent("deny-keychain"))
denied.refresh(); finish(denied)
expect(denied.sessionData != nil && !denied.automaticRefreshSuspended, "Successful manual authorization must restore normal automatic refresh")
expect(denied.memoryRequests == 1, "Successful retry must pass the main app's session to the worker")

try seedAuthenticated(runtime: cacheRuntime)
let malformed = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: cacheRuntime,
    credentialReader: { _ in (errSecSuccess, Data("not-json".utf8)) })
malformed.refresh(); finish(malformed)
malformed.refresh(automatic: true)
expect(malformed.keychainReads == 1 && malformed.workerRequests == 0 && malformed.automaticRefreshSuspended,
    "Invalid credential data must stop without another implicit Keychain attempt")

// Revoking a login while the OS authorization is pending must remain immediate.
try seedAuthenticated(runtime: cacheRuntime)
let entered = DispatchSemaphore(value: 0)
let release = DispatchSemaphore(value: 0)
let late = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: cacheRuntime,
    credentialReader: { _ in
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
        return (errSecSuccess, testSessionData)
    })
late.refresh()
expect(entered.wait(timeout: .now() + 1) == .success, "Native Keychain read must run off the UI thread")
late.logout()
release.signal()
finish(late)
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
expect(late.sessionData == nil && late.authState == "logged_out", "Late system authorization must not restore a revoked session")
expect(late.workerRequests == 1, "Cancelled authorization must not start its old refresh worker")

// Legacy sessions are migrated only when no auth marker exists, not after logout.
let legacyRuntime = testRuntime.appendingPathComponent("legacy-test")
try FileManager.default.createDirectory(at: legacyRuntime, withIntermediateDirectories: true)
let legacy = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: legacyRuntime,
    credentialReader: { account in
        expect(account == "session", "Pre-0.3 login must use the existing Keychain account")
        return (errSecSuccess, testSessionData)
    })
legacy.refresh(); finish(legacy)
expect(legacy.authState == "authenticated" && legacy.sessionData != nil && legacy.keychainReads == 1,
    "Native reader must preserve an existing legacy session")

// Controls update the panel immediately, merge repeated taps, and revert on failure.
let controlRuntime = testRuntime.appendingPathComponent("control-test")
try FileManager.default.createDirectory(at: controlRuntime, withIntermediateDirectories: true)
try seedAuthenticated(runtime: controlRuntime)
let controlSpec: [String: Any] = ["services": [["iid": 2, "type": "urn:miot-spec-v2:service:air-conditioner:1", "properties": [
    ["iid": 1, "type": "urn:miot-spec-v2:property:on:1", "format": "bool", "access": ["read", "write"]],
    ["iid": 2, "type": "urn:miot-spec-v2:property:mode:1", "access": ["read", "write"],
     "value-list": [["value": 1, "description": "Cool"], ["value": 2, "description": "Heat"]]],
    ["iid": 4, "type": "urn:miot-spec-v2:property:target-temperature:1", "access": ["read", "write"], "value-range": [16, 32, 1]]]]]]
let controlState: [[String: Any]] = [["siid": 2, "piid": 1, "code": 0, "value": true],
    ["siid": 2, "piid": 2, "code": 0, "value": 1], ["siid": 2, "piid": 4, "code": 0, "value": 26.0]]
try saveFixture("report.json", ["devices": [["device": ["did": "test-room", "name": "测试空调"], "spec": controlSpec, "state": controlState]]], runtime: controlRuntime)
let control = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: controlRuntime,
    credentialReader: { _ in (errSecSuccess, testSessionData) })
func controls() -> [[String]] {
    guard let text = try? String(contentsOf: controlRuntime.appendingPathComponent("controls.jsonl"), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
}
func settle(_ model: AppModel) {
    let deadline = Date(timeIntervalSinceNow: 6)
    while (model.active || model.inFlight != nil || !model.pending.isEmpty) && Date() < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    }
    expect(!model.active && model.inFlight == nil && model.pending.isEmpty, "Queued controls must drain")
}
expect(control.selected?.target == 26, "Control fixture must load the reported temperature")
for value in [27.0, 28.0, 29.0] { control.set("target-temperature", value: value, delay: 0.6) }
expect(control.selected?.target == 29 && !control.active, "Taps must show immediately and wait for the debounce")
settle(control)
expect(controls().count == 1 && Array(controls()[0][2..<6]) == ["--field", "target-temperature", "--value", "29"],
    "Repeated temperature taps must send only the final value")
control.set("target-temperature", value: 27.0)
control.flush()
expect(control.inFlight != nil, "First control must start")
control.set("mode", value: 2)
expect(control.selected?.mode == 2, "Taps during a running command must not be dropped")
settle(control)
expect(controls().count == 3 && controls()[2].contains("mode"), "A tap made during a running command must be sent afterwards")
control.set("target-temperature", value: 26.0)
control.set("target-temperature", value: 28.0); settle(control)
try Data().write(to: controlRuntime.appendingPathComponent("fail-control"))
control.set("target-temperature", value: 31.0)
expect(control.selected?.target == 31, "Failure case must first show the optimistic value")
settle(control)
expect(control.selected?.target == 26 && control.message.contains("未调整成功"), "A failed control must revert to the reported state")

expect(Updater.isNewer("0.3.10", than: "0.3.9") && Updater.isNewer("0.4", than: "0.3.9") &&
    !Updater.isNewer("0.3.9", than: "0.3.9") && !Updater.isNewer("0.3.8", than: "0.3.9"), "Update check must compare versions numerically")

// Accessories: rooms ordering, parsing, optimistic queue and generic property addresses.
let accessoryRuntime = testRuntime.appendingPathComponent("accessory-test")
try FileManager.default.createDirectory(at: accessoryRuntime, withIntermediateDirectories: true)
try seedAuthenticated(runtime: accessoryRuntime)
let lightProps: [[String: Any]] = [
    ["address": "light.on", "format": "bool", "readable": true, "writable": true],
    ["address": "light.brightness", "format": "uint8", "readable": true, "writable": true, "range": [1, 100, 1]]]
let curtainProps: [[String: Any]] = [
    ["address": "curtain.motor-control", "format": "uint8", "readable": false, "writable": true,
     "options": [["value": 1, "description": "Open"], ["value": 0, "description": "Pause"], ["value": 2, "description": "Close"]]],
    ["address": "curtain.current-position", "format": "uint8", "readable": true, "writable": false, "range": [0, 100, 1]]]
try saveFixture("report.json", ["devices": [["device": ["did": "test-room", "name": "主卧空调"], "room": "主卧",
    "spec": controlSpec, "state": controlState]],
    "accessories": [
        ["device": ["did": "lamp", "name": "吸顶灯", "isOnline": true], "room": "主卧", "kind": "light", "group": false,
         "props": lightProps, "state": ["light.on": false, "light.brightness": 40]],
        ["device": ["did": "group", "name": "主卧筒灯", "isOnline": true], "room": "主卧", "kind": "light", "group": true,
         "props": lightProps, "state": ["light.on": true, "light.brightness": 80]],
        ["device": ["did": "k1", "name": "厨房射灯", "isOnline": true], "room": "厨房", "kind": "light", "group": false, "props": lightProps, "state": [:]],
        ["device": ["did": "k2", "name": "厨房灯带", "isOnline": false], "room": "厨房", "kind": "light", "group": false, "props": lightProps, "state": [:]],
        ["device": ["did": "c1", "name": "走廊窗帘", "isOnline": true], "room": "走廊", "kind": "curtain", "group": false,
         "props": curtainProps, "state": ["curtain.current-position": 30]]]], runtime: accessoryRuntime)
UserDefaults.standard.removeObject(forKey: "selectedArea")
let home = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: accessoryRuntime,
    credentialReader: { _ in (errSecSuccess, testSessionData) })
expect(home.areas == ["主卧", "厨房", "走廊"], "Rooms with air conditioners come first, then rooms by device count")
expect(home.area == "主卧" && home.areaRoom != nil, "The air conditioner card belongs to its room")
expect(home.areaAccessories.map(\.id) == ["group", "lamp"], "Light groups are listed before single lights")
expect(home.areaActive("主卧") && !home.areaActive("厨房"), "A room is active when something in it is on")
home.selectArea("厨房")
expect(home.areaRoom == nil && home.areaAccessories.count == 2, "Rooms without an air conditioner show only devices")
settleQueue(home)
home.setAccessory("k2", "light.on", value: true)
expect(home.pending["k2"] == nil, "Offline devices must not accept commands")
home.selectArea("主卧")
settleQueue(home)
let before = accessoryControls().count
home.setAccessory("lamp", "light.on", value: true)
home.setAccessory("lamp", "light.brightness", value: 70.0, delay: 0.3)
expect(home.areaAccessories.first { $0.id == "lamp" }?.isOn == true, "Accessory taps show immediately")
settleQueue(home)
let sent = accessoryControls()
expect(sent.count == before + 1, "Changes to one device are merged into one command")
let args = sent.last!
expect(args.contains("lamp") && args.contains("light.on") && args.contains("light.brightness") && args.contains("70"),
    "Accessory commands carry property addresses and values")
home.setAccessory("lamp", "light.on", value: true)
expect(home.pending["lamp"] == nil || home.inFlight != nil || accessoryControls().count == sent.count,
    "Unchanged values are not resent")
settleQueue(home)
try Data().write(to: accessoryRuntime.appendingPathComponent("fail-control"))
home.setAccessory("group", "light.on", value: false)
expect(home.areaAccessories.first { $0.id == "group" }?.isOn == false, "Failure case first shows the optimistic value")
settleQueue(home)
expect(home.areaAccessories.first { $0.id == "group" }?.isOn == true && home.message.contains("未调整成功"),
    "A failed accessory command reverts to the reported state")
try FileManager.default.removeItem(at: accessoryRuntime.appendingPathComponent("fail-control"))
home.selectArea("走廊")
settleQueue(home)
let curtainBefore = accessoryControls().count
home.setAccessory("c1", "curtain.motor-control", value: 1.0)
settleQueue(home)
home.setAccessory("c1", "curtain.motor-control", value: 1.0)
settleQueue(home)
expect(accessoryControls().count == curtainBefore + 2, "Curtain actions are sent every time, even when repeated")
// Turning everything off: scope, exclusions, one batched run, partial failure.
home.selectArea("主卧")
settleQueue(home)
let homeOff = home.offTargets(nil)
expect(Set(homeOff.keys) == ["group", "test-room"] && homeOff["test-room"] == ["on": AnyHashable(false)],
    "Whole-home off covers lights and air conditioners that are on, never curtains: \(homeOff.keys)")
let kitchenOff = home.offTargets("厨房")
expect(kitchenOff.isEmpty, "Room off only covers that room")
let batchBefore = accessoryControls().count
try "group".write(to: accessoryRuntime.appendingPathComponent("fail-control"), atomically: true, encoding: .utf8)
expect(home.turnOff(area: nil) == 2, "Whole-home off queues every target")
expect(home.areaAccessories.allSatisfy { $0.isOn != true }, "Everything shows off immediately")
settleQueue(home)
let batchArgs = accessoryControls().last!
expect(accessoryControls().count == batchBefore + 1 && batchArgs.first == "--batch", "Several devices go out in one batched run")
expect(batchArgs[1].contains("test-room") && batchArgs[1].contains("group"), "The batch carries every device")
expect(home.areaAccessories.first { $0.id == "group" }?.isOn == true && home.message.contains("主卧筒灯未调整成功"),
    "Only the device the worker reports as failed is named and reverted: \(home.message)")
try FileManager.default.removeItem(at: accessoryRuntime.appendingPathComponent("fail-control"))

// A tap stops a running refresh instead of waiting behind it.
try Data().write(to: accessoryRuntime.appendingPathComponent("slow-refresh"))
home.refresh()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
expect(home.active && home.process?.arguments?.contains("--refresh") == true, "Refresh must be running")
let tapStart = Date()
home.setAccessory("lamp", "light.on", value: true)
settleQueue(home)
expect(Date().timeIntervalSince(tapStart) < 2.5 && home.phase == "complete", "A tap must not wait for the slow refresh")
try FileManager.default.removeItem(at: accessoryRuntime.appendingPathComponent("slow-refresh"))

// Favourites persist and toggle without switching rooms.
UserDefaults.standard.removeObject(forKey: "favorites")
home.favorites = []
home.toggleFavorite("c1"); home.toggleFavorite("lamp")
expect(home.favoriteAccessories.map(\.id) == ["c1", "lamp"] && UserDefaults.standard.stringArray(forKey: "favorites") == ["c1", "lamp"],
    "Favourites keep their order and persist")
home.quickToggle(home.favoriteAccessories[1])
expect(home.pending["lamp"]?["light.on"] == AnyHashable(true), "Clicking a favourite light switches it")
settleQueue(home)
home.quickToggle(home.favoriteAccessories[0])
expect(home.pending["c1"]?["curtain.motor-control"] == AnyHashable(2.0), "Clicking an open curtain closes it")
settleQueue(home)
home.toggleFavorite("c1")
expect(home.favorites == ["lamp"], "Favourites can be removed")
UserDefaults.standard.removeObject(forKey: "favorites")

func accessoryControls() -> [[String]] {
    guard let text = try? String(contentsOf: accessoryRuntime.appendingPathComponent("controls.jsonl"), encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String] }
}
func settleQueue(_ model: AppModel) {
    let deadline = Date(timeIntervalSinceNow: 6)
    repeat { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    while (model.active || model.inFlight != nil || !model.pending.isEmpty) && Date() < deadline
    expect(!model.active && model.inFlight == nil && model.pending.isEmpty, "Accessory queue must drain")
}
let realReport = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))) as! [String: Any]
var kinds = Set<String>()
for raw in realReport["accessories"] as? [[String: Any]] ?? [] {
    guard let item = AppModel.accessory(raw), item.online, kinds.insert(item.kind + "\(item.group)").inserted,
          !AccessoryDetail.controls(item).isEmpty else { continue }
    let detail = NSHostingView(rootView: AccessoryDetail(item: item, model: home).frame(width: 344))
    expect(abs(detail.fittingSize.height - AccessoryDetail.height(item)) <= 1,
        "Detail height estimate for \(item.kind): \(AccessoryDetail.height(item)) vs \(detail.fittingSize.height)")
}
// The compact air-conditioner card and the tile grid report their real heights.
home.selectArea("主卧")
if let room = home.areaRoom {
    for expanded in [false, true] {
        let card = NSHostingView(rootView: ClimateProbe(model: home, expanded: expanded).frame(width: 344))
        expect(abs(card.fittingSize.height - ControlView.climateHeight(room, expanded: expanded)) <= 1,
            "Climate card height expanded=\(expanded): \(ControlView.climateHeight(room, expanded: expanded)) vs \(card.fittingSize.height)")
    }
}
// Every room fits without scrolling: one row up to seven rooms, two rows beyond.
expect(ControlView.roomRowsHeight(7) == ControlView.roomChipHeight && ControlView.roomRowsHeight(9) == ControlView.roomChipHeight * 2 + 6,
    "Room rows: one row up to seven rooms")
let roomsView = NSHostingView(rootView: RoomProbe(model: home).frame(width: 344))
expect(abs(roomsView.fittingSize.height - ControlView.roomRowsHeight(home.areas.count)) <= 1, "Room row height matches")
let firstArea = home.area
home.stepArea(1); let secondArea = home.area
home.stepArea(-1)
expect(secondArea != firstArea && home.area == firstArea, "Arrow keys move between rooms and back")
home.selectArea(home.areas.last!); home.stepArea(1)
expect(home.area == home.areas.first, "Stepping past the last room wraps around")
home.selectArea("主卧")
let gridItems = home.areaAccessories
let grid = NSHostingView(rootView: GridProbe(model: home, items: gridItems).frame(width: 344))
expect(abs(grid.fittingSize.height - ControlView.gridHeight(gridItems, detail: nil)) <= 1,
    "Tile grid height: \(ControlView.gridHeight(gridItems, detail: nil)) vs \(grid.fittingSize.height)")
print("Native accessories: rooms, groups, optimistic queue, merged commands, revert, curtain actions, turn-off batches, refresh preemption and favourites passed")

// Flood alarms: notify once, remind every 30 minutes, report recovery, flag the menu bar.
let floodRuntime = testRuntime.appendingPathComponent("flood-test")
try FileManager.default.createDirectory(at: floodRuntime, withIntermediateDirectories: true)
try seedAuthenticated(runtime: floodRuntime)
func floodReport(_ wet: Bool) throws {
    try saveFixture("report.json", ["devices": [["device": ["did": "test-room", "name": "主卧空调"], "room": "主卧",
        "spec": controlSpec, "state": controlState]], "accessories": [],
        "alarms": [["device": ["did": "flood", "name": "水浸卫士", "isOnline": true], "room": "厨房", "kind": "submersion-sensor",
                    "props": [["address": "submersion-sensor.submersion-state", "format": "bool", "readable": true, "writable": false]],
                    "state": ["submersion-sensor.submersion-state": wet], "read_at": Date().timeIntervalSince1970]]],
        runtime: floodRuntime)
}
try floodReport(false)
let flood = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: floodRuntime,
    credentialReader: { _ in (errSecSuccess, testSessionData) })
var notices: [String] = []
var title = ""
flood.notifier = { title, _ in notices.append(title) }
flood.titleChanged = { title = $0 }
expect(flood.alarms.count == 1 && flood.wetAlarms.isEmpty && notices.isEmpty, "A dry sensor raises nothing")
try floodReport(true); flood.poll()
expect(notices == ["检测到漏水"] && title.contains("漏水") && flood.wetAlarms.count == 1, "A wet sensor notifies and flags the menu bar")
flood.evaluateAlarms()
expect(notices.count == 1, "No repeated notice within 30 minutes")
flood.evaluateAlarms(now: Date(timeIntervalSinceNow: 31 * 60))
expect(notices.count == 2, "Still wet after 30 minutes: remind again")
try floodReport(false); flood.poll()
expect(notices.last == "漏水已恢复" && !title.contains("漏水"), "Recovery is reported and the menu bar returns to normal")
flood.checkAlarms(); finish(flood)
expect(flood.workerRequests == 1, "Background check runs the small alarm read")
print("Native flood alarms: notify, remind, recover, menu bar flag and background check passed")

// Sleep timers: fire once, persist, drop stale ones, include outlets, never curtains.
UserDefaults.standard.removeObject(forKey: "timers")
let timerRuntime = testRuntime.appendingPathComponent("timer-test")
try FileManager.default.createDirectory(at: timerRuntime, withIntermediateDirectories: true)
try seedAuthenticated(runtime: timerRuntime)
let outletProps: [[String: Any]] = [["address": "switch.on", "format": "bool", "readable": true, "writable": true]]
try saveFixture("report.json", ["devices": [["device": ["did": "test-room", "name": "主卧空调"], "room": "主卧",
    "spec": controlSpec, "state": controlState]], "accessories": [
        ["device": ["did": "plug", "name": "插座", "isOnline": true], "room": "主卧", "kind": "outlet", "group": false,
         "props": outletProps, "state": ["switch.on": true]],
        ["device": ["did": "lamp", "name": "吸顶灯", "isOnline": true], "room": "主卧", "kind": "light", "group": false,
         "props": lightProps, "state": ["light.on": false]],
        ["device": ["did": "c1", "name": "窗帘", "isOnline": true], "room": "主卧", "kind": "curtain", "group": false,
         "props": curtainProps, "state": [:]]]], runtime: timerRuntime)
let timed = AppModel(worker: URL(fileURLWithPath: CommandLine.arguments[2]), runtime: timerRuntime,
    credentialReader: { _ in (errSecSuccess, testSessionData) })
var timerNotices: [String] = []
timed.notifier = { _, body in timerNotices.append(body) }
let curtainItem = timed.accessories.first { $0.id == "c1" }!, plugItem = timed.accessories.first { $0.id == "plug" }!
expect(!AppModel.timerEligible(curtainItem) && AppModel.timerEligible(plugItem), "Curtains cannot be timed; outlets can")
let start = Date()
timed.setTimer("test-room", hours: 1, now: start)
timed.setTimer("plug", hours: 2, now: start)
timed.setTimer("lamp", hours: 1, now: start)
expect((UserDefaults.standard.dictionary(forKey: "timers") as? [String: Double])?.count == 3, "Timers persist across restarts")
expect(AppModel.remaining(start.addingTimeInterval(3600 + 1), now: start) == "1:01 后关闭", "Countdown text")
timed.checkTimers(now: start.addingTimeInterval(1800))
expect(timed.pending.isEmpty && timed.timers.count == 3, "Nothing fires early")
timed.checkTimers(now: start.addingTimeInterval(3601))
expect(timed.pending["test-room"] == ["on": AnyHashable(false)] && timed.pending["lamp"] == nil && timed.timers.keys.sorted() == ["plug"],
    "Due timers switch running devices off; devices already off are left alone")
expect(timerNotices.last == "已关闭 主卧空调", "A fired timer is reported")
settleQueue(timed)
timed.checkTimers(now: start.addingTimeInterval(2 * 3600 + 3 * 3600))
expect(timed.pending.isEmpty && timed.timers.isEmpty, "A timer missed by more than two hours is dropped")
timed.setTimer("plug", hours: 1, now: start)
timed.checkTimers(now: start.addingTimeInterval(3601))
expect(timed.pending["plug"] == ["switch.on": AnyHashable(false)], "Timed outlets switch off")
settleQueue(timed)
timed.setTimer("lamp", hours: 4); timed.cancelTimer("lamp")
expect(timed.timers.isEmpty, "Timers can be cancelled")
UserDefaults.standard.removeObject(forKey: "timers")
print("Native sleep timers: eligibility, persistence, firing, stale drop, outlets and cancel passed")

// Appearance: follow macOS by default; light / dark persist and apply app-wide.
UserDefaults.standard.removeObject(forKey: "appearance")
let preferences = Preferences()
expect(preferences.appearance == "system" && Preferences.nsAppearance("system") == nil, "Default follows the system")
preferences.appearance = "light"
expect(NSApp.appearance?.name == .aqua && UserDefaults.standard.string(forKey: "appearance") == "light", "Light applies and persists")
preferences.appearance = "dark"
expect(NSApp.appearance?.name == .darkAqua, "Dark applies")
preferences.appearance = "system"
expect(NSApp.appearance == nil, "Back to following the system")
UserDefaults.standard.set("purple", forKey: "appearance")
expect(Preferences().appearance == "system", "Unknown saved values fall back to the system")
UserDefaults.standard.removeObject(forKey: "appearance")
func resolved(_ color: Color, _ name: NSAppearance.Name) -> NSColor {
    var result = NSColor.clear
    NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = NSColor(color).usingColorSpace(.sRGB)! }
    return result
}
expect(resolved(ControlView.accent, .aqua).greenComponent < 0.6 && resolved(ControlView.accent, .darkAqua).greenComponent > 0.8,
    "The accent darkens in light mode for contrast")
print("Native appearance: system default, light, dark, persistence and adaptive colours passed")

let leaseRuntime = testRuntime.appendingPathComponent("lease-test")
try FileManager.default.createDirectory(at: leaseRuntime, withIntermediateDirectories: true)
var lease = ApplicationLease(runtime: leaseRuntime)
expect(lease != nil, "First app instance must acquire its lease")
expect(ApplicationLease(runtime: leaseRuntime) == nil, "A duplicate app instance must not start another authorization loop")
lease = nil
expect(ApplicationLease(runtime: leaseRuntime) != nil, "Exiting the app must release its lease")
print("Native authentication: single main-app read, worker private pipes, retry suspension, revocation race, legacy migration, optimistic controls, and duplicate-instance lease passed")

// Test-only wrappers exposing ControlView sections.
struct ClimateProbe: View {
    @ObservedObject var model: AppModel
    let expanded: Bool
    var body: some View { ControlView(model: model).climateCardForTesting(model.areaRoom!, expanded: expanded) }
}
struct GridProbe: View {
    @ObservedObject var model: AppModel
    let items: [Accessory]
    var body: some View { ControlView(model: model).tileGrid(items, favorites: false) }
}
struct RoomProbe: View {
    @ObservedObject var model: AppModel
    var body: some View { ControlView(model: model).roomTabs }
}
