#!/bin/zsh
# Usage: probe.sh "<applescript body inside tell application Keynote>"
# Prints result and wall-clock ms.
s=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
r=$(osascript -e "tell application \"Keynote\"" -e "$1" -e "end tell" 2>&1)
e=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
echo "[$((e-s)) ms] $r"
