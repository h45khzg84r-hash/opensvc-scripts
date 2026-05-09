#!/bin/bash
# opensvc_remove_app.sh - Removes an app resource from an OpenSVC HA service
# Usage: opensvc_remove_app.sh <SERVICE> <APP_PATH>
# Author.: adriano.costa
# Version: 20260419
#
# The script file path is automatically loaded from the RID.
# The script file on disk is NOT removed.

SERVICE=$1
RID=$2

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <SERVICE> <RID>"
    echo ""
    echo "  Arguments:"
    echo "    <SERVICE>    Name of the OpenSVC service (e.g. SERVICE_NAME)"
    echo "    <RID     >   Application RID (must be started with app#)"
    echo "                 (e.g. app#app_01)"
    echo ""
    echo "  Notes:"
    echo "    - The script file on disk is NOT removed."
    echo "    - Only the resource definition is removed from the service."
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} SERVICE_NAME app#app_01"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF

Remove Application resource from OpenSVC service:
  Service Name.......: ${SERVICE}
  Primary Node.......: ${PRIMARY} (${IP_PRI})
  Standby Node.......: ${STANDBY} (${IP_STA})

RID (Application) to remove:
  Application path...: ${APP_PATH}
  Resource ID........: ${RID}

EOF
}

# -------------------
init_vars()
# -------------------
{
    HOST=$(hostname)
    [[ -z "$SERVICE" ]]   && return 1
    [[ -z "$RID" ]]       && return 2
    [[ "$RID" =~ ^app# ]] || return 7

    # Collect cluster nodes
    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]] && return 3
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    # Validate service exists
    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]] && return 4
    grep -Fxq "${SERVICE}" <<< "${SERVICES}" || return 5

    # APP_PATH from the RID in the service
    APP_PATH="$(om cfg get --param "${RID}".script --service "${SERVICE}")"
    [[ -z "$APP_PATH" ]] && return 6

    # Resolve PRIMARY / STANDBY
    resolve_svc_nodes; RC=$?
    (( RC == 1 )) && return 8
    (( RC == 2 )) && return 9

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
[[ $# -lt 2 ]] && usage "Missing arguments. Expected 2, got $#."

init_logs

clear

########################################
stage "Activity started in $(date +'%d/%m/%Y %H:%M')"
########################################
phase "Collecting Information"
init_vars; RC=$?
case $RC in
    0)  while IFS= read -r LINE; do
            show GREEN "\t\t${LINE}"
        done < <(build_report_block)
        update_status ok "All the information was collected" ;;
    1)  update_status err "Variable SERVICE is empty." ;;
    2)  update_status err "Variable APP_PATH is empty." ;;
    3)  update_status err "Cannot list cluster nodes." ;;
    4)  update_status err "Cannot list cluster services." ;;
    5)  update_status err "Service ${SERVICE} not found." ;;
    6)  update_status err "No app resource found for script ${APP_PATH} in ${SERVICE}." ;;
    7)  update_status err "Resource ${RID} is not an app resource (must start with app#)." ;;
    8)  update_status err "PRIMARY node is empty - is ${SERVICE} down?" ;;
    9)  update_status err "STANDBY node is empty - is it down?" ;;
    *)  update_status err "Unexpected error in init_vars (RC=${RC})." ;;
esac

show YELLOW  "[ Warning ]\tTHIS ACTION IS REVERSIBLE."
show YELLOW  "\t\tYou will need to create the resource again in the cluster."
prompt_continue "Does it start the filesystem remotion?" || update_status no_go "Aborted. No action was taken."
show GREEN ""

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
NODE=${PRIMARY}
stage "On PRIMARY node (${PRIMARY})"
########################################
phase "Freezing the OpenSVC Cluster service"
opensvc_freeze; RC=$?
case $RC in
    0) update_status ok   "Service frozen successfully." ;;
    2) update_status warn "Service is already frozen." ;;
    5) update_status err  "Failed to freeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status err  "Unexpected error during freeze (RC=${RC})." ;;
esac

# Stop resource before removing its definition
phase "Stop ${RID} on ${PRIMARY}"
run_command -l "om ${SERVICE} stop --rid ${RID} --node ${PRIMARY}"; RC=$?
case $RC in
    0) update_status ok  "Resource ${RID} stopped on ${PRIMARY}." ;;
    *) update_status err "Failed to stop ${RID}. Check 'om ${SERVICE} print status -r'." ;;
esac

# Clear provisioned state on all nodes (avoid part-provisioned after delete)
phase "Unprovision ${RID} on all nodes"
run_command -l "om ${SERVICE} set unprovisioned --rid ${RID} --node ${NODES_CSV}"; RC=$?
case $RC in
    0) update_status ok  "Resource ${RID} marked as unprovisioned on all nodes." ;;
    *) update_status err "Failed to set ${RID} as unprovisioned (RC=${RC})." ;;
esac

phase "Remove ${RID} from ${SERVICE}"
run_command -l "om ${SERVICE} delete --rid ${RID}"; RC=$?
case $RC in
    0) update_status ok  "Resource ${RID} removed from ${SERVICE} configuration." ;;
    *) update_status err "Failed to remove ${RID}. Check 'om ${SERVICE} print resinfo'." ;;
esac

phase "Sync config to all cluster nodes"
NODE=${PRIMARY}
run_command -l "om ${SERVICE} sync all"; RC=$?
case $RC in
    0) update_status ok  "Service configuration synced to all cluster nodes." ;;
    *) update_status err "Sync failed. Check cluster connectivity." ;;
esac

phase "Check ${SERVICE} status after removing"
check_ml_status; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

phase "Unfreezing the OpenSVC service"
opensvc_unfreeze; RC=$?
case $RC in
    0) update_status ok   "Service unfrozen successfully." ;;
    2) update_status warn "Service is already unfrozen." ;;
    5) update_status err  "Failed to unfreeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status err  "Unexpected error during freeze (RC=${RC})." ;;
esac

########################################
stage "POST-CHECK"
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

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE ""
show BLUE "[Success]\tResource ${RID} removed from ${SERVICE}."
show BLUE "\t\tScript ${APP_PATH} is intact on disk."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
write_log "$(report_block)"
exit 0