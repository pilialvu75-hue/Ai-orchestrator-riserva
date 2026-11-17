"""Regression guard for tunnel-client v0.0.21 Windows command-line parsing.

The upstream parseCommandArgv in pkg/runtimeconfig/config.go consumes a raw
backslash as an escape character unless inside single quotes. A string that
looks like a valid Windows -File path is therefore NOT necessarily valid as
an MCP stdio command. No keys, local processes or network calls are needed.
"""
import pathlib
import unittest


def parse_argv_like_tunnel_client(raw):
    args = []
    current = []
    single = False
    double = False
    escaped = False
    for char in raw:
        if escaped:
            current.append(char)
            escaped = False
            continue
        if single:
            if char == "'":
                single = False
            else:
                current.append(char)
            continue
        if double:
            if char == "\\":
                escaped = True
            elif char == '"':
                double = False
            else:
                current.append(char)
            continue
        if char == "\\":
            escaped = True
        elif char == "'":
            single = True
        elif char == '"':
            double = True
        elif char.isspace():
            if current:
                args.append("".join(current))
                current = []
        else:
            current.append(char)
    if escaped or single or double:
        raise ValueError("Incomplete command quoting")
    if current:
        args.append("".join(current))
    return args


class TunnelWindowsArgvTests(unittest.TestCase):
    def test_literal_windows_path_survives_single_quotes(self):
        path = r"C:\Users\vivob\Downloads\AIVEXUS-Tunnel-Client\aivexus_mcp.ps1"
        command = "powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File " + "'" + path + "'"
        argv = parse_argv_like_tunnel_client(command)
        self.assertEqual(argv[-1], path)
        self.assertEqual(argv[-2], "-File")
        self.assertEqual(len(argv), 6)

    def test_unquoted_windows_path_would_be_mangled(self):
        path = r"C:\Users\vivob\Downloads\AIVEXUS-Tunnel-Client\aivexus_mcp.ps1"
        raw = "powershell.exe -File " + path
        self.assertNotEqual(parse_argv_like_tunnel_client(raw)[-1], path)

    def test_launcher_preserves_literal_backslashes(self):
        launcher = pathlib.Path(__file__).with_name("aivexus_tunnel_start.ps1").read_text(encoding="utf-8")
        self.assertIn("$mcpCommand = 'powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File ' + [char]39 + $stagedAdapter + [char]39", launcher)
        self.assertIn("& $clientPath init --force", launcher)
        self.assertIn("--mcp.stdio-failure-policy=exit", launcher)


if __name__ == "__main__":
    unittest.main()
