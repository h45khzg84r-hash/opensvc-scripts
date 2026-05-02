#!/bin/bash
# opensvc_add_fs.sh - Adds a new filesystem resource to an OpenSVC HA service
# Usage: opensvc_add_fs.sh <SERVICE> <FS> [SIZE_GB] [FSTYPE]
# Author.:
# Version: 20260419

SERVICE=$1
FS=$2
SIZE_GB="${3:-0.3}"    # default: 300MB (ignored if LV already exists)
FSTYPE="${4:-xfs}"

#######################################################################
# General Functions
#######################################################################

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <SERVICE> <FS> [SIZE_GB] [FSTYPE]"
    echo ""
    echo "  Arguments:"
    echo "    <SERVICE>   Name of the OpenSVC service (e.g. SERVICE_NAME)"
    echo "    <FS>        Mount point for the new filesystem (e.g. /SERVICE_NAME/newfs)"
    echo "    [SIZE_GB]   Size of the new LV in GB (default: 0.1 = 100MB)"
    echo "                Ignored if LV already exists - data is preserved."
    echo "    [FSTYPE]    Filesystem type: xfs, ext4, ext3, ext2 (default: xfs)"
    echo ""
    echo "  Notes:"
    echo "    - LV path is derived automatically as /dev/<VG>/<FS_with_slashes_as_underscores>."
    echo "    - If the LV already exists, SIZE_GB is ignored and data is preserved."
    echo "    - If the LV does not exist, it will be created with the given SIZE_GB."
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} SERVICE_NAME /SERVICE_NAME/newfs"
    echo "    ${SCRIPT} SERVICE_NAME /SERVICE_NAME/newfs 10"
    echo "    ${SCRIPT} SERVICE_NAME /SERVICE_NAME/newfs 20 ext4"
    echo ""
    exit 1
}

# -------------------
create_log()
# -------------------
{
    local HEADER
    HEADER="Activity...: Add filesystem resource to an OpenSVC service
 Service...: ${SERVICE}
 Resource..: ${NEW_RID:-N/A}
 Mount.....: ${FS}
 Device....: ${LV_PATH}
 FS Type...: ${FSTYPE}
 Size......: ${SIZE_GB}G ${LV_EXISTS_MSG}
 Primary...: ${PRIMARY} (${IP_PRI}) 
 Standby...: ${STANDBY} (${IP_STA})"
    write_log "${HEADER}"
}

