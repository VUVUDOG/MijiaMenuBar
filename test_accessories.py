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


if __name__ == "__main__":
    unittest.main()
