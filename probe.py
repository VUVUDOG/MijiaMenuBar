"""Cloud worker for the menu bar app. Credentials stay in macOS Keychain."""
import argparse
import json
import os
import sys
import time
from pathlib import Path

import requests
from keyring.errors import KeyringError

from auth import SessionStore, StaleSession
from cloud import CloudError, XiaomiCloud

ROOT = Path(__file__).resolve().parent
RUNTIME = Path(os.environ.get("HITACHI_RUNTIME_PATH", str(ROOT / ".runtime")))
SERVICE = "HitachiMenuBar.CloudWorker" if getattr(sys, "frozen", False) else "HitachiMenuBar.XiaomiCloud"
store = None
session_output = False


def write_json(name, value):
    store.write_json(name, value)


def status(phase, message, reason=None):
    try:
        write_json("status.json", {"phase": phase, "message": message, **({"reason": reason} if reason else {})})
    except StaleSession:
        return
    print(message, file=sys.stderr if session_output else sys.stdout, flush=True)


SENSOR_WORDS = ("sensor_ht", "temp_hum", "thermo", "sensor_temp", "weather", "airmonitor", "airm.")


def is_air_conditioner(device):
    return "空调" in device.get("name", "") or any(
        w in device.get("model", "").lower() for w in ("hitachi", "aircondition", ".airc"))


def discover_sensors(cloud, devices):
    """Find MiJia thermometers and remember which property holds temperature / humidity."""
    sensors = []
    for device in devices:
        model = device.get("model", "").lower()
        if is_air_conditioner(device) or not (
                any(w in model for w in SENSOR_WORDS) or any(w in device.get("name", "") for w in ("温度", "温湿度"))):
            continue
        entry = {"device": {k: device.get(k) for k in ("did", "name", "model", "isOnline")},
                 "room": cloud.device_rooms.get(device.get("did"))}
        try:
            spec = cloud.spec(device.get("model"))
            entry["fields"] = cloud.climate_fields(spec) if spec else {}
        except (CloudError, requests.RequestException, ValueError, KeyError):
            entry["fields"] = {}
        if entry["fields"]:
            sensors.append(entry)
    return sensors


def pair_sensor(item, sensors):
    """Same MiJia room first; otherwise a sensor whose name or room mentions the AC's room name."""
    readable = [s for s in sensors if "temperature" in s.get("values", {})]
    room = item.get("room")
    same_room = [s for s in readable if room and s.get("room") == room]
    if same_room:
        return same_room[0]
    label = item["device"].get("name", "").replace("空调", "").strip()
    return next((s for s in readable if label and (label in s["device"].get("name", "") or label == s.get("room"))), None)


def read_climate(cloud, report):
    from concurrent.futures import ThreadPoolExecutor

    def read(sensor):
        try:
            sensor["values"], sensor["codes"] = cloud.fork().read_climate(sensor["device"]["did"], sensor["fields"])
        except (CloudError, requests.RequestException, ValueError, KeyError):
            sensor["values"], sensor["codes"] = {}, {"temperature": "error"}
        sensor["read_at"] = time.time()

    sensors = report.get("sensors", [])
    if sensors:
        with ThreadPoolExecutor(max_workers=min(6, len(sensors))) as pool:
            list(pool.map(read, sensors))
    for item in report["devices"]:
        sensor = pair_sensor(item, report.get("sensors", []))
        item["climate"] = None if not sensor else {
            "temperature": sensor["values"]["temperature"], "humidity": sensor["values"].get("relative-humidity"),
            "sensor": sensor["device"].get("name")}


# Accessory kinds offered in the panel and the property addresses each may expose.
# Wall switches are deliberately excluded: they can cut power to smart lights.
ACCESSORY_KINDS = ("light", "curtain", "outlet", "fan", "air-purifier", "bath-heater")
CONTROL_ADDRESSES = (
    "light.on", "light.brightness", "light.color-temperature",
    "switch.on",
    "fan.on", "fan.mode", "fan.fan-level", "fan.horizontal-swing",
    "air-purifier.on", "air-purifier.mode", "air-purifier.fan-level",
    "curtain.motor-control", "curtain.target-position",
    "ptc-bath-heater.mode", "ptc-bath-heater.ventilation", "ptc-bath-heater.target-temperature",
)
# Bump when the property whitelist changes so saved reports rediscover accessories once.
ACCESSORY_SCHEMA = 2
READING_ADDRESSES = (
    "curtain.current-position", "power-consumption.electric-power",
    "environment.pm2.5-density", "environment.temperature", "environment.relative-humidity",
)


