#!/usr/bin/env bash
set -euo pipefail

#
#    Copyright (C) 2024 ysfchn / Yusuf Cihan
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published
#    by the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program. If not, see <http://www.gnu.org/licenses/>.
#

WORK_FOLDER="${WORK_FOLDER:-}"
FORCE_CLI="${FORCE_CLI:-}"


# Previous releases of ADK don't have their version name in the links, so we manually map 
# the display names of links with their corresponding ADK version separated with "|" character.
# https://learn.microsoft.com/en-us/mem/configmgr/core/plan-design/configs/support-for-windows-adk#windows-adk-versions
VERSION_MAPPINGS="
Windows 11 22H2|10.1.22621.1
Windows 11|10.1.22000.1
Windows Server 2022|10.1.20348.1
Windows 10 2004|10.1.19041.1
Windows 10 1903|10.1.18362.1
Windows 10 1809|10.1.17763.1
Windows 10 1803|10.1.17134.1
Windows 10 1709|10.1.16299.15
Windows 10 1703|10.1.15063.0
Windows 10 1607|10.1.14393.0
"


# Obtains a list of ADK downloads & creates a TSV output.
# ADK downloads are listed in below URL, unfortunately I haven't come across to a machine-readable 
# format, so we parse the HTML here to capture the links on the page & re-format link names to
# match with other links.
# https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install
get_adk_downloads() {
    resolve_links="${1:-1}"
    version_mapping_pattern="$(echo "${VERSION_MAPPINGS}" | sed -r "s/(.*)\|(.*)/s\/(for \1)$\/\\\\1\\\\t\2\/g/g")"
    echo "Obtaining a list of ADK downloads..." >&2
    page="$(curl -sS "https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install" || echo "")"
    if [ -z "${page}" ]
    then
        echo "Couldn't connect to the internet!" >&2
        exit 1
    fi
    adk_list="$(echo "${page}" \
        | grep -oP "https://go\.microsoft\.com/fwlink/p?/?\?[lL]ink[Ii]d=([0-9]+)\" data-linktype=\"external\">(.*?)</a>" \
        | sed -rn "s/(.*?)=([0-9]+)\" data-linktype=\"external\">(.*?)<\/a>/\1=\2\t\2\t\3/p" \
        | sed -r "s/(.*?)\tDownload the Windows (.*?)$/\1\t\2/g; s/(.*?)\t(.*?)Windows (PE|ADK) (.*?)$/\1\t\2\3 \4/g" \
        | sed -rn "s/(.*?)\t(PE|ADK)(.*?)$/\1\t\2\3/p" \
        | sed -r "s/, version / /g; s/for ADK/for the ADK/g; s/(for the ADK )([0-9]+)$/\1for Windows 10 \2/g" \
        | sed -r "s/(.*?)\t(.*?)ADK ([0-9.]+)( .*?)/\1\t\2ADK \3\4\t\3/g" \
        | sed -r "${version_mapping_pattern}"
    )"
    if [ "${resolve_links}" = "1" ]
    then
        # Visit all Microsoft redirect links and output the target path of the URLs.
        links_file="$(mktemp --suffix "_adk_links")"
        get_redirect_link "$(echo "${adk_list}" | sed -rn "s/([^\t]+)\t.*/\1/p")" > "${links_file}"
        paste -d "\t" "${links_file}" - < <(echo "${adk_list}" | sed -r "s/^([^\t]+)\t//g")
        rm -f "${links_file}"
    else
        echo "${adk_list}"
    fi
}


# Checks for required dependencies and fails if missing.
check_dependencies() {
    missing=""
    if [ -z "$(command -v xmlstarlet)" ]; then
        missing+=", xmlstarlet"
    elif [ -z "$(command -v zenity)" ] && [ "$(is_tty)" = "0" ]; then
        missing+=", zenity"
    elif [ -z "$(command -v aria2c)" ]; then
        missing+=", aria2c"
    elif [ -z "$(command -v 7z)" ]; then
        missing+=", 7z"
    fi
    if [ -n "${missing}" ]
    then
        echo "Missing dependencies was detected! Exiting..." >&2
        echo "Required packages: ${missing}" >&2
        exit 1
    fi
}


