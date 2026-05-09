#!/bin/bash
# opensvc_deactivate_service.sh - Stop a service and rename it to a CHANGE number
# Usage: opensvc_deactivate.sh <SERVICE> <CHANGE>
# Author.: adriano.costa
# Version: 20260509
#
# Stops the service on all nodes, freezes and disables it to prevent any
# restart attempt, then renames it to <CHANGE> (e.g. CHG0012345).
# !! THIS ACTION IS REVERSIBLE but requires manual intervention to restore. !!

SERVICE=$1
CHANGE="${2:-}"

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <SERVICE> [CHANGE]"
    echo ""
    echo "  Arguments:"
    echo "    <SERVICE>   Name of the OpenSVC service to deactivate"
    echo "    [CHANGE]    Optional change number - if provided, renames the service"
    echo "                (e.g. CHG0012345)"
    echo ""
    echo "  Notes:"
    echo "    - The service will be stopped, frozen and disabled on all nodes."
    echo "    - If CHANGE is given, the service is renamed for traceability."
    echo "    - Configuration is preserved - service can be restored manually."
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} SERVICE_NAME"
    echo "    ${SCRIPT} SERVICE_NAME CHG0012345"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF
    
Deactivate a service:    
  Service Name..........: ${SERVICE}
  Primary Node..........: ${PRIMARY} (${IP_PRI})
  Standby Node..........: ${STANDBY} (${IP_STA})

  Change Number.........: ${CHANGE:-n/a}
EOF
}