def accessory_props(spec):
    """Only the whitelisted properties, with the metadata the panel needs to render them."""
    props = []
    for address in CONTROL_ADDRESSES + READING_ADDRESSES:
        service, prop = XiaomiCloud.find_property(spec, address)
        if not prop:
            continue
        access = prop.get("access", [])
        if address in CONTROL_ADDRESSES and "write" not in access:
            continue
        if address in READING_ADDRESSES and "read" not in access:
            continue
        entry = {"address": address, "siid": service["iid"], "piid": prop["iid"],
                 "format": prop.get("format"), "readable": "read" in access,
                 "writable": address in CONTROL_ADDRESSES}
        if prop.get("value-range"):
            entry["range"] = prop["value-range"]
        if prop.get("value-list"):
            entry["options"] = [{"value": o["value"], "description": o.get("description", "")}
                                for o in prop["value-list"]]
        if prop.get("unit"):
            entry["unit"] = prop["unit"]
        props.append(entry)
    return props


ALARM_ADDRESSES = ("submersion-sensor.submersion-state", "battery.battery-level")


def discover_alarms(cloud, devices, home):
    """Flood (submersion) sensors in the home; they are polled even while the panel is closed."""
    alarms = []
    for device in devices:
        did, model = device.get("did"), device.get("model")
        if not did or not model or (home and cloud.device_homes.get(did) != home):
            continue
        try:
            spec = cloud.spec(model)
        except (CloudError, requests.RequestException, ValueError, KeyError):
            continue
        if XiaomiCloud.kind((spec or {}).get("type")) != "submersion-sensor":
            continue
        props = []
        for address in ALARM_ADDRESSES:
            service, prop = XiaomiCloud.find_property(spec, address)
            if prop and "read" in prop.get("access", []):
                props.append({"address": address, "siid": service["iid"], "piid": prop["iid"],
                              "format": prop.get("format"), "readable": True, "writable": False})
        if any(p["address"] == ALARM_ADDRESSES[0] for p in props):
            alarms.append({"device": {k: device.get(k) for k in ("did", "name", "model", "isOnline")},
                           "room": cloud.device_rooms.get(did) or "其他", "kind": "submersion-sensor",
                           "props": props, "state": {}})
    return alarms


def choose_home(cloud, summaries):
    """The home that holds the air conditioners, otherwise the one with the most devices."""
    homes = [cloud.device_homes.get(d["did"]) for d in summaries]
    homes = [h for h in homes if h] or [h for h in cloud.device_homes.values() if h]
    return max(set(homes), key=homes.count) if homes else None


def discover_accessories(cloud, devices, home):
    accessories = []
    for device in devices:
        did, model = device.get("did"), device.get("model")
        if not did or not model or is_air_conditioner(device):
            continue
        if home and cloud.device_homes.get(did) != home:
            continue
        try:
            spec = cloud.spec(model)
        except (CloudError, requests.RequestException, ValueError, KeyError):
            continue
        kind = XiaomiCloud.kind((spec or {}).get("type"))
        if kind not in ACCESSORY_KINDS:
            continue
        props = accessory_props(spec)
        if not any(p["writable"] for p in props):
            continue
        accessories.append({"device": {k: device.get(k) for k in ("did", "name", "model", "isOnline")},
                            "room": cloud.device_rooms.get(did) or "其他", "kind": kind,
                            "group": model.startswith("mijia.light.group"), "props": props, "state": {}})
    return accessories


def read_accessories(cloud, accessories):
    items = [(a["device"]["did"], p["address"], p["siid"], p["piid"])
             for a in accessories if a["device"].get("isOnline", True) for p in a["props"] if p["readable"]]
    try:
        values = cloud.read_addresses(items)
    except (CloudError, requests.RequestException, ValueError, KeyError):
        return
    for accessory in accessories:
        did = accessory["device"]["did"]
        if did in values:
            accessory["state"] = values[did]
            accessory["read_at"] = time.time()


def control_devices(cloud, report, commands):
    """Send commands for several devices in parallel; returns {did: error message} for failures."""
    from concurrent.futures import ThreadPoolExecutor
    acs = {d["device"]["did"]: d for d in report["devices"]}
    accessories = {a["device"]["did"]: a for a in report.get("accessories", [])}

    def run(did, changes):
        # Each thread gets its own HTTP session.
        client = XiaomiCloud(cloud.credentials)
        try:
            if did in accessories:
                client.set_stored(accessories[did]["device"], accessories[did]["props"], changes)
            elif did in acs and acs[did].get("spec"):
                client.set_properties(acs[did]["device"], acs[did]["spec"], changes)
            else:
                raise CloudError("没有找到这个设备")
        except CloudError as exc:
            return did, str(exc)
        except requests.RequestException:
            return did, "连接米家服务失败，请稍后重试"
        return did, None

    with ThreadPoolExecutor(max_workers=min(8, max(1, len(commands)))) as pool:
        results = list(pool.map(lambda item: run(*item), commands.items()))
    return {did: error for did, error in results if error}


