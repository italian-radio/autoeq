#!/bin/bash

# this bash script does auto-eq  on a folder of files so that they can
# be mixed together without massive differences of EQ balance or overall loudness

# this script splits a directory of audio files into bands, then 
# sets each band to be equal to the perceived loudness of the others (but
# does not use any files you have tagged as red to calculate ave levels)

# Requires Mac OS (for file labels), with sox and ffmpeg installed (via Homebrew)
# CD to the directory of the audio files before running this script
# cd "/Volumes/Space Disco/Shortened"

has_red_label() {
    filename=$1
    # Check Finder label using xattr
    # xattr -p com.apple.FinderInfo "$filename" | cut -c 28-29 | grep -q "0C" && return 0
    xattr -p com.apple.FinderInfo "$filename" 2>/dev/null | cut -c 28-29 | grep -q "0C" && return 0

    # Check "Red" tag using mdls    
    label=$(mdls -name kMDItemUserTags "$filename" | grep -o "Red")
    if [ -z "$label" ]; then
        return 1  # No red label, return false.
    else
        return 0  # Red label found, return true.
    fi
}

mkdir -p "leaded/quiet/bands/normalized/recombined/final"

# Specify your band edges here, in Hz.
band_edges=(120 320 860 2320 6250)

# Calculate the number of bands.
num_bands=${#band_edges[@]}
num_bands=$((num_bands + 1))  # 1 for the 0 Hz and 1 for the high-pass filter band.

# Prepend the segment first, before the actual splitting and normalization
for file in *.wav; do
    # Copy a segment from 1/4 into the audio file
    length=$(soxi -D "$file")
    start=$(echo "$length / 2" | bc)
    sox --no-show-progress "$file" "leaded/head_$file" trim $start 10

    # Append 1 second of silence to the copied segment to the original audio file
    sox --no-show-progress "leaded/head_$file" "leaded/temp_$file" pad 0 1
    mv "leaded/temp_$file" "leaded/head_$file"

    # Prepend the copied segment to the original audio file
    sox --no-show-progress --combine concatenate "leaded/head_$file" "$file" "leaded/leaded_$file"

    filename=${file##*/}
    basename=$(basename "$file" .wav)

    # Reduce volume by 50% to avoid clipping
    sox --no-show-progress "leaded/leaded_$filename" "leaded/quiet/quiet_$filename" vol 0.5

    # Band separation
    low_limit=0

    # Process each band
    for (( i=0; i<$num_bands; i++ ))
    do

        # Upper limit of the current band
        high_limit=${band_edges[i]}

       # Special case for the last band (upper limit is infinity)
        if (( i == num_bands-1 ))
        then
            ffmpeg -v quiet -i "leaded/quiet/quiet_${filename}" -af "highpass=${low_limit}" "leaded/quiet/bands/${basename}_band${i}.wav"
        elif (( i == 0 ))
        then
            ffmpeg -v quiet -i "leaded/quiet/quiet_${filename}" -af "lowpass=${high_limit}" "leaded/quiet/bands/${basename}_band${i}.wav"
        else 
            ffmpeg -v quiet -i "leaded/quiet/quiet_${filename}" -af "highpass=${low_limit}, lowpass=${high_limit}" "leaded/quiet/bands/${basename}_band${i}.wav"
        fi

        # Apply filters

        # Update the lower limit for the next band
        low_limit=$high_limit
    done

done

# Calculate the average loudness for each band, then normalize.
for (( band=0; band<num_bands; band++ )); do
    sum=0
    count=0
    for file in leaded/quiet/bands/*_band${band}.wav; do 

        # If original file has a red label, skip loudness calculation
        original_filename=$(basename "${file/_band${band}/}")
        if has_red_label "$original_filename"; then
            echo "SKIPPING LOUDNESS CALCULATION FOR $original_filename BECAUSE IT HAS A RED LABEL."
            continue
        else
            echo "INCORPORATING LOUDNESS CALCULATION FOR $original_filename." 
        fi

        loudness=$(ffmpeg -i "$file" -af ebur128=framelog=verbose -f null - 2>&1 | awk '/I:/{print $2}')
        sum=$(echo "$sum + $loudness" | bc -l)
        ((count++))
    done
    average=$(echo "$sum / $count" | bc -l)
    echo "Average loudness for band $band: $average LUFS"
    
    # Normalize files to the average loudness.
    for file in leaded/quiet/bands/*_band${band}.wav; do 
        filename=${file##*/}
        ffmpeg -v quiet -i "$file" -af loudnorm=I=$average:TP=-1.5:LRA=11 -ar 44100 "leaded/quiet/bands/normalized/normalized_$filename"; 
    done
done

# Mix the band files back into the original files.
for file in *.wav; do 
    basename=$(basename "$file" .wav)
    inputs=()
    for (( band=0; band<num_bands; band++ )); do
        inputs+=("leaded/quiet/bands/normalized/normalized_${basename}_band${band}.wav")
    done
    sox --no-show-progress -m "${inputs[@]}" "leaded/quiet/bands/normalized/recombined/temp_recombined_${basename}.wav"
    
    # Trim the prepended audio from the new audio file
    sox --no-show-progress "leaded/quiet/bands/normalized/recombined/temp_recombined_${basename}.wav" "leaded/quiet/bands/normalized/recombined/recombined_${basename}.wav" trim 11
    
    # Cleanup temporary files
    rm "leaded/quiet/bands/normalized/recombined/temp_recombined_${basename}.wav"
done

# Normalize the output files.
for file in leaded/quiet/bands/normalized/recombined/*.wav; do 
    ffmpeg -v quiet -i "$file" -af loudnorm=I=-16:TP=-1.5:LRA=11 -ar 44100 "leaded/quiet/bands/normalized/recombined/final/final_${file##*/}"; 
done
