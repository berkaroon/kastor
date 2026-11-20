#!/bin/bash
set -euo pipefail

app=${1:?Usage: scripts/security-gate.sh path/to/Kastor.app}
root=$(cd "$(dirname "$0")/.." && pwd)
claims=$(mktemp)
trap 'rm -f "$claims"' EXIT

/usr/bin/codesign --verify --deep --strict "$app"
signature=$(/usr/bin/codesign -dv "$app" 2>&1)
if [[ $signature != *flags=*runtime* ]]; then
    echo 'Expected Hardened Runtime.' >&2
    exit 1
fi
/usr/bin/codesign -d --xml --entitlements "$claims" "$app"
if [[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$claims") != true ]]; then
    echo 'Expected App Sandbox.' >&2
    exit 1
fi
if [[ $(/usr/libexec/PlistBuddy -c 'Print' "$claims" | /usr/bin/grep -c ' = ') != 1 ]]; then
    echo 'Unexpected entitlements.' >&2
    exit 1
fi
if [[ $(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$app/Contents/Info.plist") != true ]]; then
    echo 'Expected a menu bar agent.' >&2
    exit 1
fi
version=$(/usr/bin/sed -nE 's/^[[:space:]]*exactVersion: ([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$root/project.yml")
if [[ -z $version ]]; then
    echo 'Expected exactVersion in project.yml.' >&2
    exit 1
fi
lock="$root/Kastor.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if [[ $(/usr/bin/grep -c '"identity"' "$lock") != 1 ]]; then
    echo 'Expected exactly one pinned Swift package in Package.resolved.' >&2
    exit 1
fi
if ! /usr/bin/grep -Eq '"identity"[[:space:]]*:[[:space:]]*"keyboardshortcuts"' "$lock"; then
    echo 'Expected keyboardshortcuts package in Package.resolved.' >&2
    exit 1
fi
locked_version=$(/usr/bin/sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*$/\1/p' "$lock")
if [[ $locked_version != "$version" ]]; then
    echo "Expected KeyboardShortcuts version $version in Package.resolved, got ${locked_version:-none}." >&2
    exit 1
fi
if /usr/bin/grep -REn '(URLSession|NWConnection|CGEventPost|AXIsProcessTrusted|print\(|os_log\()' "$root/Kastor" --include='*.swift'; then
    echo 'Review unexpected network, event injection or logging APIs.' >&2
    exit 1
fi
echo 'Security gate passed (signature, runtime, sandbox, dependency and source checks).'
