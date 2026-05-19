#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/build_and_run.sh --ui-test-settings >/tmp/autocomp_ui_launch.log

MODEL_TEXT="$(osascript <<'OSA'
on visibleText(e)
  tell application "System Events"
    set found to ""
    try
      repeat with c in UI elements of e
        try
          set r to role of c as text
          if r is "AXStaticText" or r is "AXTextField" then
            try
              set v to value of c
              if v is not missing value then set found to found & (v as text) & linefeed
            end try
            try
              set n to name of c
              if n is not missing value then set found to found & (n as text) & linefeed
            end try
          end if
        end try
        set found to found & my visibleText(c)
      end repeat
    end try
    return found
  end tell
end visibleText

tell application "System Events"
  repeat 20 times
    if exists process "AutoComp" then
      tell process "AutoComp"
        if exists window "Model" then return my visibleText(window "Model")
      end tell
    end if
    delay 0.25
  end repeat
  error "AutoComp Model window did not appear"
end tell
OSA
)"

grep -q "Remote backend" <<<"$MODEL_TEXT"
grep -q "http://100.98.1.45:8000" <<<"$MODEL_TEXT"
grep -q "Qwen/Qwen3.6-35B-A3B" <<<"$MODEL_TEXT"

osascript <<'OSA'
tell application "TextEdit"
  activate
  make new document
end tell
delay 0.5
tell application "System Events"
  tell process "TextEdit"
    set frontmost to true
    keystroke "I think"
  end tell
end tell
delay 3
tell application "TextEdit"
  close front document saving no
end tell
OSA

/usr/bin/log show --last 20s --predicate 'process == "AutoComp" AND eventMessage CONTAINS "received response, status 200"' --style compact | grep -q 'status 200'

echo "AutoComp UI smoke test passed"
