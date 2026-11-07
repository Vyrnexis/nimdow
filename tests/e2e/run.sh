#!/usr/bin/env bash
# End-to-end input tests for nimdow running in a nested River.
#
#   bash tests/e2e/run.sh [-o OUTDIR] [-t TIMEOUT_SECONDS] [-b] [-s SCENARIO[,SCENARIO...]]
#
#   -o  output dir for screenshots, logs and results (default: $E2E_OUT or ./e2e-out)
#   -t  overall timeout of the nested river (default 240)
#   -b  build bin/nimdow and bin/nimdowinput first
#   -s  only run the named scenarios (comma separated, see `scenario_*` below)
#
# Requires: river >= 0.5, grim, alacritty, jq, dbus-run-session, python3 with
# gi (for tests/e2e/fake_sni.py), a running Wayland session to nest in.
# nimdow is driven with tests/e2e/config.toml; input is injected with
# bin/nimdowinput (virtual keyboard/pointer). State is asserted through
# `nimdow --dumpState`, with screenshots (grim) as extra evidence.
#
# The nested river runs inside `dbus-run-session`: the tray tests use a private
# session bus and never touch the real one (the inner part aborts if the bus
# address is the outer one).
#
# The script runs twice: the outer part starts river, whose -c command is this
# script again with --inner (it then runs inside the nested session).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="$ROOT/tests/e2e/run.sh"

if [ "${1:-}" = "--inner" ]; then
  MODE=inner
  shift
else
  MODE=outer
fi

OUT="${E2E_OUT:-$ROOT/e2e-out}"
TIMEOUT=240
BUILD=0
ONLY=""
while getopts "o:t:bs:" opt; do
  case $opt in
    o) OUT="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    b) BUILD=1 ;;
    s) ONLY="$OPTARG" ;;
    *) exit 2 ;;
  esac
done
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
RESULTS="$OUT/results.txt"