# Checks if WORK_FOLDER is set & is a valid directory, otherwise prompt selecting
# an directory to set as a WORK_FOLDER throughout the script.
verify_work_folder() {
    if [ -z "${WORK_FOLDER}" ] || [ ! -d "${WORK_FOLDER}" ]
    then
        echo "Work directory is not set or not a directory!" >&2
        if [ "$(is_tty)" = "0" ]
        then
            echo "Picking a folder to use as a work directory..." >&2
            folder="$(zenity --file-selection --directory --title "Pick or create a new directory for working folder" || echo "")"
            if [ -z "${folder}" ] || [ ! -d "${folder}" ]
            then
                echo "Operation was cancelled!" >&2
                exit 1
            fi
            WORK_FOLDER="${folder}"
        else
            echo "Set the work directory with WORK_FOLDER variable!" >&2
            exit 1
        fi
    fi
    echo "Work directory: ${WORK_FOLDER}" >&2
}


# Follows the given Microsoft redirection link(s) and returns their final redirect path line by line.
# If the redirect path returns a Bing domain, then it means that we hit an non-existing 
# "go.microsoft.com" link, so we fail here.
get_redirect_link() {
    links="$@"
    while IFS= read -r line; do {
        if [[ "${line}" == *"www.bing.com"* ]]
        then
            echo "Couldn't retrieve the link: ${line}. Exiting!" >&2
            exit 1
        else
            echo "${line}"
        fi
    }; done < <(echo "${links}" | xargs curl -I -LSsq -o /dev/null -w "%{url_effective}\n" -H "User-Agent: Burn" | grep -oP "^https://.*")
}


# Extracts the given adksetup.exe file to a temporary directory and gets the version of ADK
# from setup file and prints it. Finally, clears the created temporary directory.
# TODO: Unused
get_adk_version_from_exe() {
    installer_file="${1}"
    temp_folder="$(mktemp -d --suffix "_adk_setup")"
    7z x -y -aoa -tCAB -bb0 -bso0 -bse1 -bsp1 -o"${temp_folder}" "${installer_file}"

    # Read the XML Burn manifest and get a list of embedded payload files.
    # Then, for each file, move it from the source to their expected location.
    while IFS= read -r line; do {
        ifile="$(echo "${line}" | cut -d "|" -f 1 | tr "\\\\" "/")"
        ofile="$(echo "${line}" | cut -d "|" -f 2 | tr "\\\\" "/")"
        mkdir --parents "$(dirname "${temp_folder}/${ofile}")" >&2
        mv --force --no-target-directory "${temp_folder}/${ifile}" "${temp_folder}/${ofile}"
    }; done < <(
        cat "${temp_folder}/0" | xmlstarlet sel -N "x=http://schemas.microsoft.com/wix/2008/Burn" \
        --no-doc-namespace --template --match "./x:BurnManifest/x:UX/x:Payload[@Packaging='embedded']" \
        --value-of "./@SourcePath" --output "|" --value-of "./@FilePath" --nl
    )

    # Product version is found in the "UserExperienceManifest.xml" file.
    cat "${temp_folder}/UserExperienceManifest.xml" | xmlstarlet sel -N "x=http://schemas.microsoft.com/Setup/2010/01/Burn/UserExperience" \
        --no-doc-namespace --template --value-of "./x:UserExperienceManifest/x:Settings/x:ProductVersion" --nl
    rm -rf "${temp_folder}"
}


is_tty() {
    if [ "${XDG_SESSION_TYPE}" = "tty" ]; then
        echo "1"
    elif [ -n "${FORCE_CLI}" ]; then
        echo "1"
    else
        echo "0"
    fi
}


