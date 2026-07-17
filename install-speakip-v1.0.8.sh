#!/usr/bin/env bash
#
# Speak IP for AllStarLink Version 3
# Supports Debian 12 (Bookworm) and Debian 13 (Trixie)
#
# Written and developed by Freddie McGuire, KD5FMU, Ham Radio Crusader,
# with assistance from OpenAI ChatGPT.
# Created: June 2026
#
# Installs:
#   - ASL3 native Piper TTS package (asl3-tts)
#   - DTMF commands 890 through 893
#   - Local IP announcement approximately 5 seconds after Asterisk/network startup
#   - Uninstall support: sudo ./install-speakip.sh --uninstall
#
# Version 1.0.8:
#   - Correctly detects ASL3 template/inheritance stanzas such as:
#       [functions](functions-main)
#     as well as plain:
#       [functions]
#   - Uses the detected asterisk binary path instead of hardcoding /usr/bin/asterisk.
#   - Uses WorkingDirectory=/ to avoid permission warnings when running as the asterisk user.
#   - Avoids PROGRAM_VERSION being overwritten by /etc/os-release.
#   - Sets /etc/asterisk/local and Speak IP helper files to asterisk-friendly permissions.
#   - Changes DTMF commands from 990-993 to 890-893 to avoid common command conflicts.
#   - Removes old Speak IP 990-993 entries when reinstalling or uninstalling.
#   - Adds attribution headers to all generated helper scripts.
#   - Detaches IP announcement scripts from the app_rpt DTMF cmd process.
#   - Cleans up Perl detach handling to remove the harmless "Statement unlikely" warning.
#

set -Eeuo pipefail

PROGRAM_NAME="Speak IP"
PROGRAM_ID="speakip"
PROGRAM_VERSION="1.0.8"

ASTERISK_DIR="/etc/asterisk"
LOCAL_DIR="${ASTERISK_DIR}/local"
RPT_CONF="${ASTERISK_DIR}/rpt.conf"
CONFIG_FILE="${LOCAL_DIR}/speakip.conf"
SOUND_DIR="/usr/local/share/asterisk/sounds/speakip"
SERVICE_FILE="/etc/systemd/system/speakip-boot.service"
BASE_URL="http://198.58.124.150/kd5fmu"

DTMF_LINES=(
  "890 = cmd,/etc/asterisk/local/shutdown.pl"
  "891 = cmd,/etc/asterisk/local/reboot.pl"
  "892 = cmd,/etc/asterisk/local/sayip.pl"
  "893 = cmd,/etc/asterisk/local/saypublicip.pl"
)

OLD_DTMF_LINES=(
  "990 = cmd,/etc/asterisk/local/shutdown.pl"
  "991 = cmd,/etc/asterisk/local/reboot.pl"
  "992 = cmd,/etc/asterisk/local/sayip.pl"
  "993 = cmd,/etc/asterisk/local/saypublicip.pl"
)

log()  { printf '\n[%s] %s\n' "$PROGRAM_NAME" "$*"; }
warn() { printf '\n[%s] WARNING: %s\n' "$PROGRAM_NAME" "$*" >&2; }
die()  { printf '\n[%s] ERROR: %s\n' "$PROGRAM_NAME" "$*" >&2; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this installer with sudo or as root."
}

check_platform() {
  [[ -r /etc/os-release ]] || die "Cannot determine the operating system."
  # shellcheck disable=SC1091
  . /etc/os-release

  [[ "${ID:-}" == "debian" ]] || die "This installer supports Debian only."
  case "${VERSION_ID:-}" in
    12|13) ;;
    *) die "This installer supports Debian 12 or Debian 13. Detected: ${PRETTY_NAME:-unknown}" ;;
  esac

  [[ -f "$RPT_CONF" ]] || die "$RPT_CONF was not found. Install and configure AllStarLink Version 3 first."
  id asterisk >/dev/null 2>&1 || die "The asterisk user was not found. Install AllStarLink Version 3 first."
}

validate_node() {
  local node="$1"
  [[ "$node" =~ ^[0-9]{3,10}$ ]] || die "Node number must contain only digits and be between 3 and 10 digits long."
}

