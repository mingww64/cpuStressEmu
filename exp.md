# Experiment Details

## 1. Objective
To check out the thermal characteristics of the CPU cooling solution under **different** power limits (Package Power Target - PPT) while keeping the computational load the **same**. One of the main things that came out of this was the **thermal resistance model** of this specific cooling solution.

## 2. System and Hardware
* **CPU**: AMD Ryzen 4650G 65W TDP (max out at 51W)
* **Cooler**: Noctua NH-L9a Fan & Heatsink


## 3. Configuration & Control Software

The experiment was orchestrated using a BASH script [`emu.sh`](https://github.com/mingww64/cpuStressEmu/blob/main/emu.sh).

<details>
<summary>Click to expand/collapse the emu.sh script</summary>

```bash

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
```

</details> 


### 3.1. Sensor Monitoring
* **CPU Temperature & Power:**
    * kernel module `ryzen_smu` with utility `ryzen_monitor`

* **CPU Fan RPM:**
    * hwmon

### 3.2. CPU Power Control (PPT)
* **Utility:** `ryzen_monitor`
* **Argument Format for Setting PPT:** `--set-ppt=`
* **PPT Values Tested (Watts):** 15~55 with resolution of 1w.

### 3.3. CPU Load Generation
* **Load Generation:** stress test using `mprime` in the background.
* **`mprime` Thread Count:** 6 threads (with hyperthearding, used for all PPT tests).

## 4. Test Protocol
This is a summary of a series of process repeated for each PPT value.

* **Warm-up Duration:** 30 seconds.
* **Measurement Duration per Test:** 30 seconds.
* **Cool-down Duration after each Test:** 0 seconds. *Practically unnecessary as PPTs are incremental and heat are supposed to rise between tests.*
* **Output CSV File Name:** `cpu_cooling_data_controlled.csv`.
* **Sampling Interval:** 1 second.
* **Ambient Temperature (at start of test sequence):** 22.8 °C.

## 5. Procedure Summary

1.  Set the CPU PPT limit using the configured `ryzen_monitor` command.
2.  If enabled, start `mprime` with the specified number of threads.
3.  Wait for the warm-up duration to allow temperatures to stabilize.
4.  During the measurement duration, periodically (based on sampling interval):
    * Read CPU temperature $T_{case}$.
    * Read CPU power $P_{cpu}$.
    * Read CPU fan RPM.
    * Record these values along with the ambient temperature $T_{ambient}$ and current timestamp to the CSV file.
5.  Stop `mprime` (if running).
6.  Wait for the cool-down duration (if any).
7.  Repeat for the next PPT value.
8.  After all tests, reset the CPU PPT to the specified reset value.

## 6. Thermal Resistance Model Development

### 6.1. Thermal Resistance Calculation
For each data point collected, the overall thermal resistance $R_{th}$ of the cooling system was calculated using the fundamental relationship:

$R_{th} = (T_{case} - T_{ambient}) / P_{cpu}$

Where $T_{case}$ is the CPU temperature, $T_{ambient}$ is the intake air temperature, and $P_{cpu}$ is the actual CPU power consumed.

### 6.2. Physics-Informed Model Structure
A physics-informed model was chosen to describe the relationship between thermal resistance and CPU fan RPM (airflow). The model structure is:

$R_{th}(RPM) = R_{fixed} + C / RPM^n$

Where:
* **$R_{fixed}$**: Represents the sum of thermal resistances that are largely independent of airflow, such as conduction through Thermal Interface Materials (TIMs), the CPU's Integrated Heat Spreader (IHS), and the cooler's baseplate.
* **$C / RPM^n$**: Represents the convective thermal resistance from the heatsink fins to the air. This component is highly dependent on airflow.
    * **$C$**: A constant related to the heat sink geometry, material properties, and fluid (air) properties.
    * **$n$**: An exponent characterizing the relationship between airflow velocity (assumed proportional to RPM) and the convective heat transfer coefficient. Theoretical values for $n$ often range from 0.5 (laminar flow) to 0.8 (turbulent flow).

### 6.3. Model Fitting
The model parameters $R_{fixed}$, $C$, and $n$ were determined by fitting the model equation to the experimentally derived $RPM$, $R_{th}$ data points. This was achieved using a non-linear least squares regression algorithm (specifically, `scipy.optimize.curve_fit` in the Python [analysis](https://github.com/mingww64/cpuStressEmu/blob/main/fit.py)).

The fitted parameters obtained from the analysis were approximately:
* $R_{fixed} \approx 0.0000 \, °C/W$
* $C \approx 12.0157$
* $n \approx 0.3467$

### 6.3.1. Pseudo-code for Model Fitting (`fit.py`)
The following pseudo-code outlines the algorithm used in `fit.py` to determine the model parameters:
<details>
    <summary>Click to expand/collapse pseudo-code</summary>

```psudocode
BEGIN SCRIPT fit.py

  // 1. Load and Prepare Data

  Extract RPM data (x_data_raw) from DataFrame using expected_rpm_column_name.
  Extract Thermal Resistance data (y_data_raw) from DataFrame using expected_rth_column_name.

  Sort x_data_raw and y_data_raw based on x_data_raw values (ascending RPM) to get sorted_x_data and sorted_y_data.

  // 2. Define the Model Function
  FUNCTION thermal_resistance_model(rpm, r_fixed, c, n)
    // This function implements: R_th(RPM) = R_fixed + C / RPM^n
    RETURN r_fixed + c / (rpm POWER n)
  END FUNCTION

  // 3. Set up for Curve Fitting
  //    Initial guesses are based on observed data characteristics:
  //    - r_fixed_guess: A fraction of the minimum observed thermal resistance.
  //    - c_guess: Derived from the range of thermal resistance and a mid-range RPM value.
  //    - n_guess: A common empirical value (e.g., 0.7).
  Define initial_guesses_for_parameters = [r_fixed_guess, c_guess, n_guess]

  //    Bounds constrain the search space for parameters:
  //    - r_fixed: Must be non-negative.
  //    - C: Must be non-negative.
  //    - n: Typically between 0.1 and 1.5 based on physical expectations.
  Define lower_bounds_for_parameters = [0, 0, 0.1]
  Define upper_bounds_for_parameters = [max(sorted_y_data), PositiveInfinity, 1.5]

  Initialize fitted_parameters = null
  Initialize model_fit_successful = false

  // 4. Perform Curve Fitting
  TRY
    // Use a non-linear least squares method (e.g., Levenberg-Marquardt via scipy.optimize.curve_fit)
    // to find parameters that best fit the thermal_resistance_model to the data.
    fitted_parameters, covariance_matrix = curve_fit(
                                              function_to_fit = thermal_resistance_model,
                                              x_values = sorted_x_data,
                                              y_values = sorted_y_data,
                                              initial_parameter_guesses = initial_guesses_for_parameters,
                                              parameter_bounds = (lower_bounds_for_parameters, upper_bounds_for_parameters),
                                              max_function_evaluations = 5000 // Allow sufficient iterations
                                           )
    Extract r_fixed_fit, c_fit, n_fit from fitted_parameters.
    model_fit_successful = true
    Print "Fitted Model Parameters:"
    Print "  R_fixed = ", r_fixed_fit
    Print "  C = ", c_fit
    Print "  n = ", n_fit

    // Calculate y-values predicted by the fitted model for plotting
    Calculate y_model_predictions = thermal_resistance_model(sorted_x_data, r_fixed_fit, c_fit, n_fit)

  // 5. Plot Experimental Data and Fitted Model
  Create a new plot figure.
  Plot a scatter plot of (sorted_x_data, sorted_y_data) representing "Experimental Data".

  IF model_fit_successful THEN
    Plot a line plot of (sorted_x_data, y_model_predictions) representing the "Fitted Model".
    Include fitted parameter values in the legend or title for the model.
  END IF

  Set plot title (e.g., "Thermal Resistance vs. CPU Fan RPM").
  Set X-axis label (e.g., "CPU Fan RPM (RPM)").
  Set Y-axis label (e.g., "Thermal Resistance (°C/W)").
  Add a legend to the plot.
  Add a grid to the plot for readability.
  Save the plot to an image file (e.g., "thermal_resistance_model_fit.png").

  // 6. "Sweet Spot" Analysis (if model fit was successful)
  IF model_fit_successful THEN
    // Calculate the derivative of the fitted model with respect to RPM:
    // d(R_th)/d(RPM) = -n_fit * c_fit * RPM^(-n_fit - 1)
    Calculate derivative_values = -n_fit * c_fit * (sorted_x_data POWER (-n_fit - 1)).

    Create a new plot figure for the derivative.

    TRY
      // Identify a "sweet spot" or region of diminishing returns.
      // This is where the negative slope of R_th vs RPM becomes significantly flatter.
      // Example heuristic: Find where the derivative is, say, 10% of its maximum absolute value
      // (most negative value) observed in the lower RPM range.
      Calculate max_abs_derivative_at_low_rpm = max(absolute_value(derivative_values for x_data in first 20% of RPM range)).
      Define sweet_spot_threshold_derivative = -0.1 * max_abs_derivative_at_low_rpm.

      Find potential_sweet_spot_rpm = last x_data value where derivative_value < sweet_spot_threshold_derivative.
      // This RPM indicates a point beyond which increasing fan speed yields much smaller reductions in R_th.

      IF potential_sweet_spot_rpm is found THEN
        Add a vertical line on the derivative plot at potential_sweet_spot_rpm, labeling it (e.g., "Potential Sweet Spot Zone").
        Print discussion about the potential sweet spot and its implications.
      ELSE
        Print "Could not programmatically identify a specific sweet spot with current logic."
      END IF
    CATCH AnyErrorDuringSweetSpotCalculation
      Print "Error during sweet spot analysis."
    END TRY

    Add a legend to the derivative plot.
    Add a grid to the derivative plot.
    Save the derivative plot to an image file (e.g., "thermal_resistance_derivative.png").
  END IF

  Print "Model fitting and analysis complete."
  Print "Plots saved."

END SCRIPT
```
</details>

---
This resulted in the specific model equation:

$R_{th}(RPM) \approx 0.0000 + 12.0157 / RPM^{0.3467}$

$R_{th}(RPM) \approx 12.0157 / RPM^{0.3467}$

The value of $R_{fixed}$ being close to zero suggests that, for this specific dataset and cooler, the airflow-dependent convective resistance is the dominant factor in the total thermal resistance, or that the fixed resistances are very small and effectively absorbed into the convective term by the fitting process. The exponent $n \approx 0.35$ indicates the sensitivity of the cooler's performance to changes in fan speed.