# Extracts a WiX packaged executable installer file, rearranges the files and creates
# an ARIA2 formatted file in given path to download the online files from Microsoft in bulk,
# so we don't need to rely on running the setup executable on a Windows machine.
extract_burn_bundle() {
    extracted_folder="${1}"
    aria2_file="${2}"
    download_root="${3:-}"
    previous_features="${4:-}"

    if [ ! -d "${extracted_folder}" ]; then
        echo "Given path '${extracted_folder}' is not a directory!" >&2
        exit 1
    fi

    if [ ! -f "${extracted_folder}/0" ]; then
        echo "Given path '${extracted_folder}' doesn't contain the extracted setup files!" >&2
        exit 1
    fi

    touch "${aria2_file}"

    if [ ! -f "${aria2_file}" ]; then
        echo "Given path '${aria2_file}' must be an file!" >&2
        exit 1
    fi

    # Read the XML Burn manifest and get a list of embedded payload files.
    # Then, for each file, move it from the source to their expected location.
    echo "Moving files..." >&2
    while IFS= read -r line; do {
        ifile="$(echo "${line}" | cut -d "|" -f 1 | tr "\\\\" "/")"
        ofile="$(echo "${line}" | cut -d "|" -f 2 | tr "\\\\" "/")"
        if [ -f "${extracted_folder}/${ifile}" ]
        then
            mkdir --parents --verbose "$(dirname "${extracted_folder}/${ofile}")" >&2
            mv --force --no-target-directory "${extracted_folder}/${ifile}" "${extracted_folder}/${ofile}" >&2
            echo "${ifile} -> ${ofile}" >&2
        else
            if [ ! -f "${extracted_folder}/${ofile}" ]
            then
                echo "Cannot locate ${ifile}!" >&2
                exit 1
            fi
        fi
    }; done < <(
        cat "${extracted_folder}/0" | xmlstarlet sel -N "x=http://schemas.microsoft.com/wix/2008/Burn" \
        --no-doc-namespace --template --match "./x:BurnManifest/x:UX/x:Payload[@Packaging='embedded']" \
        --value-of "./@SourcePath" --output "|" --value-of "./@FilePath" --nl
    )

    # Get a list of configuration options along with their dependencies of the setup.
    echo "Listing features..." >&2
    features="$(cat "${extracted_folder}/UserExperienceManifest.xml" | xmlstarlet sel -N "x=http://schemas.microsoft.com/Setup/2010/01/Burn/UserExperience" \
        --no-doc-namespace --template --match "./x:UserExperienceManifest/x:Options/x:Option" \
        --output "|" --value-of "./@Id" --output ":" --value-of "./x:Dependencies/x:Dependency/@Id" \
        | tr "\n" "," | tr "|" "\n" | sed "s/OptionId\.//g" | sed -rn "s/^(.+)/\1/p")"

    if [ "$(is_tty)" = "1" ] && [ -z "${previous_features}" ]
    then
        echo "${features}"
        exit 0
    fi

    # Prompt selecting the features. Then for each picked feature, remove duplicates
    # and format the selected items to separate with a new line.
    columns=""
    while IFS="" read -r line || [ -n "$line" ]
    do
        if [ -z "${line}" ]; then continue; fi
        id="$(echo "${line}" | cut -d ":" -f 1)"
        dependencies="$(echo "${line}" | cut -d ":" -f 2)"
        picked="FALSE"
        if [[ "${previous_features}" == *"${id}"* ]]; then
            picked="TRUE"
        fi
        columns+=" \"${picked}\" \"${id}\" \"${dependencies}\""
    done <<< "${features}"

    if [ "$(is_tty)" = "0" ]
    then
        features_pick="$(echo "${columns}" | xargs zenity \
            --list --checklist --title "adk-downloader" --width 800 --height 600 \
            --text "Choose features to download. Dependencies will be automatically included." --print-column "ALL" --separator "," \
            --column "" --column "Feature" --column "Depends on" || echo "CANCEL")"

        if [ "${features_pick}" = "CANCEL" ]
        then
            echo "Operation was cancelled." >&2
            exit 1
        fi
    else
        features_pick="${previous_features}"
    fi

    features_list="$(printf "${features_pick}" | tr "," "\n" | sort -u | sed -rn "s/(.+)/OptionId\.\1/p")"

    if [ "$(is_tty)" = "0" ] && [ -z "${features_list}" ]
    then
        zenity --error --title "adk-downloader" --text "At least select an one feature to download!" || true
        echo "Not selected any feature!" >&2
        extract_burn_bundle "${extracted_folder}" "${aria2_file}" "${download_root}" "${features_pick}"
        return
    fi
    
    progress_pid=
    if [ "$(is_tty)" = "0" ]
    then
        cat /dev/zero | zenity --progress --pulsate --no-cancel --auto-kill --width 500 --title "adk-downloader" \
            --text "Collecting list of required packages for selected features..." &
        progress_pid="$!"
    fi

    # Read download URL from the setup manifest and follow the Microsoft redirect link
    # to get the final URL for the files to be downloaded.
    if [ -z "${download_root}" ]
    then
        echo "Resolving download URL..." >&2
        download_root="$(cat "${extracted_folder}/UserExperienceManifest.xml" | xmlstarlet sel -N "x=http://schemas.microsoft.com/Setup/2010/01/Burn/UserExperience" \
            --no-doc-namespace --template --value-of "./x:UserExperienceManifest/x:Settings/x:SourceResolution/x:DownloadRoot")"
        download_root="$(get_redirect_link "${download_root}")"
    else
        echo "Using cached download URL." >&2
    fi

    # Iterate through selected packages and their files to download, then obtain the download
    # path of the files and create an ARIA2C file for list of obtained files to be downloaded.
    echo "Resolving packages..." >&2
    total_size=0
    feature_info=""
    while read -r feature; do {
        feature_size=0
        while read -r package; do {
            echo "#" >> "${aria2_file}"
            echo "# Package: ${package}" >> "${aria2_file}"
            echo "# Requested by: ${feature}" >> "${aria2_file}"
            echo "#" >> "${aria2_file}"
            echo "" >> "${aria2_file}"
            while read -r sub; do {
                sub_file="$(cat "${extracted_folder}/0" | xmlstarlet sel -N "x=http://schemas.microsoft.com/wix/2008/Burn" \
                    --no-doc-namespace --template --match "./x:BurnManifest/x:Payload[@Id='${sub}']" \
                    --value-of "./@SourcePath" --output "|" --value-of "./@FilePath" --output "|" --value-of "./@Hash" --output "|" --value-of "./@FileSize" --nl)"
                source_path="$(echo "${sub_file}" | cut -d "|" -f 1 | tr "\\\\" "/" | sed "s/ /%20/g")"
                output_path="$(echo "${sub_file}" | cut -d "|" -f 2 | tr "\\\\" "/")"
                checksum="$(echo "${sub_file}" | cut -d "|" -f 3)"
                sub_size="$(echo "${sub_file}" | cut -d "|" -f 4)"
                feature_size=$(($feature_size + $sub_size))
                echo "[root]/${source_path}" >> "${aria2_file}"
                echo "  out=${output_path}" >> "${aria2_file}"
                echo "  checksum=sha-1=${checksum}" >> "${aria2_file}"
                echo "" >> "${aria2_file}"
            }; done < <(
                cat "${extracted_folder}/0" | xmlstarlet sel -N "x=http://schemas.microsoft.com/wix/2008/Burn" \
                    --no-doc-namespace --template --match "./x:BurnManifest/x:Chain/*[@Id='${package}']/x:PayloadRef" \
                    --value-of "./@Id" --nl
            )
        }; done < <(
            cat "${extracted_folder}/UserExperienceManifest.xml" | xmlstarlet sel -N "x=http://schemas.microsoft.com/Setup/2010/01/Burn/UserExperience" \
                --no-doc-namespace --template --match "./x:UserExperienceManifest/x:Options/x:Option[@Id='${feature}']/x:Packages/x:Package" \
                --value-of "./@Id" --nl
        )
        total_size=$(($total_size + $feature_size))
        size_human="$(echo "${feature_size}" | numfmt --to iec --suffix "B")"
        if [ "${feature_size}" -eq "0" ]
        then
            echo "Feature with name '${feature//OptionId./}' doesn't exists!" >&2
            exit 1
        else
            echo "${feature//OptionId./} - ${size_human}" >&2
        fi
        feature_info+="\n${feature//OptionId./} - ${size_human}"
    }; done <<< "${features_list}"
    sed -i"" "s|^\[root\]|${download_root}|g" "${aria2_file}"

    if [ -n "${progress_pid}" ]
    then
        kill "${progress_pid}" || true
    fi

    # Prompt for confirming the installation, if user has cancelled,
    # show the same feature dialog again.
    size_human="$(echo "${total_size}" | numfmt --to iec --suffix "B")"

    if [ "$(is_tty)" = "0" ]
    then
        confirm="$(
            zenity --title "adk-downloader" --question \
            --text "These requested features will be downloaded:\n${feature_info}\n\nThis will require a total of ${size_human} of disk space.\n\nProceed?" \
            || echo $?
        )"
        if [ -n "${confirm}" ]; then
            extract_burn_bundle "${extracted_folder}" "${aria2_file}" "${download_root}" "${features_pick}"
            return
        fi
    fi

    echo "Created ARIA2 file to: ${aria2_file}" >&2
}


