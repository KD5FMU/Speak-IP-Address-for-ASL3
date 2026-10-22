"""Exercise real installer functions against isolated rpt.conf fixtures."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / 'install-speakip-v1.0.11.sh'
COMMANDS = [
    '890 = cmd,/etc/asterisk/local/shutdown.pl',
    '891 = cmd,/etc/asterisk/local/reboot.pl',
    '892 = cmd,/etc/asterisk/local/sayip.pl',
    '893 = cmd,/etc/asterisk/local/saypublicip.pl',
    '894 = ilink,6',
]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.conf = Path(self.temp.name) / 'rpt.conf'
        self.conf.write_text('[functions]\n42 = ilink,1\n')
        self.conf.chmod(0o644)
        # Load definitions without invoking the privileged installer entry point.
        source = INSTALLER.read_text()
        self.assertTrue(source.endswith('main "$@"\n'))
        self.library = Path(self.temp.name) / 'installer-functions.sh'
        self.library.write_text(source.removesuffix('main "$@"\n'))

    def run_functions(self, commands, success=True):
        result = subprocess.run(
            ['bash', '-c', 'source "$1"; RPT_CONF="$2"; ' + commands,
             'test', str(self.library), str(self.conf)],
            text=True, capture_output=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_install_stanza_variants_and_repeat(self):
        for header in ('[functions]', '[functions](functions-main)', '[other]'):
            with self.subTest(header=header):
                self.conf.write_text(header + '\n42 = ilink,1\n')
                self.run_functions('add_dtmf_commands; add_dtmf_commands')
                lines = self.conf.read_text().splitlines()
                for entry in COMMANDS:
                    self.assertEqual(lines.count(entry), 1)
                self.assertIn('42 = ilink,1', lines)
                self.assertEqual(self.conf.stat().st_mode & 0o777, 0o644)
                self.assertTrue(list(Path(self.temp.name).glob('rpt.conf.speakip-backup-*')))

    def test_upgrade_and_uninstall_legacy_entries(self):
        old = [entry.replace(str(890 + i), str(990 + i), 1)
               for i, entry in enumerate(COMMANDS[:4])]
        self.conf.write_text('[functions](functions-main)\n42 = ilink,1\n' +
                             '\n'.join(COMMANDS[:4] + old) + '\n')
        self.run_functions('add_dtmf_commands')
        lines = self.conf.read_text().splitlines()
        for entry in COMMANDS:
            self.assertEqual(lines.count(entry), 1)
        for entry in old:
            self.assertNotIn(entry, lines)
        self.run_functions('remove_dtmf_commands; remove_dtmf_commands')
        remaining = self.conf.read_text()
        self.assertIn('42 = ilink,1', remaining)
        for entry in COMMANDS + old:
            self.assertNotIn(entry, remaining)

    def test_conflict_for_each_command_leaves_config_unchanged(self):
        for code in range(890, 895):
            with self.subTest(code=code):
                original = f'[functions]\n  {code} = ilink,1\n'
                self.conf.write_text(original)
                result = self.run_functions('add_dtmf_commands', success=False)
                self.assertIn(f'DTMF command {code} is already in use', result.stderr)
                self.assertEqual(self.conf.read_text(), original)

    def test_conflict_stops_install_before_package_changes(self):
        self.conf.write_text('[functions]\n894 = ilink,1\n')
        marker = Path(self.temp.name) / 'packages-started'
        self.run_functions('check_platform() { :; }; '
                           'prompt_for_node() { echo 12345; }; '
                           'install_packages() { touch "$(dirname "$RPT_CONF")/packages-started"; }; '
                           'install_speakip', success=False)
        self.assertFalse(marker.exists())

    def test_identical_entry_cannot_hide_conflicting_duplicate(self):
        self.conf.write_text('[functions]\n894 = ilink,6\n[other]\n894 = ilink,1\n')
        self.run_functions('check_dtmf_conflicts', success=False)

    def test_uninstall_preserves_unrelated_894(self):
        self.conf.write_text('[functions]\n894 = ilink,1\n')
        self.run_functions('remove_dtmf_commands')
        self.assertIn('894 = ilink,1', self.conf.read_text())

    def test_platform_gate_debian_12_and_13(self):
        # Substitute only the OS metadata path and account lookup; run the actual gate.
        source = self.library.read_text()
        for version, supported in [('12', True), ('13', True), ('11', False)]:
            with self.subTest(version=version):
                release = Path(self.temp.name) / 'os-release'
                release.write_text(f'ID=debian\nVERSION_ID={version}\n')
                self.library.write_text(source.replace('/etc/os-release', str(release)))
                self.run_functions('id() { return 0; }; check_platform; '
                                   '[[ "$PROGRAM_VERSION" == 1.0.11 ]]', success=supported)

    def test_generated_perl_syntax(self):
        # Stub ownership changes only; generated helpers remain in the temporary directory.
        self.run_functions('LOCAL_DIR="$(dirname "$RPT_CONF")"; '
                           'chown() { :; }; write_common_perl_module; '
                           'write_sayip_script; write_saypublicip_script; '
                           'write_shutdown_script; write_reboot_script; '
                           'PERL5LIB="$LOCAL_DIR" validate_generated_files')


if __name__ == '__main__':
    unittest.main()
