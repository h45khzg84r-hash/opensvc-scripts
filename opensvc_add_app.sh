#!/bin/bash
# opensvc_add_app.sh - Adds a new app resource to an OpenSVC HA service
# Usage: opensvc_add_app.sh <SERVICE> <APP_PATH> [APP_NAME]
# Author.: adriano.costa
# Version: 20260419
#
# The app resource RID will be app#<APP_NAME> (or app#<script_basename>).
# Fields: script, start=true, stop=true, check=true, optional=true

SERVICE=$1
APP_PATH=$2
APP_NAME="${3:-}"

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <SERVICE> <APP_PATH> [APP_NAME]"
    echo ""
    echo "  Arguments:"
    echo "    <SERVICE>    Name of the OpenSVC service (e.g. SERVICE_NAME)"
    echo "    <APP_PATH>   Full path to the app script on the primary node"
    echo "                 (e.g. /SERVICE_NAME/appli/bin/start.sh)"
    echo "    [APP_NAME]   Resource name suffix for app# RID (default: script basename)"
    echo "                 (e.g. myapp -> app#myapp)"
    echo ""
    echo "  Notes:"
    echo "    - RID is derived as app#<APP_NAME> with counter if already in use."
    echo "    - Defaults: start=true, stop=true, check=true, optional=true."
    echo "    - The script file must already exist on the primary node."
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} SERVICE_NAME /SERVICE_NAME/appli/bin/start.sh"
    echo "    ${SCRIPT} SERVICE_NAME /SERVICE_NAME/appli/bin/start.sh myapp"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF

Add app resource to an OpenSVC service:
  Service Name ......: ${SERVICE}"
  Primary Node.......: ${PRIMARY} (${IP_PRI})"
  Standby Node.......: ${STANDBY} (${IP_STA})"

New Application details:
  Application Name...: ${APP_NAME}"
  Resource ID........: ${NEW_RID:-N/A}

Resource parameters:
  Script.............: ${APP_PATH}
  Start..............: ${P_START}
  Stop...............: ${P_STOP}
  Check..............: ${P_CHECK}
  Optional...........: ${P_OPTIONAL}

EOF
}

# -------------------
init_vars()
# -------------------
{
    HOST=$(hostname)	
    [[ -z "$SERVICE" ]]                      && return 1
    # SERVICE must not be a path - catch swapped arguments
    [[ "$SERVICE" == /* ]]                   && return 2
    [[ -z "$APP_PATH" ]]                     && return 3
    # APP_PATH must be an absolute path
    [[ "$APP_PATH" != /* ]]                  && return 4

    # Collect cluster nodes
    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]]                        && return 5
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    # Validate service exists
    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]]                     && return 6
    grep -Fxq "${SERVICE}" <<< "${SERVICES}" || return 7

    # Resolve PRIMARY / STANDBY
    resolve_svc_nodes; RC=$?
    (( RC == 1 )) && return 8
    (( RC == 2 )) && return 9

     # Check script exists and is executable on primary node
    remote "test -f ${APP_PATH}" || return 10
    remote "test -x ${APP_PATH}" || return 11

    # APP_NAME from script basename if not provided
    [[ -z "${APP_NAME}" ]] && APP_NAME="${APP_PATH##*/}" && APP_NAME="${APP_NAME%.*}"

    # Check if app already exist
    EXISTING_RID="$(om "${SERVICE}" print resinfo 2>/dev/null | awk -v app="${APP_NAME}" '$2=="app#"app')"
    [[ -n "${EXISTING_RID}" ]] && return 12 || NEW_RID="app#${APP_NAME}"

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
[[ $# -lt 2 ]] && usage "Missing arguments. Expected at least 2, got $#."

init_logs

clear

########################################
stage "Activity started in $(date +'%d/%m/%Y %H:%M')"
########################################
phase "Collecting environment status"
init_vars; RC=$?
case $RC in
    0)  ;;
    1)  update_status err  "Variable SERVICE is empty." ;;
    2)  update_status err  "SERVICE looks like a path (starts with /). Did you swap SERVICE and APP_PATH?" ;;
    3)  update_status err  "Variable APP_PATH is empty." ;;
    4)  update_status err  "APP_PATH must be an absolute path (starts with /)." ;;
    5)  update_status err  "Cannot list cluster nodes." ;;
    6)  update_status err  "Cannot list cluster services." ;;
    7)  update_status err  "Service ${SERVICE} not found." ;;
    8)  update_status err  "PRIMARY node is empty - is ${SERVICE} down?" ;;
    9)  update_status err  "STANDBY node is empty - is it down?" ;;
   10)  update_status err  "Script ${APP_PATH} not found on ${PRIMARY}." ;;
   11)  update_status err  "Script ${APP_PATH} is not executable on ${PRIMARY}." ;;
   12)  update_status err  "Application ${APP_NAME} (${APP_PATH}) is already created in ${SERVICE}. Nothing to do." ;;
