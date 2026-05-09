#!/bin/bash
# opensvc_decommission_service.sh - Permanently remove a service and its LVM resources
# Usage: opensvc_decommission_service.sh <SERVICE>
# Author.: adriano.costa
# Version: 20260509
#
# Stops, removes all LVs/VG/PVs/multipath and deletes the service from all nodes.
# !! THIS ACTION IS IRREVERSIBLE - all data will be permanently lost !!

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
    echo "    <SERVICE>   Name of the OpenSVC service to decommission"
    echo ""
    echo "  Notes:"
    echo "    - Stops and deletes the service from all nodes."
    echo "    - Unmounts all filesystems and removes all LVs on all nodes."
    echo "    - Removes the VG, PVs and flushes multipath on all nodes."
    echo "    - THIS ACTION IS IRREVERSIBLE - ALL DATA WILL BE LOST."
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} SERVICE_NAME"
    echo "    ${SCRIPT} CHG0012345"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF

Decommission OpenSVC service:    
  Service Name..........: ${SERVICE}
  Primary Node..........: ${PRIMARY} (${IP_PRI})
  Standby Node..........: ${STANDBY} (${IP_STA})

LVM service structure: 
  VG Name...............: ${VG_NAME}
  LVOLs list............: ${LV_LIST}
  PVs List..............: ${PV_LIST}

EOF
}