start_aria2() {
    file="${1}"
    output="${2}"

    if [ ! -d "${output}" ]; then
        echo "Output path '${output}' is not a directory!" >&2
        exit 1
    fi

    total_file="$(grep -oP "^https?://.*" "${file}" | sort -u | wc -l)"
    current_file=0

    # Create a temporary named pipe to track aria2c progress, so Zenity can pull it from
    # the pipe to update the progress.
    pipefile="$(mktemp --dry-run --suffix "_pipe_${RANDOM}")"
    mkfifo "${pipefile}"

    # GET https://download.microsoft.com/download/5/8/6/5866fc30-973c-40c6-ab3f-2edb2fc3f727/ADK/Installers/0d981f062236baed075df3f42b1747db.cab
    # Accept: */*
    # User-Agent: Burn
    # Host: download.microsoft.com
    # Connection: Keep-Alive
    # Cache-Control: no-cache
    LC_ALL=C aria2c \
        --input-file="${file}" --max-concurrent-downloads=5 --check-integrity=true --continue=true \
        --max-connection-per-server=2 --split=5 --dir="${output}" --retry-wait=1 --uri-selector=inorder \
        --user-agent="Burn" --use-head=true --http-no-cache=true --enable-http-keep-alive=true \
        --file-allocation=none --auto-file-renaming=false --allow-overwrite=false --enable-color=false \
        --human-readable=false --show-console-readout=true --truncate-console-readout=false 2>&1 | while read line
    do
        line=$(echo "${line}" | sed -rn "s/.*? \[NOTICE\] Download complete: (.*?)$/\1/p")
        if [ -n "${line}" ]; then
            current_file=$(($current_file + 1))
            progress="$(echo "scale=2; ($current_file/$total_file)*100" | bc)"
            echo "# Downloading... ${progress}% - ${line}"
            echo "${progress}"
        fi
    done > "${pipefile}" &

    zenity --progress --auto-close --text "Downloading, it might take a while..." --width 600 --height 200 \
        --title "adk-downloader" --progress 0 < "${pipefile}"
    rm -rf "${pipefile}"
}


