"""Xiaomi cloud client for explicitly selected HVAC properties."""
import base64
import hashlib
import json
import os
import time
from urllib.parse import urlparse

import requests
from Crypto.Cipher import ARC4


class CloudError(Exception):
    pass


def decode_account(text):
    return json.loads(text.removeprefix("&&&START&&&"))


def rc4(key, payload):
    cipher = ARC4.new(base64.b64decode(key))
    cipher.encrypt(bytes(1024))
    return cipher.encrypt(payload)


def signature(path, params, signed_nonce):
    parts = ["POST", path.removeprefix("/app")]
    parts.extend(f"{k}={v}" for k, v in params.items())
    parts.append(signed_nonce)
    return base64.b64encode(hashlib.sha1("&".join(parts).encode()).digest()).decode()


class XiaomiCloud:
    def __init__(self, credentials=None):
        self.session = requests.Session()
        self.agent = "Android-7.1.1-1.0.0-ONEPLUS A3010-136-HITACHIMENUBAR APP/xiaomi.smarthome APPV/62830"
        self.session.headers["User-Agent"] = self.agent
        self.credentials = credentials
        self.device_rooms = {}
        self._instances = None

    @staticmethod
    def account_url(url):
        parsed = urlparse(url)
        # Account replies may carry login secrets in the query. Never log these URLs.
        if parsed.scheme != "https" or not parsed.hostname or not any(
            parsed.hostname == host or parsed.hostname.endswith("." + host)
            for host in ("xiaomi.com", "mi.com")
        ):
            raise CloudError("登录服务返回了无法识别的地址")
        return url

    def start_qr(self):
        response = self.session.get(
            "https://account.xiaomi.com/longPolling/loginUrl",
            params={"_qrsize": "480", "qs": "%3Fsid%3Dxiaomiio%26_json%3Dtrue",
                    "callback": "https://sts.api.io.mi.com/sts", "_hasLogo": "false",
                    "sid": "xiaomiio", "serviceParam": "", "_locale": "zh_CN",
                    "_dc": str(int(time.time() * 1000))}, timeout=20,
        )
        response.raise_for_status()
        data = decode_account(response.text)
        if not all(data.get(k) for k in ("qr", "lp", "loginUrl")):
            raise CloudError(f"米家扫码登录暂不可用（code={data.get('code', 'unknown')}）")
        image = self.session.get(self.account_url(data["qr"]), timeout=20)
        image.raise_for_status()
        return image.content, data

    def wait_qr(self, data):
        deadline = time.monotonic() + min(float(data.get("timeout", 180)), 300)
        while time.monotonic() < deadline:
            try:
                response = self.session.get(self.account_url(data["lp"]), timeout=20)
            except requests.Timeout:
                continue
            response.raise_for_status()
            result = decode_account(response.text)
            if result.get("code") != 0 or not result.get("ssecurity"):
                raise CloudError(f"扫码登录未完成或已过期（code={result.get('code', 'unknown')}）")
            token_response = self.session.get(self.account_url(result["location"]), timeout=20)
            token_response.raise_for_status()
            tokens = [c.value for r in [*token_response.history, token_response]
                      for c in r.cookies if c.name == "serviceToken"]
            if not tokens:
                tokens = [c.value for c in self.session.cookies if c.name == "serviceToken"]
            if not tokens:
                raise CloudError("扫码已确认，但未获得米家云端会话")
            self.credentials = {"user_id": str(result["userId"]),
                                "ssecurity": result["ssecurity"], "service_token": tokens[-1]}
            return
        raise CloudError("二维码已过期，请重新生成后扫码")

    def api(self, path, payload):
        # Restrict the compatibility probe to read-only operations.
        allowed = {"v2/homeroom/gethome_merged", "v2/home/home_device_list",
                   "home/device_list", "miotspec/prop/get"}
        if path not in allowed:
            raise CloudError("验证工具只支持读取设备")
        return self._request(path, payload)

    def set_property(self, device, spec, field, value):
        return self.set_properties(device, spec, {field: value})

    def set_properties(self, device, spec, values):
        """Air-conditioner fields: validate every change, send them together, read them back."""
        allowed = {"on", "mode", "target-temperature", "fan-level"}
        resolved = []
        for field, value in values.items():
            if field not in allowed:
                raise CloudError("不支持这个控制功能")
            properties = [(s, p) for s in spec.get("services", [])
                          if any(part in s.get("type", "") for part in (":air-conditioner:", ":fan-control:"))
                          for p in s.get("properties", []) if f":{field}:" in p.get("type", "")]
            if len(properties) != 1:
                raise CloudError("设备未提供唯一的控制属性")
            resolved.append((properties[0][0], properties[0][1], value))
        return self._apply(device, resolved, "空调控制未成功")

    @staticmethod
    def kind(urn):
        parts = (urn or "").split(":")
        return parts[3] if len(parts) > 3 else ""

    @classmethod
    def find_property(cls, spec, address):
        """Resolve "service-kind.property-kind" (e.g. light.brightness) to one property.

        The first matching service wins; when a service repeats a property kind,
        the one with a value list (named options) is preferred."""
        service_kind, _, prop_kind = address.partition(".")
        for service in spec.get("services", []):
            if cls.kind(service.get("type")) != service_kind:
                continue
            matches = [p for p in service.get("properties", []) if cls.kind(p.get("type")) == prop_kind]
            if matches:
                return service, next((p for p in matches if p.get("value-list")), matches[0])
        return None, None

    def set_addresses(self, device, spec, values):
        """Generic accessory control by property address, validated against the device spec."""
        resolved = []
        for address, value in values.items():
            service, prop = self.find_property(spec, address)
            if not prop:
                raise CloudError("设备未提供这个控制功能")
            resolved.append((service, prop, value))
        return self._apply(device, resolved, "设备控制未成功")

    def set_stored(self, device, props, values):
        """Accessory control from the property metadata saved at sync time (no spec download)."""
        by_address = {p["address"]: p for p in props}
        resolved = []
        for address, value in values.items():
            meta = by_address.get(address)
            if not meta or not meta.get("writable"):
                raise CloudError("该设备不支持这个控制功能")
            prop = {"iid": meta["piid"], "format": meta.get("format") or "",
                    "access": ["write"] + (["read"] if meta.get("readable") else [])}
            if meta.get("range"):
                prop["value-range"] = meta["range"]
            if meta.get("options"):
                prop["value-list"] = meta["options"]
            resolved.append(({"iid": meta["siid"]}, prop, value))
        return self._apply(device, resolved, "设备控制未成功")

    @staticmethod
    def _validate(prop, value):
        if "write" not in prop.get("access", []):
            raise CloudError("该设备属性不可写")
        if prop.get("format") == "bool":
            if type(value) is not bool:
                raise CloudError("开关值必须是 true 或 false")
            return value
        if type(value) not in (int, float):
            raise CloudError("控制值必须是数字")
        if prop.get("format", "").startswith(("uint", "int")):
            if value != int(value):
                raise CloudError("控制值必须是整数")
            value = int(value)
        if options := prop.get("value-list"):
            if value not in [o["value"] for o in options]:
                raise CloudError("控制值不在设备支持的选项中")
        if limits := prop.get("value-range"):
            low, high, step = limits
            if not low <= value <= high or abs((value - low) / step - round((value - low) / step)) > 1e-6:
                raise CloudError("数值超出设备范围或不符合调节步长")
        return value

    @staticmethod
    def _matches(prop, expected, actual):
        if actual == expected:
            return True
        # Some lights quantize brightness / colour temperature slightly.
        if limits := prop.get("value-range"):
            if isinstance(actual, (int, float)) and not isinstance(actual, bool):
                low, high, step = limits
                return abs(actual - expected) <= (high - low) * 0.02
        return False

    def _apply(self, device, resolved, failure):
        changes, checks = [], []
        for service, prop, value in resolved:
            value = self._validate(prop, value)
            change = {"did": device["did"], "siid": service["iid"], "piid": prop["iid"], "value": value}
            changes.append(change)
            # Write-only actions (e.g. curtain open/close) cannot be read back.
            if "read" in prop.get("access", []):
                checks.append((change, prop))
        if not changes:
            raise CloudError("没有需要发送的控制指令")
        result = self._request("miotspec/prop/set", {"params": changes})
        # code 1 means the device accepted the command and executes it asynchronously.
        if not isinstance(result, list) or len(result) != len(changes) or any(r.get("code") not in (0, 1) for r in result):
            failed = [r for r in result if r.get("code") not in (0, 1)] if isinstance(result, list) else []
            code = failed[0].get("code", "unknown") if failed else "unknown"
            raise CloudError(f"{failure}（code={code}）")
        if not checks:
            return result
        # A successful acknowledgement is not sufficient: read back every changed value.
        # Poll quickly so a confirmed change is reported as soon as the cloud reflects it.
        query = [{k: v for k, v in change.items() if k != "value"} for change, _ in checks]
        # Check early, then back off: most devices confirm within half a second.
        for delay in (0.15, 0.25, 0.3, 0.3, 0.4, 0.4, 0.5, 0.5, 0.6, 0.6):
            time.sleep(delay)
            state = self.api("miotspec/prop/get", {"params": query}) or []
            if all(any(p.get("code") == 0 and self._matches(prop, change["value"], p.get("value")) and
                       p.get("siid") == change["siid"] and p.get("piid") == change["piid"] for p in state)
                   for change, prop in checks):
                return result
        raise CloudError("指令已发送，但暂未确认设备状态；请刷新查看")

    def fork(self):
        """A client for another thread: same login and spec cache, separate HTTP session."""
        client = XiaomiCloud(self.credentials)
        client._instances = self._instances
        return client

    def read_addresses(self, items):
        """items: [(did, address, siid, piid)] -> {did: {address: value}}; batches of 10 read in parallel."""
        from concurrent.futures import ThreadPoolExecutor
        chunks = [items[start:start + 10] for start in range(0, len(items), 10)]

        def fetch(chunk):
            return chunk, self.fork().api("miotspec/prop/get", {"params": [
                {"did": did, "siid": siid, "piid": piid} for did, _, siid, piid in chunk]}) or []

        if len(chunks) <= 1:
            results = [(chunk, self.api("miotspec/prop/get", {"params": [
                {"did": did, "siid": siid, "piid": piid} for did, _, siid, piid in chunk]}) or []) for chunk in chunks]
        else:
            with ThreadPoolExecutor(max_workers=min(6, len(chunks))) as pool:
                results = list(pool.map(fetch, chunks))
        values = {}
        for chunk, state in results:
            for did, address, siid, piid in chunk:
                match = next((p for p in state if p.get("did") == did and p.get("siid") == siid
                              and p.get("piid") == piid and p.get("code") == 0 and "value" in p), None)
                if match:
                    values.setdefault(did, {})[address] = match["value"]
        return values

    def _request(self, path, payload):
        if not self.credentials:
            raise CloudError("请先扫码登录米家")
        cred = self.credentials
        nonce = base64.b64encode(os.urandom(8) + int(time.time() / 60).to_bytes(4, "big")).decode()
        signed_nonce = base64.b64encode(hashlib.sha256(
            base64.b64decode(cred["ssecurity"]) + base64.b64decode(nonce)).digest()).decode()
        url = "https://api.io.mi.com/app/" + path
        params = {"data": json.dumps(payload, separators=(",", ":"))}
        params["rc4_hash__"] = signature("/" + path, params, signed_nonce)
        params = {k: base64.b64encode(rc4(signed_nonce, v.encode())).decode() for k, v in params.items()}
        params["signature"] = signature("/" + path, params, signed_nonce)
        params.update({"ssecurity": cred["ssecurity"], "_nonce": nonce})
        response = self.session.post(url, data=params, timeout=30,
            headers={"MIOT-ENCRYPT-ALGORITHM": "ENCRYPT-RC4", "Accept-Encoding": "identity",
                     "Content-Type": "application/x-www-form-urlencoded",
                     "X-XIAOMI-PROTOCAL-FLAG-CLI": "PROTOCAL-HTTP2"},
            cookies={"userId": cred["user_id"], "serviceToken": cred["service_token"],
                     "yetAnotherServiceToken": cred["service_token"], "locale": "zh_CN",
                     "timezone": "GMT+08:00", "channel": "MI_APP_STORE"})
        response.raise_for_status()
        try:
            result = json.loads(response.text)
        except ValueError:
            result = json.loads(rc4(signed_nonce, base64.b64decode(response.text)))
        if result.get("code", 0) != 0:
            raise CloudError(f"米家云端请求失败（{path}, code={result.get('code')}）")
        return result.get("result")

    def devices(self):
        merged = self.api("v2/homeroom/gethome_merged", {
            "fg": True, "fetch_share": True, "fetch_share_dev": True,
            "fetch_cariot": True, "limit": 300, "app_ver": 7, "plat_form": 0}) or {}
        homes = list(merged.get("homelist") or [])
        homes += list(merged.get("share_home_list") or [])
        # Remember each device's MiJia room so sensors can be paired with air conditioners.
        self.device_rooms = {did: room.get("name") for home in homes for room in home.get("roomlist") or []
                             if room.get("name") for did in room.get("dids") or []}
        # Which MiJia home (by name) each device belongs to; accessories are limited to one home.
        self.device_homes = {did: home.get("name") for home in homes for room in home.get("roomlist") or []
                             for did in room.get("dids") or []}
        baseline = self.api("home/device_list", {
            "getVirtualModel": True, "getHuamiDevices": 1,
            "get_split_device": False, "support_smart_home": True}) or {}
        devices = {d["did"]: d for d in baseline.get("list", []) if d.get("did")}
        for home in homes:
            home_id = home.get("id", home.get("home_id"))
            owner = home.get("uid", home.get("home_owner", self.credentials["user_id"]))
            if home_id is None:
                continue
            start = ""
            seen = set()
            while True:
                page = self.api("v2/home/home_device_list", {
                    "home_owner": int(owner), "home_id": int(home_id), "limit": 300,
                    "start_did": start, "get_split_device": False,
                    "support_smart_home": True, "get_cariot_device": True,
                    "get_third_device": True}) or {}
                for device in page.get("device_info") or []:
                    did = device.get("did")
                    if did:
                        devices.setdefault(did, {}).update(device)
                        self.device_homes.setdefault(did, home.get("name"))
                following = page.get("max_did") or ""
                if not page.get("has_more") or not following or following in seen:
                    break
                seen.add(following)
                start = following
        return list(devices.values())

    def spec(self, model):
        if self._instances is None:
            response = self.session.get("https://miot-spec.org/miot-spec-v2/instances",
                                        params={"status": "all"}, timeout=30)
            response.raise_for_status()
            self._instances = response.json().get("instances", [])
        matches = [i for i in self._instances if i.get("model") == model]
        if not matches:
            return None
        urn = max(matches, key=lambda i: i.get("version", 0))["type"]
        response = self.session.get("https://miot-spec.org/miot-spec-v2/instance",
                                    params={"type": urn}, timeout=30)
        response.raise_for_status()
        return response.json()

    def read_state(self, device, spec):
        properties = []
        for service in spec.get("services", []):
            # Only inspect HVAC, fan, environment and temperature-related services.
            if not any(word in service.get("type", "") for word in
                       (":air-conditioner:", ":environment:", ":fan-control:", ":thermostat:")):
                continue
            for prop in service.get("properties", []):
                if "read" in prop.get("access", []):
                    properties.append({"did": device["did"], "siid": service["iid"], "piid": prop["iid"]})
        values = []
        for start in range(0, len(properties), 10):
            values += self.api("miotspec/prop/get", {"params": properties[start:start + 10]}) or []
        return values

    @staticmethod
    def climate_fields(spec):
        """Locate readable indoor temperature / humidity properties (never target temperature)."""
        fields = {}
        for service in spec.get("services", []):
            for prop in service.get("properties", []):
                kind = prop.get("type", "").split(":")[3] if prop.get("type", "").count(":") >= 3 else ""
                if kind in ("temperature", "relative-humidity") and "read" in prop.get("access", []):
                    fields.setdefault(kind, [service["iid"], prop["iid"]])
        return fields

    def read_climate(self, did, fields):
        """Read cached sensor values; returns ({field: value}, {field: code})."""
        query = [{"did": did, "siid": siid, "piid": piid} for siid, piid in fields.values()]
        if not query:
            return {}, {}
        state = self.api("miotspec/prop/get", {"params": query}) or []
        values, codes = {}, {}
        for field, (siid, piid) in fields.items():
            match = next((p for p in state if p.get("siid") == siid and p.get("piid") == piid), {})
            codes[field] = match.get("code", "missing")
            if match.get("code") == 0 and isinstance(match.get("value"), (int, float)):
                values[field] = match["value"]
        return values, codes