prompt_for_node() {
  local node=""
  if [[ -n "${SPEAKIP_NODE:-}" ]]; then
    node="$SPEAKIP_NODE"
  elif [[ -t 0 ]]; then
    read -r -p "Enter the AllStarLink node number for Speak IP: " node
  else
    die "No node number was supplied. Use: sudo SPEAKIP_NODE=12345 ./install-speakip.sh"
  fi
  validate_node "$node"
  printf '%s' "$node"
}

backup_rpt_conf() {
  local stamp backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${RPT_CONF}.speakip-backup-${stamp}"
  cp -a "$RPT_CONF" "$backup"
  log "Backed up rpt.conf to $backup"
}

check_dtmf_conflicts() {
  local code expected existing
  for expected in "${DTMF_LINES[@]}"; do
    code="${expected%% *}"
    existing="$(grep -E "^[[:space:]]*${code}[[:space:]]*=" "$RPT_CONF" || true)"
    if [[ -n "$existing" ]] && ! grep -Fqx "$expected" <<<"$existing"; then
      die "DTMF command ${code} is already in use in $RPT_CONF:
$existing

Choose different DTMF numbers before installing Speak IP."
    fi
  done
}

add_dtmf_commands() {
  check_dtmf_conflicts
  backup_rpt_conf

  local tmp line
  tmp="$(mktemp)"
  cp "$RPT_CONF" "$tmp"

  # Remove exact previous Speak IP entries first, making the operation repeatable.
  for line in "${DTMF_LINES[@]}" "${OLD_DTMF_LINES[@]}"; do
    grep -Fvx "$line" "$tmp" > "${tmp}.new" || true
    mv "${tmp}.new" "$tmp"
  done

  grep -Fvx "; Speak IP commands - installed by install-speakip.sh" "$tmp" > "${tmp}.new" || true
  mv "${tmp}.new" "$tmp"
  grep -Fvx "; Speak IP functions stanza - installed by install-speakip.sh" "$tmp" > "${tmp}.new" || true
  mv "${tmp}.new" "$tmp"

  # Match either:
  #   [functions]
  # or ASL3 inherited style:
  #   [functions](functions-main)
  #
  # This is the fix for fresh ASL3 template-based rpt.conf files.
  if grep -Eq '^[[:space:]]*\[functions\]([[:space:]]*\([^)]*\))?[[:space:]]*$' "$tmp"; then
    awk '
      BEGIN { inserted=0 }
      {
        print
        if (!inserted && $0 ~ /^[[:space:]]*\[functions\]([[:space:]]*\([^)]*\))?[[:space:]]*$/) {
          print ""
          print "; Speak IP commands - installed by install-speakip.sh"
          print "890 = cmd,/etc/asterisk/local/shutdown.pl"
          print "891 = cmd,/etc/asterisk/local/reboot.pl"
          print "892 = cmd,/etc/asterisk/local/sayip.pl"
          print "893 = cmd,/etc/asterisk/local/saypublicip.pl"
          inserted=1
        }
      }
    ' "$tmp" > "${tmp}.final"
    log "Found existing [functions] stanza and added Speak IP DTMF commands there."
  else
    cp "$tmp" "${tmp}.final"
    {
      printf '\n'
      printf '; Speak IP functions stanza - installed by install-speakip.sh\n'
      printf '[functions]\n'
      printf '; Speak IP commands - installed by install-speakip.sh\n'
      printf '890 = cmd,/etc/asterisk/local/shutdown.pl\n'
      printf '891 = cmd,/etc/asterisk/local/reboot.pl\n'
      printf '892 = cmd,/etc/asterisk/local/sayip.pl\n'
      printf '893 = cmd,/etc/asterisk/local/saypublicip.pl\n'
    } >> "${tmp}.final"
    warn "No [functions] stanza was found, so one was created at the end of rpt.conf."
  fi

  install -o root -g asterisk -m 0640 "${tmp}.final" "$RPT_CONF"
  rm -f "$tmp" "${tmp}.final"
  log "Added DTMF commands 890 through 893."
}

