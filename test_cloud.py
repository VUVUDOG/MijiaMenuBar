import base64
import unittest
import requests
from unittest.mock import patch

from cloud import CloudError, XiaomiCloud, rc4


class CloudTests(unittest.TestCase):
    def test_rc4_drop_1024_matches_rfc6229(self):
        key = base64.b64encode(bytes([1, 2, 3, 4, 5])).decode()
        self.assertEqual(rc4(key, bytes(16)).hex(), "30abbcc7c20b01609f23ee2d5f6bb7df")

    def test_probe_rejects_writes_before_network(self):
        cloud = XiaomiCloud()
        for endpoint in ("miotspec/prop/set", "miotspec/action", "home/rpc"):
            with self.assertRaises(CloudError):
                cloud.api(endpoint, {})

    def test_third_party_devices_and_pagination(self):
        cloud = XiaomiCloud({"user_id": "123"})
        calls = []

        def api(path, payload):
            calls.append((path, payload))
            if path == "v2/homeroom/gethome_merged":
                return {"homelist": [{"id": "1", "uid": "123"}]}
            if path == "home/device_list":
                return {"list": [{"did": "ordinary"}]}
            if not payload["start_did"]:
                return {"device_info": [{"did": "x.third-1", "name": "客厅空调"}],
                        "has_more": True, "max_did": "x.third-1"}
            return {"device_info": [{"did": "x.third-2", "name": "主卧空调"}], "has_more": False}

        cloud.api = api
        self.assertEqual([d["did"] for d in cloud.devices()], ["ordinary", "x.third-1", "x.third-2"])
        pages = [p for path, p in calls if path == "v2/home/home_device_list"]
        self.assertTrue(all(p["get_third_device"] for p in pages))
        self.assertEqual(pages[1]["start_did"], "x.third-1")

    def control_spec(self):
        return {"services": [{"iid": 2, "type": "urn:miot-spec-v2:service:air-conditioner:0000780F",
                             "properties": [{"iid": 4, "type": "urn:miot-spec-v2:property:target-temperature:00000021",
                                             "format": "float", "access": ["read", "write"],
                                             "value-range": [16, 32, 1]}]}]}

    def test_control_validates_before_sending(self):
        cloud = XiaomiCloud()
        for value in [15, 33, 26.5, True, "26"]:
            with self.assertRaises(CloudError):
                cloud.set_property({"did": "test"}, self.control_spec(), "target-temperature", value)
        for field in ["fault", "serial-number", "unknown"]:
            with self.assertRaises(CloudError):
                cloud.set_property({"did": "test"}, self.control_spec(), field, 0)

    def test_control_requires_readback_not_just_acknowledgement(self):
        cloud = XiaomiCloud()
        cloud._request = lambda path, payload: [{"did": "test", "code": 0}]
        cloud.api = lambda path, payload: [{"siid": 2, "piid": 4, "code": 0, "value": 26}]
        with patch("cloud.time.sleep"), self.assertRaises(CloudError):
            cloud.set_property({"did": "test"}, self.control_spec(), "target-temperature", 27)

    def test_control_success_after_readback(self):
        cloud = XiaomiCloud()
        sent = []
        def request(path, payload):
            sent.append((path, payload))
            return [{"did": "test", "code": 0}]
        cloud._request = request
        cloud.api = lambda path, payload: [{"siid": 2, "piid": 4, "code": 0, "value": 27}]
        with patch("cloud.time.sleep"):
            cloud.set_property({"did": "test"}, self.control_spec(), "target-temperature", 27)
        self.assertEqual(sent[0], ("miotspec/prop/set", {"params": [{"did": "test", "siid": 2, "piid": 4, "value": 27}]}))


    def test_multiple_controls_share_one_request_and_readback(self):
        cloud = XiaomiCloud()
        spec = self.control_spec()
        spec["services"][0]["properties"].append({"iid": 2, "type": "urn:miot-spec-v2:property:mode:00000008",
                                                  "format": "uint8", "access": ["read", "write"],
                                                  "value-list": [{"value": 1}, {"value": 2}]})
        sent, reads = [], []
        def request(path, payload):
            sent.append(payload)
            return [{"code": 0}, {"code": 0}]
        def api(path, payload):
            reads.append(payload)
            return [{"siid": 2, "piid": 4, "code": 0, "value": 27}, {"siid": 2, "piid": 2, "code": 0, "value": 2}]
        cloud._request, cloud.api = request, api
        with patch("cloud.time.sleep"):
            cloud.set_properties({"did": "test"}, spec, {"target-temperature": 27, "mode": 2})
        self.assertEqual(len(sent), 1)
        self.assertEqual(len(sent[0]["params"]), 2)
        self.assertEqual(len(reads), 1)

    def test_expired_token_is_reported_as_session_expired(self):
        from unittest.mock import MagicMock
        from cloud import SessionExpired
        cloud = XiaomiCloud({"user_id": "u", "ssecurity": "c2VjdXJpdHk=", "service_token": "t"})
        response = MagicMock(status_code=426, text='{"code":0,"message":"SERVICETOKEN_EXPIRED"}')
        cloud.session.post = lambda *a, **k: response
        with self.assertRaises(SessionExpired):
            cloud._request("miotspec/prop/get", {"params": []})
        response.status_code, response.text = 426, '{"code":0,"message":"other"}'
        response.raise_for_status.side_effect = requests.HTTPError("426")
        with self.assertRaises(requests.HTTPError):
            cloud._request("miotspec/prop/get", {"params": []})


if __name__ == "__main__":
    unittest.main()
