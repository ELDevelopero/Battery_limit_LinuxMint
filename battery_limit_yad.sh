#!/usr/bin/env bash
# battery_limit_yad.sh (Smart Auto-Reduce Feature with Persistent Settings)

# Paths and files
POLKIT_RULE="/etc/polkit-1/rules.d/90-battery-charge.rules"
BATTERY_PATH="/sys/class/power_supply/BAT0/charge_control_end_threshold"
AC_PATH="/sys/class/power_supply/AC0/online"
ICON_PATH="/usr/share/icons/hicolor/64x64/apps/car_bat.png"
LOCKFILE="/tmp/battery_limit_yad.lock"         # For tray icon instance
MONITOR_PID_FILE="/tmp/battery_limit_monitor.pid"
TRAY_PID_FILE="/tmp/battery_limit_tray.pid"
RESET_FLAG="/tmp/battery_limit_reset.flag"
SMART_FEATURE_FLAG="$HOME/.battery_limit_smart.flag"
CONFIG_FILE="$HOME/.battery_limit_config"
APP_LOCK="$HOME/.battery_limit_app.lock"       # For main instance persistence
PGID_FILE="$HOME/.battery_limit_pg.pid"          # Stores main process group ID

# Lock file for the monitor process
MONITOR_LOCK="/tmp/battery_limit_monitor.lock"

# For testing: trigger auto‑reduce after 30 seconds
TIME_LIMIT=7200

# Defaults
DEFAULT_LIMIT=80           
REDUCED_LIMIT=75          
CURRENT_AC_TIME=0
LAST_AC_STATE=0

#############################################
# MAIN INSTANCE SETUP (when no argument is given)
#############################################
if [ -z "$1" ]; then
    # Check for a stale main instance lock.
    if [ -e "$APP_LOCK" ]; then
        if [ -f "$PGID_FILE" ]; then
            PGID=$(cat "$PGID_FILE")
            if pgrep -g "$PGID" >/dev/null 2>&1; then
                echo "Battery limit tray app is already running."
                exit 1
            else
                # No process in that group; remove stale locks.
                rm -f "$APP_LOCK" "$PGID_FILE"
            fi
        else
            rm -f "$APP_LOCK"
        fi
    fi
    touch "$APP_LOCK"
    trap "rm -f $APP_LOCK" EXIT

    # Make sure this instance becomes the process-group leader.
    PGID=$(ps -o pgid= $$ | tr -d ' ')
    echo "$PGID" > "$PGID_FILE"
    # When this process exits, kill its entire process group.
    trap "kill -- -$PGID" EXIT
fi

####################################################
# Initialize Smart Feature and Config
####################################################
if [ ! -f "$SMART_FEATURE_FLAG" ]; then
    echo "on" > "$SMART_FEATURE_FLAG"
fi
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$DEFAULT_LIMIT" > "$CONFIG_FILE"
fi

# Kill any previous tray icon instance.
pkill -f "yad --notification" >/dev/null 2>&1
sleep 1

# Prevent multiple tray icon instances using LOCKFILE.
if [[ -e "$LOCKFILE" ]]; then
    echo "Battery limit tray icon instance is already running."
    exit 1
fi
trap "rm -f $LOCKFILE" EXIT
touch "$LOCKFILE"

########################################
# FUNCTION DEFINITIONS
########################################

get_battery_limit() {
    if [[ -f "$CONFIG_FILE" ]]; then
        tr -d '\n' < "$CONFIG_FILE"
    elif [[ -f "$BATTERY_PATH" ]]; then
        tr -d '\n' < "$BATTERY_PATH"
    else
        echo "Unknown"
    fi
}

is_ac_plugged() {
    if [[ -f "$AC_PATH" ]]; then
        cat "$AC_PATH"
    else
        echo "0"
    fi
}

set_limit() {
    local LIMIT="$1"
    pkexec bash -c "echo $LIMIT > '$BATTERY_PATH'"
    echo "$LIMIT" > "$CONFIG_FILE"
    update_tray
}

reset_limit() {
    set_limit "100"
    touch "$RESET_FLAG"
}

show_limit_dialog() {
    CURRENT_LIMIT=$(get_battery_limit)  
    allowed_values="10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100"
    found=0
    for v in $allowed_values; do
        if [ "$v" = "$CURRENT_LIMIT" ]; then
            found=1
            break
        fi
    done
    if [ $found -eq 0 ]; then
        CURRENT_LIMIT="$DEFAULT_LIMIT"
    fi
    list="$CURRENT_LIMIT"
    for v in $allowed_values; do
        if [ "$v" != "$CURRENT_LIMIT" ]; then
            list="$list!$v"
        fi
    done

    SMART_STATE=$(tr -d '\n' < "$SMART_FEATURE_FLAG")
    if [ "$SMART_STATE" = "on" ]; then
        SMART_DEFAULT="TRUE"
    else
        SMART_DEFAULT="FALSE"
    fi

    # Checkbox comes first.
    result=$(yad --form --title="Battery Limit Settings (Current: $CURRENT_LIMIT%)" --width=400 --height=220 \
      --field="Smart Charge Adjust":CHK "$SMART_DEFAULT" \
      --field="Battery Limit:CB" "$list" "$CURRENT_LIMIT" \
      --field="If Smart Charge Adjust is enabled, when on AC power too long and your battery limit is ≥80%, it will automatically lower to 75%.":LBL)
    
    if [ -z "$result" ]; then
        update_tray
        return
    fi

    CHK_STATE=$(echo "$result" | cut -d'|' -f1)
    NEW_LIMIT=$(echo "$result" | cut -d'|' -f2)
    
    if [ "$CHK_STATE" = "TRUE" ]; then
        echo "on" > "$SMART_FEATURE_FLAG"
    else
        echo "off" > "$SMART_FEATURE_FLAG"
    fi

    if [ "$NEW_LIMIT" != "$CURRENT_LIMIT" ]; then
        set_limit "$NEW_LIMIT"
        touch "$RESET_FLAG"
    else
        update_tray
    fi
}

