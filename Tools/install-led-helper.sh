#!/bin/bash
# Installs (or removes) the privileged helper that lets Umbra switch the status LED.
#
# Grants exactly one thing: this user may run this one binary, with one of four
# fixed arguments, as root without a password. The binary takes no SMC key names
# from its caller, so the grant cannot be widened by passing something clever.
#
#   ./Tools/install-led-helper.sh
#   ./Tools/install-led-helper.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")/.."

# Runs one command as root. Prefers sudo when a terminal exists to type into;
# otherwise falls back to macOS's own authentication dialog, so the password is
# handled by the system Security framework and never passes through this script.
run_privileged() {
  local command="$1"
  if sudo -n true 2>/dev/null; then
    sudo /bin/sh -c "$command"
  elif [ -t 0 ]; then
    sudo /bin/sh -c "$command"
  else
    local escaped
    escaped=$(printf '%s' "$command" | sed 's/\\/\\\\/g; s/"/\\"/g')
    echo "No terminal available for a password prompt — using the macOS authentication dialog."
    osascript -e "do shell script \"$escaped\" with administrator privileges" > /dev/null
  fi
}

HELPER_DST="/usr/local/libexec/umbra-led"
SUDOERS_DST="/etc/sudoers.d/umbra-led"
USER_NAME="$(id -un)"

if [ "${1:-}" = "--uninstall" ]; then
  echo "Removing the LED helper. You will be asked for your password."
  run_privileged "/bin/rm -f $SUDOERS_DST $HELPER_DST"
  echo "Removed $SUDOERS_DST and $HELPER_DST"
  exit 0
fi

echo "Building the helper..."
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
clang -O2 -framework IOKit -o "$STAGE/umbra-led" Tools/umbra-led.c

# Confirm it works before asking for any privilege: status needs no root.
if ! "$STAGE/umbra-led" status > /dev/null; then
  echo "error: the helper cannot reach the SMC on this Mac. Nothing was installed." >&2
  exit 1
fi

cat > "$STAGE/sudoers" <<RULE
# Installed by Umbra's install-led-helper.sh. Remove this file to revoke.
$USER_NAME ALL=(root) NOPASSWD: $HELPER_DST status, $HELPER_DST off, $HELPER_DST on, $HELPER_DST revert
RULE

# A malformed file in sudoers.d can lock you out of sudo entirely, so it is
# syntax-checked before it is ever placed there.
if ! visudo -cf "$STAGE/sudoers" > /dev/null; then
  echo "error: generated sudoers rule failed validation. Nothing was installed." >&2
  exit 1
fi
echo "sudoers rule validated."

# One elevation for all three, so the password is asked for exactly once.
echo "Installing. You will be asked for your password once."
run_privileged "/usr/bin/install -d -o root -g wheel -m 0755 $(dirname "$HELPER_DST") \
  && /usr/bin/install -o root -g wheel -m 0755 $STAGE/umbra-led $HELPER_DST \
  && /usr/bin/install -o root -g wheel -m 0440 $STAGE/sudoers $SUDOERS_DST"

echo "Verifying the grant works without a password..."
if sudo -n "$HELPER_DST" status > /dev/null 2>&1; then
  echo "OK: $HELPER_DST is callable without a password."
  echo "Umbra will pick it up the next time it launches."
else
  echo "error: the rule was installed but sudo still refuses. Check $SUDOERS_DST" >&2
  exit 1
fi
