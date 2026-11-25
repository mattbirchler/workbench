#!/bin/zsh
# Captures the iPhone app's demo mode in the simulator for the App Store
# screenshots, in dark mode. Debug builds only: BENCH_OPEN_PROJECT,
# BENCH_OPEN_SCREEN and BENCH_SURFACE_SAMPLE jump straight to a screen.
# Then run compose.py.
#
#   capture.sh                                              iPhone 6.9"
#   SIM="iPad Pro 13-inch (M5)" PREFIX=ipad WAIT=9 capture.sh
#   SIM="iPhone Duo" PREFIX=duo DISPLAY_ID=1 WAIT=14 capture.sh
#
# The Duo's outer display is display 1. Its inner display (3) is black
# unless the device is opened in Device Hub first; simctl can't change poses.
# Boot one simulator at a time.
set -euo pipefail
cd "$(dirname "$0")/../.."
SIM=${SIM:-"Store iPhone 17 Pro Max"}
PREFIX=${PREFIX:-iphone}
WAIT=${WAIT:-6}
U=$(xcrun simctl list devices available -j | python3 -c "
import json,sys; d=json.load(sys.stdin)['devices']
print(next(x['udid'] for k,v in d.items() if 'iOS-27' in k for x in v if x['name']=='$SIM'))")
OUT=fastlane/screenshots/raw
DISPLAY_ARG=${DISPLAY_ID:+--display=$DISPLAY_ID}
mkdir -p $OUT

xcodegen generate -q
xcodebuild -project Bench.xcodeproj -scheme BenchPhone -configuration Debug \
    -destination "platform=iOS Simulator,id=$U" -derivedDataPath build/phonesim build -quiet
xcrun simctl boot $U 2>/dev/null || true
xcrun simctl bootstatus $U -b >/dev/null
xcrun simctl status_bar $U override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl install $U build/phonesim/Build/Products/Debug-iphonesimulator/Bench.app
xcrun simctl ui $U appearance dark

# name, seconds to wait, then NAME=value launch settings
cap() {
    local name=$1 wait=$2; shift 2
    xcrun simctl terminate $U me.birchtree.BenchPhone 2>/dev/null || true
    env SIMCTL_CHILD_BENCH_DEMO=1 ${@/#/SIMCTL_CHILD_} \
        xcrun simctl launch $U me.birchtree.BenchPhone -checklistExpanded YES >/dev/null
    sleep $wait
    xcrun simctl io $U screenshot ${=DISPLAY_ARG} $OUT/$PREFIX-$name.png >/dev/null 2>&1
    echo $OUT/$PREFIX-$name.png
}
cap list $WAIT
cap permission $WAIT BENCH_OPEN_PROJECT=Website
cap working $WAIT BENCH_OPEN_PROJECT=Recipes
cap agent $WAIT BENCH_OPEN_PROJECT=dark-mode
cap changes $((WAIT + 2)) BENCH_OPEN_PROJECT=dark-mode BENCH_OPEN_SCREEN=changes
cap widgets $WAIT BENCH_SURFACE_SAMPLE=widgets

xcrun simctl terminate $U me.birchtree.BenchPhone || true
xcrun simctl ui $U appearance light
xcrun simctl status_bar $U clear
