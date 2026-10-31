#!/bin/bash
# Generates the ipa_post_processor of the Telegram app (genrule //Ghostgram/Features/Vless:EmbedXrayCore).
#
#   make-embed-script.sh <output script> [<slice zip> ...]
#
# rules_apple runs a post-processor in the exec configuration with nothing but the tool itself, so the
# generated script is self-contained: it carries every built slice of GGXrayCore.framework (base64)
# and, when run on the unpacked archive, copies the slice that matches the app's platform into
# <App>.app/Frameworks. Signing runs after the post-processor and signs everything in Frameworks/.
# With no slices built the script does nothing, and the app reports that the VPN core is not bundled.

set -euo pipefail

output="$1"
shift

{
    cat <<'HEADER'
#!/bin/bash
set -euo pipefail
# rules_apple may start the post-processor with an empty environment (tree-artifact bundling).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin${PATH:+:$PATH}"
work="$1"
# Zipped bundling hands over the unpacked archive (Payload/<App>.app); tree-artifact bundling hands
# over the bundle's parent and names the bundle in TREE_ARTIFACT_OUTPUT.
app="${TREE_ARTIFACT_OUTPUT:-}"
if [ -z "$app" ] && [ -d "$work/Payload" ]; then
    app="$(find "$work/Payload" -maxdepth 1 -type d -name '*.app' | head -n 1)"
fi
if [ -z "$app" ]; then
    app="$(find "$work" -maxdepth 1 -type d -name '*.app' | head -n 1)"
fi
if [ -z "$app" ] || [ ! -f "$app/Info.plist" ]; then
    exit 0
fi
platform="$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$app/Info.plist" 2>/dev/null || echo iphoneos)"
case "$platform" in
    iphonesimulator) slice=ios_sim_arm64 ;;
    *) slice=ios_arm64 ;;
esac
begin="__GGXRAYCORE_${slice}_BEGIN__"
end="__GGXRAYCORE_${slice}_END__"
if ! grep -q "^${begin}\$" "$0"; then
    exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sed -n "/^${begin}\$/,/^${end}\$/p" "$0" | sed '1d;$d' | base64 -D > "$tmp/core.zip"
mkdir -p "$app/Frameworks"
rm -rf "$app/Frameworks/GGXrayCore.framework"
ditto -x -k "$tmp/core.zip" "$app/Frameworks"
exit 0
HEADER
    for archive in "$@"; do
        case "$archive" in
            *.framework.zip) ;;
            *) continue ;;
        esac
        slice="$(basename "$(dirname "$archive")")"
        echo "__GGXRAYCORE_${slice}_BEGIN__"
        base64 -b 76 -i "$archive"
        echo "__GGXRAYCORE_${slice}_END__"
    done
} > "$output"
chmod +x "$output"
