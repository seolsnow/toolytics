#!/usr/bin/env bash
# toolytics scheduler installer — portable, idempotent, self-configuring.
# Schedules build.sh once a day so usage history is captured into the persistent
# CSVs BEFORE Claude Code's transcript cleanup (default 30d) deletes the source logs.
#   macOS -> launchd LaunchAgent
#   Linux -> systemd --user timer  (cron fallback if systemd absent)
# Everything is derived at install time (no machine paths baked in), and re-running
# just refreshes the install — so this doubles as a SessionStart self-install guard.
#
#   ./install-daemon.sh            # install/refresh for the current OS + user
#   ./install-daemon.sh ensure     # install ONLY if missing (cheap; for the SessionStart hook)
#   ./install-daemon.sh --remove   # uninstall
set -euo pipefail

LABEL="com.seolsnow.toolytics"
SRC="$(cd "$(dirname "$0")" && pwd)"            # holds build.sh
BUILD="$SRC/build.sh"
HOUR=12; MIN=0                                  # daily run time (local)
OUT="${TOOLYTICS_HOME:-$HOME/.toolytics}"
LOG="$OUT/scheduler.log"
PYBIN="$(command -v python3 || true)"
[ -n "$PYBIN" ] || { echo "python3 not found on PATH" >&2; exit 1; }
PYDIR="$(dirname "$PYBIN")"                      # so the scheduler's minimal PATH finds python3
mkdir -p "$OUT"
ACTION="${1:-install}"

# ---------- macOS: launchd ----------
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mac_remove() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"; echo "removed launchd agent $LABEL"
}
mac_install() {
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$BUILD</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TOOLYTICS_OPEN</key><string>0</string>
    <key>PATH</key><string>$PYDIR:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>$HOUR</integer><key>Minute</key><integer>$MIN</integer></dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  launchctl enable "gui/$(id -u)/$LABEL"
  echo "installed launchd agent -> $PLIST (daily $(printf '%02d:%02d' "$HOUR" "$MIN"))"
}

# ---------- Linux: systemd --user, else cron ----------
UD="$HOME/.config/systemd/user"
lin_remove() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now toolytics.timer 2>/dev/null || true
    rm -f "$UD/toolytics.timer" "$UD/toolytics.service"
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  ( crontab -l 2>/dev/null | grep -v "# $LABEL" || true ) | crontab - 2>/dev/null || true
  echo "removed linux scheduler"
}
lin_install() {
  if command -v systemctl >/dev/null 2>&1; then
    mkdir -p "$UD"
    cat > "$UD/toolytics.service" <<UNITEOF
[Unit]
Description=toolytics daily usage scan
[Service]
Type=oneshot
Environment=TOOLYTICS_OPEN=0
Environment=PATH=$PYDIR:/usr/bin:/bin:/usr/sbin:/sbin
ExecStart=/bin/bash "$BUILD"
StandardOutput=append:$LOG
StandardError=append:$LOG
UNITEOF
    cat > "$UD/toolytics.timer" <<UNITEOF
[Unit]
Description=toolytics daily usage scan timer
[Timer]
OnCalendar=*-*-* $(printf '%02d:%02d' "$HOUR" "$MIN"):00
Persistent=true
[Install]
WantedBy=timers.target
UNITEOF
    systemctl --user daemon-reload
    systemctl --user enable --now toolytics.timer
    loginctl enable-linger "$USER" 2>/dev/null || true   # run even when logged out (best-effort)
    echo "installed systemd --user timer toolytics.timer (daily $(printf '%02d:%02d' "$HOUR" "$MIN"))"
  else
    local line="$MIN $HOUR * * * TOOLYTICS_OPEN=0 PATH=$PYDIR:/usr/bin:/bin /bin/bash \"$BUILD\" >> \"$LOG\" 2>&1 # $LABEL"
    ( crontab -l 2>/dev/null | grep -v "# $LABEL" || true; echo "$line" ) | crontab -
    echo "installed cron job (daily $(printf '%02d:%02d' "$HOUR" "$MIN")); systemd not found"
  fi
}