# Get a list of ADK versions and prompt user to choose one of ADK versions to download.
# Then, download the ADK installer to WORK_FOLDER. Or, if chosen by the user, save the 
# list of versions to a selected path.
pick_adk_version() {
    adk_downloads="${1:-}"
    picked_version="${2:-}"

    # If ADK downloads are not cached from an previous task, 
    # fetch the ADK versions with showing a indefinite progress bar.
    progress_pid=
    if [ "$(is_tty)" = "0" ] && [ -z "${adk_downloads}" ]
    then
        cat /dev/zero | zenity --progress --pulsate --no-cancel --auto-kill --width 500 --title "adk-downloader" \
            --text "Extracting &amp; resolving ADK downloads from Microsoft docs...\nIt might take a while depending on connection.\n" &
        progress_pid="$!"
    fi

    if [ -z "${adk_downloads}" ]
    then
        adk_downloads="$(get_adk_downloads)"
    fi

    if [ "$(is_tty)" = "1" ] && [ -z "${picked_version}" ]
    then
        echo "${adk_downloads}"
        exit 0
    fi

    if [ -n "${progress_pid}" ]
    then
        kill "${progress_pid}" || true
    fi

    # Parse downloads text to quote-wrapped values, so they can be used
    # as columns in list picker.
    columns=""
    while IFS="" read -r line || [ -n "$line" ]
    do
        link="$(echo "${line}" | cut -f 1 | rev | cut -d "/" -f 1 | rev)"
        name="$(echo "${line}" | cut -f 3)"
        version="$(echo "${line}" | cut -f 4)"
        id="$(echo "${line}" | cut -f 2)"
        picked="FALSE"
        if [ "${picked_version}" = "${version}" ]; then
            picked="TRUE"
        fi
        columns+=" \"${picked}\" \"${name}\" \"${version}\" \"${id}\" \"${link}\""
    done <<< "${adk_downloads}"

    if [ "$(is_tty)" = "0" ]
    then
        # Show a list picker to pick from retrieved ADK versions.
        selection="$(
            echo "${columns}" | xargs zenity --list --radiolist --title "adk-downloader" --width 850 --height 600 \
            --text "Select an ADK version to download:" --print-column "4" \
            --column "" --column "Name" --column "Version" --column "Link Id" --column "File" \
            "TRUE" "Save versions table to disk..." "" "" "" || echo "CANCEL"
        )"

        # If saving to the disk chosen, prompt an file saving dialog and write
        # the fetched ADK list to the file.
        if [ -z "${selection}" ]
        then
            echo "Saving version to disk." >&2
            output_file="$(zenity --file-selection --title "adk-downloader" --save --filename "versions.tsv" --confirm-overwrite || echo "")"
            if [ -z "${output_file}" ]
            then
                echo "Cancelled to save." >&2
                pick_adk_version "${adk_downloads}"
                return
            else
                echo "${adk_downloads}" > "${output_file}"
                echo "Saved to: ${output_file}" >&2
                pick_adk_version "${adk_downloads}"
                return
            fi
        elif [ "${selection}" = "CANCEL" ]
        then
            echo "Operation was cancelled." >&2
            exit 1
        fi
    else
        selection="${picked_version}"
    fi

    # Get the URL & version of the picked file.
    echo "Picked ID: ${selection}" >&2
    picked_item="$(echo "${adk_downloads}" | sed -rn "s/^([^\t]+)\t${selection}\t.*\t(.*)/\1\t\2/p")"
    if [ -z "${picked_item}" ]; then
        echo "Couldn't find the version info based on the selection!" >&2
        exit 1
    fi

    download_link="$(echo "${picked_item}" | cut -f 1)"
    file_name="$(echo "${picked_item}" | cut -f 1 | rev | cut -d "/" -f 1 | rev)"
    folder_name="$(echo "${picked_item}" | cut -f 2)"

    # Download the picked file in the version named folder in work directory.
    verify_work_folder
    mkdir --parents --verbose "${WORK_FOLDER}/${folder_name}" >&2
    echo "Downloading ${download_link}..." >&2

    progress_pid=
    if [ "$(is_tty)" = "0" ]
    then
        cat /dev/zero | zenity --progress --pulsate --no-cancel --auto-kill --width 500 --title "adk-downloader" \
            --text "Downloading ${file_name}...\n" &
        progress_pid="$!"
    fi

    wget -nv --show-progress -O "${WORK_FOLDER}/${folder_name}/${file_name}" "${download_link}"

    if [ -n "${progress_pid}" ]
    then
        kill "${progress_pid}" || true
    fi

    echo "Downloaded to: ${WORK_FOLDER}/${folder_name}/${file_name}" >&2

    if [ "$(is_tty)" = "0" ]
    then
        extract="$(zenity --question --title "adk-downloader" --text "Extract the installer to ${WORK_FOLDER}/${folder_name} now?" || echo "1")"
        if [ -z "${extract}" ]
        then
            mkdir --parents --verbose "${WORK_FOLDER}/${folder_name}/ADK" >&2
            mkdir --parents --verbose "${WORK_FOLDER}/${folder_name}/_installer" >&2
            extract_adk_installer "${WORK_FOLDER}/${folder_name}/${file_name}" "${WORK_FOLDER}/${folder_name}/_installer" "${WORK_FOLDER}/${folder_name}/ADK"

            # If file is an EXE setup, run aria2 for downloads.
            if [[ "${WORK_FOLDER}/${folder_name}/${file_name}" =~ "/adksetup.exe"* ]]
            then
                extract_burn_bundle "${WORK_FOLDER}/${folder_name}/_installer" "${WORK_FOLDER}/${folder_name}/aria2c"
                start_aria2 "${aria2_file}" "${WORK_FOLDER}/${folder_name}/ADK"
            fi
        fi
    else
        mkdir --parents --verbose "${WORK_FOLDER}/${folder_name}/ADK" >&2
        mkdir --parents --verbose "${WORK_FOLDER}/${folder_name}/_installer" >&2
        extract_adk_installer "${WORK_FOLDER}/${folder_name}/${file_name}" "${WORK_FOLDER}/${folder_name}/_installer" "${WORK_FOLDER}/${folder_name}/ADK"
    fi
}


