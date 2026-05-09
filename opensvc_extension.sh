#!/bin/bash
# opensvc_extension.sh - Extends a filesystem in an OpenSVC HA cluster
# Usage: opensvc_extension.sh <FS> <SIZE_GB>
# Author.: adriano.costa
# Version: 20260419

FS=$1
SIZE=$2

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <FS> <SIZE_GB>"
    echo ""
    echo "  Arguments:"
    echo "    <FS>        Mount point of the filesystem to extend (e.g. /data/myapp)"
    echo "    <SIZE_GB>   Target size in GB - must be greater than current size (e.g. 50)"
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} /data/myapp 50"
    echo "    ${SCRIPT} /SERVICE_NAME/data 100"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF

Extension of filesystem in an OpenSVC Cluster:
  Service Name ......: ${SERVICE}"
  Primary Node.......: ${PRIMARY} (${IP_PRI})"
  Standby Node.......: ${STANDBY} (${IP_STA})"

LVM service structure:
  Resource ID........: ${RID}
  Filesystem.........: ${FS}
  OLD size...........: ${OLD_LV_SIZE_G}G
  NEW size...........: ${SIZE_G}G

EOF
}

# -------------------
init_vars()
# -------------------
{
    local COUNT SVC_STATUS

    HOST=$(hostname)
    [[ -z "$FS" ]] && return 1

    SERVICE="$(grep -Rl "mnt *= *${FS}\>" /etc/opensvc/ | xargs -n1 basename | sed 's/.conf$//')"
    [[ -z "$SERVICE" ]] && return 2
    COUNT=$(grep -c '.' <<< "${SERVICE}")
    (( COUNT > 1 )) && { echo "Multiple services with mnt=${FS}: ${SERVICE}"; return 2; }

    RID="$(om "${SERVICE}" print resinfo | awk '/^[|`]-/ && /[a-z]#/ { rid=$2 } /mnt / && $NF == "'"${FS}"'" { print rid }')"
    [[ -z "$RID" ]] && return 3

    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]] && return 8
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    SVC_STATUS="$(om "${SERVICE}" print status --node "${NODES_CSV}" 2>/dev/null)"
    resolve_svc_nodes; RC=$?
    (( RC == 1 )) && return 5
    (( RC == 2 )) && return 4

    LV_NAME="$(om "${SERVICE}" get --kw "${RID}".dev 2>/dev/null)"
    [[ -z "$LV_NAME" || "$LV_NAME" == "None" ]] && return 6

    VG_NAME="$(remote "lvs ${LV_NAME} --noheadings -o vg_name 2>/dev/null | xargs")"
    [[ -z "$VG_NAME" || "$VG_NAME" == "None" ]] && return 7

    remote "command -v needs-restarting &>/dev/null || dnf install -q -y dnf-utils &>/dev/null"

    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]] && return 9

    grep -Fxq "${SERVICE}" <<< "${SERVICES}" || return 11

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
[[ $# -lt 2 ]] && usage "Missing arguments. Expected 2, got $#."
[[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]] || usage "SIZE_GB must be a positive number (got: $2)."
NEED_LUN=0
OLD_LV_SIZE_G=0

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
    1)   update_status err "Variable FS is empty." ;;
    2)   update_status err "Cannot identify SERVICE for ${FS}. Is it in an OpenSVC cluster?" ;;
    3)   update_status err "Cannot determine RID for ${FS}." ;;
    4)   update_status err "STANDBY node is empty - is it down?" ;;
    5)   update_status err "PRIMARY node is empty - is ${SERVICE} down?" ;;
    6)   update_status err "LV_NAME is empty." ;;
    7)   update_status err "VG_NAME is empty." ;;
    8)   update_status err "Cannot list cluster nodes." ;;
    9)   update_status err "Cannot list cluster services." ;;
    11)  update_status err "Service ${SERVICE} not found." ;;
    *)   update_status err "Unexpected error in init_vars (RC=${RC})." ;;
esac

