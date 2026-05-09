#!/bin/bash
# opensvc_remove_fs.sh - Remove a filesystem resource from an OpenSVC HA service
# The LV and its filesystem data are preserved; only the resource definition is removed.
# Usage: opensvc_remove_fs.sh <FS>
# Author.: adriano.costa
# Version: 20260508

FS=$1

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <FS>"
    echo ""
    echo "  Arguments:"
    echo "    <FS>   Mount point of the filesystem resource to remove"
    echo "           (e.g. /SERVICE_NAME/test0)"
    echo ""
    echo "  Notes:"
    echo "    - SERVICE and RID are derived automatically from the mount point."
    echo "    - The LV and its filesystem data are preserved."
    echo "    - Only the resource definition is removed from the service."
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} /SERVICE_NAME/test0"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF

Remove filesystem resource from OpenSVC service:
  Service Name.......: ${SERVICE}
  Primary Node.......: ${PRIMARY} (${IP_PRI})
  Standby Node.......: ${STANDBY} (${IP_STA})

RID (Filesystem) to remove:
  Resource ID........: ${RID}
  Filesystem Name....: ${FS}
  Logical Volume.....: ${FS_DEV}

EOF
}

# -------------------
init_vars()
# -------------------
{
    local COUNT

    HOST=$(hostname)
    [[ -z "$FS" ]] && return 1

    # Derive SERVICE from mount point (same logic as opensvc_extension.sh)
    SERVICE="$(grep -Rl "mnt *= *${FS}\>" /etc/opensvc/ | xargs -n1 basename | sed 's/.conf$//')"
    [[ -z "$SERVICE" ]] && return 2

    COUNT=$(grep -c '.' <<< "${SERVICE}")
    (( COUNT > 1 )) && return 3

    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]] && return 7

    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]] && return 8

    grep -Fxq "${SERVICE}" <<< "${SERVICES}" || return 9

    resolve_svc_nodes; RC=$?
    (( RC == 1 )) && return 10
    (( RC == 2 )) && return 11

    # Derive RID from mount point
    RID="$(om "${SERVICE}" print status -r --node "${NODE}" 2>/dev/null | awk -v fs="${FS}" '/fs#/ { gsub(/.*@/,"",$NF); if($NF==fs) print $2 }')"
    [[ -z "$RID" ]] && return 4
    [[ "$RID" =~ ^fs# ]] || return 5

    FS_DEV="$(remote "om ${SERVICE} get --kw ${RID}.dev 2>/dev/null")"
    [[ -z "$FS_DEV" || "$FS_DEV" == "None" ]] && return 6

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
[[ $# -lt 1 ]] && usage "Missing argument. FS (mount point) is required."

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
    1)  update_status err "Variable FS is empty." ;;
    2)  update_status err "This script is not support multiple services with mnt=${FS}." ;;
    3)  update_status err "Cannot identify SERVICE for ${FS}. Is it in an OpenSVC cluster?" ;;
    4)  update_status err "Cannot determine RID for ${FS}." ;;
    5)  update_status err "Resource for ${FS} is not a filesystem resource (must start with fs#)." ;;
    6)  update_status err "Cannot determine device (dev) for ${RID}." ;;
    7)  update_status err "Cannot list cluster nodes." ;;
    8)  update_status err "Cannot list cluster services." ;;
    9)  update_status err "Service ${SERVICE} not found." ;;
    10) update_status err "PRIMARY node is empty - is ${SERVICE} down?" ;;
    11) update_status err "STANDBY node is empty - is it down?" ;;
    *)  update_status err "Unexpected error in init_vars (RC=${RC})." ;;
esac

show YELLOW  "\n[ Warning ]\tTHIS ACTION IS REVERSIBLE."
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

phase "Unmounting ${FS}"
run_command -l "om ${SERVICE} stop --rid ${RID} --node ${PRIMARY}"; RC=$?
case $RC in
    0) update_status ok  "Resource ${RID} stopped - ${FS} unmounted on ${PRIMARY}." ;;
    *) update_status err "Failed to stop ${RID}. Check 'om ${SERVICE} print status -r'." ;;
esac

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

phase "Check ${SERVICE} status after changes"
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

phase "Verify ${FS} is unmounted"
run_command "! mountpoint -q ${FS} 2>/dev/null || timeout 10 df -h ${FS}"; RC=$?
case $RC in
    0) update_status ok  "${FS} confirmed as unmounted on ${PRIMARY}." ;;
    *) update_status warn "${FS} may still be mounted. Check manually." ;;
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

NODE=${PRIMARY}

show RED  ""
show RED  "[ Warning ]\tTHIS ACTION IS IRREVERSIBLE !!"
show RED  ""
show RED  "\t\tLogical Volume.....: ${FS_DEV}"
show RED  "\t\tAll data on this device will be permanently destroyed."
show GREEN ""
prompt_continue "Destroy FS on ${FS_DEV##*/}?"; REMOVE=$?
phase "Destroy FS on ${FS_DEV##*/}"
show GREEN ""
if (( REMOVE == 0 )); then
    show GREEN ""
    run_command "wipefs -a ${FS_DEV}"; RC=$?
    case $RC in
        0) update_status ok  "Filesystem signature wiped from ${FS_DEV}." ;;
        *) update_status err "wipefs failed on ${FS_DEV} (RC=${RC})." ;;
    esac
    show GREEN ""
    run_command "lvremove -y ${FS_DEV}"; RC=$?
    case $RC in
        0) update_status ok  "LV ${FS_DEV} removed successfully." ;;
        *) update_status err "lvremove failed on ${FS_DEV} (RC=${RC})." ;;
    esac
else
    run_command "lvs ${LV_PATH}" || update_status err "lvs command failed (RC=${RC})."
    update_status skip "Filesystem destruction skipped."
fi

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE ""
show BLUE "[Success]\tResource ${RID} has been removed in the ${SERVICE}."
(( REMOVE == 0)) && show BLUE "\t\tThe Filesystem ${FS} was unmounted its device ${FS_DEV} has been removed."
(( REMOVE == 0)) && show BLUE "\t\tTHE ACTION IS IRREVERSIBLE. All data has been permanently destroyed."
(( REMOVE == 1)) && show BLUE "\t\tThe Filesystem ${FS} was unmounted but the device ${FS_DEV} and its data are intact."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
write_log "$(report_block)"
exit 0