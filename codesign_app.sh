#!/bin/sh

self_dir=$(/usr/bin/dirname "$0")
app_to_sign="$1"
identity="$2"

if test -z "$app_to_sign"; then
    echo "error: a path to app must be provided"
    exit 1
fi

# full path
app_to_sign=$(/bin/realpath "$app_to_sign")
app_id=$(/usr/bin/defaults read "$app_to_sign/Contents/Info.plist" CFBundleIdentifier)
if test "$?" != "0"; then
    echo "error: could not obtain bundle identifier for app at: $app_to_sign"
    exit 1
fi

entitlements_path="$self_dir/OMCApplet.entitlements"

if test -z "$identity"; then
    identity="-"
    entitlements=""
    timestamp="--timestamp=none"
    options=""
else
    entitlements="--entitlements \"$entitlements_path\""
    timestamp="--timestamp"
    options="--options runtime"
fi

if test -d "$app_to_sign/Contents/Support/Llama.cpp"; then
    pushd "$app_to_sign/Contents/Support/Llama.cpp"
    echo "/usr/bin/codesign --verbose --force $options $timestamp --sign $identity '*'"
    /usr/bin/codesign --verbose --force $options $timestamp --sign "$identity" *
    popd
fi

echo "/usr/bin/codesign --deep --verbose --force $options $entitlements $timestamp --identifier $app_id --sign $identity $app_to_sign"
/usr/bin/codesign --deep --verbose --force $options $entitlements $timestamp --identifier "$app_id" --sign "$identity" "$app_to_sign"

echo ""
echo "Verifying codesigned app:"
echo "-------------------------"
/usr/bin/codesign -dv --verbose=4 "$app_to_sign"
echo "-------------------------"
