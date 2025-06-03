#!/bin/bash

# Linux CPU Data Logger Script (Updated v13 - Ryzen Monitor Read, PPT Control & mprime Load)
#
# This script collects CPU temperature, package power (from a ryzen_monitor read command), 
# fan RPM (from hwmon), and ambient temperature.
# Optionally:
#   1. Controls CPU Package Power Target (PPT) limits using a user-defined command.
#   2. Runs mprime (Prime95) in the background to generate CPU load.
# Assumes the ryzen_monitor READ command streams output continuously.
# Assumes the command for SETTING PPT is a one-shot command.

# --- Configuration & Setup ---
DEFAULT_SAMPLING_INTERVAL_S=1 
DEFAULT_OUTPUT_FILE="cpu_cooling_data_controlled.csv"
DEFAULT_RYZEN_MONITOR_READ_CMD="ryzen_monitor --test-export" 
DEFAULT_PPT_CONTROL_CMD_BASE="ryzen_monitor" 
DEFAULT_PPT_SET_ARG_FORMAT="--set-ppt=" 

# --- Configurable Ryzen Monitor Parsing Parameters (for reading data) ---
DEFAULT_RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP="cpu_thm"
DEFAULT_RYZEN_MONITOR_TEMP_FIELD_NAME="cpu_thm"
DEFAULT_RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER="cpu_ppt"
DEFAULT_RYZEN_MONITOR_POWER_FIELD_NAME="cpu_ppt"

# --- Global Variables for Background Processes ---
RYZEN_MONITOR_READ_PID_GLOBAL=""
RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL=""
MPRIME_PID_GLOBAL=""

# --- Helper Functions ---
find_sensor_file() { # For fan hwmon fallback
    local device_name_filter_regex="$1"; local label_substring_regex="$2"; local input_prefix="$3"; local friendly_name="$4"
    for hwmon_dev_path in /sys/class/hwmon/hwmon*; do
        [ ! -d "$hwmon_dev_path" ] && continue
        local current_device_name=""; if [ -f "$hwmon_dev_path/name" ]; then current_device_name=$(<"$hwmon_dev_path/name"); fi
        if [ -n "$device_name_filter_regex" ] && ! echo "$current_device_name" | grep -qE "$device_name_filter_regex"; then continue; fi
        if [ -n "$label_substring_regex" ]; then
            for label_file in "$hwmon_dev_path/${input_prefix}"*_label; do
                [ ! -f "$label_file" ] && continue
                if grep -qE "$label_substring_regex" "$label_file" 2>/dev/null; then
                    local input_file="${label_file%_label}_input"; if [ -f "$input_file" ]; then echo "$input_file"; return 0; fi
                fi
            done
        elif [ -n "$device_name_filter_regex" ]; then 
            local first_input_file=$(find "$hwmon_dev_path" -name "${input_prefix}*_input" -print -quit 2>/dev/null)
            if [ -n "$first_input_file" ] && [ -f "$first_input_file" ]; then echo "$first_input_file"; return 0; fi
        fi
    done
    return 1 
}

