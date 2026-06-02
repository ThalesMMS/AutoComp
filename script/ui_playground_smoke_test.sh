#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

./script/build_and_run.sh --ui-test-playground >/tmp/autocomp_playground_launch.log

osascript <<'OSA'
on appendAttribute(e, attributeName, currentText)
  tell application "System Events"
    try
      if attributeName is "name" then set attributeValue to name of e
      if attributeName is "value" then set attributeValue to value of e
      if attributeValue is not missing value then return currentText & (attributeValue as text) & linefeed
    end try
    return currentText
  end tell
end appendAttribute

on modelWindowText()
  tell application "System Events"
    try
      tell process "AutoComp"
        if not (exists window "Model") then return ""
        set found to ""
        tell scroll area 1 of group 2 of splitter group 1 of group 1 of window "Model"
          repeat with sectionGroup in groups
            repeat with e in UI elements of sectionGroup
              set found to my appendAttribute(e, "name", found)
              set found to my appendAttribute(e, "value", found)
            end repeat
          end repeat
        end tell
        return found
      end tell
    on error
      return ""
    end try
  end tell
end modelWindowText

on hasAllRequiredText(foundText)
  set requiredTexts to {"Prefix", "Fill in middle", "playground completion", "Latency"}
  repeat with targetText in requiredTexts
    if foundText does not contain (targetText as text) then return false
  end repeat
  return true
end hasAllRequiredText

on waitForPlaygroundSmoke()
  tell application "System Events"
    repeat 40 times
      if exists process "AutoComp" then
        set foundText to my modelWindowText()
        if my hasAllRequiredText(foundText) then return "Playground smoke ready"
      end if
      delay 0.5
    end repeat
    error "Playground completion did not appear"
  end tell
end waitForPlaygroundSmoke

tell application "System Events"
  my waitForPlaygroundSmoke()
end tell
OSA

echo "AutoComp playground smoke test passed"