SIZE_G=$(printf "%.2f" "$(bc -l <<< "scale=2; ${SIZE}")")
SIZE_B=$(bc -l <<< "scale=2; ${SIZE} * 1024^3")

########################################
stage "PRE-CHECK"
########################################
phase "Checking status of ${SERVICE}"
check_ml_status sync prstart provisioned rid; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

phase "Checking LVM status"
check_lvm_status; RC=$?
case $RC in
    0) update_status ok "LVM status looks good. VG has sufficient free space." ;;
    5) update_status ok "LVM status OK. VG has insufficient free space - a new LUN will be required."; NEED_LUN=1 ;;
    6) update_status err "Desired size (${SIZE_G}G) is not greater than current size (${LV_SIZE_G}G)." ;;
    *) update_status err "Unexpected error during LVM status check (RC=${RC})." ;;
esac

phase "Checking multipath status"
multipath_status; RC=$?
case $RC in
    0) update_status ok   "No multipath issues.\n" ;;
    3) update_status warn ;;
    4) update_status no_go ;;
    *) update_status err  "Unexpected error during multipath command (RC=${RC})." ;;
esac

phase "Checking for a pending reboot"
run_command "needs-restarting -r"; RC=$?
case $RC in
    0) update_status ok  "No system reboot required before this extension." ;;
    *) update_status err "System requires reboot before maintenance." ;;
esac

########################################
stage "On PRIMARY node (${PRIMARY})"
########################################
phase "Extending lvol ${LV_NAME}"
make_lv_extension; RC=$?
case $RC in
    0) update_status ok    "lvol ${LV_NAME} extended (${LV_SIZE_G}G to ${SIZE}G)."; write_log "$(report_block)"
       show BLUE "\n\t\tLog: ${FINAL_LOG}"; exit 0 ;;
    3) update_status skip  "Continuing..." ;;
    4) update_status no_go "Exiting..." ;;
    5) update_status err   "lvextend failed on ${LV_NAME}. Check 'lvs' and filesystem consistency." ;;
    7) update_status err   "LV size after extension is not what was expected." ;;
    *) update_status err   "Unexpected error during extension (RC=${RC})." ;;
esac

phase "Freezing the OpenSVC Cluster nodes"
opensvc_freeze node; RC=$?
case $RC in
    0) update_status ok   "Nodes frozen successfully." ;;
    2) update_status warn "Nodes are already frozen." ;;
    5) update_status err  "Failed to freeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status err  "Unexpected error during freeze (RC=${RC})." ;;
esac

phase "Checking service ${SERVICE} status"
check_ml_status sync prstart provisioned rid; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

phase "Checking if LVM cache is up-to-date"
run_command "pvscan --cache"; RC=$?
case $RC in
    0) update_status ok  "LVM internal cache updated." ;;
    *) update_status err "Unexpected error during pvscan (RC=${RC})." ;;
esac

phase "Rescanning SCSI bus to find new LUN"
make_rescan; RC=$?
case $RC in
    0) update_status ok "SCSI bus rescanned successfully." ;;
    *) update_status err "Unexpected error during rescan (RC=${RC})." ;;
esac

phase "Checking for new LUNs"
multipath_status; RC=$?
case $RC in
    0) update_status ok   "No multipath issues." ;;
    2) update_status err  "multipath -ll returned no output." ;;
    3) update_status warn ;;
    4) update_status no_go ;;
    *) update_status err  "Unexpected error during multipath command (RC=${RC})." ;;
esac
show GREEN ""

phase "Selecting new LUNs"
select_luns; RC=$?
LUNS=$(cat "${DIR}/luns_selected")
case $RC in
    0)   update_status ok    "LUNs selected:"
         for LUN in ${LUNS}; do show GREEN "\t\t${LUN}"; done ;;
    1|2) update_status no_go "No LUNs selected. Need a LUN of at least ${LUN_SIZE_G}G to extend ${FS} to ${SIZE_G}G." ;;
    3)   update_status err   "No LUNs detected. Need a LUN of at least ${LUN_SIZE_G}G to extend ${FS} to ${SIZE_G}G." ;;
