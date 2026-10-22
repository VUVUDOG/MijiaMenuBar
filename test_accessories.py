import unittest
from types import SimpleNamespace
from unittest.mock import patch

import probe
from cloud import CloudError, XiaomiCloud

LIGHT = {"type": "urn:miot-spec-v2:device:light:1", "services": [
    {"iid": 2, "type": "urn:miot-spec-v2:service:light:1", "properties": [
        {"iid": 1, "type": "urn:miot-spec-v2:property:on:1", "format": "bool", "access": ["read", "write"]},
        {"iid": 2, "type": "urn:miot-spec-v2:property:brightness:1", "format": "uint8", "access": ["read", "write"],
         "value-range": [1, 100, 1]},
        {"iid": 7, "type": "urn:miot-spec-v2:property:mode:1", "format": "uint8", "access": ["read", "write"],
         "value-list": [{"value": 0, "description": "None"}]}]}]}
CURTAIN = {"type": "urn:miot-spec-v2:device:curtain:1", "services": [
    {"iid": 2, "type": "urn:miot-spec-v2:service:curtain:1", "properties": [
        {"iid": 1, "type": "urn:miot-spec-v2:property:motor-control:1", "format": "uint8", "access": ["write"],
         "value-list": [{"value": 0, "description": "Pause"}, {"value": 1, "description": "Open"}]},
        {"iid": 3, "type": "urn:miot-spec-v2:property:current-position:1", "format": "uint8", "access": ["read"],
         "value-range": [0, 100, 1]},
        {"iid": 4, "type": "urn:miot-spec-v2:property:target-position:1", "format": "uint8",
         "access": ["read", "write"], "value-range": [0, 100, 1]}]}]}


