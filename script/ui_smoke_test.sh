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

PROBE_TEXT="$(osascript <<'OSA'
on visibleText(e)
  tell application "System Events"
    set found to ""
    try
      repeat with c in UI elements of e
        try
          set r to role of c as text
          if r is "AXStaticText" or r is "AXTextField" or r is "AXButton" then
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
  tell process "AutoComp"
    set providerGroup to first group of first scroll area of group 2 of splitter group 1 of group 1 of window "Model"
    click first button of providerGroup
    repeat 30 times
      set textSnapshot to my visibleText(window "Model")
      if textSnapshot contains "Connected" then return textSnapshot
      delay 0.5
    end repeat
    return my visibleText(window "Model")
  end tell
end tell
OSA
)"

grep -q "Connected" <<<"$PROBE_TEXT"

echo "AutoComp UI smoke test passed"
