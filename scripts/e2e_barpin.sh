#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${APP_PATH:-dist/BarPin.app}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-12}"
PROCESS_NAME="${PROCESS_NAME:-}"

log() {
  printf "[e2e] %s\n" "$*"
}

fail() {
  printf "[e2e][FAIL] %s\n" "$*" >&2
  exit 1
}

assert_file() {
  if [[ ! -e "$1" ]]; then
    fail "missing: $1"
  fi
}

wait_for_manage_window() {
  local timeout="$1"
  local start now
  start="$(date +%s)"
  while true; do
    if osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "System Events"
  if not (exists process "$PROCESS_NAME") then
    return false
  end if
  tell process "$PROCESS_NAME"
    if (count of windows) is 0 then
      return false
    end if
    repeat with w in windows
      set t to name of w as text
      if t contains "Manage" or t contains "管理" then
        return true
      end if
    end repeat
    return false
  end tell
end tell
APPLESCRIPT
    then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      return 1
    fi
    sleep 0.3
  done
}

detect_process_name() {
  if [[ -n "$PROCESS_NAME" ]]; then
    return
  fi
  if [[ -f "$APP_PATH/Contents/Info.plist" ]]; then
    PROCESS_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [[ -z "$PROCESS_NAME" ]]; then
    PROCESS_NAME="BarPin"
  fi
}

preflight_automation_permission() {
  if ! osascript <<'APPLESCRIPT' >/dev/null 2>&1
tell application "System Events"
  count of processes
end tell
APPLESCRIPT
  then
    fail "System Events automation is not permitted. Enable Automation/Accessibility for your terminal (or Codex) and retry."
  fi
}

preflight_accessibility_for_process() {
  if ! osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "System Events"
  if not (exists process "$PROCESS_NAME") then
    return true
  end if
  tell process "$PROCESS_NAME"
    count of windows
  end tell
end tell
APPLESCRIPT
  then
    fail "Accessibility for controlling \"$PROCESS_NAME\" is not permitted. Enable Accessibility for your terminal (or Codex) and retry."
  fi
}

close_manage_window_if_exists() {
  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  if not (exists process "$PROCESS_NAME") then
    return
  end if
  tell process "$PROCESS_NAME"
    repeat with w in windows
      set t to name of w as text
      if t contains "Manage" or t contains "管理" then
        try
          click button 1 of w
        end try
      end if
    end repeat
  end tell
end tell
APPLESCRIPT
}

main() {
  assert_file "$APP_PATH"
  detect_process_name
  preflight_automation_permission

  log "launch app: $APP_PATH (process: $PROCESS_NAME)"
  open "$APP_PATH"
  sleep 1
  preflight_accessibility_for_process

  log "trigger reopen event (1)"
  open "$APP_PATH"
  if ! wait_for_manage_window "$TIMEOUT_SECONDS"; then
    fail "manage window did not appear after reopen"
  fi
  log "manage window opened successfully"

  log "close manage window"
  close_manage_window_if_exists
  sleep 0.5

  log "trigger reopen event (2)"
  open "$APP_PATH"
  if ! wait_for_manage_window "$TIMEOUT_SECONDS"; then
    fail "manage window did not re-open after close"
  fi
  log "manage window re-opened successfully"

  log "PASS: manage window reopen flow is stable"
}

main "$@"
