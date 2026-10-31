#!/bin/bash
# Builds GGXrayCore.framework — the VLESS core of «VPN по подписке» — as a DYNAMIC framework that
# the app never links against: GGVless opens it with dlopen when the user switches the VPN on, so
# the Go runtime inside it does not start for anyone else.
#
#   Ghostgram/Features/Vless/Core/build-core.sh              # device slice
#   Ghostgram/Features/Vless/Core/build-core.sh --simulator  # device + simulator slices
#   Ghostgram/Features/Vless/Core/build-core.sh --force      # rebuild even if up to date
#
# Outputs (gitignored): build/<slice>/GGXrayCore.framework.zip, slice = ios_arm64 | ios_sim_arm64.
# The Bazel post-processor //Ghostgram/Features/Vless:EmbedXrayCore copies the matching slice into
# Telegram.app/Frameworks before signing. Without the outputs the app builds and the VPN screen
# says that the core is not bundled.
#
# Needs: Go >= 1.26 and Xcode command line tools. The first run needs network access once to fetch
# github.com/xtls/xray-core into the Go module cache and to write go/go.sum (commit it).

set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
readonly GO_DIR="$HERE/go"
readonly OUT_ROOT="$HERE/build"
readonly NAME="GGXrayCore"
readonly MIN_IOS="15.0"
readonly BUNDLE_ID="org.ghostgram.app.GGXrayCore"

# Temporary directories of every slice, removed however the script ends.
WORK_DIRS=()
cleanup() {
    if [ "${#WORK_DIRS[@]}" -gt 0 ]; then
        rm -rf "${WORK_DIRS[@]}"
    fi
}
trap cleanup EXIT

simulator=0
force=0
for argument in "$@"; do
    case "$argument" in
        --simulator) simulator=1 ;;
        --force) force=1 ;;
        -h|--help) sed -n '2,18p' "$SELF"; exit 0 ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

command -v go >/dev/null || { echo "error: go is not installed" >&2; exit 1; }
command -v xcrun >/dev/null || { echo "error: xcrun is not available" >&2; exit 1; }
go_version="$(go env GOVERSION | sed -e 's/^go//')"
go_major="${go_version%%.*}"
go_minor="$(echo "$go_version" | cut -d. -f2)"
if [ "$go_major" -lt 1 ] || { [ "$go_major" -eq 1 ] && [ "$go_minor" -lt 26 ]; }; then
    echo "error: Go 1.26 or newer is required (found $go_version)" >&2
    exit 1
fi

cd "$GO_DIR"
if [ ! -f go.sum ]; then
    echo "go.sum is missing: resolving modules (network access needed once)"
    go mod tidy
fi

# Fingerprint of everything that defines the output; a second run with nothing changed is a no-op.
fingerprint() {
    {
        cat "$GO_DIR/go.mod" "$GO_DIR/go.sum" "$GO_DIR"/*.go "$SELF"
        echo "$go_version"
        xcrun --sdk "$1" --show-sdk-version
    } | shasum -a 256 | cut -d' ' -f1
}

build_slice() {
    local slice="$1" sdk="$2" target="$3"
    local out="$OUT_ROOT/$slice"
    local stamp="$out/.fingerprint"
    local current
    current="$(fingerprint "$sdk")"
    if [ "$force" -eq 0 ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$current" ] && [ -f "$out/$NAME.framework.zip" ]; then
        echo "$slice: up to date"
        return
    fi

    local sdk_path work framework
    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    work="$(mktemp -d)"
    WORK_DIRS+=("$work")
    framework="$work/$NAME.framework"
    mkdir -p "$framework" "$out"

    echo "$slice: building the Go archive"
    CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
    CC="$(xcrun --sdk "$sdk" --find clang)" \
    CGO_CFLAGS="-isysroot $sdk_path -target $target" \
    CGO_LDFLAGS="-isysroot $sdk_path -target $target" \
        go build -buildmode=c-archive -trimpath -tags ios \
            -ldflags="-s -w -buildid=" \
            -o "$work/lib$NAME.a" .

    echo "$slice: linking $NAME.framework"
    printf '_ggxc_version\n_ggxc_free\n_ggxc_last_error\n_ggxc_test\n_ggxc_start\n_ggxc_stop\n_ggxc_is_running\n_ggxc_uplink\n_ggxc_downlink\n' > "$work/exports.txt"
    xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sdk_path" -dynamiclib \
        -Wl,-all_load "$work/lib$NAME.a" \
        -Wl,-exported_symbols_list,"$work/exports.txt" \
        -framework CoreFoundation -framework Security -lresolv \
        -install_name "@rpath/$NAME.framework/$NAME" \
        -o "$framework/$NAME"

    local platform="iPhoneOS"
    if [ "$sdk" = "iphonesimulator" ]; then
        platform="iPhoneSimulator"
    fi
    cat > "$framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$NAME</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>$platform</string>
    </array>
    <key>MinimumOSVersion</key>
    <string>$MIN_IOS</string>
</dict>
</plist>
PLIST

    # Exactly the bridge's functions are exported, and nothing outside the framework may need it.
    local exported
    exported="$(xcrun nm -gU "$framework/$NAME" | awk '{print $3}' | grep '^_ggxc_' | sort | tr '\n' ' ')"
    for symbol in $(sort "$work/exports.txt"); do
        case " $exported " in
            *" $symbol "*) ;;
            *) echo "error: $symbol is not exported by $NAME" >&2; exit 1 ;;
        esac
    done

    rm -f "$out/$NAME.framework.zip"
    (cd "$work" && ditto -c -k --sequesterRsrc --keepParent "$NAME.framework" "$out/$NAME.framework.zip")
    echo "$current" > "$stamp"
    echo "$slice: $(du -h "$out/$NAME.framework.zip" | cut -f1) -> $out/$NAME.framework.zip"
}

build_slice ios_arm64 iphoneos "arm64-apple-ios$MIN_IOS"
if [ "$simulator" -eq 1 ]; then
    build_slice ios_sim_arm64 iphonesimulator "arm64-apple-ios$MIN_IOS-simulator"
fi