remove_dtmf_commands() {
  [[ -f "$RPT_CONF" ]] || return 0

  local tmp line
  tmp="$(mktemp)"
  cp "$RPT_CONF" "$tmp"

  for line in "${DTMF_LINES[@]}" "${OLD_DTMF_LINES[@]}"; do
    grep -Fvx "$line" "$tmp" > "${tmp}.new" || true
    mv "${tmp}.new" "$tmp"
  done

  grep -Fvx "; Speak IP commands - installed by install-speakip.sh" "$tmp" > "${tmp}.new" || true
  mv "${tmp}.new" "$tmp"
  grep -Fvx "; Speak IP functions stanza - installed by install-speakip.sh" "$tmp" > "${tmp}.new" || true
  mv "${tmp}.new" "$tmp"

  # If the installer had to create an empty [functions] stanza, leave it alone.
  # Removing whole stanzas automatically is riskier than removing the exact lines we installed.

  install -o root -g asterisk -m 0640 "$tmp" "$RPT_CONF"
  rm -f "$tmp"
}

download_file() {
  local remote_name="$1"
  local local_name="$2"
  local url="${BASE_URL}/${remote_name}"
  local destination="${SOUND_DIR}/${local_name}"

  if curl -fL --connect-timeout 10 --max-time 60 "$url" -o "$destination"; then
    chmod 0644 "$destination"
    chown root:asterisk "$destination"
    return 0
  fi

  rm -f "$destination"
  return 1
}

install_audio_files() {
  install -d -o root -g asterisk -m 0755 "$SOUND_DIR"

  log "Downloading Speak IP audio prompts..."

  download_file "shutdown.ulaw" "shutdown.ulaw" \
    || die "Could not download ${BASE_URL}/shutdown.ulaw"

  download_file "reboot.ulaw" "reboot.ulaw" \
    || die "Could not download ${BASE_URL}/reboot.ulaw"

  # The request mentioned both saylocalip.ulaw and sayip.ulaw.
  # Prefer saylocalip.ulaw, but accept sayip.ulaw as a compatible fallback.
  if ! download_file "saylocalip.ulaw" "saylocalip.ulaw"; then
    warn "saylocalip.ulaw was not found. Trying sayip.ulaw as a fallback."
    download_file "sayip.ulaw" "saylocalip.ulaw" \
      || die "Could not download saylocalip.ulaw or the sayip.ulaw fallback."
  fi

  download_file "saypublicip.ulaw" "saypublicip.ulaw" \
    || die "Could not download ${BASE_URL}/saypublicip.ulaw"
}

write_config() {
  local node="$1"
  cat > "$CONFIG_FILE" <<EOF
# Speak IP configuration
#
# Written and developed by Freddie McGuire, KD5FMU, Ham Radio Crusader,
# with assistance from OpenAI ChatGPT.
# Created: June 2026
#
# Installed by install-speakip.sh
NODE=${node}
SOUND_DIR=${SOUND_DIR}
ASTERISK_BIN=$(command -v asterisk || true)
EOF
  chown root:asterisk "$CONFIG_FILE"
  chmod 0644 "$CONFIG_FILE"
}

write_common_perl_module() {
  cat > "${LOCAL_DIR}/SpeakIP.pm" <<'PERL'
# Speak IP helper module for AllStarLink Version 3
#
# Written and developed by Freddie McGuire, KD5FMU, Ham Radio Crusader,
# with assistance from OpenAI ChatGPT.
# Created: June 2026
#
# Purpose:
#   Shared helper functions used by the Speak IP command scripts.
#
# Installed by install-speakip.sh

package SpeakIP;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
  load_config
  play_prompt
  speak_text
  spoken_ipv4
  valid_ipv4
  logger
  detach_and_exit
);

sub logger {
    my ($message) = @_;
    system('/usr/bin/logger', '-t', 'speakip', $message);
}

