#!/bin/bash
# opensvc_monitor.sh - tmux monitoring SCRIPT_TEMP for OpenSVC maintenance scripts
# Usage: opensvc_monitor.sh <command> [args...]
# Author.: adriano.costa
# Version: 20260419
#
# Commands:
#   switch    <SERVICE>
#   extension <FS> <SIZE_GB>
#   add_fs    <SERVICE> <FS> [SIZE_GB] [FSTYPE]
#   remove_fs <FS>

#######################################################################
# Functions
#######################################################################

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <command> [args...]"
    echo ""
    echo "  Commands:"
    echo "    ${SCRIPT} switch              <SERVICE>"
    echo "    ${SCRIPT} extension           <FS> <SIZE_GB>"
    echo "    ${SCRIPT} add_fs              <SERVICE> <FS> [SIZE_GB] [FSTYPE]"
    echo "    ${SCRIPT} remove_fs           <FS>"
    echo "    ${SCRIPT} add_app             <SERVICE> <APP_PATH> [APP_NAME]"
    echo "    ${SCRIPT} remove_app          <SERVICE> <APP_PATH>"
    echo "    ${SCRIPT} create_svc          <SERVICE> <INTERFACE> <IP>"
    echo "    ${SCRIPT} deactivate          <SERVICE> [CHANGE]"
    echo "    ${SCRIPT} decommission_svc    <SERVICE>"
    echo "    ${SCRIPT} decommission_cluster"
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} switch           SERVICE_NAME"
    echo "    ${SCRIPT} extension        /SERVICE_NAME/data 50"
    echo "    ${SCRIPT} add_fs           SERVICE_NAME /SERVICE_NAME/newfs 10"
    echo "    ${SCRIPT} remove_fs        /SERVICE_NAME/test0"
    echo "    ${SCRIPT} add_app          SERVICE_NAME /SERVICE_NAME/bin/start.sh"
    echo "    ${SCRIPT} create_svc       sltifraxssvc7 bond0 100.100.100.100/255.255.255.0"
    echo "    ${SCRIPT} deactivate       SERVICE_NAME CHG0012345"
    echo "    ${SCRIPT} decommission_svc SERVICE_NAME"
    echo ""
    exit 1
}

# -------------------
install_tmux()
# -------------------
{
    command -v tmux >/dev/null 2>&1 && return 0
    echo "Installing pre-requisite: tmux..."
    dnf -q install -y tmux > /tmp/dnf.log 2>&1
    return $?
}

# -------------------
send_monitor()
# -------------------
{
    local PANE="$1" CMD="$2"
    [[ -z "$PANE" || -z "$CMD" ]] && return 0
    tmux send-keys -t "$PANE" "$CMD" C-m
}

# -------------------
set_pane_title()
# -------------------
# Description: Set a descriptive title on a tmux pane (visible in border).
#              Requires tmux >= 2.3 for pane-border-status.
#              Silently ignored on older versions.
#
#   $1  = PANE  - pane ID
#   $2  = TITLE - title string
# -------------------
{
    local PANE="$1" TITLE="$2"
    [[ -z "$PANE" || -z "$TITLE" ]] && return 0
    tmux select-pane -t "$PANE" -T "$TITLE" 2>/dev/null || true
}

