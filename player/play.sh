#!/bin/zsh
# play.sh <any audio file: flac/wav/aiff/m4a/mp3> [seconds]
# env: LDAC_ADDR=<headphone bt address> (required), LDAC_Q=hq|sq|mq (default hq)
# Decodes to stereo PCM at the file's own rate (capped at 96 kHz — the XM4 limit) and streams it over LDAC.
set -e
[[ -z "$LDAC_ADDR" ]] && { echo "set LDAC_ADDR=xx-xx-xx-xx-xx-xx (System Information → Bluetooth)"; exit 1; }
in="$1"; secs="${2:-0}"
here="${0:A:h}"
rate=$(afinfo "$in" | awk '/Data format/{for(i=1;i<=NF;i++) if($i=="Hz,") print $(i-1)}')
bits=$(afinfo "$in" | awk '/source bit depth/{gsub(/[^0-9]/,"",$NF); print $NF}')
case "$rate" in 44100|48000|88200|96000) out=$rate;; 176400) out=88200;; *) out=96000;; esac
[[ "$bits" == 16 ]] && fmt=LEI16 || fmt=LEI24
wav="${TMPDIR:-/tmp}/ldacplay-$$.wav"
if [[ "${in:e:l}" == "flac" ]] && ! afinfo "$in" >/dev/null 2>&1; then
  ffmpeg -loglevel error -i "$in" -ar $out -sample_fmt s32 "$wav"
else
  afconvert -f WAVE -d ${fmt}@${out} -c 2 "$in" "$wav"
fi
echo "source: ${rate} Hz, ${bits:-?} bit  ->  LDAC ${out} Hz"
trap 'rm -f "$wav"' EXIT
"$here/ldacplay" "$wav" "$secs"