sub load_config {
    my $file = '/etc/asterisk/local/speakip.conf';
    open my $fh, '<', $file or die "Unable to read $file: $!\n";

    my %cfg;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        next unless $line =~ /^([A-Z_]+)=(.*)$/;
        $cfg{$1} = $2;
    }
    close $fh;

    die "NODE is missing from $file\n" unless defined $cfg{NODE} && $cfg{NODE} =~ /^\d{3,10}$/;
    $cfg{SOUND_DIR} ||= '/usr/local/share/asterisk/sounds/speakip';
    if (defined $cfg{ASTERISK_BIN} && $cfg{ASTERISK_BIN} ne '') {
        $ENV{'SPEAKIP_ASTERISK_BIN'} = $cfg{ASTERISK_BIN};
    }

    return \%cfg;
}

sub play_prompt {
    my ($node, $prompt_path) = @_;
    return 0 unless -r "${prompt_path}.ulaw" || -r "${prompt_path}.ul";

    my $asterisk = $ENV{'SPEAKIP_ASTERISK_BIN'} || '/usr/sbin/asterisk';
    if (!-x $asterisk) {
        $asterisk = '/usr/bin/asterisk' if -x '/usr/bin/asterisk';
    }

    if (!-x $asterisk) {
        logger("Unable to find executable asterisk binary for prompt playback.");
        return 0;
    }

    my $result = system($asterisk, '-rx', "rpt playback $node $prompt_path");
    return $result == 0;
}

sub speak_text {
    my ($node, $text) = @_;

    chdir '/' or logger("Unable to change working directory to / before asl-tts: $!");

    my $tts = '/usr/bin/asl-tts';
    $tts = '/usr/local/bin/asl-tts' if !-x $tts && -x '/usr/local/bin/asl-tts';

    if (!-x $tts) {
        logger("Unable to find executable asl-tts binary.");
        return 0;
    }

    logger("Running asl-tts for node $node.");
    my $result = system($tts, '-n', $node, '-t', $text);
    if ($result != 0) {
        logger("asl-tts failed for node $node with exit status $result.");
    }
    return $result == 0;
}

sub valid_ipv4 {
    my ($ip) = @_;
    return 0 unless defined $ip && $ip =~ /^\d{1,3}(?:\.\d{1,3}){3}$/;
    my @octets = split /\./, $ip;
    for my $octet (@octets) {
        return 0 if $octet > 255;
    }
    return 1;
}

sub spoken_ipv4 {
    my ($ip) = @_;
    my %digit = (
        '0' => 'zero',  '1' => 'one',   '2' => 'two',   '3' => 'three',
        '4' => 'four',  '5' => 'five',  '6' => 'six',   '7' => 'seven',
        '8' => 'eight', '9' => 'nine',
    );

    my @octets = split /\./, $ip;
    my @spoken;
    for my $octet (@octets) {
        push @spoken, join(' ', map { $digit{$_} } split //, $octet);
    }
    return join(' dot ', @spoken);
}

sub detach_and_exit {
    my (@cmd) = @_;

    my $pid = fork();
    if (!defined $pid) {
        logger("Unable to fork detached Speak IP process: $!");
        return 0;
    }

    # Parent exits immediately so app_rpt cmd is not held open.
    if ($pid) {
        exit 0;
    }

    # Child detaches from the app_rpt/Asterisk command context.
    eval { require POSIX; POSIX::setsid(); };
    chdir '/' or logger("Unable to chdir to / in detached Speak IP process: $!");

    open STDIN,  '<', '/dev/null';
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';

    # A tiny pause lets the app_rpt command process fully return before playback/TTS starts.
    sleep 1;

    my $result = system(@cmd);
    if ($result != 0) {
        logger("Detached Speak IP command failed: @cmd");
        exit 1;
    }

    exit 0;
}

1;
PERL

  chown root:asterisk "${LOCAL_DIR}/SpeakIP.pm"
  chmod 0644 "${LOCAL_DIR}/SpeakIP.pm"
}