# ---------------------------------------------------------------------------
# Outer: start river
# ---------------------------------------------------------------------------
if [ "$MODE" = outer ]; then
  export PATH="$HOME/.nimble/bin:$PATH"
  for tool in river grim alacritty jq dbus-run-session python3; do
    command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 2; }
  done
  if [ "$BUILD" = 1 ] || [ ! -x "$ROOT/bin/nimdow" ] || [ ! -x "$ROOT/bin/nimdowinput" ]; then
    (cd "$ROOT" &&
      nim c --hints:off -o:bin/nimdow --deepcopy:on src/nimdow.nim &&
      nim c --hints:off -o:bin/nimdowinput tests/e2e/nimdowinput.nim) || exit 2
  fi

  rm -f "$OUT"/*.png "$OUT"/*.log "$OUT"/*.json "$OUT"/typed.txt "$RESULTS"
  : > "$RESULTS"
  # Unix socket paths are short: nimdow's IPC socket lives in a private runtime dir.
  RT="$(mktemp -d /tmp/nde2e.XXXXXX)"
  chmod 700 "$RT"
  export E2E_RT="$RT" E2E_OUT="$OUT" E2E_ONLY="$ONLY" E2E_OUTER_BUS="${DBUS_SESSION_BUS_ADDRESS:-none}"

  # run_phase <name> <number of nested outputs> <scenario names...>
  # Phases: "multi" (two outputs) and "single" (one output, ends with exitSession).
  run_phase() {
    local phase="$1" outputs="$2" scenarios=" ${*:3} " s want=0
    if [ -z "$ONLY" ]; then
      want=1
    else
      for s in ${ONLY//,/ }; do
        [[ "$scenarios" == *" $s "* ]] && want=1
      done
    fi
    [ "$want" = 1 ] || return 0
    export E2E_PHASE="$phase"
    local start=$SECONDS
    WLR_WL_OUTPUTS="$outputs" timeout -k 5 "$TIMEOUT" dbus-run-session -- river -no-xwayland \
      -log-level "${E2E_RIVER_LOG:-warning}" \
      -c "bash '$SELF' --inner > '$OUT/inner-$phase.log' 2>&1" > "$OUT/river-$phase.log" 2>&1
    local river_status=$?
    local elapsed=$((SECONDS - start))

    # exitSession (last scenario of the single phase): river must exit by itself.
    if grep -q '^PENDING exitSession' "$RESULTS"; then
      sed -i '/^PENDING exitSession/d' "$RESULTS"
      if [ "$river_status" = 124 ] || [ "$river_status" = 137 ]; then
        echo "FAIL exitSession: river was still running after ${TIMEOUT}s" >> "$RESULTS"
      elif ! grep -q "Starting Nimdow" "$OUT/nimdow-$phase.log" 2>/dev/null; then
        echo "FAIL exitSession: nimdow log missing" >> "$RESULTS"
      else
        echo "PASS exitSession: river exited (status $river_status) after ${elapsed}s" >> "$RESULTS"
      fi
    fi

    # River/Wayland protocol errors and nimdow crashes.
    # (The wlroots wayland backend prints "Io error: Broken pipe" when the outer
    # window goes away at shutdown; that is not a nimdow problem.)
    # River's "timeout occurred, some imperfect frames may be shown" means a client
    # (alacritty resizing its GL surface) was slower than River's configure
    # timeout. That is client latency, not a protocol error: counted as a note.
    local bad_river timeouts bad_nimdow
    bad_river=$(grep -E '^(error|warning)|^[A-Za-z]*Error|Segmentation|protocol error|wl_display' \
      "$OUT/river-$phase.log" | grep -viE 'Broken pipe|ExitFailure|timeout occurred' || true)
    timeouts=$(grep -c 'timeout occurred' "$OUT/river-$phase.log")
    [ "$timeouts" -gt 0 ] && echo "NOTE riverTimeouts-$phase: $timeouts slow-client configure timeouts (not protocol errors)" >> "$RESULTS"
    if [ -n "$bad_river" ]; then
      echo "FAIL riverLog-$phase: $(echo "$bad_river" | head -3 | tr '\n' '|')" >> "$RESULTS"
    else
      echo "PASS riverLog-$phase: no protocol errors" >> "$RESULTS"
    fi
    # (nimdow's log also holds the output of spawned alacritty clients, which
    # complain when river goes away.)
    bad_nimdow=$(grep -E 'ERROR|Error:|SIGSEGV|unhandled exception|Traceback|Segmentation' \
      "$OUT/nimdow-$phase.log" 2>/dev/null | grep -viE 'Broken pipe|ExitFailure' || true)
    if [ -n "$bad_nimdow" ]; then
      echo "FAIL nimdowLog-$phase: $(echo "$bad_nimdow" | head -3 | tr '\n' '|')" >> "$RESULTS"
    else
      echo "PASS nimdowLog-$phase: no errors" >> "$RESULTS"
    fi
  }

  run_phase multi 2 multiMonitor
  run_phase trayhost 1 trayHostOnly
  run_phase single 1 spawn viewTags moveToTag focus masterCount masterWidth floating \
    fullscreen close tagOps order reload typing dragMove dragResize barClick barScroll \
    clickFocus appRules scratchpad statusBar trayIcons trayClick trayUpdate trayVanish exitSession
  rm -rf "$RT"

  echo
  echo "=== e2e results ($OUT) ==="
  cat "$RESULTS"
  fails=$(grep -c '^FAIL' "$RESULTS")
  passes=$(grep -c '^PASS' "$RESULTS")
  echo "passed: $passes  failed: $fails"
  [ "$fails" = 0 ] && [ "$passes" -gt 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
# Inner: runs inside the nested river
# ---------------------------------------------------------------------------
cd "$ROOT" || exit 1
# Never run against the user's real session bus.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || [ "$DBUS_SESSION_BUS_ADDRESS" = "${E2E_OUTER_BUS:-none}" ]; then
  echo "FAIL dbus-$E2E_PHASE: not inside a private session bus, refusing to run" >> "$E2E_OUT/results.txt"
  exit 1
fi
ONLY="${E2E_ONLY:-}"
# River sets a relative WAYLAND_DISPLAY; nimdow gets a private runtime dir for its IPC socket.
export WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
export XDG_RUNTIME_DIR="$E2E_RT"

NIMDOW="$ROOT/bin/nimdow"
INPUT="$ROOT/bin/nimdowinput"
ST="$OUT/state.json"
JQDEFS='def M: .monitors[0]; def C: M.clients; def F: .focused;
  def n: [C[]] | length; def cnt(a): [C[] | select(.app_id == a)] | length;
  def app(a): [C[] | select(.app_id == a)][0];'

dump() {
  rm -f "$ST"
  "$NIMDOW" --dumpState "$ST" >/dev/null 2>&1
  local i
  for i in $(seq 1 40); do
    [ -s "$ST" ] && return 0
    sleep 0.05
  done
  return 1
}

# q <jq-expr>: prints the value from a fresh state dump.
q() { dump; jq -r "$JQDEFS $1" "$ST" 2>/dev/null; }

FAILED=0
DETAIL=""
# expect <description> <jq-boolean-expr>: polls the state for up to ~3s.
expect() {
  local desc="$1" expr="$2" i
  for i in $(seq 1 20); do
    if dump && jq -e "$JQDEFS $expr" "$ST" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.15
  done
  FAILED=1
  DETAIL="$DETAIL [$desc: $expr]"
  cp "$ST" "$OUT/fail-$CURRENT-$(date +%s%N).json" 2>/dev/null
  return 1
}

shot() { grim "$OUT/$1.png" 2>/dev/null; }
key() { "$INPUT" key "$1"; }
spawn() {  # spawn <class> <title> : a client outside of key bindings
  alacritty --class "$1" --title "$2" -e sleep 3600 >/dev/null 2>&1 &
}

CURRENT=""
begin() {
  CURRENT="$1"
  FAILED=0
  DETAIL=""
  echo "--- $1 (river log line $(wc -l < "$OUT/river-$PHASE.log"))"
  reset
}
finish() {
  echo "    done (river log line $(wc -l < "$OUT/river-$PHASE.log"))"
  if [ "$FAILED" = 0 ]; then
    echo "PASS $CURRENT: ok" >> "$RESULTS"
  else
    echo "FAIL $CURRENT:$DETAIL" >> "$RESULTS"
  fi
}

# Closes every test window, views tag 1 and re-enables the bar.
reset() {
  pkill -f 'alacritty --class [e]2e' 2>/dev/null
  expect "reset: no windows" '[.monitors[].clients[]] | length == 0' >/dev/null
  FAILED=0; DETAIL=""
  if [ "$(q '.monitors[0].selectedTags | tostring')" != "[1]" ]; then
    key super+1
    expect "reset: tag 1" 'M.selectedTags == [1]' >/dev/null
  fi
  if [ "$(q 'M.barVisible')" != "true" ]; then
    key super+b
    expect "reset: bar" 'M.barVisible' >/dev/null
  fi
  FAILED=0; DETAIL=""
}

# term <key>: spawns a window with a key binding and waits for it.
spawn_key() {  # spawn_key <key> <app_id> <expected count>
  key "$1"
  expect "spawn $2" "cnt(\"$2\") == $3 and F.app_id == \"$2\""
}

WIDTH=0; HEIGHT=0; BAR=0

center_of() {  # center_of <app_id> -> "x y" of the window's center
  q "app(\"$1\") | \"\(.x + .width / 2 | floor) \(.y + .height / 2 | floor)\""
}

run() {  # run <scenario function name>
  if [ -n "$ONLY" ] && ! [[ ",$ONLY," == *",${1#scenario_},"* ]]; then
    return
  fi
  "$1"
  finish
}

# ---------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------

scenario_spawn() {
  begin spawn
  spawn_key super+Return e2e-term 1
  expect "tiled on tag 1, visible, below the bar" \
    'F.tags == [1] and F.visible and (F.floating | not) and F.y >= M.barHeight and F.x >= 0'
  expect "fills the monitor (single window)" \
    "F.width + 2 * F.borderWidth <= $WIDTH and F.reportedWidth == F.width and F.reportedHeight == F.height"
  shot spawn
  spawn_key super+i e2e-browser 1
  spawn_key super+p e2e-launcher 1
  expect "three windows" 'n == 3'
  shot spawn-three
}

scenario_viewTags() {
  begin viewTags
  spawn_key super+Return e2e-term 1
  local n
  for n in 2 3 4 5 6 7 8 9; do
    key "super+$n"
    expect "view tag $n" "M.selectedTags == [$n]"
  done
  expect "window hidden away from tag 1" '(C[0].visible | not)'
  shot viewTags-9
  key super+1
  expect "back on tag 1" 'M.selectedTags == [1] and C[0].visible'
}

scenario_moveToTag() {
  begin moveToTag
  spawn_key super+Return e2e-term 1
  key super+shift+3
  expect "window moved to tag 3, hidden" 'C[0].tags == [3] and (C[0].visible | not) and M.selectedTags == [1]'
  key super+3
  expect "view tag 3 shows it" 'M.selectedTags == [3] and C[0].visible and F.app_id == "e2e-term"'
  key super+shift+5
  expect "moved on to tag 5" 'C[0].tags == [5] and (C[0].visible | not)'
  key super+5
  expect "tag 5" 'C[0].visible'
}

scenario_focus() {
  begin focus
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  spawn_key super+p e2e-launcher 1
  local start next prev
  start="$(q 'F.app_id')"
  key super+j
  expect "focusNext changes focus" "F.app_id != \"$start\""
  next="$(q 'F.app_id')"
  key super+j
  expect "focusNext again" "F.app_id != \"$next\" and F.app_id != \"$start\""
  key super+j
  expect "focusNext wraps around" "F.app_id == \"$start\""
  key super+k
  expect "focusPrevious" "F.app_id != \"$start\""
  prev="$(q 'F.app_id')"
  [ "$prev" = "$next" ] && : # (order is the stack order; only require a change and return)
  key super+j
  expect "back to start" "F.app_id == \"$start\""
  shot focus
}

scenario_masterCount() {
  begin masterCount
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  spawn_key super+p e2e-launcher 1
  local leftcol='([C[] | .x] | min) as $x | [C[] | select(.x == $x)] | length'
  expect "one master" "$leftcol == 1"
  key super+z
  expect "two masters share the left column" "$leftcol == 2"
  shot masterCount-2
  key super+x
  expect "one master again" "$leftcol == 1"
}

scenario_masterWidth() {
  begin masterWidth
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  local masterw
  masterw='([C[] | .x] | min) as $x | [C[] | select(.x == $x)][0].width'
  local w0
  w0="$(q "$masterw")"
  key super+l
  expect "wider master" "$masterw > $w0"
  local w1
  w1="$(q "$masterw")"
  key super+h
  key super+h
  expect "narrower master" "$masterw < $w1"
  shot masterWidth
  key super+l
  expect "restored" "$masterw == $w0"
}

scenario_floating() {
  begin floating
  spawn_key super+Return e2e-term 1
  key super+space
  expect "toggled to floating" 'F.floating'
  shot floating
  key super+space
  expect "toggled back to tiled" '(F.floating | not)'
}

scenario_fullscreen() {
  begin fullscreen
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  key super+f
  expect "fullscreen state" 'F.fullscreen'
  expect "client got the whole output" \
    "F.reportedWidth == $WIDTH and F.reportedHeight == $HEIGHT"
  expect "other windows hidden" '[C[] | select(.visible)] | length == 1'
  shot fullscreen
  key super+f
  expect "left fullscreen" '(F.fullscreen | not) and ([C[] | select(.visible)] | length == 2)'
}

scenario_close() {
  begin close
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  key super+shift+q
  expect "focused window closed" 'n == 1 and F.app_id == "e2e-term"'
  key super+shift+q
  expect "last window closed" 'n == 0 and F == null'
}

scenario_tagOps() {
  begin tagOps
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  key super+ctrl+2
  expect "toggleTagView adds tag 2 to the view" 'M.selectedTags == [1,2]'
  key super+ctrl+2
  expect "toggleTagView removes it again" 'M.selectedTags == [1]'
  key super+Right
  expect "goToRightTag" 'M.selectedTags == [2]'
  key super+Left
  expect "goToLeftTag" 'M.selectedTags == [1]'
  key super+Left
  expect "goToLeftTag wraps to the last tag" 'M.selectedTags == [9]'
  key super+Right
  expect "goToRightTag wraps to the first tag" 'M.selectedTags == [1]'
  key super+3
  expect "tag 3" 'M.selectedTags == [3]'
  key super+w
  expect "goToPreviousTag" 'M.selectedTags == [1]'
  key super+shift+Right
  expect "moveWindowToRightTag moves the focused window to tag 2" \
    'app("e2e-browser").tags == [2] and (app("e2e-browser").visible | not) and F.app_id == "e2e-term"'
  key super+shift+ctrl+3
  expect "toggleWindowTag adds tag 3" 'app("e2e-term").tags == [1,3]'
  key super+shift+ctrl+3
  expect "toggleWindowTag removes tag 3" 'app("e2e-term").tags == [1]'
  key super+shift+Left
  expect "moveWindowToLeftTag wraps to tag 9" 'app("e2e-term").tags == [9]'
  shot tagOps
}

scenario_order() {
  begin order
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  spawn_key super+p e2e-launcher 1
  local before after
  before="$(q '[C[].app_id] | join(",")')"
  key super+r
  after="$(q '[C[].app_id] | join(",")')"
  expect "rotateClients changes the stack order" "([C[].app_id] | join(\",\")) != \"$before\""
  key super+r
  key super+r
  expect "three rotations restore the order" "([C[].app_id] | join(\",\")) == \"$before\""
  local focused
  focused="$(q 'F.app_id')"
  key super+shift+j
  expect "moveWindowNext reorders the stack, focus stays" \
    "([C[].app_id] | join(\",\")) != \"$before\" and F.app_id == \"$focused\""
  key super+shift+k
  expect "moveWindowPrevious restores it" "([C[].app_id] | join(\",\")) == \"$before\""
}

scenario_reload() {
  begin reload
  spawn_key super+Return e2e-term 1
  key super+shift+r
  # Bindings are re-created: they must still work.
  key super+2
  expect "bindings work after reloadConfig" 'M.selectedTags == [2]'
  key super+1
  expect "tag 1" 'M.selectedTags == [1] and F.app_id == "e2e-term"'
}

scenario_typing() {
  begin typing
  local file="$OUT/typed.txt"
  rm -f "$file"
  alacritty --class e2e-type --title e2e-type -e sh -c "cat > '$file'" >/dev/null 2>&1 &
  expect "new window has the keyboard focus" 'F.app_id == "e2e-type"'
  sleep 1
  "$INPUT" type "Hello, World! 42"
  key Return
  key control+d
  local i ok=0
  for i in $(seq 1 20); do
    if [ "$(cat "$file" 2>/dev/null)" = "Hello, World! 42" ]; then ok=1; break; fi
    sleep 0.2
  done
  if [ "$ok" = 0 ]; then
    FAILED=1
    DETAIL="$DETAIL [typed text did not arrive: \"$(cat "$file" 2>/dev/null)\"]"
  fi
}

scenario_dragMove() {
  begin dragMove
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  local x0 y0 cx cy
  x0="$(q 'app("e2e-browser").x')"
  y0="$(q 'app("e2e-browser").y')"
  read -r cx cy <<<"$(center_of e2e-browser)"
  "$INPUT" drag super left "$cx" "$cy" $((cx - 60)) $((cy + 70))
  expect "dragged window floats and moved by the drag delta" \
    "app(\"e2e-browser\") | .floating and (.x - ($x0 - 60) | fabs) <= 3 and (.y - ($y0 + 70) | fabs) <= 3"
  shot dragMove
}

scenario_dragResize() {
  begin dragResize
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  local w0 h0 cx cy
  w0="$(q 'app("e2e-browser").width')"
  h0="$(q 'app("e2e-browser").height')"
  read -r cx cy <<<"$(center_of e2e-browser)"
  "$INPUT" drag super right "$cx" "$cy" $((cx - 40)) $((cy - 50))
  expect "resized by the drag delta (bottom-right edges)" \
    "app(\"e2e-browser\") | .floating and (.width - ($w0 - 40) | fabs) <= 3 and (.height - ($h0 - 50) | fabs) <= 3"
  shot dragResize
}

# Bar tag N center: tags are drawn left to right in 24px cells (default font).
bar_tag_x() { echo $((12 + 24 * ($1 - 1))); }

scenario_barClick() {
  begin barClick
  spawn_key super+Return e2e-term 1
  "$INPUT" move "$(bar_tag_x 4)" $((BAR / 2))
  "$INPUT" click left
  expect "bar click on tag 4 views it" 'M.selectedTags == [4]'
  "$INPUT" move "$(bar_tag_x 1)" $((BAR / 2))
  "$INPUT" click left
  expect "bar click on tag 1 views it" 'M.selectedTags == [1]'
  shot barClick
}

scenario_barScroll() {
  begin barScroll
  spawn_key super+Return e2e-term 1
  "$INPUT" move "$(bar_tag_x 4)" $((BAR / 2))
  "$INPUT" scroll down
  expect "scroll down views the next tag" 'M.selectedTags == [2]'
  "$INPUT" scroll down
  expect "scroll down again" 'M.selectedTags == [3]'
  "$INPUT" scroll up
  expect "scroll up views the previous tag" 'M.selectedTags == [2]'
}

scenario_clickFocus() {
  begin clickFocus
  spawn_key super+Return e2e-term 1
  spawn_key super+i e2e-browser 1
  local cx cy
  read -r cx cy <<<"$(center_of e2e-term)"
  "$INPUT" move "$cx" "$cy"
  "$INPUT" click left
  expect "click focuses the clicked tiled window" 'F.app_id == "e2e-term"'
  read -r cx cy <<<"$(center_of e2e-browser)"
  "$INPUT" move "$cx" "$cy"
  "$INPUT" click left
  expect "click focuses the other window" 'F.app_id == "e2e-browser"'
  shot clickFocus
}

scenario_appRules() {
  begin appRules
  spawn e2e-float e2e-float
  expect "class rule: floating at 100,100 sized 400x300" \
    'app("e2e-float") | .floating and .x == 100 and .y == 100 and .width == 400 and .height == 300'
  spawn e2e-plain e2e-titled
  expect "title rule: moved to tag 4" 'app("e2e-plain") | .tags == [4] and (.visible | not)'
  spawn e2e-center e2e-center
  expect "rule without position: floating and centered in the usable area" \
    "app(\"e2e-center\") | .floating and ((.x + (.width + 2 * .borderWidth) / 2) - $WIDTH / 2 | fabs) <= 2
       and ((.y + (.height + 2 * .borderWidth) / 2) - ($BAR + ($HEIGHT - $BAR) / 2) | fabs) <= 2
       and .y >= $BAR"
  # The title is set (OSC 0) shortly after the window was mapped: the title rule
  # still applies (see applyLateRules in windowmanager.nim).
  alacritty --class e2e-late -e sh -c "sleep 0.3; printf '\\033]0;e2e-late-title\\007'; sleep 3600" \
    >/dev/null 2>&1 &
  expect "late title rule: moved to tag 5" 'app("e2e-late") | .tags == [5]'
  shot appRules
  # Hidden windows are configured once viewed (and can be closed afterwards).
  key super+4
  expect "tag 4 shows the rule's window" 'M.selectedTags == [4] and app("e2e-plain").visible'
  key super+5
  expect "tag 5 shows the late-rule window" 'M.selectedTags == [5] and app("e2e-late").visible'
}

scenario_scratchpad() {
  begin scratchpad
  spawn_key super+Return e2e-term 1
  key super+shift+s
  expect "window hidden in the scratchpad" 'n == 0 and (.scratchpad | length) == 1'
  key super+s
  expect "popped: floating, inside the area below the bar, centered in it" \
    "F.app_id == \"e2e-term\" and F.floating and F.y >= $BAR
       and ((F.x + (F.width + 2 * F.borderWidth) / 2) - $WIDTH / 2 | fabs) <= 2
       and ((F.y + (F.height + 2 * F.borderWidth) / 2) - ($BAR + ($HEIGHT - $BAR) / 2) | fabs) <= 2"
  shot scratchpad
}

scenario_statusBar() {
  begin statusBar
  spawn_key super+Return e2e-term 1
  key super+b
  expect "bar hidden, window uses the whole output" "(M.barVisible | not) and F.y == 0"
  shot statusBar-hidden
  key super+b
  expect "bar back" "M.barVisible and F.y >= $BAR"
}

scenario_exitSession() {
  begin exitSession
  spawn_key super+Return e2e-term 1
  echo "PENDING exitSession" >> "$RESULTS"
  key control+alt+Delete
  sleep 5
}

# --- System tray (StatusNotifierItem) -------------------------------------
# Fixtures: tests/e2e/fake_sni.py on the private session bus.
FAKE="$ROOT/tests/e2e/fake_sni.py"
SNI_LOG="$OUT/sni-${E2E_PHASE:-single}.log"
TRAY_PIDS=()
tray_kill() {
  local p
  for p in "${TRAY_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  TRAY_PIDS=()
}
# tray_item <variant> <id>: starts a fake item; its pid is in LAST_PID.
tray_item() {
  python3 "$FAKE" item --variant "$1" --id "$2" --log "$SNI_LOG" >> "$OUT/fake-$2.out" 2>&1 &
  LAST_PID=$!
  TRAY_PIDS+=("$LAST_PID")
}
# tray_up: fresh fixtures (a named icon, then a pixmap icon), both shown.
tray_up() {
  tray_kill
  : > "$SNI_LOG"
  tray_item name fake-name; NAME_PID=$LAST_PID
  expect "first tray icon" '(M.tray | length) == 1'
  tray_item pixmap fake-pixmap; PIX_PID=$LAST_PID
  expect "both tray icons" '(M.tray | length) == 2'
}
tray_x() { q "[M.tray[] | select(.id == \"$1\")][0] | .x + (.width / 2 | floor)"; }
wait_log() {  # wait_log <pattern> <description>
  local i
  for i in $(seq 1 30); do
    grep -q -- "$1" "$SNI_LOG" 2>/dev/null && return 0
    sleep 0.15
  done
  FAILED=1
  DETAIL="$DETAIL [$2: no '$1' in sni.log]"
  return 1
}

scenario_trayIcons() {
  begin trayIcons
  tray_up
  expect "icons are real, active, inside the bar and do not overlap" \
    "M.barHeight as \$bh | all(M.tray[]; .hasIcon and .status == \"isActive\" and .width == (\$bh - 4) and .x >= 0) and (M.tray[1].x >= M.tray[0].x + M.tray[0].width + 4)"
  expect "named icon found through the theme chain, pixmap converted" \
    '(M.tray[0].icon | test("dialog-information")) and (M.tray[1].icon | startswith("pixmap:32x32"))'
  nimdow_status="tray status text"
  "$NIMDOW" --status "$nimdow_status" >/dev/null 2>&1
  sleep 0.5
  shot trayIcons
  "$NIMDOW" --status "" >/dev/null 2>&1
  tray_kill
}

scenario_trayClick() {
  begin trayClick
  tray_up
  local nx px y=$((BAR / 2))
  nx="$(tray_x fake-name)"; px="$(tray_x fake-pixmap)"
  "$INPUT" move "$nx" "$y"; "$INPUT" click left
  wait_log "fake-name Activate " "left click activates"
  "$INPUT" click middle
  wait_log "fake-name SecondaryActivate " "middle click"
  "$INPUT" click right
  wait_log "fake-name ContextMenu " "right click"
  "$INPUT" scroll down
  wait_log "fake-name Scroll 1 vertical" "scroll down"
  "$INPUT" scroll up
  wait_log "fake-name Scroll -1 vertical" "scroll up"
  "$INPUT" move "$px" "$y"; "$INPUT" click left
  wait_log "fake-pixmap Activate " "click on the second icon"
  # A click on a tray icon does not click a bar tag.
  expect "tags untouched" 'M.selectedTags == [1]'
  tray_kill
}

scenario_trayUpdate() {
  begin trayUpdate
  tray_up
  expect "initial icons" '(M.tray[0].icon | test("dialog-information")) and (M.tray[1].icon | test("pixmap:32x32:FF0000"))'
  kill -USR1 "$NAME_PID" "$PIX_PID"
  expect "NewIcon: named icon changed to the svg, pixmap to green|yellow" \
    '(M.tray[0].icon | test("audio-headphones.svg")) and (M.tray[1].icon | test("pixmap:32x32:00C800")) and all(M.tray[]; .hasIcon)'
  shot trayUpdate
  kill -USR2 "$PIX_PID"
  expect "Passive hides the item" '(M.tray | length) == 1 and M.tray[0].id == "fake-name"'
  kill -USR2 "$PIX_PID"
  expect "Active shows it again" '(M.tray | length) == 2'
  tray_kill
}

scenario_trayVanish() {
  begin trayVanish
  tray_up
  kill -9 "$NAME_PID"
  expect "icon removed when its owner disappears" '(M.tray | length) == 1 and M.tray[0].id == "fake-pixmap"'
  tray_kill
  expect "all icons gone" '(M.tray | length) == 0'
}

# nimdow starts with another watcher already on the bus (phase trayhost).
scenario_trayHostOnly() {
  begin trayHostOnly
  expect "item registered before nimdow started is shown (watcher's list)" \
    '(M.tray | length) >= 1 and M.tray[0].id == "fake-name" and M.tray[0].hasIcon'
  grep -q "another StatusNotifierWatcher exists" "$OUT/nimdow-$PHASE.log" || {
    FAILED=1; DETAIL="$DETAIL [nimdow did not report host-only mode]"; }
  wait_log "watcher RegisterStatusNotifierHost org.kde.StatusNotifierHost-" "nimdow registered its host"
  tray_item pixmap fake-pixmap; PIX_PID=$LAST_PID
  expect "item registered later (watcher signal) is shown" '(M.tray | length) == 2 and all(M.tray[]; .hasIcon)'
  [ "$(grep -c 'watcher RegisterStatusNotifierItem' "$SNI_LOG")" -ge 2 ] || {
    FAILED=1; DETAIL="$DETAIL [items were not registered with the other watcher]"; }
  shot trayHostOnly
  local nx
  nx="$(tray_x fake-name)"
  "$INPUT" move "$nx" $((BAR / 2)); "$INPUT" click left
  wait_log "fake-name Activate " "click in host-only mode"
  # The other watcher goes away: nimdow takes the name over and serves new items.
  kill "$WATCHER_PID"
  sleep 1
  tray_item name fake-late
  expect "a new item registers with nimdow's own watcher" '[M.tray[] | select(.id == "fake-late")] | length == 1'
  tray_kill
}

# Two outputs side by side (WLR_WL_OUTPUTS=2); output 1 is monitors[0].
scenario_multiMonitor() {
  begin multiMonitor
  local M2='.monitors[1]'
  expect "two monitors side by side, each with a bar" \
    "(.monitors | length) == 2 and M.area.x == 0 and $M2.area.x == M.area.width and M.barVisible and $M2.barVisible"
  expect "monitor 1 is selected first" 'M.selected'
  spawn_key super+Return e2e-term 1
  key super+period
  expect "focusNextMonitor selects monitor 2" "$M2.selected and (M.selected | not)"
  key super+i
  expect "new window opens on the selected monitor" \
    "($M2.clients | length) == 1 and $M2.clients[0].app_id == \"e2e-browser\" and $M2.clients[0].x >= $M2.area.x and (M.clients | length) == 1"
  shot multi-two
  key super+shift+comma
  expect "moveWindowToPreviousMonitor moves it to monitor 1 and selects it" \
    "($M2.clients | length) == 0 and (M.clients | length) == 2 and M.selected"
  shot multi-moved
  # The selected monitor follows the pointer.
  local w h
  w="$(q 'M.area.width')"; h="$(q 'M.area.height')"
  "$INPUT" move $((w + w / 2)) $((h / 2))
  expect "pointer on monitor 2 selects it" "$M2.selected"
  "$INPUT" move $((w / 2)) $((h / 2))
  expect "pointer back on monitor 1" "M.selected"
  # Drag a window onto the other monitor.
  local cx cy
  read -r cx cy <<<"$(center_of e2e-browser)"
  "$INPUT" drag super left "$cx" "$cy" $((w + w / 2)) $((h / 2))
  expect "dropped window belongs to monitor 2 and floats" \
    "($M2.clients | length) == 1 and $M2.clients[0].floating and $M2.clients[0].x >= $M2.area.x - 5 and (M.clients | length) == 1"
  shot multi-drag
  # Bar click on monitor 2 only changes monitor 2's tags.
  "$INPUT" move $((w + 12 + 24 * 2)) $((BAR / 2))
  "$INPUT" click left
  expect "bar click on monitor 2 views tag 3 there" "$M2.selectedTags == [3] and M.selectedTags == [1]"
  "$INPUT" move $((w + 12)) $((BAR / 2))
  "$INPUT" click left
  expect "back to tag 1 on monitor 2" "$M2.selectedTags == [1]"
}

# ---------------------------------------------------------------------------

PHASE="${E2E_PHASE:-single}"
if [ "$PHASE" = trayhost ]; then
  # Another StatusNotifierWatcher, and an item registered with it, before nimdow starts.
  : > "$SNI_LOG"
  python3 "$FAKE" watcher --log "$SNI_LOG" > "$OUT/fake-watcher.out" 2>&1 &
  WATCHER_PID=$!
  for i in $(seq 1 50); do grep -q READY "$OUT/fake-watcher.out" && break; sleep 0.1; done
  tray_item name fake-name
  for i in $(seq 1 50); do grep -q "watcher RegisterStatusNotifierItem" "$SNI_LOG" && break; sleep 0.1; done
fi
"$NIMDOW" --config "$ROOT/tests/e2e/config.toml" > "$OUT/nimdow-$PHASE.log" 2>&1 &
NIMDOW_PID=$!
EXPECTED_MONITORS=1
[ "$PHASE" = multi ] && EXPECTED_MONITORS=2
for i in $(seq 1 50); do
  dump && break
  sleep 0.2
done
if ! expect "nimdow started with $EXPECTED_MONITORS monitor(s)" "[.monitors[]] | length == $EXPECTED_MONITORS"; then
  echo "FAIL startup-$PHASE: nimdow did not come up: $DETAIL" >> "$RESULTS"
  exit 1
fi
WIDTH="$(q 'M.area.width')"
HEIGHT="$(q 'M.area.height')"
BAR="$(q 'M.barHeight')"
# Absolute pointer motion is mapped over the bounding box of all outputs.
export NIMDOWINPUT_EXTENT="$(q '"\([.monitors[] | .area.x + .area.width] | max)x\([.monitors[] | .area.y + .area.height] | max)"')"
echo "phase $PHASE: output ${WIDTH}x${HEIGHT}, bar $BAR, pointer extent $NIMDOWINPUT_EXTENT"
shot start

if [ "$PHASE" = multi ]; then
  run scenario_multiMonitor
elif [ "$PHASE" = trayhost ]; then
  run scenario_trayHostOnly
else
  for s in spawn viewTags moveToTag focus masterCount masterWidth floating fullscreen close \
           tagOps order reload typing dragMove dragResize barClick barScroll clickFocus \
           appRules scratchpad statusBar trayIcons trayClick trayUpdate trayVanish; do
    run "scenario_$s"
  done
  reset
  if [ -z "$ONLY" ] || [[ ",$ONLY," == *",exitSession,"* ]]; then
    scenario_exitSession
  fi
fi
tray_kill
[ -n "${WATCHER_PID:-}" ] && kill "$WATCHER_PID" 2>/dev/null
# Reached when exitSession did not run (or did not end the session).
"$NIMDOW" --exitSession >/dev/null 2>&1
sleep 2
kill "$NIMDOW_PID" 2>/dev/null