# ---------- Windows (Git Bash / MSYS / Cygwin): schtasks ----------
# Native Windows path: register a Scheduled Task that runs build.sh via Git Bash
# once a day. A tiny .cmd wrapper at $OUT/run-daemon.cmd stabilizes PATH and
# quoting so the schtasks command stays simple and re-installable.
TASK_NAME="toolytics"
WRAPPER="$OUT/run-daemon.cmd"
win_paths() {
  WIN_BUILD="$(cygpath -w "$BUILD")"
  WIN_LOG="$(cygpath -w "$LOG")"
  WIN_WRAPPER="$(cygpath -w "$WRAPPER")"
  WIN_PYDIR="$(cygpath -w "$PYDIR")"
  BASH_PATH="$(command -v bash)"
  WIN_BASH_DIR="$(dirname "$(cygpath -w "$BASH_PATH")")"
}
win_write_wrapper() {
  win_paths
  cat > "$WRAPPER" <<WRAPEOF
@echo off
set "PATH=$WIN_PYDIR;$WIN_BASH_DIR;%PATH%"
set TOOLYTICS_OPEN=0
bash -c "exec '$BUILD' >> '$LOG' 2>&1"
WRAPEOF
}
win_remove() {
  MSYS_NO_PATHCONV=1 schtasks /Delete /TN "$TASK_NAME" /F >/dev/null 2>&1 || true
  rm -f "$WRAPPER"
  echo "removed scheduled task $TASK_NAME"
}
win_install() {
  win_write_wrapper
  MSYS_NO_PATHCONV=1 schtasks /Delete /TN "$TASK_NAME" /F >/dev/null 2>&1 || true
  MSYS_NO_PATHCONV=1 schtasks /Create /TN "$TASK_NAME" /SC DAILY \
    /ST "$(printf '%02d:%02d' "$HOUR" "$MIN")" \
    /TR "\"$WIN_WRAPPER\"" /F >/dev/null
  echo "installed scheduled task $TASK_NAME -> $WIN_WRAPPER (daily $(printf '%02d:%02d' "$HOUR" "$MIN"))"
}
win_ensure() {
  win_paths
  MSYS_NO_PATHCONV=1 schtasks /Query /TN "$TASK_NAME" /V /FO LIST 2>/dev/null \
    | grep -F -q "$WIN_WRAPPER" || win_install
}

# ---------- ensure: install if missing OR if the registered build path is stale ----------
# a plugin version bump moves build.sh (cache/.../0.1.1 -> 0.1.2); the old path is then
# deleted and the daily collector would silently die. so ensure must also refresh when the
# registered command no longer points at the current $BUILD — not just when it's absent.
mac_ensure() {
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 \
    && grep -Fq "<string>$BUILD</string>" "$PLIST" 2>/dev/null || mac_install
}
lin_ensure() {
  if command -v systemctl >/dev/null 2>&1; then
    { systemctl --user is-enabled toolytics.timer >/dev/null 2>&1 \
      && grep -Fq "$BUILD" "$UD/toolytics.service" 2>/dev/null \
      && grep -Fq "append:$LOG" "$UD/toolytics.service" 2>/dev/null; } || lin_install
  else
    ( crontab -l 2>/dev/null | grep "# $LABEL" | grep -Fq "$BUILD" ) || lin_install
  fi
}

case "$(uname -s):$ACTION" in
  Darwin:install)  mac_install ;;
  Darwin:ensure)   mac_ensure ;;
  Darwin:--remove) mac_remove ;;
  Linux:install)   lin_install ;;
  Linux:ensure)    lin_ensure ;;
  Linux:--remove)  lin_remove ;;
  MINGW*:install|MSYS*:install|CYGWIN*:install)        win_install ;;
  MINGW*:ensure|MSYS*:ensure|CYGWIN*:ensure)           win_ensure ;;
  MINGW*:--remove|MSYS*:--remove|CYGWIN*:--remove)     win_remove ;;
  *) echo "unsupported: OS=$(uname -s) action=$ACTION (try: install | ensure | --remove)" >&2; exit 1 ;;
esac