write_sayip_script() {
  cat > "${LOCAL_DIR}/sayip.pl" <<'PERL'
#!/usr/bin/perl
#
# Speak IP local IP announcement script for AllStarLink Version 3
#
# Written and developed by Freddie McGuire, KD5FMU, Ham Radio Crusader,
# with assistance from OpenAI ChatGPT.
# Created: June 2026
#
# Purpose:
#   Plays the local IP prompt, then speaks the node local IPv4 address over the air.
#
# Installed by install-speakip.sh

use strict;
use warnings;
use lib '/etc/asterisk/local';
use SpeakIP qw(load_config play_prompt speak_text spoken_ipv4 valid_ipv4 logger detach_and_exit);

if (!@ARGV || $ARGV[0] ne '--direct') {
    detach_and_exit('/etc/asterisk/local/sayip.pl', '--direct');
    exit 0;
}

logger('Starting local IP announcement in direct mode.');
my $cfg = load_config();
my $node = $cfg->{NODE};
my $sound_dir = $cfg->{SOUND_DIR};

my $ip = '';

# Prefer the source address used for a normal outbound route.
if (open my $route, '-|', '/usr/sbin/ip', '-4', 'route', 'get', '1.1.1.1') {
    while (my $line = <$route>) {
        if ($line =~ /\bsrc\s+(\d{1,3}(?:\.\d{1,3}){3})\b/) {
            $ip = $1;
            last;
        }
    }
    close $route;
}

# Fallback for unusual routing configurations.
if (!valid_ipv4($ip) && open my $host, '-|', '/usr/bin/hostname', '-I') {
    my $line = <$host> // '';
    close $host;
    for my $candidate (split /\s+/, $line) {
        if (valid_ipv4($candidate) && $candidate !~ /^127\./) {
            $ip = $candidate;
            last;
        }
    }
}

if (!valid_ipv4($ip)) {
    logger('Unable to determine the local IPv4 address.');
    play_prompt($node, "$sound_dir/saylocalip");
    speak_text($node, 'The local I P address could not be determined');
    exit 1;
}

play_prompt($node, "$sound_dir/saylocalip");
sleep 1;
my $spoken = spoken_ipv4($ip);
speak_text($node, $spoken) or logger("asl-tts failed while speaking local IP $ip");
logger("Local IPv4 address announced: $ip");
exit 0;
PERL

  chown root:asterisk "${LOCAL_DIR}/sayip.pl"
  chmod 0755 "${LOCAL_DIR}/sayip.pl"
}

write_saypublicip_script() {
  cat > "${LOCAL_DIR}/saypublicip.pl" <<'PERL'
#!/usr/bin/perl
#
# Speak IP public IP announcement script for AllStarLink Version 3
#
# Written and developed by Freddie McGuire, KD5FMU, Ham Radio Crusader,
# with assistance from OpenAI ChatGPT.
# Created: June 2026
#
# Purpose:
#   Plays the public IP prompt, then speaks the node public IPv4 address over the air.
#
# Installed by install-speakip.sh

use strict;
use warnings;
use lib '/etc/asterisk/local';
use SpeakIP qw(load_config play_prompt speak_text spoken_ipv4 valid_ipv4 logger detach_and_exit);

if (!@ARGV || $ARGV[0] ne '--direct') {
    detach_and_exit('/etc/asterisk/local/saypublicip.pl', '--direct');
    exit 0;
}

logger('Starting public IP announcement in direct mode.');
my $cfg = load_config();
my $node = $cfg->{NODE};
my $sound_dir = $cfg->{SOUND_DIR};
my $ip = '';

my @services = (
    'https://api.ipify.org',
    'https://checkip.amazonaws.com',
);

for my $url (@services) {
    if (open my $curl, '-|', '/usr/bin/curl', '-4', '-fsS', '--connect-timeout', '5', '--max-time', '10', $url) {
        my $candidate = <$curl> // '';
        close $curl;
        $candidate =~ s/^\s+|\s+$//g;
        if (valid_ipv4($candidate)) {
            $ip = $candidate;
            last;
        }
    }
}

if (!valid_ipv4($ip)) {
    logger('Unable to determine the public IPv4 address.');
    play_prompt($node, "$sound_dir/saypublicip");
    speak_text($node, 'The public I P address could not be determined');
    exit 1;
}

play_prompt($node, "$sound_dir/saypublicip");
sleep 1;
my $spoken = spoken_ipv4($ip);
speak_text($node, $spoken) or logger("asl-tts failed while speaking public IP $ip");
logger("Public IPv4 address announced: $ip");
exit 0;
PERL

  chown root:asterisk "${LOCAL_DIR}/saypublicip.pl"
  chmod 0755 "${LOCAL_DIR}/saypublicip.pl"
}