update_tray() {
    local CURRENT_LIMIT
    CURRENT_LIMIT=$(get_battery_limit)

    if [[ -f "$TRAY_PID_FILE" ]]; then
       old_pid=$(cat "$TRAY_PID_FILE")
       if kill -0 "$old_pid" 2>/dev/null; then
          kill "$old_pid"
          sleep 1
       fi
       rm -f "$TRAY_PID_FILE"
    fi
    yad --notification --image="$ICON_PATH" --text="🔋 Battery set at: $CURRENT_LIMIT%" \
         --command="bash -c '$HOME/battery_limit_yad.sh show_limit_dialog'" \
         --menu="Reset to 100%!bash -c '$HOME/battery_limit_yad.sh reset_limit'|Quit!bash -c '$HOME/battery_limit_yad.sh quit_tray'" &
    echo $! > "$TRAY_PID_FILE"
}

# --- Restored monitor_ac_usage function ---
monitor_ac_usage() {
    RUN_MONITOR=1
    trap "RUN_MONITOR=0" SIGTERM SIGINT
    exec 200>"$MONITOR_LOCK"
    flock -n 200 || exit 0
    echo $$ > "$MONITOR_PID_FILE"
    while [ "$RUN_MONITOR" -eq 1 ]; do
        if [[ -f "$RESET_FLAG" ]]; then
            CURRENT_AC_TIME=0
            rm -f "$RESET_FLAG"
        fi
        AC_STATE=$(is_ac_plugged)
        if [[ "$AC_STATE" == "1" ]]; then
            if [[ "$LAST_AC_STATE" == "0" ]]; then
                CURRENT_AC_TIME=0
            fi
            current_limit=$(get_battery_limit)
            smart=$(tr -d '\n' < "$SMART_FEATURE_FLAG")
            if [[ "$smart" == "on" && "$current_limit" -ge 80 ]]; then
                CURRENT_AC_TIME=$((CURRENT_AC_TIME + 1))
                remaining=$((TIME_LIMIT - CURRENT_AC_TIME))
                [ $remaining -lt 0 ] && remaining=0
                # (If needed, you could store remaining in a TIMER_FILE for debugging)
                if [[ "$CURRENT_AC_TIME" -ge "$TIME_LIMIT" && "$current_limit" -ne "$REDUCED_LIMIT" ]]; then
                    set_limit "$REDUCED_LIMIT"
                    CURRENT_AC_TIME=0
                    update_tray
                fi
            else
                CURRENT_AC_TIME=0
            fi
        else
            if [[ "$LAST_AC_STATE" == "1" ]]; then
                CURRENT_AC_TIME=0
                if [[ "$(get_battery_limit)" -ne "$DEFAULT_LIMIT" ]]; then
                    set_limit "$DEFAULT_LIMIT"
                fi
            fi
        fi
        LAST_AC_STATE="$AC_STATE"
        sleep 1
    done
    rm -f "$MONITOR_PID_FILE" "$MONITOR_LOCK"
    exit 0
}
# --- End monitor_ac_usage function ---

quit_tray() {
    if [ -f "$PGID_FILE" ]; then
        PGID=$(cat "$PGID_FILE")
        kill -- -$PGID 2>/dev/null
        while pgrep -g "$PGID" >/dev/null 2>&1; do
            sleep 1
        done
        rm -f "$PGID_FILE"
    fi
    rm -f "$TRAY_PID_FILE"
    exit 0
}

force_quit() {
    echo "Force quitting battery_limit_yad.sh..."
    if [ -f "$PGID_FILE" ]; then
        PGID=$(cat "$PGID_FILE")
        kill -- -$PGID 2>/dev/null
        while pgrep -g "$PGID" >/dev/null 2>&1; do
            sleep 1
        done
        rm -f "$PGID_FILE"
    fi
    rm -f "$APP_LOCK" "$LOCKFILE" "$MONITOR_PID_FILE" "$TRAY_PID_FILE"
    echo "Force quit complete."
    exit 0
}

########################################
# MAIN CLI HANDLING
########################################

case "$1" in
    set_limit)
        set_limit "$2"
        ;;
    reset_limit)
        reset_limit
        ;;
    show_limit_dialog)
        show_limit_dialog
        ;;
    quit_tray)
        quit_tray
        ;;
    force_quit)
        force_quit
        ;;
    monitor_ac_usage)
        monitor_ac_usage
        ;;
    *)
        set_limit "$(get_battery_limit)"
        update_tray
        monitor_ac_usage &
        ;;
esac