def main(argv=None):
    global store, session_output
    parser = argparse.ArgumentParser()
    parser.add_argument("--login", action="store_true", help="重新扫码登录")
    parser.add_argument("--logout", action="store_true", help="退出登录并清除本机设备缓存")
    parser.add_argument("--refresh", action="store_true", help="刷新已发现设备的状态")
    parser.add_argument("--room", help="指定已发现设备的标识")
    parser.add_argument("--field", action="append",
                        help="控制属性（空调字段或配件地址如 light.on），可重复；与 --value 按顺序配对")
    parser.add_argument("--scope", help="刷新时只读取该房间的配件")
    parser.add_argument("--alarms", action="store_true", help="只读取水浸传感器（后台定时检查）")
    parser.add_argument("--batch", help="JSON：{设备标识: {属性: 值}}，多个设备并行控制")
    parser.add_argument("--value", action="append", help="JSON 控制值，可重复")
    parser.add_argument("--import-session", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--session-stdin", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--session-output", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--require-session", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    session_output = args.session_output
    os.umask(0o077)
    RUNTIME.mkdir(parents=True, exist_ok=True, mode=0o700)
    store = SessionStore(RUNTIME, SERVICE)
    try:
        action = "import" if args.import_session else "logout" if args.logout else "login" if args.login else None
        store.begin(action, os.environ.get("HITACHI_AUTH_GENERATION"))
        if args.logout:
            status("logged_out", "已退出登录")
            return 0
        if args.import_session:
            session = json.load(sys.stdin)
            if not all(isinstance(session.get(k), str) and session[k] for k in ("user_id", "ssecurity", "service_token")):
                raise CloudError("登录会话格式不正确")
            store.save_credentials(session)
            print("登录会话已迁移到本机钥匙串", flush=True)
            return 0
        if args.require_session and not args.login and not args.session_stdin:
            # The GUI owns credential reads. A missing/malformed private pipe
            # must never silently cause a second system authorization request.
            with store.locked():
                authenticated = store._current()["state"] == "authenticated"
            status("error" if authenticated else "logged_out",
                   "登录凭证未传入，请手动刷新或重新登录" if authenticated else "请扫码登录米家",
                   reason="keychain_access" if authenticated else None)
            return 1 if authenticated else 0
        if not args.login and not args.session_stdin:
            status("authenticating", "正在读取钥匙串中的登录会话…")
        credentials = store.memory_credentials(json.load(sys.stdin)) if args.session_stdin else store.credentials()
        cloud = XiaomiCloud(credentials)
        if args.login:
            status("starting", "正在获取米家登录二维码…")
            image, login = cloud.start_qr()
            store.write_qr(image)
            status("awaiting_scan", "请用米家 App 的扫一扫扫描登录二维码，并在手机上确认登录。")
            cloud.wait_qr(login)
            store.save_credentials(cloud.credentials)
            store.clear_qr()
        elif not cloud.credentials:
            status("logged_out", "请扫码登录米家")
            return 0
        if session_output:
            # The native app captures this pipe privately. No credentials go in
            # argv, environment, logs, status.json or other runtime files.
            print(json.dumps({"generation": store.generation, "session": cloud.credentials}), flush=True)
        if args.batch or args.room or args.field or args.value or args.refresh or args.alarms:
            if not (RUNTIME / "report.json").exists():
                raise CloudError("请先同步空调设备")
            report = json.loads((RUNTIME / "report.json").read_text())
            if ("sensors" not in report or "accessories" not in report or "alarms" not in report
                    or report.get("accessory_schema") != ACCESSORY_SCHEMA):
                # Reports from older versions: discover rooms, sensors and accessories once.
                # A failed lookup must not block the air-conditioner refresh; retry next time.
                try:
                    devices = cloud.devices()
                    for item in report["devices"]:
                        item["room"] = cloud.device_rooms.get(item["device"]["did"])
                    report["sensors"] = discover_sensors(cloud, devices)
                    report["home"] = choose_home(cloud, [d["device"] for d in report["devices"]])
                    report["accessories"] = discover_accessories(cloud, devices, report["home"])
                    report["alarms"] = discover_alarms(cloud, devices, report["home"])
                    read_accessories(cloud, report["accessories"] + report["alarms"])
                    report["accessory_schema"] = ACCESSORY_SCHEMA
                except (CloudError, requests.RequestException, ValueError, KeyError):
                    pass
            targets = report["devices"]
            if args.batch or args.room or args.field or args.value:
                if args.batch:
                    commands = json.loads(args.batch)
                elif args.room and args.field and args.value and len(args.field) == len(args.value):
                    commands = {args.room: {f: json.loads(v) for f, v in zip(args.field, args.value)}}
                else:
                    raise CloudError("控制指令缺少房间、属性或数值")
                status("controlling", "正在发送指令并确认设备状态…")
                failures = control_devices(cloud, report, commands)
                # Only the controlled devices changed; everything else keeps its last reading.
                targets = [d for d in report["devices"] if d["device"]["did"] in commands]
                read_accessories(cloud, [a for a in report.get("accessories", []) if a["device"]["did"] in commands])
                for item in targets:
                    if item.get("spec"):
                        item["state"] = cloud.read_state(item["device"], item["spec"])
                report["read_at"] = time.time()
                write_json("report.json", report)
                if failures:
                    names = {d["device"]["did"]: d["device"].get("name") for d in
                             report["devices"] + report.get("accessories", [])}
                    first = next(iter(failures.values()))
                    label = "、".join(names.get(did) or "设备" for did in failures)
                    write_json("status.json", {"phase": "error", "message": f"{label}：{first}",
                                               "failed": ",".join(failures)})
                    return 1
                status("complete", "指令已执行，云端回读已确认")
                return 0
            if args.alarms:
                # Background check while the panel is closed: one small read, no status message changes.
                read_accessories(cloud, report.get("alarms", []))
                report["alarms_read_at"] = time.time()
                write_json("report.json", report)
                return 0
            status("reading", "正在刷新空调状态…")
            # Air conditioners, thermometers and the room's accessories are read in parallel.
            # Accessories are many: refresh only the room being looked at.
            from concurrent.futures import ThreadPoolExecutor
            scoped = [a for a in report.get("accessories", []) if not args.scope or a["room"] == args.scope]
            scoped += report.get("alarms", [])

            def read_ac(item):
                if item.get("spec"):
                    item["state"] = cloud.fork().read_state(item["device"], item["spec"])

            with ThreadPoolExecutor(max_workers=8) as pool:
                jobs = [pool.submit(read_ac, item) for item in targets]
                jobs.append(pool.submit(read_climate, cloud, report))
                jobs.append(pool.submit(read_accessories, cloud.fork(), scoped))
                for job in jobs:
                    job.result()
            report["read_at"] = time.time()
            write_json("report.json", report)
            status("complete", "设备状态已更新" if not args.field else "指令已执行，云端回读已确认")
            return 0
        status("reading", "已登录，正在读取米家第三方设备…")
        devices = cloud.devices()
        # Export only the information relevant to this project; never cloud tokens/IPs/MACs.
        summaries = [{k: d.get(k) for k in ("did", "name", "model", "isOnline")}
                     for d in devices if is_air_conditioner(d)]
        write_json("devices.json", summaries)
        reports = []
        specs = {}
        for device in summaries:
            report = {"device": device, "room": cloud.device_rooms.get(device["did"])}
            model = device.get("model")
            try:
                if model and model not in specs:
                    specs[model] = cloud.spec(model)
                spec = specs.get(model)
                if spec:
                    report["spec"] = spec
                    report["state"] = cloud.read_state(device, spec)
                else:
                    report["message"] = "未找到标准 MIoT 功能定义，需要继续确认第三方控制接口。"
            except (CloudError, requests.RequestException, ValueError, KeyError) as exc:
                report["message"] = str(exc) if isinstance(exc, CloudError) else "状态查询失败，需要检查接口兼容性。"
            reports.append(report)
        home = choose_home(cloud, summaries)
        accessories = discover_accessories(cloud, devices, home)
        alarms = discover_alarms(cloud, devices, home)
        read_accessories(cloud, accessories + alarms)
        full = {"devices": reports, "sensors": discover_sensors(cloud, devices), "home": home,
                "accessories": accessories, "alarms": alarms, "accessory_schema": ACCESSORY_SCHEMA,
                "total_device_count": len(devices), "read_at": time.time()}
        read_climate(cloud, full)
        write_json("report.json", full)
        if not summaries:
            status("not_found", "登录成功，但没有找到空调设备；需要继续核对第三方设备同步接口。")
        else:
            status("complete", "设备状态已更新")
    except StaleSession:
        return 0
    except BrokenPipeError:
        # The app quit while this run was still talking to it; nothing to report.
        return 0
    except KeyringError:
        status("error", "钥匙串未授权，请允许访问后手动刷新，或重新扫码登录", reason="keychain_access")
        return 1
    except CloudError as exc:
        status("error", str(exc))
        return 1
    except requests.RequestException as exc:
        code = exc.response.status_code if exc.response is not None else "network"
        status("error", f"连接米家服务失败（{code}），请稍后刷新。")
        return 1
    except Exception as exc:
        status("error", f"连接未完成（{type(exc).__name__}），请重试。")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
