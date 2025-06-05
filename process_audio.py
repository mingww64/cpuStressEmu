#!/usr/bin/env python3
import argparse
from pydub import AudioSegment
from pydub.silence import detect_nonsilent
import os

def process_audio_refined(input_file, output_file,
                          silence_thresh_dbfs=-40,
                          min_silence_duration_to_affect_ms=700,
                          padding_between_segments_ms=150,
                          leading_padding_ms=0,
                          trailing_padding_ms=0):
    """
    Processes an audio file:
    1. Trims leading and trailing silences (longer than min_silence_duration_to_affect_ms).
    2. Reduces internal silences (longer than min_silence_duration_to_affect_ms)
       to padding_between_segments_ms.
    3. Optionally adds specified leading/trailing padding to the final output.

    Args:
        input_file (str): Path to the input audio file.
        output_file (str): Path to save the processed audio file.
        silence_thresh_dbfs (int): Silence threshold in dBFS. Quieter is silence.
        min_silence_duration_to_affect_ms (int): Min duration (ms) of a silence to be
                                                 detected and potentially altered.
        padding_between_segments_ms (int): Duration (ms) of silence to place between
                                           speech segments after removing longer silences.
        leading_padding_ms (int): Duration (ms) of silence to add at the beginning.
        trailing_padding_ms (int): Duration (ms) of silence to add at the end.
    """
    try:
        print(f"Loading audio file: {input_file}")
        audio = AudioSegment.from_file(input_file)
        original_duration_s = len(audio) / 1000.0
        print(f"Audio loaded. Original duration: {original_duration_s:.2f}s")

        if original_duration_s == 0:
            print("Input audio is empty. Saving an empty output file.")
            # Ensure output directory exists
            os.makedirs(os.path.dirname(os.path.abspath(output_file)), exist_ok=True)
            audio.export(output_file, format=output_file.split('.')[-1].lower())
            return

        print(f"Detecting non-silent parts (silence_thresh={silence_thresh_dbfs}dBFS, "
              f"min_silence_len_for_split={min_silence_duration_to_affect_ms}ms)...")

        nonsilent_ranges = detect_nonsilent(
            audio_segment=audio,
            min_silence_len=min_silence_duration_to_affect_ms, # Min duration of silence to cause a split
            silence_thresh=silence_thresh_dbfs,
            seek_step=1
        )

        if not nonsilent_ranges:
            print("No non-silent parts detected based on current settings. "
                  "The audio might be entirely silent or below the threshold.")
            # Output a silent clip of total desired padding, or original if no padding.
            final_output = AudioSegment.silent(duration=leading_padding_ms) + \
                           AudioSegment.silent(duration=trailing_padding_ms)
            
            # Ensure output directory exists
            os.makedirs(os.path.dirname(os.path.abspath(output_file)), exist_ok=True)

            if len(final_output) == 0: # if no padding requested
                print("Saving original (silent) audio as no non-silent parts were found and no padding requested.")
                audio.export(output_file, format=output_file.split('.')[-1].lower())
            else:
                print(f"Saving a silent clip with specified padding. Duration: {len(final_output)/1000.0:.2f}s")
                final_output.export(output_file, format=output_file.split('.')[-1].lower())
            return

        print(f"Found {len(nonsilent_ranges)} non-silent segments.")

        # Build the core audio by stitching non-silent parts with desired internal padding
        core_audio_segments = []
        # Add first non-silent segment
        start_idx, end_idx = nonsilent_ranges[0]
        core_audio_segments.append(audio[start_idx:end_idx])

        # Iterate through the rest of the non-silent segments
        for i in range(1, len(nonsilent_ranges)):
            # Add padding silence between segments
            core_audio_segments.append(AudioSegment.silent(duration=padding_between_segments_ms))

            # Add next non-silent segment
            start_idx, end_idx = nonsilent_ranges[i]
            core_audio_segments.append(audio[start_idx:end_idx])

        # Combine core segments
        processed_core_audio = sum(core_audio_segments, AudioSegment.empty())

        # Add leading and trailing padding
        final_output = AudioSegment.silent(duration=leading_padding_ms) + \
                       processed_core_audio + \
                       AudioSegment.silent(duration=trailing_padding_ms)

        output_duration_s = len(final_output) / 1000.0
        print(f"Exporting processed audio to: {output_file}")

        output_format = output_file.split('.')[-1].lower()
        if output_format == 'm4a':
            output_format = 'ipod' # pydub uses 'ipod' for m4a
        # Common formats like webm, mp3, ogg, wav are typically handled by their extension.

        # Ensure output directory exists
        os.makedirs(os.path.dirname(os.path.abspath(output_file)), exist_ok=True)
        final_output.export(output_file, format=output_format)
        print(f"Processed audio saved. New duration: {output_duration_s:.2f}s "
              f"(Original: {original_duration_s:.2f}s)")

    except FileNotFoundError:
        print(f"Error: Input file '{input_file}' not found.")
    except Exception as e:
        print(f"An error occurred: {e}")
        print("Please ensure FFmpeg (for WebM, MP3, M4A, OGG etc.) or Libav is "
              "installed and accessible in your system's PATH if working with non-WAV files.")


def main():
    parser = argparse.ArgumentParser(
        description="Process audio to remove/reduce long silences and add padding.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    parser.add_argument("input_file",
                        help="Path to the input audio file (e.g., .webm, .mp3, .wav, .m4a, .ogg).")
    parser.add_argument("output_file",
                        help="Path to save the processed audio file.")
    parser.add_argument("--silence_thresh", type=int, default=-40,
                        help="Silence threshold in dBFS. Quieter than this is considered silence.")
    parser.add_argument("--min_silence_len", type=int, default=700,
                        help="Minimum duration (ms) of a silence to be detected and potentially altered.")
    parser.add_argument("--padding_between", type=int, default=150,
                        help="Duration (ms) of silence to retain/insert between speech segments.")
    parser.add_argument("--leading_padding", type=int, default=0,
                        help="Duration (ms) of silence to add at the beginning of the processed audio.")
    parser.add_argument("--trailing_padding", type=int, default=0,
                        help="Duration (ms) of silence to add at the end of the processed audio.")

    args = parser.parse_args()

    process_audio_refined(
        args.input_file,
        args.output_file,
        silence_thresh_dbfs=args.silence_thresh,
        min_silence_duration_to_affect_ms=args.min_silence_len,
        padding_between_segments_ms=args.padding_between,
        leading_padding_ms=args.leading_padding,
        trailing_padding_ms=args.trailing_padding
    )

if __name__ == "__main__":
    main()
