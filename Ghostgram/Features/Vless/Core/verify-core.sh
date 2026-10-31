#!/bin/bash
# Checks a built app that the VLESS core can not start the Go runtime unless the VPN is switched on:
#   1. GGXrayCore.framework is in Frameworks/ and exports the bridge;
#   2. no binary of the app (main executable, frameworks, extensions) has a load command for it;
#   3. no binary other than the core carries Go runtime or bridge symbols (nothing linked it statically).
# If all three hold, the only way the runtime gets into the process is GGVless's dlopen.
#
#   Ghostgram/Features/Vless/Core/verify-core.sh bazel-bin/Telegram/Telegram.ipa
#   Ghostgram/Features/Vless/Core/verify-core.sh path/to/Telegram.app

set -euo pipefail

input="${1:?usage: verify-core.sh <Telegram.ipa | Telegram.app>}"
if [ -d "$input" ]; then
    app="$input"
else
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    unzip -q "$input" -d "$tmp"
    app="$(find "$tmp/Payload" -maxdepth 1 -type d -name '*.app' | head -n 1)"
fi
core="$app/Frameworks/GGXrayCore.framework/GGXrayCore"
status=0

if [ -f "$core" ]; then
    if xcrun nm -gU "$core" | grep -q ' _ggxc_start$'; then
        echo "ok: GGXrayCore.framework is bundled and exports the bridge"
    else
        echo "FAIL: GGXrayCore does not export _ggxc_start"; status=1
    fi
else
    echo "note: GGXrayCore.framework is not bundled (build-core.sh was not run); the VPN screen will say so"
fi

while IFS= read -r -d '' binary; do
    if [ "$binary" = "$core" ]; then
        continue
    fi
    if ! file "$binary" | grep -q 'Mach-O'; then
        continue
    fi
    if xcrun otool -L "$binary" | grep -q 'GGXrayCore'; then
        echo "FAIL: $binary links GGXrayCore (the runtime would start at launch)"; status=1
    fi
    if xcrun nm -a "$binary" 2>/dev/null | grep -Eq ' (_ggxc_start|_x_cgo_init|_runtime\.sysmon)$'; then
        echo "FAIL: $binary contains Go runtime or bridge symbols"; status=1
    fi
done < <(find "$app" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)

if [ "$status" -eq 0 ]; then
    echo "ok: nothing links the core; the Go runtime starts only when the VPN is switched on"
fi
exit "$status"