# -------------------
init_vars()
# -------------------
{
    HOST=$(hostname)
    [[ -z "$SERVICE" ]]                           && return 1
    # SERVICE must not be a path - catch swapped arguments
    [[ "$SERVICE" == /* ]]                        && return 2
    [[ -z "$FS" ]]                                && return 3
    # FS must be an absolute path
    [[ "$FS" != /* ]]                             && return 4
    [[ ! "${FSTYPE}" =~ ^(xfs|ext4|ext3|ext2)$ ]] && return 5

    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]]                             && return 6
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]]                          && return 7

    grep -Fxq "${SERVICE}" <<< "${SERVICES}"      || return 8

    # Check if FS already exists in this service
    EXISTING_RID="$(om "${SERVICE}" print resinfo 2>/dev/null | awk -v fs="${FS}" '/mnt / && $NF==fs { print $NF }')"
    if [[ -n "${EXISTING_RID}" ]]; then
        # Already exist - only block if already running (nothing to do)
        local RID_STATUS
        RID_STATUS="$(om "${SERVICE}" print status -r 2>/dev/null | awk -v rid="${EXISTING_RID}" '$2==rid && $4=="up" {print "up"}')"
        [[ "${RID_STATUS}" == "up" ]]             && return 9
        FS_EXIST=true
    else
        FS_EXIST=false
    fi

    SVC_STATUS="$(om "${SERVICE}" print status --node "${NODES_CSV}" 2>/dev/null)"
    resolve_svc_nodes; RC=$?
    (( RC == 1 )) && return 10
    (( RC == 2 )) && return 11

    # VG from service disk resource
    local DISK_RID
    DISK_RID="$(om "${SERVICE}" print resinfo 2>/dev/null | awk '/ disk#[0-9]+[^p]/ { print $2; exit }')"
    [[ -z "$DISK_RID" ]] && return 12
    VG_NAME="$(om "${SERVICE}" get --kw "${DISK_RID}".name 2>/dev/null)"
    [[ -z "$VG_NAME" || "$VG_NAME" == "None" ]] && return 13

    # LV_PATH: /dev/<VG>/<FS_with_slashes_as_underscores>
    local FS_STRIPPED="${FS#/}"
    LV_SHORT="${FS_STRIPPED//\//_}"
    LV_PATH="/dev/${VG_NAME}/${LV_SHORT}"

    # Check LV doesnt exist (skip if we already know it is)
    if [[ "${FS_EXIST}" == "false" ]]; then
        grep -qP "^\s*dev\s*=\s*${LV_PATH//\//\\/}\s*$" /etc/opensvc/"${SERVICE}".conf 2>/dev/null && return 14
    fi

    # Check if LV already exists on the system
    LV_SIZE="$( remote "lvs ${LV_PATH} --noheadings --units g --nosuffix -o lv_size 2>/dev/null|xargs")"
    if [[ -n "${LV_SIZE}" ]]; then
        LV_EXISTS=true
        EXISTING_FS=$(remote "blkid ${LV_PATH} -o value -s TYPE 2>/dev/null")
	[[ -n "${EXISTING_FS}" ]] && FSTYPE="${EXISTING_FS}"
        LV_EXISTS_MSG="(LV already exists - size preserved)"
	SIZE_GB=${LV_SIZE}
    else
        LV_EXISTS=false
        [[ ! "$SIZE_GB" =~ ^[0-9]*([.][0-9]+)?$ ]] && return 15
        (( $(echo "${SIZE_GB} > 0" | bc -l) ))     || return 15

        # Check VG has sufficient free space
        local VG_FREE_BYTES VG_FREE_G SIZE_BYTES
        VG_FREE_BYTES=$(remote "vgs ${VG_NAME} --noheadings --units b --nosuffix -o vg_free 2>/dev/null | xargs")
        SIZE_BYTES=$(echo "${SIZE_GB} * 1024^3" | bc -l | cut -d. -f1)
        [[ -z "$VG_FREE_BYTES" ]]                                && return 16
        (( $(echo "${VG_FREE_BYTES} < ${SIZE_BYTES}" | bc -l) )) && return 17

        EXISTING_FS=""
        LV_EXISTS_MSG="(LV will be created)"
    fi

    MOUNTED=$(remote "mountpoint -q ${FS} 2>/dev/null && echo mounted")
    [[ "${MOUNTED}" == "mounted" ]] && return 18

    # RID: use existing if it already exists, otherwise compute next available
    if [[ "${FS_EXIST}" == "true" ]]; then
        NEW_RID="${EXISTING_RID}"
    else
        local RID_BASE EXISTING_RIDS COUNTER
        RID_BASE="fs#${LV_SHORT}"
        EXISTING_RIDS="$(om "${SERVICE}" print resinfo 2>/dev/null | grep -oP 'fs#\S+')"
        if grep -qxF "${RID_BASE}" <<< "${EXISTING_RIDS}"; then
            COUNTER=1
            while grep -qxF "${RID_BASE}_${COUNTER}" <<< "${EXISTING_RIDS}"; do
                (( COUNTER++ ))
            done
            NEW_RID="${RID_BASE}_${COUNTER}"
        else
            NEW_RID="${RID_BASE}"
        fi
    fi
    RID="${NEW_RID}"

    IP_PRI="$(getent ahostsv4 "${PRIMARY}" | head -1 | awk '{print $1}')"
    IP_STA="$(getent ahostsv4 "${STANDBY}" | head -1 | awk '{print $1}')"

    remote "command -v needs-restarting &>/dev/null || dnf install -q -y dnf-utils &>/dev/null"

    return 0
}


#######################################################################
# MAIN
#######################################################################

LIBCOMMON="./lib_common.sh"
[[ -f "${LIBCOMMON}" ]]  || { echo "Library not found: ${LIBCOMMON}"; exit 1; }  && source "${LIBCOMMON}"
LIBOPENSVC="./lib_opensvc.sh"
[[ -f "${LIBOPENSVC}" ]] || { echo "Library not found: ${LIBOPENSVC}"; exit 1; } && source "${LIBOPENSVC}"
LIBLVM="./lib_lvm.sh"
[[ -f "${LIBLVM}" ]]     || { echo "Library not found: ${LIBLVM}"; exit 1; }     && source "${LIBLVM}"

[[ "$1" == "-h" || "$1" == "--help" ]] && usage
[[ $# -lt 2 ]] && usage "Missing arguments. Expected at least 2, got $#."
[[ -z "$3" || "$3" =~ ^[0-9]*([.][0-9]+)?$ ]] || usage "SIZE_GB must be a positive number (got: $3)."
[[ "$4" =~ ^(xfs|ext4|ext3|ext2)?$ ]] || usage "Invalid FSTYPE: $4. Supported: xfs, ext4, ext3, ext2."

init_logs

clear

########################################
stage "Activity started in $(date +'%d/%m/%Y %H:%M')"
########################################
phase "Collecting information"
init_vars; RC=$?
case $RC in
    0)  update_status ok  "Information collected:\n" 
        show GREEN "\t\tService............: ${SERVICE}"
        show GREEN "\t\tNew Filesystem.....: ${FS}"
        show GREEN "\t\tFilesystem type....: ${FSTYPE}"
        show GREEN "\t\tLogical Volume.....: ${LV_PATH} ${LV_EXISTS_MSG}"
        show GREEN "\t\tSize...............: ${SIZE_GB}G"
        show GREEN "\t\tResource ID........: ${NEW_RID}"
        show GREEN "\t\tPrimary Node.......: ${PRIMARY} (${IP_PRI})"
        show GREEN "\t\tStandby Node.......: ${STANDBY} (${IP_STA})"
        show GREEN "" ;;
    1)  update_status err  "Variable SERVICE is empty." ;;
    2)  update_status err  "SERVICE looks like a path (starts with /). Did you swap SERVICE and FS?" ;;
    3)  update_status err  "Variable FS (mount point) is empty." ;;
    4)  update_status err  "FS must be an absolute path (starts with /)." ;;
    5)  update_status err  "Invalid filesystem type '${FSTYPE}'. Supported: xfs, ext4, ext3, ext2." ;;
    6)  update_status err  "Cannot list cluster nodes." ;;
    7)  update_status err  "Cannot list cluster services." ;;
    8)  update_status err  "Service ${SERVICE} not found." ;;
    9)  update_status err  "Resource ${FS} is already active in ${SERVICE}. Nothing to do." ;;
    10) update_status err  "PRIMARY node is empty - is ${SERVICE} down?" ;;
    11) update_status err  "STANDBY node is empty - is it down?" ;;
    12) update_status err  "Cannot determine DISK RID of VG for service ${SERVICE}. Check disk resource." ;;
    13) update_status err  "Cannot determine VG for service ${SERVICE}. Check disk resource." ;;
    14) update_status err  "Device ${LV_PATH} already exists in ${SERVICE}." ;;
    15) update_status err  "Invalid SIZE_GB: ${SIZE_GB}. Must be a positive number." ;;
    16) update_status err  "Cannot determine free space in VG ${VG_NAME}." ;;
    17) update_status err  "Insufficient space in VG ${VG_NAME} to create LV of ${SIZE_GB}G." ;;
    18) update_status err  "Mount point ${FS} is already mounted on ${PRIMARY}." ;;
    *)  update_status err  "Unexpected error in init_vars (RC=${RC})." ;;
esac

########################################
stage "PRE-CHECK"
########################################

phase "Checking service ${SERVICE} status"
check_ml_status sync prstart provisioned rid; RC=$?
case $RC in
    0|10)  update_status ok ;;
11|12|13)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   14|15)  prompt_continue || update_status no_go "Aborting - check cluster status before continuing." ;;
   16|17)  update_status warn ;;
       *)  update_status err  "Unexpected error during fix (RC=${RC})." ;;
esac

phase "Checking LV ${LV_SHORT} status"
if [[ "${LV_EXISTS}" == "true" ]]; then
    check_lv_status; RC=$?
    case $RC in
        0) update_status ok  "LV ${LV_PATH} looks good and is ready for use." ;;
        3) update_status err "LV ${LV_PATH} is inactive on ${PRIMARY}. Check LVM / OpenSVC state." ;;
        4) update_status err "LV ${LV_PATH} is already open/in use on ${PRIMARY}." ;;
        5) update_status err "LV ${LV_PATH}: pvmove in progress." ;;
        6) update_status err "LV ${LV_PATH} is read-only." ;;
        7) update_status err "LV ${LV_PATH} is suspended." ;;
        *) update_status err "Unexpected error during LV status check (RC=${RC})." ;;
    esac
else
    run_command "lvs ${VG_NAME}" || update_status err   "Unexpected error during lvs command (RC=${RC})."	
    update_status ok "LV ${LV_PATH} does not exist and it will be created on VG ${VG_NAME} with ${SIZE_GB}G."
fi

phase "Checking multipath status"
multipath_status; RC=$?
case $RC in
    0) update_status ok    "No multipath issues." ;;
    3) update_status warn  ;;
    4) update_status no_go ;;
    *) update_status err   "Unexpected error during multipath check (RC=${RC})." ;;
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
    0) update_status ok    "Service frozen successfully." ;;
    2) update_status warn  "Service is already frozen." ;;
    5) update_status err   "Failed to freeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status err   "Unexpected error during freeze (RC=${RC})." ;;
esac


NODE=${PRIMARY}
phase "Creating LV ${LV_SHORT} on VG ${VG_NAME}"
if [[ "${LV_EXISTS}" == "false" ]]; then
    run_command "lvcreate -L ${SIZE_GB}G -y -n ${LV_SHORT} ${VG_NAME}"; RC=$?
    case $RC in
        0) update_status ok   "LV ${LV_PATH} created successfully (${SIZE_GB}G)." ;;
        *) update_status err  "lvcreate failed on VG ${VG_NAME} (RC=${RC})." ;;
    esac
else
    run_command "lvs ${VG_NAME}" || update_status err   "Unexpected error during lvs command (RC=${RC})."	
    update_status skip "LV ${LV_PATH} already exists - lvcreate command skipped."
    show YELLOW "\t\tThe original size will be preserved."
fi

phase "Adding ${NEW_RID} to ${SERVICE}"
if [[ "${FS_EXIST}" == "false" ]]; then
    run_command -l "om ${SERVICE} set --kw ${NEW_RID}.dev=${LV_PATH} --kw ${NEW_RID}.mnt=${FS} --kw ${NEW_RID}.type=${FSTYPE} --kw ${NEW_RID}.monitor=true"; RC=$?
    case $RC in
        0) update_status ok   "Resource ${NEW_RID} (type=${FSTYPE}, dev=${LV_PATH}, mnt=${FS}) added to ${SERVICE}." ;;
        *) update_status err  "Failed to add resource ${NEW_RID}. Check 'om ${SERVICE} print resinfo'." ;;
    esac
else
    run_command -l "om ${SERVICE} print status --node ${NODE} | grep ${NEW_RID}" || update_status err "Unexpected error in the print status (RC=${RC})."
    update_status skip "Resource ${NEW_RID} already exists in ${SERVICE} - skipping om set command."
fi

phase "Creating mount point ${FS}"
if [[ ! -d "${FS}" ]]; then
    NODE=${PRIMARY}
    run_command "mkdir -p ${FS}"; RC=$?
    case $RC in
        0) update_status ok   "Directory ${FS} created." ;;
        *) update_status err  "Failed to create directory ${FS} on ${PRIMARY}." ;;
    esac
else
    run_command "ls -ld ${FS}" || update_status err   "Unexpected error during ls command  (RC=${RC})."
    update_status skip "Directory ${FS} already exists."
fi

phase "Creating ${FSTYPE} FS on ${LV_SHORT}"
if [[ -z "${EXISTING_FS}" ]]; then
    NODE=${PRIMARY}
    make_mkfs; RC=$?
    case $RC in
        0)   update_status ok   "Filesystem ${FSTYPE} created successfully on ${LV_PATH}." ;;
        2|3) update_status err  "mkfs.${FSTYPE} failed on ${LV_PATH} (RC=${RC})." ;;
        *)   update_status err  "Unexpected error during mkfs (RC=${RC})." ;;
    esac
else
    run_command "blkid ${LV_PATH}" || update_status err   "Unexpected error during df command  (RC=${RC})."
    update_status skip "LV already formatted as ${EXISTING_FS} - mkfs skipped. Data preserved."
fi

phase "Set ${NEW_RID} as provisioned"
if [[ "${FS_EXIST}" == "false" ]]; then
    run_command -l "om ${SERVICE} set provisioned --rid ${NEW_RID} --node ${NODES_CSV}"; RC=$?
    case $RC in
        0) update_status ok   "Resource ${NEW_RID} marked as provisioned on all nodes." ;;
        *) update_status err  "Failed to set ${NEW_RID} as provisioned." ;;
    esac
else
    run_command -l "om ${SERVICE} print status --node ${NODE} | grep ${NEW_RID}" || update_status err "Unexpected error in the print status (RC=${RC})."
    update_status skip "Resource ${NEW_RID} already exists - provisioning state preserved."
fi

phase "Mounting ${FS} by the OpenSVC"
run_command -l "om ${SERVICE} start --rid ${NEW_RID} --node ${PRIMARY}"; RC=$?
case $RC in
    0) update_status ok   "Resource ${NEW_RID} started successfully." ;;
    *) update_status err  "Failed to start ${NEW_RID}. Check 'om ${SERVICE} print status -r'." ;;
esac

phase "Verify ${FS} is mounted"
NODE=${PRIMARY}
run_command "mountpoint ${FS} && timeout 10 df -h ${FS}"; RC=$?
case $RC in
    0) update_status ok   "${FS} confirmed as mounted." ;;
    *) update_status err  "${FS} is not mounted after start. Check 'om ${SERVICE} print status -r'." ;;
esac

phase "Sync config to cluster nodes"
NODE=${PRIMARY}
run_command -l "om ${SERVICE} sync all"; RC=$?
case $RC in
    0) update_status ok   "Service configuration synced to all cluster nodes." ;;
    *) update_status err  "Sync failed. Check cluster connectivity." ;;
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
    0) update_status ok    "Service unfrozen successfully." ;;
    2) update_status warn  "Service is already unfrozen." ;;
    5) update_status err   "Failed to unfreeze (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
    *) update_status err   "Unexpected error during freeze (RC=${RC})." ;;
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

phase "Verify ${FS} is still mounted"
NODE=${PRIMARY}
run_command "mountpoint ${FS} && timeout 10 df -h ${FS}"; RC=$?
case $RC in
    0) update_status ok   "${FS} confirmed as mounted." ;;
    *) update_status err  "${FS} is not mounted. Check 'om ${SERVICE} print status -r'." ;;
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
show BLUE "\t\tThe filesystem was mounted in ${FS} with ${SIZE_GB}G."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
create_log
exit 0

