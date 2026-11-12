"""fixtures/native/reasoning_refusal_gateway.py is the script the helper's
ReasoningQuestionTests carry inline: the app's tests and the helper's must be
refused by the same gateway."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class ReasoningRefusalGatewayTests(unittest.TestCase):
    def test_the_fixture_is_the_helper_tests_script(self):
        swift = (ROOT / "packages/swift-host/Tests/PiAgentCoreTests/ReasoningQuestionTests.swift").read_text()
        opening = 'static let gatewayScript = #"""\n'
        start = swift.index(opening) + len(opening)
        inline = swift[start:swift.index('\n"""#', start)] + "\n"
        fixture = (ROOT / "fixtures/native/reasoning_refusal_gateway.py").read_text()
        self.assertTrue(fixture.endswith(inline), "the fixture and the helper test's inline script differ")
        self.assertIn("serve_forever", inline)


if __name__ == "__main__":
    unittest.main()
