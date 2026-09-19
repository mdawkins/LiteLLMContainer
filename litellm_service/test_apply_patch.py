import importlib.util
import pathlib
import unittest


PATCH_PATH = pathlib.Path(__file__).with_name("apply_patch.py")
SPEC = importlib.util.spec_from_file_location("litellm_local_patch", PATCH_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PatchContractTest(unittest.TestCase):
    def fixture(self, body: str) -> str:
        return "class Fixture:\n    def method(self, block_type, content_block_start):\n" + body + "\n"

    def test_expected_upstream_block_is_replaced_and_compiles(self):
        patched, status = MODULE.patch_content(self.fixture(MODULE.OLD_CODE), "fixture.py")
        self.assertEqual(status, "applied")
        self.assertNotIn(MODULE.OLD_CODE, patched)
        self.assertEqual(patched.count(MODULE.PATCH_MARKER), 1)
        compile(patched, "fixture.py", "exec")

    def test_patch_is_idempotent(self):
        patched, _ = MODULE.patch_content(self.fixture(MODULE.OLD_CODE), "fixture.py")
        second, status = MODULE.patch_content(patched, "fixture.py")
        self.assertEqual(status, "already-applied")
        self.assertEqual(second, patched)

    def test_reviewed_tag_whitespace_variant_is_supported(self):
        patched, status = MODULE.patch_content(
            self.fixture(MODULE.OLD_CODE_COMPACT), "fixture.py"
        )
        self.assertEqual(status, "applied")
        self.assertEqual(patched.count(MODULE.NEW_CODE), 1)

    def test_unknown_upstream_source_fails_closed(self):
        with self.assertRaises(MODULE.PatchError):
            MODULE.patch_content("class Different: pass\n", "fixture.py")

    def test_ambiguous_upstream_source_fails_closed(self):
        with self.assertRaises(MODULE.PatchError):
            MODULE.patch_content(self.fixture(MODULE.OLD_CODE + "\n" + MODULE.OLD_CODE), "fixture.py")


if __name__ == "__main__":
    unittest.main()
