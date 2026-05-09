#!/bin/bash
# opensvc_switch.sh - Switches an OpenSVC HA service to the standby node
# Usage: opensvc_switch.sh <SERVICE>
# Author.:
# Version: 20260419

SERVICE=$1

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <SERVICE>"
    echo ""
    echo "  Arguments:"
    echo "    <SERVICE>   Name of the OpenSVC service to switch (e.g. SERVICE_NAME)"
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} SERVICE_NAME"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF

Switch OpenSVC service:
  Service Name ......: ${SERVICE}"
  Primary Node.......: ${PRIMARY} (${IP_PRI})"
  Standby Node.......: ${STANDBY} (${IP_STA})"

EOF
}

# -------------------
init_vars()
# -------------------
{
    local SVC_STATUS

    HOST=$(hostname)
    [[ -z "$SERVICE" ]] && return 1

    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]] && return 2
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]] && return 3

    grep -Fxq "${SERVICE}" <<< "${SERVICES}" || return 4

    SVC_STATUS="$(om "${SERVICE}" print status --node "${NODES_CSV}" 2>/dev/null)"
    resolve_svc_nodes; RC=$?
    (( RC == 1 )) && return 5
    (( RC == 2 )) && return 6

    return 0
}

#######################################################################
# MAIN
#######################################################################
# Load LIBS
MY_LIBS="./lib_common.sh ./lib_opensvc.sh"
for MY_LIB in $MY_LIBS; do
    if [[ -f "$MY_LIB" ]]; then
        source "$MY_LIB"
    else
        echo "ERROR: Library not found: $MY_LIB"
        exit 1
    fi
done

[[ "$1" == "-h" || "$1" == "--help" || "$1" == "-?" ]] && usage
[[ $# -lt 1 ]] && usage "Missing argument. SERVICE is required."
SWITCH_TIMEOUT=180   # seconds to wait for the switch to complete

init_logs "${SERVICE:-unknown}"

clear

########################################
stage "Activity started in $(date +'%d/%m/%Y %H:%M')"
########################################
phase "Collecting environment status"
init_vars; RC=$?
case $RC in
    0)  while IFS= read -r LINE; do
            show GREEN "\t\t${LINE}"
        done < <(build_report_block)
        update_status ok "All the information was collected" ;;
    1)  update_status err "Variable SERVICE is empty." ;;
    2)  update_status err "Cannot list cluster nodes." ;;
    3)  update_status err "Cannot list cluster services." ;;
    4)  update_status err "Service ${SERVICE} not found." ;;
    5)  update_status err "PRIMARY node is empty - is ${SERVICE} down?" ;;
    6)  update_status err "STANDBY node is empty - is it down?" ;;
    *)  update_status err "Unexpected error in init_vars (RC=${RC})." ;;
esac

prompt_continue "Can i switch it?" || update_status no_go "Aborting - check all information before continuing."

########################################
stage "PRE-CHECK"
########################################
phase "Status of ${SERVICE} on primary (${PRIMARY})"
check_ml_status sync prstart provisioned rid; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

########################################
NODE=${STANDBY}
stage "On STANDBY node (${STANDBY})"
########################################

phase "Status of ${SERVICE} on standby (${STANDBY})"
check_ml_status; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

phase "Updating LVM cache on standby node"
run_command "pvscan --cache"; RC=$?
case $RC in
    0) update_status ok  "LVM cache updated on ${STANDBY}." ;;
    *) update_status err "pvscan --cache failed on ${STANDBY}." ;;
esac

phase "Refreshing multipaths on standby node"
run_command "multipath -r" || update_status err "multipath -r failed on ${STANDBY}."
multipath_status; RC=$?
case $RC in
    0) update_status ok   "No multipath issues on ${STANDBY}." ;;
    3) update_status warn ;;
    4) update_status no_go ;;
    *) update_status err  "Unexpected error during multipath check on ${STANDBY} (RC=${RC})." ;;
esac

########################################
NODE=${PRIMARY}
stage "On PRIMARY node (${PRIMARY})"
########################################
phase "Switching ${SERVICE} to node ${STANDBY}"
run_command -l "om ${SERVICE} switch --wait --time ${SWITCH_TIMEOUT}"; RC=$?
case $RC in
    0) update_status ok  "Switch performed successfully." ;;
    *) update_status err "Switch command failed or timed out after ${SWITCH_TIMEOUT}s." ;;
esac

SVC_STATUS="$(om "${SERVICE}" print status --node "${NODES_CSV}" 2>/dev/null)"
resolve_svc_nodes
NODE="${PRIMARY}"

########################################
stage "POST-CHECK"
########################################
phase "Status of ${SERVICE} on new primary (${PRIMARY})"
check_ml_status sync prstart provisioned rid; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

########################################
NODE=${STANDBY}
stage "On STANDBY node (${STANDBY})"
########################################
phase "Status of ${SERVICE} on standby (${STANDBY})"
check_ml_status; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE ""
show BLUE "[Success]\tService ${SERVICE} has been switched successfully."
show BLUE "\t\tPRIMARY node is now ${PRIMARY}."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
write_log "$(report_block)"
exit 0