esac

phase "Creating PV on new disks"
make_pvcreate; RC=$?
case $RC in
    0) update_status ok  "PV(s) created successfully." ;;
    *) update_status err "Unexpected error during pvcreate (RC=${RC})." ;;
esac

phase "Checking LVM state on primary node"
get_pvs_status || update_status err "Unexpected error during pvs command (RC=${RC})."
get_vgs_status || update_status err "Unexpected error during vgs command (RC=${RC})."
update_status ok "LVM state on primary node looks good."

phase "Checking multipath status"
multipath_status; RC=$?
case $RC in
    0) update_status ok   "No multipath issues." ;;
    3) update_status warn ;;
    4) update_status no_go ;;
    *) update_status err  "Unexpected error during multipath command (RC=${RC})." ;;
esac
show GREEN ""

########################################
NODE=${STANDBY}
stage "On STANDBY node (${STANDBY})"
########################################
phase "Checking LVM state on standby node"
get_pvs_status || update_status err "Unexpected error during pvs command (RC=${RC})."
get_vgs_status || update_status err "Unexpected error during vgs command (RC=${RC})."
update_status ok "LVM state on standby node looks good."

phase "Check ${SERVICE} on standby"
check_ml_status; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

phase "Check LVM cache on standby node"
run_command "pvscan --cache"; RC=$?
case $RC in
    0) update_status ok  "LVM internal cache updated." ;;
    *) update_status err "Unexpected error during pvscan (RC=${RC})." ;;
esac

phase "Creating multipaths on standby node"
run_command "multipath -r" || update_status err "Unexpected error during 'multipath -r' (RC=${RC})."
multipath_status; RC=$?
case $RC in
    0) update_status ok   "No multipath issues.\n" ;;
    3) update_status warn ;;
    4) update_status no_go ;;
    *) update_status err  "Unexpected error during multipath command (RC=${RC})." ;;
esac

########################################
NODE=${PRIMARY}
stage "On PRIMARY node (${PRIMARY})"
########################################
phase "Extending VG ${VG_NAME}"
make_vg_extension; RC=$?
case $RC in
    0) update_status ok  "VG ${VG_NAME} extended successfully."; NEED_LUN=0 ;;
[2-4]) update_status err "LVM inconsistency detected. Check 'vgs'/'lvs'." ;;
    5) update_status err "Space still insufficient after vgextend. VG: ${VG_SIZE_G}G, free: ${VG_FREE_G}G." ;;
    *) update_status err "Unexpected error during vgextend (RC=${RC})." ;;
esac

phase "Check ${SERVICE} on primary"
check_ml_status sync prstart provisioned rid; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

phase "Unfreezing the OpenSVC nodes"
opensvc_unfreeze; RC=$?
case $RC in
    0) update_status ok   "Nodes unfrozen successfully." ;;
    2) update_status warn "Nodes is already unfrozen." ;;
    5) update_status err  "Failed to unfreeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status err  "Unexpected error during freeze (RC=${RC})." ;;
esac

########################################
stage "POST-CHECK"
########################################
phase "Checking status of ${SERVICE}"
check_ml_status sync prstart provisioned rid; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

phase "Extending lvol on primary node"
make_lv_extension; RC=$?
case $RC in
    0) update_status ok   "lvol ${LV_NAME} extended (${LV_SIZE_G}G → ${SIZE}G)." ;;
    3) update_status err "Insufficient VG space persists after vgextend. Cannot extend ${FS} (RC=${RC})." ;;
    4) update_status skip ;;
    5) update_status err  "lvextend failed on ${LV_NAME}. Check 'lvs' and filesystem consistency." ;;
    7) update_status err  "LV size not as expected after extension." ;;
    *) update_status err  "Unexpected error during extension (RC=${RC})." ;;
esac

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE ""
show BLUE "[Success]\tThe filesystem ${FS} has been successfully extended from ${OLD_LV_SIZE_G}G to ${SIZE_G}G."
show BLUE "\t\tAll data has been preserved."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
write_log "$(report_block)"
exit 0