# -------------------
new_pane()
# -------------------
# Description: Split a tmux pane and return the new pane ID.
#              Handles three generations of tmux syntax:
#                < 2.1  : no -P flag  -> split then display-message
#               >= 2.1  : -P -F available, size with -p PERCENT
#               >= 3.1  : size with -l PERCENT% (preferred)
#
#   $1  = DIRECTION  - -h (horizontal) or -v (vertical)
#   $2  = PERCENT    - size of new pane as percentage
#   $3  = TARGET     - target pane ID
#
# RC: (none - prints pane ID or empty string on error)
# -------------------
{
    local DIRECTION="$1" PERCENT="$2" TARGET="$3"
    local PANE_ID TMUX_MAJ TMUX_MIN

    # Parse version safely - strips prefixes like "next-" and suffixes like "a"
    TMUX_MAJ=$(tmux -V | grep -oP '\d+' | head -1)
    TMUX_MIN=$(tmux -V | grep -oP '\d+' | sed -n '2p')

    if (( TMUX_MAJ > 3 || ( TMUX_MAJ == 3 && TMUX_MIN >= 1 ) )); then
        # >= 3.1: -l % and -P -F 
        PANE_ID=$(tmux split-window "$DIRECTION" -l "${PERCENT}%" -t "$TARGET" -P -F "#{pane_id}" 2>&1)
    elif (( TMUX_MAJ > 2 || ( TMUX_MAJ == 2 && TMUX_MIN >= 1 ) )); then
        # >= 2.1: -P -F but size uses -p %
        PANE_ID=$(tmux split-window "$DIRECTION" -p "$PERCENT" -t "$TARGET" -P -F "#{pane_id}" 2>&1)
    else
        # < 2.1 (e.g. 1.8): no -P flag
        tmux split-window "$DIRECTION" -p "$PERCENT" -t "$TARGET" 2>&1
        PANE_ID=$(tmux display-message -p "#{pane_id}")
    fi

    if [[ "$PANE_ID" == %* ]]; then
        echo "$PANE_ID"
    else
        echo "ERROR: new_pane $DIRECTION $PERCENT $TARGET -> $PANE_ID" >&2
        echo ""
    fi
}

# -------------------
show_final_log()
# -------------------
{
    local SEP
    SEP=$(printf '\e[1;34m%*s\e[0m\n' "${COLS}" '' | tr ' ' '=')
    clear
    echo -e "$SEP"
    if [[ -f "${FINAL_LOG}" ]]; then
        cat "${FINAL_LOG}"
    else
        echo "Log not found: ${FINAL_LOG}"
    fi
    echo -e "$SEP"
    cp /dev/null /tmp/phase.log 2>/dev/null
}

#######################################################################
# MAIN
#######################################################################

