#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/build_and_run.sh --ui-test-playground >/tmp/autocomp_playground_launch.log

PLAYGROUND_TEXT="$(osascript <<'OSA'
on visibleText(e)
  tell application "System Events"
    set found to ""
    try
      repeat with c in UI elements of e
        try
          set r to role of c as text
          if r is "AXStaticText" or r is "AXTextField" or r is "AXTextArea" or r is "AXButton" then
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
  repeat 40 times
    if exists process "AutoComp" then
      tell process "AutoComp"
        if exists window "Model" then
          set textSnapshot to my visibleText(window "Model")
          if textSnapshot contains "playground completion" then return textSnapshot
        end if
      end tell
    end if
    delay 0.25
  end repeat
  error "Playground completion did not appear"
end tell
OSA
)"

grep -q "Prefix" <<<"$PLAYGROUND_TEXT"
grep -q "Fill in middle" <<<"$PLAYGROUND_TEXT"
grep -q "playground completion" <<<"$PLAYGROUND_TEXT"
grep -q "Latency" <<<"$PLAYGROUND_TEXT"

echo "AutoComp playground smoke test passed"