read_ryzen_monitor_metric_from_file() {
    local temp_file_path="$1"; local target_line_grep_pattern="$2"; local field_name="$3"
    local package_line="" value="" field_set=""
    if [ -z "$temp_file_path" ] || [ ! -f "$temp_file_path" ]; then echo "Debug: Temp file '$temp_file_path' not found." >&2; return 1; fi
    package_line=$(grep "$target_line_grep_pattern" "$temp_file_path" | tail -n 1)
    if [ -z "$package_line" ]; then echo "Debug: Pattern '$target_line_grep_pattern' not found in '$temp_file_path'." >&2; return 1; fi
    field_set=$(echo "$package_line" | cut -d ' ' -f2-); value=$(echo "$field_set" | tr ',' '\n' | grep "${field_name}=" | cut -d '=' -f2 | sed 's/i$//')
    if [ -n "$value" ] && [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then echo "$value"; return 0; else
        echo "Debug: Failed to extract numeric '$field_name' from line: '$package_line' (value: '$value')" >&2; return 1; fi
}

start_ryzen_monitor_read_background() {
    local cmd_to_run="$1"
    if [ -z "$cmd_to_run" ]; then echo "Error: No ryzen_monitor READ command to start." >&2; return 1; fi
    stop_ryzen_monitor_read_background 
    RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL=$(mktemp /tmp/ryzen_monitor_read_output.XXXXXX)
    echo "Starting ryzen_monitor READ: '$cmd_to_run' > '$RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL'" >&2
    eval "$cmd_to_run" > "$RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL" 2>/dev/null &
    RYZEN_MONITOR_READ_PID_GLOBAL=$!
    sleep 0.5 
    if ! ps -p "$RYZEN_MONITOR_READ_PID_GLOBAL" > /dev/null; then
        echo "Error: Failed to start ryzen_monitor READ command: '$cmd_to_run'." >&2
        RYZEN_MONITOR_READ_PID_GLOBAL=""; rm -f "$RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL"; RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL=""; return 1
    fi
    echo "ryzen_monitor READ started (PID: $RYZEN_MONITOR_READ_PID_GLOBAL)." >&2
    return 0
}

stop_ryzen_monitor_read_background() {
    if [ -n "$RYZEN_MONITOR_READ_PID_GLOBAL" ] && ps -p "$RYZEN_MONITOR_READ_PID_GLOBAL" > /dev/null; then
        echo "Stopping background ryzen_monitor READ (PID: $RYZEN_MONITOR_READ_PID_GLOBAL)..." >&2
        kill "$RYZEN_MONITOR_READ_PID_GLOBAL"; sleep 0.2 
        if ps -p "$RYZEN_MONITOR_READ_PID_GLOBAL" > /dev/null; then kill -9 "$RYZEN_MONITOR_READ_PID_GLOBAL"; fi
    fi
    RYZEN_MONITOR_READ_PID_GLOBAL=""
    if [ -n "$RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL" ] && [ -f "$RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL" ]; then
        rm -f "$RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL"
    fi
    RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL=""
}

# --- PPT Control & mprime Variables ---
CONTROL_PPT="n"; PPT_CONTROL_CMD_BASE=""; PPT_SET_ARG_FORMAT=""; PPT_VALUES_TO_TEST=(); PPT_RESET_VALUE=""
USE_MPRIME="n"; MPRIME_PATH=""; MPRIME_THREAD_COUNTS_FOR_PPT_TESTS=""; MPRIME_THREAD_COUNTS_ITERATE=() # New for iterating mprime if PPT is off
WARMUP_DURATION=30; MEASUREMENT_DURATION=120; COOLDOWN_DURATION=60

cleanup_all() {
    echo -e "\nPerforming cleanup..."
    stop_ryzen_monitor_read_background 
    if [ -n "$MPRIME_PID_GLOBAL" ] && ps -p "$MPRIME_PID_GLOBAL" > /dev/null; then
        echo "Stopping mprime (PID: $MPRIME_PID_GLOBAL)..."; kill "$MPRIME_PID_GLOBAL"; sleep 1
        if ps -p "$MPRIME_PID_GLOBAL" > /dev/null; then kill -9 "$MPRIME_PID_GLOBAL"; fi
    fi
    MPRIME_PID_GLOBAL=""
    if [[ "$CONTROL_PPT" =~ ^[Yy]$ ]] && [ -n "$PPT_CONTROL_CMD_BASE" ] && [ -n "$PPT_SET_ARG_FORMAT" ] && [ -n "$PPT_RESET_VALUE" ]; then
        local reset_cmd_full="$PPT_CONTROL_CMD_BASE $PPT_SET_ARG_FORMAT$PPT_RESET_VALUE"
        echo "Attempting to reset PPT to $PPT_RESET_VALUE W using: $reset_cmd_full"
        eval "$reset_cmd_full"; if [ $? -eq 0 ]; then echo "PPT reset successfully."; else echo "Warning: PPT reset command failed."; fi
    fi
    echo "Data (if any) saved to $OUTPUT_FILE"; echo "Cleanup complete. Exiting."; exit 0 
}
trap cleanup_all SIGINT SIGTERM

if ! command -v bc &> /dev/null; then echo "Error: 'bc' not installed." >&2; exit 1; fi
if [[ $EUID -ne 0 ]]; then echo "Warning: Root privileges likely required for ryzen_monitor and PPT/mprime control." >&2; fi

# --- Ryzen Monitor READ Command Setup ---
RYZEN_MONITOR_READ_CMD_USER=""
RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP_USER=""
RYZEN_MONITOR_TEMP_FIELD_NAME_USER=""
RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER_USER=""
RYZEN_MONITOR_POWER_FIELD_NAME_USER=""

read -r -p "Enter command for READING ryzen_monitor data (e.g., 'ryzen_monitor_ng --test-export'): [$DEFAULT_RYZEN_MONITOR_READ_CMD] " RYZEN_MONITOR_READ_CMD_USER
RYZEN_MONITOR_READ_CMD_USER=${RYZEN_MONITOR_READ_CMD_USER:-$DEFAULT_RYZEN_MONITOR_READ_CMD}
if [ -z "$RYZEN_MONITOR_READ_CMD_USER" ]; then echo "Error: Ryzen monitor READ command is required. Exiting." >&2; cleanup_all; fi
RYZEN_MONITOR_READ_BASE_CMD=$(echo "$RYZEN_MONITOR_READ_CMD_USER" | awk '{print $1}')
if ! command -v "$RYZEN_MONITOR_READ_BASE_CMD" &> /dev/null || [ ! -x "$(command -v "$RYZEN_MONITOR_READ_BASE_CMD")" ]; then
    echo "Error: Ryzen monitor READ command base '$RYZEN_MONITOR_READ_BASE_CMD' not found or not executable. Exiting." >&2; cleanup_all; fi
echo "Using ryzen_monitor READ command: '$RYZEN_MONITOR_READ_CMD_USER'"

read -r -p "Enter grep pattern for TEMP line in ryzen_monitor output: [$DEFAULT_RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP] " RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP_USER
RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP_USER=${RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP_USER:-$DEFAULT_RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP}
read -r -p "Enter field name for TEMP on that line: [$DEFAULT_RYZEN_MONITOR_TEMP_FIELD_NAME] " RYZEN_MONITOR_TEMP_FIELD_NAME_USER
RYZEN_MONITOR_TEMP_FIELD_NAME_USER=${RYZEN_MONITOR_TEMP_FIELD_NAME_USER:-$DEFAULT_RYZEN_MONITOR_TEMP_FIELD_NAME}

read -r -p "Enter grep pattern for POWER line in ryzen_monitor output: [$DEFAULT_RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER] " RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER_USER
RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER_USER=${RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER_USER:-$DEFAULT_RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER}
read -r -p "Enter field name for POWER on that line: [$DEFAULT_RYZEN_MONITOR_POWER_FIELD_NAME] " RYZEN_MONITOR_POWER_FIELD_NAME_USER
RYZEN_MONITOR_POWER_FIELD_NAME_USER=${RYZEN_MONITOR_POWER_FIELD_NAME_USER:-$DEFAULT_RYZEN_MONITOR_POWER_FIELD_NAME}

# Fan RPM Detection
CPU_FAN_RPM_FILE=""
# ... (Standard fan detection logic - kept concise for brevity)
NCT_HWMON_DEVICE_PATH=""; for hwmon_dir in /sys/class/hwmon/hwmon*; do if [ -f "$hwmon_dir/name" ] && grep -q "nct6793" "$hwmon_dir/name" 2>/dev/null; then NCT_HWMON_DEVICE_PATH="$hwmon_dir"; break; fi; done
if [ -n "$NCT_HWMON_DEVICE_PATH" ]; then POTENTIAL_FAN2_PATH="$NCT_HWMON_DEVICE_PATH/fan2_input"; if [ -f "$POTENTIAL_FAN2_PATH" ] && [ -r "$POTENTIAL_FAN2_PATH" ]; then CPU_FAN_RPM_FILE="$POTENTIAL_FAN2_PATH"; fi; fi
if [ -z "$CPU_FAN_RPM_FILE" ] || [ ! -f "$CPU_FAN_RPM_FILE" ]; then CPU_FAN_RPM_FILE_GENERIC=$(find_sensor_file "" "cpu_fan|fan1|fan2" "fan" "CPU Fan RPM (Generic)"); if [ -n "$CPU_FAN_RPM_FILE_GENERIC" ] && [ -f "$CPU_FAN_RPM_FILE_GENERIC" ]; then CPU_FAN_RPM_FILE="$CPU_FAN_RPM_FILE_GENERIC"; else CPU_FAN_RPM_FILE=$(find_sensor_file "" "" "fan" "CPU Fan RPM (Absolute Fallback)"); fi; fi

echo -e "\n--- Sensor Configuration Summary ---"
echo "CPU Temperature: From '$RYZEN_MONITOR_READ_CMD_USER', line matching '$RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP_USER', field '$RYZEN_MONITOR_TEMP_FIELD_NAME_USER'"
echo "CPU Power: From '$RYZEN_MONITOR_READ_CMD_USER', line matching '$RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER_USER', field '$RYZEN_MONITOR_POWER_FIELD_NAME_USER'"
if [ -n "$CPU_FAN_RPM_FILE" ] && [ -f "$CPU_FAN_RPM_FILE" ] ; then echo "CPU Fan RPM Path: $CPU_FAN_RPM_FILE"; else echo "CPU Fan RPM: Not found/Not logging"; CPU_FAN_RPM_FILE=""; fi
echo "------------------------------------"

# --- User Inputs for PPT Control ---
read -r -p "Do you want to control CPU PPT limits during tests? (y/N): " CONTROL_PPT
if [[ "$CONTROL_PPT" =~ ^[Yy]$ ]]; then
    read -r -p "Enter BASE command for SETTING PPT (e.g., ryzenadj): [$DEFAULT_PPT_CONTROL_CMD_BASE] " PPT_CONTROL_CMD_BASE
    PPT_CONTROL_CMD_BASE=${PPT_CONTROL_CMD_BASE:-$DEFAULT_PPT_CONTROL_CMD_BASE}
    PPT_CONTROL_CMD_BASE_EXE=$(echo "$PPT_CONTROL_CMD_BASE" | awk '{print $1}')
    if ! command -v "$PPT_CONTROL_CMD_BASE_EXE" &> /dev/null || [ ! -x "$(command -v "$PPT_CONTROL_CMD_BASE_EXE")" ]; then
        echo "Error: PPT control command base '$PPT_CONTROL_CMD_BASE_EXE' not found/executable. Disabling PPT control." >&2; CONTROL_PPT="n"
    else
        read -r -p "Enter argument format for SETTING PPT (e.g., --ppt-limit=): [$DEFAULT_PPT_SET_ARG_FORMAT] " PPT_SET_ARG_FORMAT
        PPT_SET_ARG_FORMAT=${PPT_SET_ARG_FORMAT:-$DEFAULT_PPT_SET_ARG_FORMAT}
        read -r -p "Enter PPT values (in Watts) to test (space separated, e.g., \"35 45 55\"): " PPT_VALUES_STR
        read -a PPT_VALUES_TO_TEST <<< "$PPT_VALUES_STR"
        if [ ${#PPT_VALUES_TO_TEST[@]} -eq 0 ]; then echo "No PPT values. Disabling PPT control." >&2; CONTROL_PPT="n"; fi
        read -r -p "Enter PPT value to RESET to after tests (e.g., 65 or 0 for auto): " PPT_RESET_VALUE
        if ! [[ "$PPT_RESET_VALUE" =~ ^[0-9]+$ ]]; then echo "Invalid reset PPT. Will not reset."; PPT_RESET_VALUE=""; fi
    fi
fi

# --- User Inputs for mprime Stress Testing ---
if [[ "$CONTROL_PPT" =~ ^[Yy]$ ]]; then # If controlling PPT, mprime is an option to ensure load
    read -r -p "Do you want to run mprime in the background during PPT tests? (y/N): " USE_MPRIME
    if [[ "$USE_MPRIME" =~ ^[Yy]$ ]]; then
        read -r -p "Enter full path to mprime executable: " MPRIME_PATH
        if [ ! -x "$MPRIME_PATH" ]; then echo "Error: mprime not found/executable. Disabling mprime." >&2; USE_MPRIME="n"; else
            read -r -p "Enter mprime thread count to use for ALL PPT tests: " MPRIME_THREAD_COUNTS_FOR_PPT_TESTS
            if ! [[ "$MPRIME_THREAD_COUNTS_FOR_PPT_TESTS" =~ ^[0-9]+$ ]] || [ "$MPRIME_THREAD_COUNTS_FOR_PPT_TESTS" -eq 0 ]; then
                 echo "Invalid mprime thread count. Disabling mprime." >&2; USE_MPRIME="n"; fi
        fi
    fi
elif [[ "$CONTROL_PPT" != "y" && "$CONTROL_PPT" != "Y" ]]; then # Only ask to iterate mprime threads if PPT control is OFF
    read -r -p "Do you want to run mprime stress tests (iterating through thread counts)? (y/N): " USE_MPRIME
    if [[ "$USE_MPRIME" =~ ^[Yy]$ ]]; then
        read -r -p "Enter full path to mprime executable: " MPRIME_PATH
        if [ ! -x "$MPRIME_PATH" ]; then echo "Error: mprime not found/executable. Disabling mprime." >&2; USE_MPRIME="n"; else
            read -r -p "Enter mprime thread counts to iterate (space separated, e.g., \"1 2 4 8\"): " MPRIME_THREAD_COUNTS_STR
            read -a MPRIME_THREAD_COUNTS_ITERATE <<< "$MPRIME_THREAD_COUNTS_STR"
            if [ ${#MPRIME_THREAD_COUNTS_ITERATE[@]} -eq 0 ]; then echo "No mprime threads for iteration. Disabling mprime." >&2; USE_MPRIME="n"; fi
        fi
    fi
fi

if [[ "$CONTROL_PPT" =~ ^[Yy]$ ]] && [[ ! "$USE_MPRIME" =~ ^[Yy]$ ]]; then
    echo "WARNING: PPT control is enabled, but mprime (or other load generation) is not."
    echo "Ensure you run a CPU stress test MANUALLY in the background for PPT limits to be effective."
fi
if [[ "$USE_MPRIME" =~ ^[Yy]$ ]]; then
    echo "IMPORTANT: Ensure mprime (e.g. prime.txt) is configured for the desired test type (e.g. Small FFTs)."
    read -r -p "Warm-up duration (s) [${WARMUP_DURATION}]: " W_D; WARMUP_DURATION=${W_D:-$WARMUP_DURATION}
    read -r -p "Measurement duration per test (s) [${MEASUREMENT_DURATION}]: " M_D; MEASUREMENT_DURATION=${M_D:-$MEASUREMENT_DURATION}
    read -r -p "Cool-down duration after each test (s) [${COOLDOWN_DURATION}]: " C_D; COOLDOWN_DURATION=${C_D:-$COOLDOWN_DURATION}
fi

# --- User Inputs for Logging File & Interval ---
read -r -p "Enter output CSV file name [${DEFAULT_OUTPUT_FILE}]: " OUTPUT_FILE; OUTPUT_FILE=${OUTPUT_FILE:-$DEFAULT_OUTPUT_FILE}
read -r -p "Enter sampling interval (s) [${DEFAULT_SAMPLING_INTERVAL_S}]: " SAMPLING_INTERVAL_S; SAMPLING_INTERVAL_S=${SAMPLING_INTERVAL_S:-$DEFAULT_SAMPLING_INTERVAL_S}
if ! [[ "$SAMPLING_INTERVAL_S" =~ ^[0-9]+([.][0-9]+)?$ ]] || (( $(echo "$SAMPLING_INTERVAL_S <= 0" | bc -l) )); then SAMPLING_INTERVAL_S=$DEFAULT_SAMPLING_INTERVAL_S; fi
AMBIENT_TEMP_C=""; while true; do read -r -p "Ambient temp (°C): " AMBIENT_TEMP_C; if [[ "$AMBIENT_TEMP_C" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then break; else echo "Invalid."; fi; done

# --- Initialize Logging File ---
if [ -f "$OUTPUT_FILE" ]; then read -r -p "'$OUTPUT_FILE' exists. Overwrite? (y/N): " O; if [[ ! "$O" =~ ^[Yy]$ ]]; then echo "Exiting."; cleanup_all; fi; fi
HEADER="Timestamp,CPU_Power_W_Actual,CPU_Temp_C"; if [ -n "$CPU_FAN_RPM_FILE" ]; then HEADER+=",CPU_Fan_RPM"; fi
HEADER+=",Ambient_Temp_C"
if [[ "$CONTROL_PPT" =~ ^[Yy]$ ]]; then HEADER+=",Set_PPT_W"; fi
if [[ "$USE_MPRIME" =~ ^[Yy]$ ]]; then HEADER+=",Mprime_Threads"; fi
echo "$HEADER" > "$OUTPUT_FILE"

# --- Data Logging Function ---
log_data_segment() { # Renamed from log_data_for_duration for clarity
    local duration_seconds="$1"; local current_set_ppt="$2"; local current_mprime_threads="$3"
    local start_time_log_func=$SECONDS; local elapsed_time=0; local samples_taken=0
    echo "Logging data for $duration_seconds seconds (Set PPT: $current_set_ppt W, Mprime Threads: $current_mprime_threads)..."
    
    local ryzen_monitor_read_active_for_segment=false 
    if [ -n "$RYZEN_MONITOR_READ_CMD_USER" ]; then 
        if start_ryzen_monitor_read_background "$RYZEN_MONITOR_READ_CMD_USER"; then
            ryzen_monitor_read_active_for_segment=true
        else echo "Critical Error: Failed to start ryzen_monitor READ. CPU Temp/Power will be RMStartFail." >&2; fi
    else echo "Critical Error: RYZEN_MONITOR_READ_CMD_USER is not set." >&2; fi

    while (( elapsed_time < duration_seconds )); do
        current_time_for_log=$(date +"%Y-%m-%d %H:%M:%S.%3N"); cpu_temp_c="N/A"; cpu_power_w_actual="N/A" 
        if $ryzen_monitor_read_active_for_segment; then
            val_temp=$(read_ryzen_monitor_metric_from_file "$RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL" "$RYZEN_MONITOR_TARGET_LINE_PATTERN_TEMP_USER" "$RYZEN_MONITOR_TEMP_FIELD_NAME_USER")
            if [ -n "$val_temp" ]; then cpu_temp_c=$val_temp; else cpu_temp_c="ReadErrRMThm"; fi
            val_power=$(read_ryzen_monitor_metric_from_file "$RYZEN_MONITOR_READ_OUTPUT_FILE_GLOBAL" "$RYZEN_MONITOR_TARGET_LINE_PATTERN_POWER_USER" "$RYZEN_MONITOR_POWER_FIELD_NAME_USER")
            if [ -n "$val_power" ]; then cpu_power_w_actual=$val_power; else cpu_power_w_actual="ReadErrRMPpt"; fi
        else cpu_temp_c="RMStartFail"; cpu_power_w_actual="RMStartFail"; fi
        
        fan_rpm_to_log="N/A"; if [ -n "$CPU_FAN_RPM_FILE" ] && [ -f "$CPU_FAN_RPM_FILE" ]; then val=$(cat "$CPU_FAN_RPM_FILE" 2>/dev/null); fan_rpm_to_log=${val:-0}; if ! [[ "$fan_rpm_to_log" =~ ^[0-9]+$ ]]; then fan_rpm_to_log=0; fi; fi
        
        LOG_LINE="$current_time_for_log,$cpu_power_w_actual,$cpu_temp_c"; CONSOLE_LINE="Logged: P_act=${cpu_power_w_actual}W, T=${cpu_temp_c}C"
        if [ -n "$CPU_FAN_RPM_FILE" ]; then LOG_LINE+=",$fan_rpm_to_log"; CONSOLE_LINE+=", F=${fan_rpm_to_log}RPM"; else LOG_LINE+=",N/A"; CONSOLE_LINE+=", F=N/A"; fi
        LOG_LINE+=",$AMBIENT_TEMP_C"; CONSOLE_LINE+=", Amb=${AMBIENT_TEMP_C}C"
        if [ "$current_set_ppt" != "N/A" ]; then LOG_LINE+=",$current_set_ppt"; CONSOLE_LINE+=", SetPPT=${current_set_ppt}W"; fi
        if [ "$current_mprime_threads" != "N/A" ]; then LOG_LINE+=",$current_mprime_threads"; CONSOLE_LINE+=", MprimeThr=$current_mprime_threads"; fi
        
        echo "$LOG_LINE" >> "$OUTPUT_FILE"; printf "%s\r" "$CONSOLE_LINE"
        samples_taken=$((samples_taken + 1)); sleep "$SAMPLING_INTERVAL_S"; elapsed_time=$((SECONDS - start_time_log_func))
    done
    echo; echo "Finished logging segment ($samples_taken samples over $elapsed_time seconds)."
    if $ryzen_monitor_read_active_for_segment; then stop_ryzen_monitor_read_background; fi
}

# --- Main Test Orchestration ---
if [[ "$CONTROL_PPT" =~ ^[Yy]$ ]]; then # PPT Control is ON
    echo "Starting PPT control test sequence..."
    if [[ "$USE_MPRIME" =~ ^[Yy]$ ]]; then
        echo "mprime will run with $MPRIME_THREAD_COUNTS_FOR_PPT_TESTS threads during PPT tests."
    else
        echo "WARNING: PPT control is enabled, but mprime is not. Ensure a manual CPU stress test is running."
    fi

    for ppt_val in "${PPT_VALUES_TO_TEST[@]}"; do
        echo -e "\n--- Processing PPT: $ppt_val W ---"
        SET_CMD_FULL="$PPT_CONTROL_CMD_BASE $PPT_SET_ARG_FORMAT$ppt_val"
        echo "Setting PPT: $SET_CMD_FULL"
        eval "$SET_CMD_FULL"
        if [ $? -ne 0 ]; then echo "Warning: Command to set PPT to $ppt_val W failed. Skipping." >&2; continue; fi

        current_mprime_threads_for_log="N/A"
        if [[ "$USE_MPRIME" =~ ^[Yy]$ ]]; then
            current_mprime_threads_for_log="$MPRIME_THREAD_COUNTS_FOR_PPT_TESTS"
            echo "Starting mprime with $current_mprime_threads_for_log threads..."
            "$MPRIME_PATH" -m"$current_mprime_threads_for_log" -t > /dev/null 2>&1 & MPRIME_PID_GLOBAL=$!
            sleep 1 
            if ! ps -p "$MPRIME_PID_GLOBAL" > /dev/null; then
                echo "Error: Failed to start mprime. Skipping this PPT test."; MPRIME_PID_GLOBAL=""; continue; fi
            echo "mprime started (PID: $MPRIME_PID_GLOBAL)."
        fi
        
        echo "Warming up for $WARMUP_DURATION seconds..."
        sleep "$WARMUP_DURATION"
        log_data_segment "$MEASUREMENT_DURATION" "$ppt_val" "$current_mprime_threads_for_log" 
        
        if [[ "$USE_MPRIME" =~ ^[Yy]$ ]] && [ -n "$MPRIME_PID_GLOBAL" ]; then
            echo "Stopping mprime (PID: $MPRIME_PID_GLOBAL)..."; kill "$MPRIME_PID_GLOBAL"; wait "$MPRIME_PID_GLOBAL" 2>/dev/null
            MPRIME_PID_GLOBAL=""; echo "mprime stopped."
        fi
        if [[ "$ppt_val" != "${PPT_VALUES_TO_TEST[-1]}" ]]; then 
            echo "Cooling down for $COOLDOWN_DURATION seconds..."; sleep "$COOLDOWN_DURATION"; fi
    done
    echo -e "\nAll PPT control tests complete."

elif [[ "$USE_MPRIME" =~ ^[Yy]$ ]]; then # PPT Control is OFF, mprime is ON
    echo "Starting mprime load test sequence (iterating mprime threads)..."
    for threads in "${MPRIME_THREAD_COUNTS_ITERATE[@]}"; do
        echo -e "\n--- Starting mprime test with $threads threads ---"
        "$MPRIME_PATH" -m"$threads" -t > /dev/null 2>&1 & MPRIME_PID_GLOBAL=$!
        sleep 1 
        if ! ps -p "$MPRIME_PID_GLOBAL" > /dev/null; then
            echo "Error: Failed to start mprime with $threads threads. Skipping."; MPRIME_PID_GLOBAL=""; continue; fi
        echo "mprime started (PID: $MPRIME_PID_GLOBAL) for $threads threads."
        echo "Warming up for $WARMUP_DURATION seconds..."; sleep "$WARMUP_DURATION"
        log_data_segment "$MEASUREMENT_DURATION" "N/A" "$threads" 
        echo "Stopping mprime (PID: $MPRIME_PID_GLOBAL)..."; kill "$MPRIME_PID_GLOBAL"; wait "$MPRIME_PID_GLOBAL" 2>/dev/null
        MPRIME_PID_GLOBAL=""; echo "mprime stopped."
        if [[ "$threads" != "${MPRIME_THREAD_COUNTS_ITERATE[-1]}" ]]; then 
            echo "Cooling down for $COOLDOWN_DURATION seconds..."; sleep "$COOLDOWN_DURATION"; fi
    done
    echo -e "\nAll mprime iteration tests complete."
else # BOTH PPT Control and mprime are OFF - Continuous Logging
    echo "No PPT control or mprime tests. Starting continuous data logging. Press Ctrl+C to stop."
    log_data_segment 999999999 "N/A" "N/A" 
fi

cleanup_all 
