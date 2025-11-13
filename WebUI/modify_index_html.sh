#!/bin/sh

# modify default index.html to add theming or branding
# the modifications are described in 'webui-index.sed' command file

self_dir=$(/usr/bin/dirname "$0")
in_html_path="$1"

if [ -z "${in_html_path}" ]; then
    echo "error: a path to index.html to modify must be provided"
    exit 1
fi

using_temp_file=1
if [[ "${in_html_path}" == *.gz ]]; then
	gzipped_file_path="${in_html_path}"
	in_html_path="/tmp/index-original.html"

	echo "Uncompressing ${gzipped_file_path} to ${in_html_path}"

	/usr/bin/gzip -v -d -c "${gzipped_file_path}" > "${in_html_path}"
	using_temp_file=0
fi

sed_commands_path="${self_dir}/webui-index.sed"

if ! [ -f "${sed_commands_path}" ]; then
    echo "error: Cound not find ${sed_commands_path}"
    exit 1
fi

out_html_path="${self_dir}/index-modified.html"

echo "Modifying ${in_html_path} and saving to ${out_html_path}"

/usr/bin/sed -E -f "${sed_commands_path}" "${in_html_path}" > "${out_html_path}"

if [ ${using_temp_file} = 0 ]; then
	/bin/rm "${in_html_path}"
fi

# Verify replacements were done correctly
echo "Verifying all modifications"

replacement_found=0
# Read each line from the sed file and search in the HTML file
while IFS= read -r line; do
    # Extract the third field using cut
    replaced_string=$(echo "$line" | /usr/bin/cut -d '|' -f 3)

    if [ -n "${replaced_string}" ]; then
        /usr/bin/fgrep --count --quiet -e "${replaced_string}" "${out_html_path}"
        replacement_found=$?
        if [ $replacement_found != 0 ]; then
        	break
        fi
    fi
done < "${sed_commands_path}"

if [ $replacement_found != 0 ]; then
	echo "ERORR: some modifications could not be applied. Please review original index.html and patterns"
	exit 1
else
	echo "All modifications applied successfully"
	echo "Copy ${out_html_path} to app's Contents/Resources/WebUI/index.html"
fi

