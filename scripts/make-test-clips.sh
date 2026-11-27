#!/bin/bash
# Makes small synthetic clips that mimic every kind of file in the library, for the engine tests.
# Names starting with "native_" must play in the native engine; "any_" may fall back to mpv.
# Usage: scripts/make-test-clips.sh <output folder>
set -u
out="${1:?output folder}"; mkdir -p "$out"; cd "$out"
V="-f lavfi -i testsrc2=size=1280x720:rate=24000/1001:duration=8"
V4K="-f lavfi -i testsrc2=size=3840x2160:rate=24:duration=4"
A="-f lavfi -i sine=frequency=440:sample_rate=48000:duration=8"
SRT="$out/_subs.srt"; printf '1\n00:00:01,000 --> 00:00:03,000\nHello\n\n2\n00:00:04,000 --> 00:00:06,000\nWorld\n' > "$SRT"
ASS="$out/_subs.ass"; ffmpeg -v error -y -i "$SRT" "$ASS"
mk() { local name="$1"; shift; if ffmpeg -nostdin -v error -y "$@" "$name"; then echo "made $name"; else echo "SKIPPED $name (encoder missing)"; rm -f "$name"; fi; }
X264="-c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 48"
X265="-c:v libx265 -preset ultrafast -pix_fmt yuv420p -x265-params log-level=error:keyint=48"
X265_10="-c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -x265-params log-level=error:keyint=48"
HDR="-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc"

mk native_mp4_h264_avc1_aac.mp4        $V $A $X264 -c:a aac -tag:v avc1
mk native_mp4_h264_avc3_aac.mp4        $V $A $X264 -x264-params repeat-headers=1 -c:a aac -tag:v avc3
mk native_mp4_hevc_hvc1_ac3.mp4        $V $A $X265 -c:a ac3 -tag:v hvc1
mk native_mp4_hevc_hev1_eac3.mp4       $V $A $X265 -x265-params log-level=error:keyint=48:repeat-headers=1 -c:a eac3 -tag:v hev1
mk native_mp4_hevc10_hdr10_hev1.mp4    $V4K -f lavfi -i sine=duration=4 $X265_10 $HDR -c:a aac -tag:v hev1
mk native_mkv_hevc10_srt_ass.mkv       $V $A -i "$SRT" -i "$ASS" -map 0 -map 1 -map 2 -map 3 $X265_10 -c:a aac -c:s copy
mk native_mkv_hevc10_hdr10_4k.mkv      $V4K -f lavfi -i sine=duration=4 $X265_10 $HDR -c:a eac3
mk native_mkv_h264_multiaudio.mkv      $V $A $A $A $A -map 0 -map 1 -map 2 -map 3 -map 4 $X264 -c:a:0 aac -c:a:1 ac3 -c:a:2 libopus -c:a:3 flac
mk any_mkv_h264_interlaced.mkv         $V $A -c:v libx264 -preset ultrafast -pix_fmt yuv420p -flags +ildct+ilme -x264-params tff=1 -c:a aac
mk native_mkv_h264_truehd.mkv          $V $A $X264 -c:a truehd -strict -2
mk native_mkv_h264_dts.mkv             $V $A $X264 -c:a dca -strict -2
mk native_mov_h264_pcm.mov             $V $A $X264 -c:a pcm_s24le
mk native_mkv_hevc_offset_audio.mkv    $V -itsoffset 0.2 $A $X265 -c:a aac
mk any_mkv_h264_10bit.mkv              $V $A -c:v libx264 -preset ultrafast -pix_fmt yuv420p10le -c:a aac
mk any_avi_mpeg4_mp3.avi               $V $A -c:v mpeg4 -q:v 5 -c:a libmp3lame
mk any_webm_vp9_opus.webm              $V $A -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -c:a libopus
mk any_mkv_av1_opus.mkv                $V $A -c:v libsvtav1 -preset 12 -c:a libopus
mk any_ts_mpeg2_ac3.ts                 $V $A -c:v mpeg2video -c:a ac3
rm -f "$SRT" "$ASS"
ls -la