write_shutdown_script() {
  cat > "${LOCAL_DIR}/shutdown.pl" <<'PERL'
#!/usr/bin/perl
#
# Speak IP shutdown command script for AllStarLink Version 3
#
# Written and developed by Freddie McGuire, KD5FMU, Ham Radio Crusader,
# with assistance from OpenAI ChatGPT.
# Created: June 2026
#
# Purpose:
#   Plays the shutdown prompt, waits briefly, then powers off the node.
#
# Installed by install-speakip.sh

use strict;
use warnings;
use lib '/etc/asterisk/local';
use SpeakIP qw(load_config play_prompt logger);

my $cfg = load_config();
my $node = $cfg->{NODE};
my $sound_dir = $cfg->{SOUND_DIR};

logger('Shutdown requested by Speak IP DTMF command.');
play_prompt($node, "$sound_dir/shutdown");
sleep 5;
exec '/usr/sbin/poweroff';
die "Unable to execute /usr/sbin/poweroff: $!\n";
PERL

  chown root:asterisk "${LOCAL_DIR}/shutdown.pl"
  chmod 0755 "${LOCAL_DIR}/shutdown.pl"
}

write_reboot_script() {
  cat > "${LOCAL_DIR}/reboot.pl" <<'PERL'
#!/usr/bin/perl
#
# Speak IP reboot command script for AllStarLink Version 3
#
# Written and developed by Freddie McGuire, KD5FMU, Ham Radio Crusader,
# with assistance from OpenAI ChatGPT.
# Created: June 2026
#
# Purpose:
#   Plays the reboot prompt, waits briefly, then reboots the node.
#
# Installed by install-speakip.sh

use strict;
use warnings;
use lib '/etc/asterisk/local';
use SpeakIP qw(load_config play_prompt logger);

my $cfg = load_config();
my $node = $cfg->{NODE};
my $sound_dir = $cfg->{SOUND_DIR};

logger('Reboot requested by Speak IP DTMF command.');
play_prompt($node, "$sound_dir/reboot");
sleep 5;
exec '/usr/sbin/reboot';
die "Unable to execute /usr/sbin/reboot: $!\n";
PERL

  chown root:asterisk "${LOCAL_DIR}/reboot.pl"
  chmod 0755 "${LOCAL_DIR}/reboot.pl"
}

write_systemd_service() {
  cat > "$SERVICE_FILE" <<'EOF'
# Speak IP boot announcement service for AllStarLink Version 3
#
# Written and developed by Freddie McGuire, KD5FMU, Ham Radio Crusader,
# with assistance from OpenAI ChatGPT.
# Created: June 2026
#
# Installed by install-speakip.sh

[Unit]
Description=Announce the AllStarLink node local IP address after startup
Wants=network-online.target
After=network-online.target asterisk.service
Requires=asterisk.service

[Service]
Type=oneshot
User=asterisk
Group=asterisk
WorkingDirectory=/
ExecStartPre=/bin/sleep 5
ExecStart=/etc/asterisk/local/sayip.pl --direct
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
  systemctl enable speakip-boot.service
}

validate_generated_files() {
  local file
  for file in \
    "${LOCAL_DIR}/SpeakIP.pm" \
    "${LOCAL_DIR}/sayip.pl" \
    "${LOCAL_DIR}/saypublicip.pl" \
    "${LOCAL_DIR}/shutdown.pl" \
    "${LOCAL_DIR}/reboot.pl"
  do
    perl -c "$file" >/dev/null
  done
}

