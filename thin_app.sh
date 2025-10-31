#!/bin/sh

thin_binary()
{
	local executable_path="$1"
	local parent_dir=$(/usr/bin/dirname "$executable_path")
	local executable_name=$(/usr/bin/basename "$executable_path")

	if test -d "$parent_dir"; then
		pushd "$parent_dir"
		
		echo "executable binary info before thinning:"
		echo "/usr/bin/file $executable_name"
		/usr/bin/file "$executable_name"
	
		echo "/usr/bin/lipo $executable_name -thin $one_arch -output $executable_name-$one_arch"
		/usr/bin/lipo "$executable_name" -thin "$one_arch" -output "$executable_name-$one_arch"
		lipo_result=$?
		if [ "$lipo_result" = 0 ]; then
			/bin/rm -f "$executable_name"
			/bin/mv -f "$executable_name-$one_arch" "$executable_name"
			echo "Check architecture after thinning:"
			echo "/usr/bin/file $executable_name"
			/usr/bin/file "$executable_name"
		else
			echo "lipo failed, is the executable binary fat?"
			echo "/usr/bin/file $executable_name"
			/usr/bin/file "$executable_name"
		fi
		popd
	else
		echo "error: directory does not exist: $parent_dir"
		return 1
	fi
	
	return 0
}

self_dir=$(/usr/bin/dirname "$0")

one_arch="$1"
if test -z "$one_arch"; then
	echo "usage: thin_app.sh <arch> <path/to/app>"
	exit 1
fi

app_to_thin="$2"
if test -z "$app_to_thin"; then
	echo "usage: thin_app.sh <arm64|x86_64> <path/to/app>"
	exit 1
fi

# full path
app_to_thin=$(/bin/realpath "$app_to_thin")

thin_binary "$app_to_thin/Contents/MacOS/OMCApplet"
thin_binary "$app_to_thin/Contents/Frameworks/Abracode.framework/Versions/A/Abracode"

abracode_support_dir="$app_to_thin/Contents/Frameworks/Abracode.framework/Versions/A/Support"
if test -d "$abracode_support_dir"; then
	pushd "$abracode_support_dir"
	all_tools=$(/bin/ls)
	popd
	
	while read -r one_tool; do
		thin_binary "$abracode_support_dir/$one_tool"
	done <<< "$all_tools"
else
	echo "error: Abracode.framework Support directory not found"
fi