class AccessoryTests(unittest.TestCase):
    def test_only_whitelisted_properties_are_exposed(self):
        props = {p["address"]: p for p in probe.accessory_props(LIGHT)}
        self.assertEqual(set(props), {"light.on", "light.brightness"})
        self.assertEqual(props["light.brightness"]["range"], [1, 100, 1])

    def test_home_follows_air_conditioners(self):
        cloud = SimpleNamespace(device_homes={"ac1": "御江廷", "ac2": "御江廷", "x": "公司", "y": "公司", "z": "公司"})
        self.assertEqual(probe.choose_home(cloud, [{"did": "ac1"}, {"did": "ac2"}]), "御江廷")

    def test_write_only_command_is_not_read_back(self):
        cloud = XiaomiCloud()
        cloud._request = lambda path, payload: [{"code": 1}]
        cloud.api = lambda path, payload: self.fail("write-only commands cannot be read back")
        cloud.set_addresses({"did": "c"}, CURTAIN, {"curtain.motor-control": 1})

    def test_brightness_readback_tolerates_small_quantisation(self):
        cloud = XiaomiCloud()
        cloud._request = lambda path, payload: [{"code": 0}]
        cloud.api = lambda path, payload: [{"siid": 2, "piid": 2, "code": 0, "value": 64}]
        with patch("cloud.time.sleep"):
            cloud.set_addresses({"did": "l"}, LIGHT, {"light.brightness": 65})

    def test_invalid_values_are_rejected_before_sending(self):
        cloud = XiaomiCloud()
        cloud._request = lambda path, payload: self.fail("must validate first")
        for address, value in [("light.brightness", 0), ("light.brightness", 50.5), ("light.on", 1),
                               ("curtain.target-position", 101), ("light.unknown", 1)]:
            spec = CURTAIN if address.startswith("curtain") else LIGHT
            with self.assertRaises(CloudError):
                cloud.set_addresses({"did": "d"}, spec, {address: value})


    def test_stored_metadata_controls_without_downloading_specs(self):
        props = probe.accessory_props(LIGHT)
        cloud = XiaomiCloud()
        sent = []
        cloud._request = lambda path, payload: sent.append(payload) or [{"code": 0}]
        cloud.api = lambda path, payload: [{"siid": 2, "piid": 1, "code": 0, "value": True}]
        cloud.spec = lambda model: self.fail("control must not download specs")
        with patch("cloud.time.sleep"):
            cloud.set_stored({"did": "l"}, props, {"light.on": True})
        self.assertEqual(sent[0]["params"], [{"did": "l", "siid": 2, "piid": 1, "value": True}])
        with self.assertRaises(CloudError):
            cloud.set_stored({"did": "l"}, props, {"light.brightness": 0})

    def test_batch_reports_each_failure_separately(self):
        report = {"devices": [], "accessories": [
            {"device": {"did": "ok"}, "props": probe.accessory_props(LIGHT)},
            {"device": {"did": "bad"}, "props": probe.accessory_props(LIGHT)}]}
        def request(self_, path, payload):
            did = payload["params"][0]["did"]
            return [{"code": 0 if did == "ok" else -704042011}]
        with patch.object(XiaomiCloud, "_request", request), \
             patch.object(XiaomiCloud, "api", lambda self_, path, payload: [{"siid": 2, "piid": 1, "code": 0, "value": False}]), \
             patch("cloud.time.sleep"):
            failures = probe.control_devices(XiaomiCloud({"user_id": "u", "ssecurity": "s", "service_token": "t"}), report,
                                             {"ok": {"light.on": False}, "bad": {"light.on": False}, "missing": {"light.on": False}})
        self.assertEqual(set(failures), {"bad", "missing"})


    def test_flood_sensors_in_the_home_are_discovered(self):
        flood = {"type": "urn:miot-spec-v2:device:submersion-sensor:1", "services": [
            {"iid": 2, "type": "urn:miot-spec-v2:service:submersion-sensor:1", "properties": [
                {"iid": 1006, "type": "urn:miot-spec-v2:property:submersion-state:1", "format": "bool", "access": ["read"]}]},
            {"iid": 3, "type": "urn:miot-spec-v2:service:battery:1", "properties": [
                {"iid": 1003, "type": "urn:miot-spec-v2:property:battery-level:1", "format": "uint8", "access": ["read"]}]}]}
        cloud = SimpleNamespace(spec=lambda model: flood if model == "flood" else LIGHT,
                                device_homes={"a": "家", "b": "公司", "c": "家"}, device_rooms={"a": "厨房"})
        alarms = probe.discover_alarms(cloud, [{"did": "a", "model": "flood"}, {"did": "b", "model": "flood"},
                                               {"did": "c", "model": "light"}], "家")
        self.assertEqual([a["device"]["did"] for a in alarms], ["a"])
        self.assertEqual({p["address"] for p in alarms[0]["props"]},
                         {"submersion-sensor.submersion-state", "battery.battery-level"})


    def test_bath_heater_exposes_ventilation(self):
        heater = {"type": "urn:miot-spec-v2:device:bath-heater:1", "services": [
            {"iid": 4, "type": "urn:miot-spec-v2:service:ptc-bath-heater:1", "properties": [
                {"iid": 8, "type": "urn:miot-spec-v2:property:ventilation:1", "format": "bool", "access": ["read", "write"]},
                {"iid": 17, "type": "urn:miot-spec-v2:property:mode:1", "format": "uint8", "access": ["read", "write"],
                 "value-list": [{"value": 0, "description": "Idle"}, {"value": 2, "description": "Heat"}]}]}]}
        props = {p["address"]: p for p in probe.accessory_props(heater)}
        self.assertIn("ptc-bath-heater.ventilation", props)
        self.assertTrue(props["ptc-bath-heater.ventilation"]["writable"])


    def test_hood_gets_power_fan_and_light_but_bath_heaters_do_not_get_fan_level(self):
        fan = {"iid": 3, "type": "urn:miot-spec-v2:service:fan-control:1", "properties": [
            {"iid": 1, "type": "urn:miot-spec-v2:property:fan-level:1", "format": "uint8", "access": ["read", "write"],
             "value-list": [{"value": 1, "description": "Low"}, {"value": 4, "description": "Turbo"}]}]}
        light = {"iid": 6, "type": "urn:miot-spec-v2:service:light:1", "properties": [
            {"iid": 1, "type": "urn:miot-spec-v2:property:on:1", "format": "bool", "access": ["read", "write"]}]}
        hood = {"type": "urn:miot-spec-v2:device:hood:1", "services": [
            {"iid": 2, "type": "urn:miot-spec-v2:service:hood:1", "properties": [
                {"iid": 1, "type": "urn:miot-spec-v2:property:on:1", "format": "bool", "access": ["read", "write"]}]},
            fan, light]}
        props = {p["address"]: p for p in probe.accessory_props(hood)}
        self.assertTrue(all(props[a]["writable"] for a in ("hood.on", "fan-control.fan-level", "light.on")))
        heater = {"type": "urn:miot-spec-v2:device:bath-heater:1", "services": [fan, light]}
        self.assertNotIn("fan-control.fan-level", {p["address"] for p in probe.accessory_props(heater)})


    def test_bath_heater_ventilation_level_is_the_second_fan_level(self):
        heater = {"type": "urn:miot-spec-v2:device:bath-heater:1", "services": [
            {"iid": 4, "type": "urn:miot-spec-v2:service:ptc-bath-heater:1", "properties": [
                {"iid": 8, "type": "urn:miot-spec-v2:property:ventilation:1", "format": "bool", "access": ["read", "write"]}]},
            {"iid": 5, "type": "urn:miot-spec-v2:service:fan-control:1", "properties": [
                {"iid": 7, "type": "urn:miot-spec-v2:property:fan-level:1", "format": "uint8", "access": ["read", "write"],
                 "value-list": [{"value": 0, "description": "Low"}, {"value": 1, "description": "High"}]},
                {"iid": 8, "type": "urn:miot-spec-v2:property:fan-level:1", "format": "uint8", "access": ["read", "write"],
                 "value-list": [{"value": 0, "description": "Low"}, {"value": 1, "description": "High"}]}]}]}
        props = probe.accessory_props(heater)
        addresses = [p["address"] for p in props]
        self.assertEqual(addresses[addresses.index("ptc-bath-heater.ventilation") + 1], "fan-control.fan-level#2")
        level = next(p for p in props if p["address"] == "fan-control.fan-level#2")
        self.assertEqual((level["siid"], level["piid"], level["writable"]), (5, 8, True))
        self.assertEqual(XiaomiCloud.find_property(heater, "fan-control.fan-level#3"), (None, None))


    def test_cooker_is_read_only(self):
        cooker = {"type": "urn:miot-spec-v2:device:cooker:1", "services": [
            {"iid": 2, "type": "urn:miot-spec-v2:service:cooker:1", "properties": [
                {"iid": 1, "type": "urn:miot-spec-v2:property:status:1", "format": "uint8", "access": ["read"],
                 "value-list": [{"value": 1, "description": "Idle"}, {"value": 2, "description": "Busy"}]},
                {"iid": 4, "type": "urn:miot-spec-v2:property:cook-mode:1", "format": "uint8", "access": ["read", "write"],
                 "value-list": [{"value": 2, "description": "Cook Congee"}]},
                {"iid": 7, "type": "urn:miot-spec-v2:property:left-time:1", "format": "uint16", "access": ["read"],
                 "value-range": [0, 1440, 1]}]}]}
        props = probe.accessory_props(cooker)
        self.assertEqual([p["address"] for p in props], ["cooker.status", "cooker.cook-mode", "cooker.left-time"])
        self.assertFalse(any(p["writable"] for p in props))
        cloud = SimpleNamespace(spec=lambda model: cooker, device_homes={"a": "家"}, device_rooms={"a": "厨房"})
        found = probe.discover_accessories(cloud, [{"did": "a", "model": "cooker"}], "家")
        self.assertEqual([a["kind"] for a in found], ["cooker"])


    def cooker_report(self, online=True):
        props = [{"address": "cooker.status", "siid": 2, "piid": 1, "readable": True, "writable": False},
                 {"address": "cooker.cook-mode", "siid": 2, "piid": 4, "readable": True, "writable": False,
                  "options": [{"value": 0, "description": "Fine Cook"}, {"value": 2, "description": "Cook Congee"}]}]
        return {"accessories": [{"device": {"did": "cook", "isOnline": online}, "kind": "cooker", "props": props, "state": {},
                                 "actions": [{"name": "start-cook", "siid": 2, "aiid": 1, "in": [4]},
                                             {"name": "cancel-cooking", "siid": 2, "aiid": 2, "in": []}]}]}

    def test_cooker_actions_are_validated_sent_and_confirmed(self):
        cloud = XiaomiCloud({"user_id": "u", "ssecurity": "s", "service_token": "t"})
        calls, status = [], {"value": 1}
        cloud.call_action = lambda device, siid, aiid, values: calls.append((siid, aiid, list(values))) or []
        def read(cl, accessories):
            accessories[0]["state"] = {"cooker.status": status["value"]}
        with patch("probe.read_accessories", read), patch("probe.time.sleep"):
            for bad in ([], [1], [0, 1]):
                with self.assertRaises(CloudError):
                    probe.run_action(cloud, self.cooker_report(), "cook", "start-cook", bad)
            with self.assertRaises(CloudError):
                probe.run_action(cloud, self.cooker_report(False), "cook", "start-cook", [2])
            with self.assertRaises(CloudError):
                probe.run_action(cloud, self.cooker_report(), "cook", "factory-reset", [])
            with self.assertRaises(CloudError):  # sent, but the cooker never reports cooking
                probe.run_action(cloud, self.cooker_report(), "cook", "start-cook", [2])
            status["value"] = 2
            probe.run_action(cloud, self.cooker_report(), "cook", "start-cook", [2])
            status["value"] = 1
            probe.run_action(cloud, self.cooker_report(), "cook", "cancel-cooking", [])
        self.assertEqual(calls[-2:], [(2, 1, [2]), (2, 2, [])])

    def test_action_request_shape(self):
        cloud = XiaomiCloud({"user_id": "u", "ssecurity": "s", "service_token": "t"})
        sent = []
        cloud._request = lambda path, payload: sent.append((path, payload)) or {"code": 0, "out": []}
        cloud.call_action({"did": "d"}, 2, 1, [2])
        self.assertEqual(sent, [("miotspec/action", {"params": {"did": "d", "siid": 2, "aiid": 1, "in": [2]}})])
        cloud._request = lambda path, payload: {"code": -704040005}
        with self.assertRaises(CloudError):
            cloud.call_action({"did": "d"}, 2, 1, [])


if __name__ == "__main__":
    unittest.main()
