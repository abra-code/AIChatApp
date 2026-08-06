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

thin_executables_in_dir()
{
	local dir="$1"

	if test ! -d "$dir"; then
		return
	fi

	echo ""
	echo "Searching for executables in: $dir"
	echo "-----------------------------------"

	local exec_files=$(/usr/bin/find "$dir" -type f -perm +111 -print | /usr/bin/sort)

	if test -z "$exec_files"; then
		echo "No executables found"
		echo "-----------------------------------"
		return
	fi

	local exec_file
	echo "$exec_files" | while IFS= read -r exec_file; do
		file_type=$(/usr/bin/file -b "$exec_file")
		echo "$file_type" | /usr/bin/grep -qE "Mach-O"
		if test "$?" = "0"; then
			thin_binary "$exec_file"
		fi
	done

	echo "-----------------------------------"
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

thin_executables_in_dir "$app_to_thin/Contents/MacOS"

if test -d "$app_to_thin/Contents/Helpers"; then
	thin_executables_in_dir "$app_to_thin/Contents/Helpers"
fi

if test -d "$app_to_thin/Contents/Library"; then
	thin_executables_in_dir "$app_to_thin/Contents/Library"
fi

if test -d "$app_to_thin/Contents/Support"; then
	thin_executables_in_dir "$app_to_thin/Contents/Support"
fi

if test -d "$app_to_thin/Contents/Frameworks"; then
	for fw in "$app_to_thin/Contents/Frameworks"/*.framework; do
		test -d "$fw" || continue
		thin_executables_in_dir "$fw/Versions/Current/Support"
	done

	echo ""
	echo "Thinning framework binaries in: $app_to_thin/Contents/Frameworks"
	echo "-----------------------------------"
	for fw in "$app_to_thin/Contents/Frameworks"/*.framework; do
		test -d "$fw" || continue
		fw_name=$(/usr/bin/basename "$fw" .framework)
		fw_binary="$fw/Versions/Current/$fw_name"
		if test -f "$fw_binary"; then
			echo "Thinning framework binary: $fw_name"
			thin_binary "$fw_binary"
		fi
	done
	echo "-----------------------------------"
fi