extract_adk_installer() {
    input_file="${1}"
    extract_folder="${2}"
    download_path="${3}"

    if [ ! -f "${input_file}" ]; then
        echo "File couldn't exists at: ${input_file}!" >&2
        exit 1
    fi
    if [ ! -d "${extract_folder}" ]; then
        echo "Directory couldn't exists at: ${extract_folder}!" >&2
        exit 1
    fi
    if [ ! -d "${download_path}" ]; then
        echo "Directory couldn't exists at: ${download_path}!" >&2
        exit 1
    fi

    # Unpack EXE setup.
    if [[ "${input_file}" =~ "/adksetup.exe"* ]]
    then
        echo "ADK setup found." >&2
        echo "Extracting files to: ${extract_folder}" >&2
        7z x -y -aoa -tCAB -bb0 -bso0 -bse1 -bsp1 -o"${extract_folder}" "${input_file}"
    # Unpack ISO files.
    elif [[ "${input_file}" =~ ".iso"* ]]
    then
        echo "ISO found." >&2
        echo "Extracting ISO to: ${extract_folder}" >&2
        7z x -y -aoa -bb0 -bso0 -bse1 -bsp1 -o"${download_path}" "${input_file}"
    else
        echo "Extracting is not supported for file: ${input_file}!" >&2
        exit 0
    fi
}


