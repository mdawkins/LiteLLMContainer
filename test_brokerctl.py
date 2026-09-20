import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

import brokerctl


class FakeApi:
    def __init__(self, model_rows=None):
        self.model_rows = model_rows or []
        self.calls = []

    def request(self, method, path, data=None):
        self.calls.append((method, path, data))
        if method == "GET" and path == "/model/info":
            return {"data": self.model_rows}
        if method in {"POST", "PATCH"}:
            return {"ok": True}
        raise AssertionError(f"unexpected fake API call: {method} {path}")


class BrokerRegistryTest(unittest.TestCase):
    def setUp(self):
        self.registry = brokerctl.load_registry(brokerctl.DEFAULT_REGISTRY)

    def test_routes_are_unique_and_broker_qualified(self):
        routes = brokerctl.route_names(self.registry)
        self.assertEqual(len(routes), 14)
        self.assertEqual(len(routes), len(set(routes)))
        self.assertTrue(all(route.count("/") == 2 for route in routes))
        self.assertFalse(brokerctl.find_forbidden(self.registry))

    def test_model_payloads_reference_secrets_instead_of_values(self):
        payloads = brokerctl.desired_models(self.registry)
        usai = next(row for row in payloads if row["model_name"] == "usai/primary/gpt-5.4")
        self.assertEqual(usai["litellm_params"]["api_key"], "os.environ/DOT_USAI_API_KEY")
        self.assertEqual(usai["model_info"]["input_cost_per_token"], 0.0000025)
        self.assertEqual(usai["model_info"]["managed_by"], "brokerctl")

    def test_team_cannot_exceed_parent_organization(self):
        registry = json.loads(json.dumps(self.registry))
        registry["organizations"] = [
            {"id": "org", "alias": "Org", "models": ["usai/primary/gpt-5.4"]}
        ]
        registry["teams"] = [
            {
                "id": "team",
                "alias": "Team",
                "organization_id": "org",
                "models": ["bedrock/instance-role/claude-sonnet-5"],
            }
        ]
        with self.assertRaises(brokerctl.RegistryError):
            brokerctl.validate(registry)

    def test_fallback_keys_are_rejected_at_any_depth(self):
        registry = json.loads(json.dumps(self.registry))
        registry["accounts"][0]["models"][0]["params"] = {"fallbacks": ["anything"]}
        with self.assertRaises(brokerctl.RegistryError):
            brokerctl.validate(registry)

    def test_pricing_html_tables_are_extracted_without_executing_scripts(self):
        html = """
        <html><script>window.secret = 'must not execute';</script>
        <table><tr><th>Model</th><th>Input price</th></tr>
        <tr><td>gpt-5.4</td><td>$2.50 / 1M</td></tr></table></html>
        """
        tables = brokerctl.parse_html_tables(html)
        self.assertEqual(len(tables), 1)
        self.assertEqual(tables[0]["headers"], ["Model", "Input price"])
        self.assertEqual(tables[0]["rows"], [["gpt-5.4", "$2.50 / 1M"]])

    def test_svelte_embedded_pricing_records_are_extracted(self):
        html = """
        <script>resolve(1, () => [{models:[
          {"Model Name":"GPT 5.4",Status:"API, Chat",Vendor:"OpenAI",
           "Input Cost":"$5.00 /1M","Output Cost":"$22.50 /1M"}
        ]}])</script>
        """
        records = brokerctl.extract_embedded_model_records(html)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["Model Name"], "GPT 5.4")
        self.assertEqual(records[0]["Input Cost"], "$5.00 /1M")
        self.assertEqual(records[0]["Status"], "API, Chat")
        self.assertEqual(records[0]["input_cost_per_token"], 0.000005)
        self.assertEqual(records[0]["output_cost_per_token"], 0.0000225)

    def test_bedrock_static_credentials_are_references_and_require_a_pair(self):
        registry = json.loads(json.dumps(self.registry))
        account = next(row for row in registry["accounts"] if row["broker"] == "bedrock")
        account["aws_access_key_id_env"] = "BEDROCK_B_ACCESS_KEY_ID"
        with self.assertRaises(brokerctl.RegistryError):
            brokerctl.validate(registry)
        account["aws_secret_access_key_env"] = "BEDROCK_B_SECRET_ACCESS_KEY"
        brokerctl.validate(registry)
        payload = brokerctl.desired_model(account, account["models"][0])
        self.assertEqual(
            payload["litellm_params"]["aws_access_key_id"],
            "os.environ/BEDROCK_B_ACCESS_KEY_ID",
        )

    def test_codex_import_flattens_and_protects_auth_file(self):
        registry = json.loads(json.dumps(self.registry))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.json"
            source.write_text(
                json.dumps(
                    {
                        "auth_mode": "chatgpt",
                        "tokens": {
                            "access_token": "access",
                            "refresh_token": "refresh",
                            "id_token": "id",
                            "account_id": "account",
                        },
                        "last_refresh": "now",
                    }
                ),
                encoding="utf-8",
            )
            account = next(row for row in registry["accounts"] if row["broker"] == "codex")
            account["auth_dir"] = "${TEST_CODEX_VOLUME}/primary"
            brokerctl.import_codex_auth(registry, {"TEST_CODEX_VOLUME": str(root)}, "primary", source)
            destination = root / "primary" / "auth.json"
            value = json.loads(destination.read_text(encoding="utf-8"))
            self.assertNotIn("tokens", value)
            self.assertEqual(value["refresh_token"], "refresh")
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)

    def test_model_reconciliation_creates_every_enabled_route(self):
        api = FakeApi()
        brokerctl.apply_models(api, self.registry, apply=True, prune=True)
        writes = [call for call in api.calls if call[0] == "POST"]
        self.assertEqual(len(writes), 14)
        self.assertTrue(all(call[1] == "/model/new" for call in writes))

    def test_model_reconciliation_prunes_only_managed_rows(self):
        rows = [
            {
                "model_name": "old",
                "model_info": {
                    "id": "old-id",
                    "managed_by": "brokerctl",
                    "registry_route": "usai/removed/model",
                },
            },
            {"model_name": "manual", "model_info": {"id": "manual-id"}},
        ]
        api = FakeApi(rows)
        brokerctl.apply_models(api, self.registry, apply=True, prune=True)
        deletes = [call for call in api.calls if call[1] == "/model/delete"]
        self.assertEqual(deletes, [("POST", "/model/delete", {"id": "old-id"})])

    def test_access_is_not_applied_before_routes_exist(self):
        registry = json.loads(json.dumps(self.registry))
        registry["teams"] = [
            {"id": "team", "alias": "Team", "models": ["usai/primary/gpt-5.4"]}
        ]
        brokerctl.validate(registry)
        with self.assertRaises(RuntimeError):
            brokerctl.apply_access(FakeApi(), registry, apply=True)


if __name__ == "__main__":
    unittest.main()