# -------------------
init_vars()
# -------------------
{
    HOST=$(hostname)
    [[ -z "$SERVICE" ]] && return 1
    # SERVICE must not be a path - catch swapped arguments
    [[ "$SERVICE" == /* ]] && return 5

    # Collect cluster nodes
    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]] && return 2
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    # Validate service exists
    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]] && return 3
    grep -Fxq "${SERVICE}" <<< "${SERVICES}" || return 4

    # Resolve PRIMARY / STANDBY
    resolve_svc_nodes; RC=$?
    # If service is fully down, PRIMARY may not resolve - use local host
    (( RC == 1 )) && { PRIMARY="${HOST}"; NODE="${HOST}"; STANDBY="none"; return 0; }
    (( RC == 2 )) && { STANDBY="none"; return 0; }

    # Collect VG name from disk# resource
    local DISK_RID
    DISK_RID="$(om "${SERVICE}" print status -r --node "${NODE}" 2>/dev/null | awk '/disk#[0-9]+[^p]/ {print $2; exit}')"
    [[ -n "$DISK_RID" ]] && VG_NAME="$(om "${SERVICE}" get --kw "${DISK_RID}".name 2>/dev/null)"

    # Collect all LV paths from fs# resources
    LV_LIST="$(om "${SERVICE}" print status -r --node "${NODE}" 2>/dev/null | awk '/fs#/ { gsub(/.*@/,"",$NF); print $NF }' | sort -u | tr '\n' ' ')"

    # Collect PVs belonging to this VG (for later removal)
    [[ -n "$VG_NAME" ]] && PV_LIST="$(remote "pvs --select vg_name=${VG_NAME} --noheadings -o pv_name 2>/dev/null | xargs")"

    return 0
}

#######################################################################
# MAIN
#######################################################################
# Load LIBS
MY_LIBS="./lib_common.sh ./lib_lvm.sh ./lib_opensvc.sh"
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
    5)  update_status err "SERVICE looks like a path (starts with /). Check arguments." ;;
    2)  update_status err "Cannot list cluster nodes." ;;
    3)  update_status err "Cannot list cluster services." ;;
    4)  update_status err "Service ${SERVICE} not found." ;;
    *)  update_status err "Unexpected error in init_vars (RC=${RC})." ;;
esac

show RED    "================================================================"
show RED    "             !! WARNING - IRREVERSIBLE ACTION !!"
show RED    "Service ${SERVICE} and ALL its data will be PERMANENTLY DELETED."
show RED    "================================================================"
show YELLOW "\t\tNodes   : ${NODES_CSV}"
show YELLOW "\t\tVG      : ${VG_NAME:-N/A}"
show YELLOW "\t\tLVs     : ${LV_LIST:-none}"
show YELLOW "\t\tPVs     : ${PV_LIST:-none}"
show GREEN  ""
prompt_continue "Confirm PERMANENT DECOMMISSION of service ${SERVICE}?" || update_status no_go "Decommission aborted by operator."


show RED "\n================================================================"
show RED "\tFinal confirmation required - ALL DATA WILL BE LOST."
show RED   "================================================================"
show GREEN ""
prompt_continue "Are you ABSOLUTELY SURE? This cannot be undone." || update_status no_go "Decommission aborted by operator."

########################################
stage "PRE-CHECK"
########################################
phase "Status of ${SERVICE} before decommission"
NODE=${PRIMARY}
check_ml_status; RC=$?
case $RC in
    11)  update_status ok   "Service ${SERVICE} confirmed as down on all nodes." ;;
     *)  update_status err  "Unexpected error (RC=${RC})." ;;
esac

########################################
NODE=${PRIMARY}
stage "On PRIMARY node (${PRIMARY})"
########################################
phase "Freezing the OpenSVC Cluster service"
opensvc_freeze "${SERVICE}"; RC=$?
case $RC in
    0) update_status ok   "${SERVICE} frozen successfully." ;;
    2) update_status ok "${SERVICE} is already frozen." ;;
    5) update_status err  "Failed to freeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status err  "Unexpected error during freeze (RC=${RC})." ;;
esac

phase "Stopping service ${SERVICE} on all nodes"
run_command -l "om ${SERVICE} stop --node ${NODES_CSV} --wait"; RC=$?
case $RC in
    0) update_status ok  "Service ${SERVICE} stopped on all nodes." ;;
    *) update_status warn "Stop returned RC=${RC} - proceeding." ;;
esac

phase "Deleting service ${SERVICE} from cluster"
show RED "\t\t!! DELETING ${SERVICE} NOW !!"
run_command -l "om ${SERVICE} delete --unprovision"; RC=$?
case $RC in
    0) update_status ok  "Service ${SERVICE} deleted from cluster." ;;
    *) update_status err "Deletion failed (RC=${RC}). Check 'om svc ls'." ;;
esac

cleanup_lvm_on_node "${VG_NAME}"; RC=$?
case $RC in
     0) ;;
     1) update_status err "Aborting... There are RAW devices in use. Please, Check manually." ;;
     2) update_status err ;;
     3) update_status warn "No active mount points found." ;;
 4|5|6) update_status err ;;
     *) update_status err "Unexpected error (RC=$RC)."
esac	

########################################
stage "POST-CHECK"
########################################
phase "Verifying ${SERVICE} no longer exists"
if om svc ls 2>/dev/null | grep -Fxq "${SERVICE}"; then
    update_status err "Service ${SERVICE} still visible. Check manually."
else
    update_status ok  "Service ${SERVICE} confirmed removed from cluster."
fi

phase "Verifying VG removed on all nodes"
if [[ -n "${VG_NAME}" ]]; then
    VG_REMAINING=false
    while IFS= read -r TARGET_NODE; do
        [[ -z "${TARGET_NODE}" ]] && continue
        if [[ "${HOST}" == "${TARGET_NODE}" ]]; then
            vgs "${VG_NAME}" &>/dev/null && VG_REMAINING=true && show YELLOW "\t\t${TARGET_NODE}: VG ${VG_NAME} still exists."
        else
            ssh -o LogLevel=ERROR root@"${TARGET_NODE}" "vgs ${VG_NAME}" &>/dev/null && VG_REMAINING=true && \
                show YELLOW "\t\t${TARGET_NODE}: VG ${VG_NAME} still exists."
        fi
    done <<< "${NODES}"
    if [[ "${VG_REMAINING}" == "true" ]]; then
        update_status warn "VG ${VG_NAME} still present on some nodes - check manually."
    else
        update_status ok   "VG ${VG_NAME} confirmed removed on all nodes."
    fi
else
    update_status skip "No VG found for service ${SERVICE}."
fi

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE ""
show BLUE "\t[Success]\tService ${SERVICE} permanently decommissioned."
show BLUE "\t\t\tAll data has been permanently destroyed."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
write_log "$(report_block)"
exit 0