esac

# App Start
show BLUE "\nResource parameter: start"
show BLUE "============================="
show BLUE "  The OpenSVC engine will call the script with start when the service starts [default: true]."
P_START=$(select_bool "start" "true")

# App Stop
show BLUE "\nResource parameter: stop"
show BLUE "============================="
show BLUE "  The engine will call the script with stop when the service stops [default: true]."
P_STOP=$(select_bool "stop" "true")

# App Check
show BLUE "\nResource parameter: check"
show BLUE "============================"
show BLUE "  The monitor will periodically call the script with check to verify the resource state [default: true]."
P_CHECK=$(select_bool "check" "true")

# App Optional
show BLUE "\nResource parameter: optional"
show BLUE "=============================="
show BLUE "  If true, it does not bring the service down; it is treated as non-critical [default: true]."
P_OPTIONAL=$(select_bool "optional" "true")

show GREEN ""
while IFS= read -r LINE; do
    show GREEN "\t\t${LINE}"
done < <(build_report_block)

prompt_continue "Everything is ok?" || update_status no_go "Aborting - check all information before continuing."
update_status ok  "All the information was collected.\n"

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

phase "Checking for a pending reboot"
run_command "needs-restarting -r"; RC=$?
case $RC in
    0) update_status ok  "No system reboot required before this operation." ;;
    *) update_status err "System requires reboot before maintenance." ;;
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

# Add resource only if it does not yet exist in the service
phase "Adding ${NEW_RID} to ${SERVICE}"
run_command -l "om ${SERVICE} set --kw ${NEW_RID}.script=${APP_PATH} --kw ${NEW_RID}.start=${P_START} --kw ${NEW_RID}.stop=${P_STOP} --kw ${NEW_RID}.check=${P_CHECK} --kw ${NEW_RID}.optional=${P_OPTIONAL}"; RC=$?
case $RC in
    0) update_status ok  "Resource ${NEW_RID} (script=${APP_PATH}) added to ${SERVICE}." ;;
    *) update_status err "Failed to add ${NEW_RID}. Check 'om ${SERVICE} print resinfo'." ;;
 esac

# Mark provisioned on all nodes so standby does not show part-provisioned
phase "Set ${NEW_RID} as provisioned"
run_command -l "om ${SERVICE} set provisioned --rid ${NEW_RID} --node ${NODES_CSV}"; RC=$?
case $RC in
    0) update_status ok  "Resource ${NEW_RID} marked as provisioned on all nodes." ;;
    *) update_status err "Failed to set ${NEW_RID} as provisioned." ;;
esac

phase "Start ${NEW_RID} on ${PRIMARY}"
run_command -l "om ${SERVICE} start --rid ${NEW_RID} --node ${PRIMARY}"; RC=$?
case $RC in
    0) update_status ok  "Resource ${NEW_RID} started successfully." ;;
    *) update_status err "Failed to start ${NEW_RID}. Check 'om ${SERVICE} print status -r'." ;;
esac

phase "Sync config to cluster nodes"
NODE=${PRIMARY}
run_command -l "om ${SERVICE} sync all"; RC=$?
case $RC in
    0) update_status ok  "Service configuration synced to all cluster nodes." ;;
    *) update_status err "Sync failed. Check cluster connectivity." ;;
esac

phase "Check ${SERVICE} status after adding"
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
show BLUE "[Success]\tResource ${NEW_RID} was added in the ${SERVICE}."
show BLUE "\t\tThe script ${APP_PATH} was started successfully."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
write_log "$(report_block)"
exit 0