# -------------------
init_vars()
# -------------------
{
    HOST=$(hostname)
    [[ -z "$SERVICE" ]] && return 1
    # SERVICE must not be a path - catch swapped arguments
    [[ "$SERVICE" == /* ]] && return 10
    # Validate CHANGE format if provided
    if [[ -n "$CHANGE" ]]; then
        [[ ! "$CHANGE" =~ ^[A-Za-z0-9_-]+$ ]] && return 2
    fi

    # Collect cluster nodes
    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]] && return 4
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    # Validate service exists
    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]] && return 5
    grep -Fxq "${SERVICE}" <<< "${SERVICES}" || return 6

    # VG name from disk resource
    local DISK_RID
    DISK_RID="$(om "${SERVICE}" print resinfo 2>/dev/null | awk '/disk#[0-9]+[^p]/ {print $2; exit}')"
    [[ -n "$DISK_RID" ]] && VG_NAME="$(om "${SERVICE}" get --kw "${DISK_RID}".name 2>/dev/null)"

    # Check CHANGE name not already in use (only if provided)
    [[ -n "$CHANGE" ]] && grep -Fxq "${CHANGE}" <<< "${SERVICES}" && return 7

    # Set PRIMARY / STANDBY
    SVC_STATUS="$(om "${SERVICE}" print status --node "${NODES_CSV}" 2>/dev/null)"
    resolve_svc_nodes; RC=$?
    if (( RC != 0 )); then
        local SVC_AVAIL
        SVC_AVAIL="$(om "${SERVICE}" print status 2>/dev/null | awk '/^avail[[:space:]]/ {print $2; exit}')"
        if [[ "${SVC_AVAIL}" == "down" || "${SVC_AVAIL}" == "n/a" || -z "${SVC_AVAIL}" ]]; then
            local NODE1 NODE2
            NODE1="$(awk 'NR==1' <<< "${NODES}")"
            NODE2="$(awk 'NR==2' <<< "${NODES}")"
            if [[ -n "${NODE1}" && -n "${NODE2}" ]]; then
                if [[ "${HOST}" == "${NODE1}" ]]; then
                    PRIMARY="${NODE1}"
                    STANDBY="${NODE2}"
                else
                    PRIMARY="${NODE2}"
                    STANDBY="${NODE1}"
                fi
                log_warn "Service fully down — PRIMARY=${PRIMARY} STANDBY=${STANDBY} assigned from node list"
                log_warn "Manual verification recommended before proceeding"
            else
                return 8
            fi
        else
            (( RC == 1 )) && return 8
            (( RC == 2 )) && return 9
        fi
    fi
    IP_PRI="$(getent ahostsv4 "${PRIMARY}" | head -1 | awk '{print $1}')"
    IP_STA="$(getent ahostsv4 "${STANDBY}" | head -1 | awk '{print $1}')"
    
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

init_logs

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
    10) update_status err "SERVICE looks like a path (starts with /). Check arguments." ;;
    2)  update_status err "Invalid CHANGE name '${CHANGE}'. Use alphanumeric characters only." ;;
    4)  update_status err "Cannot list cluster nodes." ;;
    5)  update_status err "Cannot list cluster services." ;;
    6)  update_status err "Service ${SERVICE} not found." ;;
    7)  update_status err "Name '${CHANGE}' already exists as a service." ;;
    8)  update_status err "PRIMARY node is empty - is ${SERVICE} down?" ;;
    9)  update_status err "STANDBY node is empty - is it down?" ;;
    *)  update_status err "Unexpected error in init_vars (RC=${RC})." ;;
esac

show RED "\n\t\t================================================================"
show RED "\t\t             !! WARNING - SERVICE DEACTIVATION !!"
show RED "\t\t================================================================"
if [[ -n "${CHANGE}" ]]; then
    show YELLOW "\t\tService ${SERVICE} will be stopped and renamed to ${CHANGE}."
else
    show YELLOW "\t\tService ${SERVICE} will be stopped (no rename requested)."
fi
show YELLOW "\t\tThe service will be stopped, frozen and disabled."
show YELLOW "\t\tDisabled prevents any start attempt - manual or automatic."
show BLUE   "\t\tConfiguration is preserved and can be restored manually."
show GREEN  ""
prompt_continue "Proceed with deactivation of ${SERVICE}?" || update_status no_go "Deactivation aborted by operator."

refresh_ml_status

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
phase "Freezing the OpenSVC Cluster nodes"
opensvc_freeze "${SERVICE}"; RC=$?
case $RC in
    0) update_status ok   "Service ${SERVICE} frozen successfully." ;;
    2) update_status warn "Service ${SERVICE} is already frozen." ;;
    5) update_status nok  "Failed to freeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status nok  "Unexpected error during freeze (RC=${RC})." ;;
esac

phase "Stopping service ${SERVICE} on all nodes"
run_command -l "om ${SERVICE} stop --node ${NODES_CSV} --wait"; RC=$?
case $RC in
    0) update_status ok  "Service ${SERVICE} stopped on all nodes." ;;
    *) update_status err "Failed to stop ${SERVICE} (RC=${RC})." ;;
esac

# Disable prevents orchestrator and operators from starting the service
phase "Disabling service ${SERVICE} on all nodes"
run_command -l "om ${SERVICE} disable --node ${NODES_CSV}"; RC=$?
case $RC in
    0) update_status ok  "Service ${SERVICE} disabled - no start attempts will be allowed." ;;
    *) update_status err "Failed to disable ${SERVICE} (RC=${RC})." ;;
esac

phase "Verifying ${SERVICE} is down in primary"
check_ml_status; RC=$?

case $RC in
    11)  update_status ok "Service ${SERVICE} confirmed as down on all nodes.";;
     *)  update_status err  "Unexpected error (RC=${RC})." ;;
esac

########################################
NODE=${STANDBY}
stage "On STANDBY node (${STANDBY})"
########################################
phase "Verifying ${SERVICE} is down in standby"
check_ml_status; RC=$?
case $RC in
    11)  update_status ok "Service ${SERVICE} confirmed as down on all nodes.";;
     *)  update_status err  "Unexpected error (RC=${RC})." ;;
esac

########################################
NODE=${PRIMARY}
stage "On PRIMARY node (${PRIMARY})"
########################################
if [[ -n "${CHANGE}" ]]; then
    DEACTIVATED_SERVICE="${CHANGE}_${SERVICE}"	
    show RED ""
    show RED "\t\t================================================================"
    show RED "\t\t!! THIS RENAME IS IRREVERSIBLE without manual config restore !!"
    show RED "\t\t================================================================"
    show GREEN ""
    prompt_continue "Confirm rename of ${SERVICE} to ${CHANGE}?" || update_status no_go "Rename aborted by operator."

    # Backup antes do rename
    for SEQ in STANDBY PRIMARY
    do
        NODE="${!SEQ}"
        stage "On ${SEQ} node (${NODE})"
        phase "Backuping of configuration file in ${SEQ} node."
        run_command "cp -vfp /etc/opensvc/${SERVICE}.conf /etc/opensvc/${SERVICE}.conf.bak" ; RC=$?
        case $RC in
            0) update_status ok  "The /etc/opensvc/${SERVICE}.conf have backuped to /etc/opensvc/${SERVICE}.conf.bak on ${NODE}." ;;
            *) update_status err "Backup of /etc/opensvc/${SERVICE}.conf. Make it manually on ${NODE}." ;;
        esac
    done
    NODE=${PRIMARY}

    phase "Renaming ${SERVICE} to ${DEACTIVATED_SERVICE}"
    # Rename config file in both hosts
    run_command "mv -v /etc/opensvc/${SERVICE}.conf /etc/opensvc/${DEACTIVATED_SERVICE}.conf \
	         && ssh root@${STANDBY} \"mv -v /etc/opensvc/${SERVICE}.conf /etc/opensvc/${DEACTIVATED_SERVICE}.conf\""
    RC=$?
    case $RC in
        0) ;;
	*) update_status err "Failed to renamed /etc/opensvc/${SERVICE}.conf file (RC=$RC)." ;;
    esac
    COUNT=1
    MAX=5
    while (( COUNT <= MAX )); do
        FORCE=0
        om svc ls | grep -qw "${DEACTIVATED_SERVICE}"; RC_NEW=$?
        om svc ls | grep -qw "${SERVICE}";             RC_OLD=$?

        if (( RC_NEW == 0 && RC_OLD != 0 )); then
            break
        elif (( RC_NEW != 0 && RC_OLD == 0 )); then 
	        show YELLOW   "[Warning]\tWaiting for daemon to detect rename of services config (${COUNT}/${MAX})"
	        FORCE=0
        elif (( RC_NEW == 0 && RC_OLD == 0 )); then
	        show YELLOW   "[Warning]\tBoth services visible - Forcing detect of rename       (${COUNT}/${MAX})"
	        FORCE=1
	    else  # RC_NEW != 0 && RC_OLD != 0 
	        show RED      "[Warning]\tNeither service visible - Forcing detect of rename     (${COUNT}/${MAX})"
	        FORCE=1
        fi
	    if (( FORCE )); then
	        remote "mv -vf /etc/opensvc/${SERVICE}.conf /etc/opensvc/${DEACTIVATED_SERVICE}.conf 2>/dev/null \
                   && ssh root@${STANDBY} \"mv -vf /etc/opensvc/${SERVICE}.conf /etc/opensvc/${DEACTIVATED_SERVICE}.conf 2>/dev/null\""

        fi
        sleep 5
        (( COUNT++ ))
    done
    RC=$(( RC_NEW == 0 && RC_OLD != 0 ? 0 : 1 ))
    case $RC in
        0) update_status ok  "Config file /etc/opensvc/${SERVICE}.conf was renamed to /etc/opensvc/${DEACTIVATED_SERVICE}.conf"
           show GREEN "\t\tThe ${SERVICE} not visible anymore." ;;
        *) update_status err "Failed to renamed /etc/opensvc/${SERVICE}.conf file (RC=$?). Restore backup is necessary" ;;
    esac

    show GREEN ""
    run_command -l "om ${DEACTIVATED_SERVICE} sync all"; RC=$?
    case $RC in
        0) update_status ok  "Service configuration synced to all cluster nodes." ;;
        *) update_status warn "Sync failed - run 'om ${DEACTIVATED_SERVICE} sync all' manually." ;;
    esac

    phase "Renaming VG ${VG_NAME} to ${DEACTIVATED_SERVICE} in both nodes"
    run_command "vgs"; RC=$?
    run_command "vgrename ${VG_NAME} ${DEACTIVATED_SERVICE}"; RC=$(( RC + $? ))
    run_command "vgs"; RC=$(( RC + $? ))
    case $RC in
        0) update_status ok  "VG ${VG_NAME} renamed to ${DEACTIVATED_SERVICE}." ;;
        *) update_status warn "VG rename failed (RC=${RC}) - proceed manually if needed." ;;
    esac
else
    DEACTIVATED_SERVICE="${SERVICE}"	
    update_status skip "No CHANGE provided - service keeps name ${DEACTIVATED_SERVICE}."
fi

phase "Unfreezing the OpenSVC service"
opensvc_unfreeze; RC=$?
case $RC in
    0) update_status ok   "Service unfrozen successfully." ;;
    2) update_status warn "Service is already unfrozen." ;;
    5) update_status nok  "Failed to unfreeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status err  "Unexpected error during freeze (RC=${RC})." ;;
esac

########################################
stage "POST-CHECK"
########################################
OLD_SERVICE=${SERVICE}
SERVICE=${DEACTIVATED_SERVICE}
phase "Verifying service is frozen/disabled"
check_ml_status; RC=$?
case $RC in
    11)  ;;
     *)  update_status err  "Unexpected error (RC=${RC})." ;;
esac

RC=2
[[ -n "${ML_FROZEN}" ]] && { show GREEN "[Success]\tThe service ${DEACTIVATED_SERVICE} is FROZEN."  ; (( RC-- )); }
[[ -n "${ML_DISA}"   ]] && { show GREEN "[Success]\tThe service ${DEACTIVATED_SERVICE} is DISABLED."; (( RC-- )); }
case $RC in
    0) update_status ok ;; 
    *) update_status err "Something wrong. The status must be FROZEN / DISABLED. Check Cluster status." ;;
esac

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE ""
[[ -n "${CHANGE}" ]] && show BLUE "[Success]\tService ${OLD_SERVICE} has been deactivated and renamed to ${DEACTIVATED_SERVICE}."
[[ -z "${CHANGE}" ]] && show BLUE "[Success]\tService ${OLD_SERVICE} has been deactivated (not renamed)."

show BLUE "\n\t\tTHIS ACTION IS IRREVERSIBLE without manual config restore."
show BLUE   "\t  -- Restore procedure (sequence is important) --"
if [[ -n "${CHANGE}" ]]; then
    show BLUE "\t  1. Rename back VG name:" 
    show BLUE "\t\t# vgrename ${DEACTIVATED_SERVICE} ${OLD_SERVICE}"
    show BLUE "\t  2. Rename back service (both nodes):" 
    show BLUE "\t\t# mv -vf /etc/opensvc/${DEACTIVATED_SERVICE}.conf /etc/opensvc/${OLD_SERVICE}.conf && \\"
    show BLUE "\t\t  ssh root@${STANDBY} mv -vf /etc/opensvc/${DEACTIVATED_SERVICE}.conf /etc/opensvc/${OLD_SERVICE}.conf"
    show BLUE "\t\t  (wait the OLD service appears again - You can check with 'om mon' command)"
    show BLUE "\t  3. Re-enable service (primary):"
    show BLUE "\t\t# om ${OLD_SERVICE} enable --node ${NODES_CSV}"
    show BLUE "\t  4. Unfreeze service (both nodes):"
    show BLUE "\t\t# om ${OLD_SERVICE} thaw  --node ${NODES_CSV} --wait"
    show BLUE "\t  5. Unfreeze node (both nodes):"
    show BLUE "\t\t# om node thaw  --node ${NODES_CSV} --wait"
    show BLUE "\t\t  (wait service starts automatically) If service didn't start, you can run:"
    show BLUE "\t  6. Start service on primary:"
    show BLUE "\t\t# om ${OLD_SERVICE} start --wait"
    show BLUE "\t  7. Syncronize nodes on primary"
    show BLUE "\t\t# om ${OLD_SERVICE} sync all"
else
    show BLUE "\t  1. Re-enable service (both nodes):"
    show BLUE "\t\t# om ${OLD_SERVICE} enable --node ${NODES_CSV}"
    show BLUE "\t  2. Unfreeze service (both nodes):"
    show BLUE "\t\t# om ${OLD_SERVICE} thaw  --node ${NODES_CSV} --wait"
    show BLUE "\t  3. Unfreeze node (both nodes):"
    show BLUE "\t\t# om node thaw  --node ${NODES_CSV} --wait"
    show BLUE "\t\t  (wait service starts automatically) If service didn't start, you can run:"
    show BLUE "\t  4. Start service on primary:"
    show BLUE "\t\t# om ${OLD_SERVICE} start --wait"
    show BLUE "\t  5. Syncronize nodes"
    show BLUE "\t\t# om ${OLD_SERVICE} sync all"
fi
show BLUE "\n\t\tLog: ${FINAL_LOG}"
write_log "$(report_block)"
exit 0