[[ "$1" == "-h" || "$1" == "--help" ]] && usage
[[ $# -lt 1 ]] && usage "Missing command."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLS=$(tput cols)
LINES=$(tput lines)
TMUX_MAJ=$(tmux -V 2>/dev/null | grep -oP '\d+' | head -1)
TMUX_MIN=$(tmux -V 2>/dev/null | grep -oP '\d+' | sed -n '2p')

install_tmux || { echo -e "Error $? during installation of tmux.\n$(cat /tmp/dnf.log)"; exit 1; }

cp /dev/null /tmp/phase.log 2>/dev/null

########################################
# Select worker and derive FINAL_LOG
########################################
case "$1" in

    switch)
        [[ -z "$2" ]] && usage "switch requires <SERVICE>."
        SERVICE="$2"
        WORKER_PATH="${SCRIPT_DIR}/opensvc_switch.sh"
        SESSION="monitor-switch-${SERVICE}"
        ARGS="${SERVICE}"
        FINAL_LOG="/tmp/opensvc_switch_${SERVICE}.log"
        ;;

    extension)
        [[ -z "$2" || -z "$3" ]] && usage "extension requires <FS> and <SIZE_GB>."
        FS="$2"; SIZE="$3"
        SERVICE=$(grep -Rl "mnt *= *${FS}\>" /etc/opensvc/ 2>/dev/null | xargs -n1 basename | sed 's/.conf$//')
        [[ -z "$SERVICE" ]] && { echo "Error: cannot identify SERVICE for FS=${FS}" >&2; exit 1; }
        WORKER_PATH="${SCRIPT_DIR}/opensvc_extension.sh"
        SESSION="monitor-extension-${SERVICE}"
        ARGS="${FS} ${SIZE}"
        FINAL_LOG="/tmp/opensvc_extension.log"
        ;;

    add_fs)
        [[ -z "$2" || -z "$3" ]] && usage "add_fs requires <SERVICE> and <FS>."
        SERVICE="$2"
        WORKER_PATH="${SCRIPT_DIR}/opensvc_add_fs.sh"
        SESSION="monitor-add_fs-${SERVICE}"
        ARGS="${@:2}"
        FINAL_LOG="/tmp/opensvc_add_fs.log"
        ;;

    remove_fs)
        [[ -z "$2" ]] && usage "remove_fs requires <FS>."
        FS="$2"
        # Derive SERVICE from the mount point registered in OpenSVC
        SERVICE=$(grep -Rl "mnt *= *${FS}\>" /etc/opensvc/ 2>/dev/null | xargs -n1 basename | sed 's/.conf$//')
        WORKER_PATH="${SCRIPT_DIR}/opensvc_remove_fs.sh"
        SESSION="monitor-remove_fs-${FS//\//_}"
        ARGS="${FS}"
        FINAL_LOG="/tmp/opensvc_remove_fs.log"
        ;;

    add_app)
        [[ -z "$2" || -z "$3" ]] && usage "add_app requires <SERVICE> and <APP_PATH>."
        SERVICE="$2"
        WORKER_PATH="${SCRIPT_DIR}/opensvc_add_app.sh"
        SESSION="monitor-add_app-${SERVICE}"
        ARGS="${@:2}"
        FINAL_LOG="/tmp/opensvc_add_app.log"
        ;;

    remove_app)
        [[ -z "$2" || -z "$3" ]] && usage "remove_app requires <SERVICE> and <APP_PATH>."
        SERVICE="$2"
        WORKER_PATH="${SCRIPT_DIR}/opensvc_remove_app.sh"
        SESSION="monitor-remove_app-${SERVICE}"
        ARGS="${@:2}"
        FINAL_LOG="/tmp/opensvc_remove_app.log"
        ;;

    create_svc)
        [[ -z "$2" || -z "$3" || -z "$4" ]] && usage "create_svc requires <SERVICE> <INTERFACE> <IP>."
        SERVICE="$2"
        WORKER_PATH="${SCRIPT_DIR}/opensvc_create_service.sh"
        SESSION="monitor-create_svc-${SERVICE}"
        ARGS="${@:2}"
        FINAL_LOG="/tmp/opensvc_create_svc.log"
        ;;

    deactivate)
        [[ -z "$2" ]] && usage "deactivate requires <SERVICE> [CHANGE]."
        SERVICE="$2"
        WORKER_PATH="${SCRIPT_DIR}/opensvc_deactivate_service.sh"
        SESSION="monitor-deactivate-${SERVICE}"
        ARGS="${@:2}"
        FINAL_LOG="/tmp/opensvc_deactivate_service.log"
        ;;

    decommission_svc)
        [[ -z "$2" ]] && usage "decommission_svc requires <SERVICE>."
        SERVICE="$2"
        WORKER_PATH="${SCRIPT_DIR}/opensvc_decommission_service.sh"
        SESSION="monitor-decommission_svc-${SERVICE}"
        ARGS="${SERVICE}"
        FINAL_LOG="/tmp/opensvc_decommission_service.log"
        ;;

    decommission_cluster)
        WORKER_PATH="${SCRIPT_DIR}/opensvc_decommission_cluster.sh"
        SERVICE=""   # No single service - cluster-wide operation
        SESSION="monitor-decommission_cluster"
        ARGS=""
        FINAL_LOG="/tmp/opensvc_decommission_cluster.log"
        ;;

    *) usage "Unknown command: $1." ;;
esac

[[ -f "$WORKER_PATH" ]] || { echo "Worker not found: ${WORKER_PATH}" >&2; exit 1; }

########################################
# Monitor commands
########################################
# Service-specific monitors only available if SERVICE is known
if [[ -n "${SERVICE}" ]]; then
    MONITOR_01="watch -t -n 2  'om ${SERVICE} print status -r | tail -n \$(tput lines)'"
    MONITOR_03="watch -t -n 1  'om ${SERVICE} logs | tail -n \$((\$(tput lines) - 1)) | sed \"s/ sid[^ ]*//\"'"