help() {
    echo
    echo "usage: $(basename "$0") [--versions] [--download ID] [--pick VERSION [--packages FEATURES]]"
    echo
    echo "options:"
    echo "    --help                Shows this text."
    echo
    echo "    --versions            Retrieves a list of ADK versions. Prints an tab separated list."
    echo "                          Each column represents, download link, download ID, name and version respectively."
    echo
    echo "    --download ID         Downloads an ADK installer with given download ID (listed in --versions) and extracts it."
    echo "                          This will not download the ADK itself, just its setup file, which is later used to pick"
    echo "                          features, see below command."
    echo
    echo "    --packages FEATURES   Creates an aria2c-formatted file with the given comma-separated feature names."
    echo "                          --pick must be set."
    echo
    echo "    --pick VERSION        Lists available features with their dependencies of an downloaded version."
    echo "                          (if --packages was not set, otherwise it just picks the version for --packages.)"
    echo
}


check_dependencies

if [ "$#" -eq 0 ]
then
    if [ "$(is_tty)" = "0" ]; then
        pick_adk_version
    else
        help
        exit 1
    fi
else
    FORCE_CLI="1"
    FLAG_VALUE="__flag__"
    download_version=
    setup_folder=
    setup_packages=
    verify_work_folder
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --versions)
            pick_adk_version
            exit 0
            ;;
            --help)
            help
            exit 0
            ;;
            --download)
            download_version="${FLAG_VALUE}"
            shift
            ;;
            --pick)
            setup_folder="${FLAG_VALUE}"
            shift
            ;;
            --packages)
            setup_packages="${FLAG_VALUE}"
            shift
            ;;
            --*)
            echo "Unknown option: ${1}" >&2
            echo "See --help for help" >&2
            exit 1
            ;;
            *)
            if [ "${download_version}" = "${FLAG_VALUE}" ]
            then
                download_version="${1}"
                shift
            elif [ "${setup_folder}" = "${FLAG_VALUE}" ]
            then
                if [ ! -d "${WORK_FOLDER}/${1}/_installer" ]
                then
                    echo "${WORK_FOLDER}/${1}/_installer is not a valid directory!" >&2
                    echo "Is this version has downloaded already?"
                    exit 1
                fi
                setup_folder="${WORK_FOLDER}/${1}/_installer"
                shift
            elif [ "${setup_packages}" = "${FLAG_VALUE}" ]
            then
                setup_packages="${1}"
                shift
            else
                echo "Unknown option: ${1}" >&2
                echo "See --help for help" >&2
                exit 1
            fi
            ;;
        esac
    done
    if [ "${download_version}" = "${FLAG_VALUE}" ]
    then
        echo "--download option requires an parameter." >&2
        echo "See --help for help" >&2
        exit 1
    elif [ "${setup_folder}" = "${FLAG_VALUE}" ]
    then
        echo "--pick option requires an parameter." >&2
        echo "See --help for help" >&2
        exit 1
    elif [ "${setup_packages}" = "${FLAG_VALUE}" ]
    then
        echo "--packages option requires an parameter." >&2
        echo "See --help for help" >&2
        exit 1
    fi
    if [ -n "${download_version}" ]
    then
        echo "Trying to download version: ${download_version}" >&2
        pick_adk_version "" "${download_version}"
        exit 0 
    fi
    if [ -n "${setup_folder}" ]
    then
        aria2_file="$(mktemp --suffix "_adk_aria2")"
        extract_burn_bundle "${setup_folder}" "${aria2_file}" "" "${setup_packages}"
        cat "${aria2_file}"
        rm -rf "${aria2_file}"
        exit 0
    elif [ -n "${setup_packages}" ]
    then
        echo "--packages option cannot be used alone, --pick also must be set for specifying which ADK version to use." >&2
        echo "See --help for help" >&2
        exit 1 
    fi
fi