repair_permissions() {
  # The Asterisk/app_rpt cmd function runs as the asterisk user.
  # It must be able to traverse /etc/asterisk/local and execute these helpers.
  chown root:asterisk "$LOCAL_DIR"
  chmod 0755 "$LOCAL_DIR"

  chown root:asterisk \
    "${LOCAL_DIR}/SpeakIP.pm" \
    "${LOCAL_DIR}/sayip.pl" \
    "${LOCAL_DIR}/saypublicip.pl" \
    "${LOCAL_DIR}/shutdown.pl" \
    "${LOCAL_DIR}/reboot.pl" \
    "$CONFIG_FILE"

  chmod 0644 "${LOCAL_DIR}/SpeakIP.pm" "$CONFIG_FILE"
  chmod 0755 \
    "${LOCAL_DIR}/sayip.pl" \
    "${LOCAL_DIR}/saypublicip.pl" \
    "${LOCAL_DIR}/shutdown.pl" \
    "${LOCAL_DIR}/reboot.pl"
}

install_packages() {
  log "Updating Debian packages. This may take a while on a node that has not been updated recently."
  export DEBIAN_FRONTEND=noninteractive
  apt update
  apt upgrade -y
  apt install -y asl3-tts curl perl
}

restart_asterisk() {
  systemctl restart asterisk
}

run_test_prompt() {
  local answer=""
  if [[ -t 0 ]]; then
    read -r -p "Would you like to announce the local IP address now? [Y/n]: " answer
    answer="${answer:-Y}"
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      cd / && sudo -u asterisk "${LOCAL_DIR}/sayip.pl" --direct || warn "The test announcement returned an error. Check: journalctl -t speakip"
    fi
  fi
}

uninstall_speakip() {
  log "Uninstalling Speak IP..."

  systemctl disable --now speakip-boot.service >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload

  if [[ -f "$RPT_CONF" ]]; then
    backup_rpt_conf
    remove_dtmf_commands
  fi

  rm -f \
    "${LOCAL_DIR}/shutdown.pl" \
    "${LOCAL_DIR}/reboot.pl" \
    "${LOCAL_DIR}/sayip.pl" \
    "${LOCAL_DIR}/saypublicip.pl" \
    "${LOCAL_DIR}/SpeakIP.pm" \
    "$CONFIG_FILE"

  rm -rf "$SOUND_DIR"

  if systemctl list-unit-files asterisk.service >/dev/null 2>&1; then
    systemctl restart asterisk || true
  fi

  log "Speak IP has been removed."
  printf '%s\n' "The asl3-tts package was left installed because other ASL3 features may use it."
}

install_speakip() {
  local node

  check_platform
  node="$(prompt_for_node)"

  install_packages

  install -d -o root -g asterisk -m 0755 "$LOCAL_DIR"
  install_audio_files
  write_config "$node"
  write_common_perl_module
  write_sayip_script
  write_saypublicip_script
  write_shutdown_script
  write_reboot_script
  validate_generated_files
  repair_permissions
  add_dtmf_commands
  write_systemd_service
  restart_asterisk

  log "Speak IP ${PROGRAM_VERSION} installation is complete."
  printf '%s\n' \
    "" \
    "Node number: $node" \
    "DTMF commands:" \
    "  *890  Play shutdown prompt, then power off" \
    "  *891  Play reboot prompt, then reboot" \
    "  *892  Announce the local IPv4 address" \
    "  *893  Announce the public IPv4 address" \
    "" \
    "Boot announcement service: speakip-boot.service" \
    "Log messages: journalctl -t speakip" \
    "Uninstall command: sudo ./install-speakip.sh --uninstall"

  run_test_prompt
}

main() {
  require_root

  case "${1:-}" in
    --repair-permissions)
      check_platform
      [[ -f "$CONFIG_FILE" ]] || die "$CONFIG_FILE was not found. Run the installer first."
      repair_permissions
      systemctl restart asterisk
      log "Speak IP permissions repaired and Asterisk restarted."
      ;;
    --uninstall|-u)
      check_platform
      uninstall_speakip
      ;;
    --help|-h)
      cat <<EOF
$PROGRAM_NAME installer version $PROGRAM_VERSION

Usage:
  sudo ./install-speakip.sh
  sudo SPEAKIP_NODE=12345 ./install-speakip.sh
  sudo ./install-speakip.sh --repair-permissions
  sudo ./install-speakip.sh --uninstall
EOF
      ;;
    "")
      install_speakip
      ;;
    *)
      die "Unknown option: $1. Use --help for usage."
      ;;
  esac
}

main "$@"