else
    MONITOR_01=""
    MONITOR_03=""
fi
MONITOR_02="watch -t -n 2  'om mon | tail -n \$(tput lines)'"
MONITOR_04="watch -t -n 0.5 'cat /tmp/phase.log | tail -n \$((\$(tput lines) - 1))'"

########################################
# Build tmux session
########################################
SCRIPT_TEMP=$(mktemp /tmp/opensvc_monitor_XXXX.sh)
chmod +x "$SCRIPT_TEMP"
cat > "$SCRIPT_TEMP" << SCRIPT_TEMP_EOF
#!/bin/bash
${WORKER_PATH} ${ARGS}
echo -e "\033[5;33m"
read -rp "[Press ENTER to close all panes]"
echo -e "\033[0m"
tmux kill-session -t "${SESSION}" 2>/dev/null
SCRIPT_TEMP_EOF

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x "$COLS" -y "$LINES" "bash $SCRIPT_TEMP" || \
    { echo "Error: failed to create tmux session." >&2; rm -f "$SCRIPT_TEMP"; exit 1; }

P_TOP_LEFT=$(tmux display-message -t "${SESSION}":0 -p "#{pane_id}")

# Enable pane border titles if tmux >= 2.3
if (( TMUX_MAJ > 2 || ( TMUX_MAJ == 2 && TMUX_MIN >= 3 ) )); then
    tmux set-option -t "$SESSION" pane-border-status top    2>/dev/null || true
    tmux set-option -t "$SESSION" pane-border-format " #{pane_title} " 2>/dev/null || true
fi

P_BOTTOM_LEFT=$(new_pane -v 30 "$P_TOP_LEFT")

########################################
# Create panes based on terminal width
########################################
if (( COLS >= 200 )); then
    P_TOP_RIGHT=$(new_pane    -h 33 "$P_TOP_LEFT")
    P_TOP_MIDDLE=$(new_pane   -h 50 "$P_TOP_LEFT")
    P_BOTTOM_RIGHT=$(new_pane -h 75 "$P_BOTTOM_LEFT")
    [[ -n "${MONITOR_01}" ]] && send_monitor "$P_TOP_MIDDLE"   "${MONITOR_01}"
    send_monitor "$P_TOP_RIGHT"    "${MONITOR_02}"
    [[ -n "${MONITOR_03}" ]] && send_monitor "$P_BOTTOM_RIGHT" "${MONITOR_03}"
    send_monitor "$P_BOTTOM_LEFT"  "${MONITOR_04}"
    set_pane_title "$P_TOP_LEFT"     " Worker: ${SESSION#monitor-} "
    set_pane_title "$P_TOP_MIDDLE"   " Service status "
    set_pane_title "$P_TOP_RIGHT"    " Cluster monitor "
    set_pane_title "$P_BOTTOM_RIGHT" " Service logs "
    set_pane_title "$P_BOTTOM_LEFT"  " Phase log "
else
    P_TOP_RIGHT=$(new_pane -h 45 "$P_TOP_LEFT")
    send_monitor "$P_TOP_RIGHT"   "${MONITOR_02}"
    send_monitor "$P_BOTTOM_LEFT" "${MONITOR_04}"
    set_pane_title "$P_TOP_LEFT"    " Worker: ${SESSION#monitor-} "
    set_pane_title "$P_TOP_RIGHT"   " Cluster monitor "
    set_pane_title "$P_BOTTOM_LEFT" " Phase log "
fi

tmux select-pane -t "$P_TOP_LEFT"
tmux attach-session -t "$SESSION"

# Session ended (kill-session ran in SCRIPT_TEMP) - cleanup and show log
rm -f "$SCRIPT_TEMP" 2>/dev/null
show_final_log