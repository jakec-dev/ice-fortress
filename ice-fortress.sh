#!/bin/bash

readonly SCRIPT="$(cd "$(dirname "$0")"; pwd)"

################
# Parse command line options
################

function print_help() {
cat << help_menu

Help menu to be added...

usage: ice-f -pd|--pa-dir <dir> -g|--gpg-rec <email> -ps|--pa-size -vr|--vid-res -h|--help

    --album_name            description

help_menu
}

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            print_help
            exit 0
            ;;
        -p|--profile-name)
            arg_profile="$2"
            shift
            shift
            ;;
        -r|--vid-resolution)
            arg_res="$2"
            shift
            shift
            ;;
        -s|--photo-size)
            arg_size="$2"
            shift
            shift
            ;;
        -a|--album-dir)
            arg_album="$2"
            shift
            shift
            ;;
        -g|--gpg-rec)
            arg_gpg="$2"
            shift
            shift
            ;;
        -v|--vault-name)
            arg_vault="$2"
            shift
            shift
            ;;
        *)
            arg_dir="$1"
            shift
            ;;
    esac
done

if [[ -z "$arg_album" ]]; then
    echo "No photo album directory specified!"
    print_help
    exit 1
fi

if [[ -z "$arg_vault" ]]; then
    echo "No vault name specified!"
    print_help
    exit 1
fi

if [[ -z "$arg_gpg" ]]; then
    echo "No GnuPG receiver specified!"
    print_help
    exit 1
fi

if [[ -z "$arg_dir" ]]; then
    echo "No file specified!"
    print_help
    exit 1
fi

################
# Script parameters
################

readonly vault_name="${arg_vault}"
readonly album_dir="${arg_album}"
readonly profile="${arg_profile:-}"
readonly pa_size="${arg_size:-1280x720}"
readonly vid_res="${arg_res:-\-1:360}"
readonly source_dir="$arg_dir"
readonly gpg_rec="$arg_gpg"

################
# Setup
################

function create_unique_name() {
    echo "  * setting up"
    tmp_dir="$(mktemp -d)"
    
    # set desired file name and tree dir
    create_date="$(exiftool "-CreateDate" $media | awk -F ': ' '{print $2}')"
    if [[ -z $create_date ]]; then
        new_name="$(echo $media_filename | sed 's/\(.*\)\..*/\1/')"
        tree_dir="unknown-date"
    else
        year="$(echo $create_date | awk -F ':' '{print $1}')"
        month="$(echo $create_date | awk -F ':' '{print $2}')"
        day="$(echo $create_date | awk -F ':' '{print $3}' | awk '{print $1}')"
        hour="$(echo $create_date | awk -F ':' '{print $3}' | awk '{print $2}')"
        minute="$(echo $create_date | awk -F ':' '{print $4}')"
        
        new_name="${year}-${month}-${day}_${hour}-${minute}"
        tree_dir="${year}/${year}-${month}"
    fi

    # define suffix and extension for entry in photo album
    case $mime_type in
        image/jpeg)
            pa_ext="jpg"
            pa_suffix=
            ;;
        video/*) # use h.265 encoding for videos in photo album
            pa_ext="mp4"
            pa_suffix=
            ;;
        *) # targets raw image files and converts them to jpeg previews in photo album 
            pa_ext="jpg"
            pa_suffix="-${media_ext^^}"
            ;;
    esac

    # set desired photo album file name and path
    pa_name="${new_name}${pa_suffix}.${pa_ext}"
    pa_path="${album_dir}/${tree_dir}/${pa_name}" 
    og_name="${new_name}.${media_ext}"

    # if file name is not unique, increment suffix until it is
    i=0
    while [[ -f $pa_path ]]; do
        ((i++))
        pa_name="${new_name}${pa_suffix}.${i}.${pa_ext}"
        pa_path="${album_dir}/${tree_dir}/${pa_name}"
        og_name="${new_name}.${i}.${media_ext}"
    done

    # set file names and paths
    og_name="${og_name// /-}"
    og_path="$(dirname $media)/${og_name}"
    arc_name="${og_name}.tgz"
    arc_path="${tmp_dir}/${arc_name}"
    enc_name="${og_name}.gpg"
    enc_path="${tmp_dir}/${enc_name}"
}

################
# Add to photo album
################

function add_to_photo_album() {
    echo "  * creating optimized copy in photo album"
    mkdir -p "${album_dir}/${tree_dir}"
    case $mime_type in
        video/*)
            ffmpeg -i $media -vf scale=$vid_res -vcodec libx265 -crf 28 -n $pa_path &> ${tmp_dir}/pa.log
            ;;
        *)
            # https://stackoverflow.com/questions/7261855/recommendation-for-compressing-jpg-files-with-imagemagick
            convert $media -sampling-factor 4:2:0 -strip -quality 85 -interlace Plane -gaussian-blur 0.05 \
                -colorspace RGB -resize ${pa_size}\> ${pa_path} &> ${tmp_dir}/pa.log
            ;;
    esac
}

################
# Rename
################

function backup_original() {
    # rename
    mv -v -n $media $og_path &>> ${tmp_dir}/.log
    
    # archive and compress
    echo "  * archiving original image"
    tar czf $arc_path $og_path &>> ${tmp_dir}/.log

    # encrypt
    echo "  * encrypting archive"
    gpg -v -e -r $gpg_rec -o $enc_path $arc_path &>> ${tmp_dir}/.log

    # upload
    echo "  * uploading encrypted archive to AWS"
    ${SCRIPT}/glacierupload -v $vault_name -d $og_name -s 2 -p $profile $enc_path >>${tmp_dir}/glacierupload.log 2>&1
    archive_id="$(tail -n 1 ${tmp_dir}/glacierupload.log)"

    # add entry to index
    echo "$pa_name: $archive_id" >> ${album_dir}/${tree_dir}/index
}

################
# Execute script
################

# https://unix.stackexchange.com/questions/9496/looping-through-files-with-spaces-in-the-names
OIFS="$IFS"
IFS=$'\n'

for media in $source_dir/*; do
   # return early if not an image or video file
    mime_type="$(file -b --mime-type $media)"
    if [[ $mime_type != "image"* && $mime_type != "video"* ]]; then
        echo "'$media' is not an image or video file. Skipping"
        continue
    fi

    # setup
    media_filename="$(basename $media)"
    media_ext="${media_filename##*.}"
    echo "Processing '$media_filename' ..."
    create_unique_name

    # run scripts
    add_to_photo_album
    backup_original

    # cleanup
    trash-put -r $tmp_dir

    echo "Completed '$media_filename'"
done

IFS="$OIFS"
