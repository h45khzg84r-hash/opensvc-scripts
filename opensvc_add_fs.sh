#!/bin/bash
# opensvc_add_fs.sh - Adds a new filesystem resource to an OpenSVC HA service
# Usage: opensvc_add_fs.sh <SERVICE> <FS> [SIZE_GB] [FSTYPE]
# Author.: adriano.costa
# Version: 20260508

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
    echo "    <SERVICE>   Name of the OpenSVC service (e.g. sltifraxssvc6)"
    echo "    <FS>        Mount point for the new filesystem (e.g. /sltifraxssvc6/newfs)"
    echo "    [SIZE_GB]   Size of the new LV in GB (default: 0.3 = 300MB)"
    echo "                Ignored if LV already exists - data is preserved."
    echo "    [FSTYPE]    Filesystem type: xfs, ext4, ext3 (default: xfs)"
    echo ""
    echo "  Notes:"
    echo "    - LV path is derived automatically as /dev/<VG>/<FS_with_slashes_as_underscores>."
    echo "    - RID is always lowercase. LV path and mount point preserve original case."
    echo "    - If the LV already exists, SIZE_GB is ignored and data is preserved."
    echo "    - If the LV does not exist, it will be created with the given SIZE_GB."
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} sltifraxssvc6 /sltifraxssvc6/newfs"
    echo "    ${SCRIPT} sltifraxssvc6 /sltifraxssvc6/newfs 10"
    echo "    ${SCRIPT} sltifraxssvc6 /sltifraxssvc6/newfs 20 ext4"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF

Add filesystem resource to an OpenSVC service:
  Service Name.......: ${SERVICE}
  Primary Node.......: ${PRIMARY} (${IP_PRI})
  Standby Node.......: ${STANDBY} (${IP_STA})

New Filesystem:
  Filesystem Name....: ${FS}
  Logical Volume.....: ${LV_PATH} ${LV_EXISTS_MSG}
  Filesystem type....: ${FSTYPE}
  Size...............: ${SIZE_GB}G
  Permissions........: ${P_PERM}
  Mountpoint owner...: ${P_OWNER} (${P_OWNER_UID})
  Mountpoint group...: ${P_GROUP} (${P_OWNER_GID})

Resource parameters:
  Resource ID........: ${NEW_RID}
  monitor............: ${P_MONITOR}
  shared.............: ${P_SHARED}
  optional...........: ${P_OPTIONAL}
  restart............: ${P_RESTART:-0 (disabled)}
  restart_delay......: ${P_RESTART_DELAY:-0 (disabled)}
EOF
}

# -------------------
init_vars()
# -------------------
{
    HOST=$(hostname)
    [[ -z "$SERVICE" ]]                            && return 1
    # SERVICE must not be a path 
    [[ "$SERVICE" == /* ]]                         && return 2
    [[ -z "$FS" ]]                                 && return 3
    # FS must be an absolute path
    [[ "$FS" != /* ]]                              && return 4
    [[ ! "${FSTYPE}" =~ ^(xfs|ext4|ext3)$ ]]       && return 5

    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]]                              && return 6
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    SERVICES="$(om svc ls 2>&1)"
    [[ -z "$SERVICES" ]]                           && return 7

    grep -Fxq "${SERVICE}" <<< "${SERVICES}"       || return 8

    # Check if FS already exists in this service
    EXISTING_RID="$(om "${SERVICE}" print resinfo 2>/dev/null | awk -v fs="${FS}" '/mnt / && $NF==fs { print $NF }')"
    if [[ -n "${EXISTING_RID}" ]]; then
        # Already exist - nothing to do
        local RID_STATUS
        RID_STATUS="$(om "${SERVICE}" print status -r 2>/dev/null | awk -v rid="${EXISTING_RID}" '$2==rid && $4=="up" {print "up"}')"
        [[ "${RID_STATUS}" == "up" ]] && return 9
        FS_EXIST=true
    else
        FS_EXIST=false
    fi

    resolve_svc_nodes; RC=$?
    (( RC == 1 )) && return 10
    (( RC == 2 )) && return 11

    # VG from service disk resource
    local DISK_RID
    DISK_RID="$(om "${SERVICE}" print resinfo 2>/dev/null | awk '/ disk#[0-9]+[^p]/ { print $2; exit }')"
    [[ -z "$DISK_RID" ]] && return 12
    VG_NAME="$(om "${SERVICE}" get --kw "${DISK_RID}".name 2>/dev/null)"
    [[ -z "$VG_NAME" || "$VG_NAME" == "None" ]] && return 13

    # LV_SHORT (used for LV_PATH and mnt)
    # RID_SHORT lowercase 
    local FS_STRIPPED="${FS#/}"
    LV_SHORT="${FS_STRIPPED//\//_}"
    RID_SHORT="${LV_SHORT,,}"         ## set lowercase
    LV_PATH="/dev/${VG_NAME}/${LV_SHORT}"

    # Check LV doesnt exist (skip if FS_EXIST)
    if [[ "${FS_EXIST}" == "false" ]]; then
        grep -qP "^\s*dev\s*=\s*${LV_PATH//\//\\/}\s*$" /etc/opensvc/"${SERVICE}".conf 2>/dev/null && return 14
    fi

    # Check if LV already exists on the system
    LV_SIZE="$(remote "lvs ${LV_PATH} --noheadings --units g --nosuffix -o lv_size 2>/dev/null | xargs")"
    if [[ -n "${LV_SIZE}" ]]; then
        LV_EXISTS=true
        LV_EXISTS_MSG="(LV already exists - size preserved)"
        SIZE_GB=${LV_SIZE}

        EXISTING_FS=$(remote "blkid ${LV_PATH} -o value -s TYPE 2>/dev/null")
        [[ -n "${EXISTING_FS}" ]] && FSTYPE="${EXISTING_FS}"
    else
        LV_EXISTS=false
        LV_EXISTS_MSG="(LV will be created)"

        [[ ! "$SIZE_GB" =~ ^[0-9]*([.][0-9]+)?$ ]]  && return 15
        (( $(echo "${SIZE_GB} > 0" | bc -l) ))      || return 15

        # Check VG has sufficient free space
        local VG_FREE_BYTES SIZE_BYTES
        VG_FREE_BYTES=$(remote "vgs ${VG_NAME} --noheadings --units b --nosuffix -o vg_free 2>/dev/null | xargs")
        [[ -z "$VG_FREE_BYTES" ]]                   && return 16

        SIZE_BYTES=$(echo "${SIZE_GB} * 1024^3" | bc -l | cut -d. -f1)
        
        (( $(echo "${VG_FREE_BYTES} < ${SIZE_BYTES}" | bc -l) )) && return 17

        EXISTING_FS=""
    fi

    MOUNTED=$(remote "mountpoint -q ${FS} 2>/dev/null && echo mounted")
    [[ "${MOUNTED}" == "mounted" ]] && return 18

    # RID: if no exist FS_EXIST, set next available (lowercase)
    if [[ "${FS_EXIST}" == "true" ]]; then
        NEW_RID="${EXISTING_RID}"
    else
        local RID_BASE EXISTING_RIDS COUNTER
        RID_BASE="fs#${RID_SHORT}"
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

    remote "command -v needs-restarting &>/dev/null || dnf install -q -y dnf-utils &>/dev/null"

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
[[ $# -lt 2 ]] && usage "Missing arguments. Expected at least 2, got $#."
[[ -z "$3" || "$3" =~ ^[0-9]*([.][0-9]+)?$ ]] || usage "SIZE_GB must be a positive number (got: $3)."
[[ "$4" =~ ^(xfs|ext4|ext3)?$ ]] || usage "Invalid FSTYPE: $4. Supported: xfs, ext4, ext3."

init_logs

clear

########################################
stage "Activity started in $(date +'%d/%m/%Y %H:%M')"
########################################
phase "Collecting information"
init_vars; RC=$?
case $RC in
    0)  ;;
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

show BLUE "Environment collected. Now configure the resource parameters."
show BLUE "Press Enter to accept the default value shown in brackets.\n"

# Monitor
show BLUE "\nResource parameter: monitor"
show BLUE "============================="
show BLUE "  Restart the resource automatically if it goes down [default: true]."
P_MONITOR=$(select_bool "monitor" "true")

# Shared
show BLUE "\nResource parameter: shared"
show BLUE "============================"
show BLUE "  Resource is shared across all cluster nodes (HA) [default: true]."
P_SHARED=$(select_bool "shared" "true")

# Optional
show BLUE "\nResource parameter: optional"
show BLUE "=============================="
show BLUE "  If true, resource failure does not affect service status [default: false]."
P_OPTIONAL=$(select_bool "optional" "false")

# Restart
show BLUE "\nResource parameter: restart"
show BLUE "============================="
show BLUE "  Number of restart attempts before giving up. 0 = disabled  [default: 2]."
P_RESTART=$(select_numeric "restart" 2)

# Restart delay
show BLUE "\nResource parameter: restart delay"
show BLUE "==================================="
show BLUE "  Seconds to wait between restart attempts. 0 = disabled  [default: 3]."
P_RESTART_DELAY=$(select_numeric "restart_delay" 3)

# Permissions
show BLUE "\nMount point permissions"
show BLUE "======================="
show BLUE "  Mount point permissions in octal format (e.g. 755, 775). The default is 755."
while true; do
    read -rp "What is the mount point permissions [Enter=755]: " P_PERM
    P_PERM="${P_PERM:-755}"
    [[ "$P_PERM" =~ ^[0-7]{3,4}$ ]] && break
    show YELLOW "\t\tInvalid permission. Use octal format (e.g. 755, 775, 0755)."
done

# Owner - validated locally via getent
show BLUE "\nMount point owner"
show BLUE "================="
show BLUE "  User owner of the mount point.The default is root."
while true; do
    read -rp "User owner [Enter=root]: " P_OWNER
    P_OWNER="${P_OWNER:-root}"
    PASSWD_LINE=$(getent passwd "$P_OWNER")
    if [[ -n "$PASSWD_LINE" ]]; then
        P_OWNER_UID=$(echo "$PASSWD_LINE" | cut -d: -f3)
        break
    fi
    show YELLOW "\t\tUser ${P_OWNER} not found. Try again."
done

# Group - validated locally via getent
show BLUE "\nMount point group owner"
show BLUE "======================="
show BLUE "  Group owner of the mount point. The default is root."
while true; do
    read -rp "Group group [Enter=root]: " P_GROUP
    P_GROUP="${P_GROUP:-root}"
    GROUP_LINE=$(getent passwd "$P_GROUP")
    if [[ -n "$GROUP_LINE" ]]; then
        P_OWNER_GID=$(echo "$GROUP_LINE" | cut -d: -f3)
        break
    fi
    show YELLOW "\t\tGroup ${P_GROUP} not found. Try again."
done

show GREEN ""
while IFS= read -r LINE; do
    show GREEN "\t\t${LINE}"
done < <(build_report_block)

prompt_continue "Everything is ok?" || update_status no_go "Aborting - check all information before continuing."
update_status ok  "All the information was collected.\n"

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
    run_command "lvs ${VG_NAME}" || update_status err "Unexpected error during lvs command (RC=${RC})."
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
    run_command "lvs ${VG_NAME}" || update_status err "Unexpected error during lvs command (RC=${RC})."
    update_status skip "LV ${LV_PATH} already exists - lvcreate command skipped."
    show YELLOW "\t\tThe original size will be preserved."
fi

phase "Adding ${NEW_RID} to ${SERVICE}"
if [[ "${FS_EXIST}" == "false" ]]; then
    # Build kw list 
    KW="--kw ${NEW_RID}.dev=${LV_PATH}"
    KW+=" --kw ${NEW_RID}.mnt=${FS}"
    KW+=" --kw ${NEW_RID}.type=${FSTYPE}"
    KW+=" --kw ${NEW_RID}.monitor=${P_MONITOR}"
    KW+=" --kw ${NEW_RID}.shared=${P_SHARED}"
    KW+=" --kw ${NEW_RID}.optional=${P_OPTIONAL}"
    KW+=" --kw ${NEW_RID}.perm=${P_PERM}"
    KW+=" --kw ${NEW_RID}.user=${P_OWNER}"
    KW+=" --kw ${NEW_RID}.group=${P_GROUP}"
    [[ -n "${P_RESTART}"       ]] && KW+=" --kw ${NEW_RID}.restart=${P_RESTART}"
    [[ -n "${P_RESTART_DELAY}" ]] && KW+=" --kw ${NEW_RID}.restart_delay=${P_RESTART_DELAY}"

    run_command -l "om ${SERVICE} set ${KW}"; RC=$?
    case $RC in
        0) update_status ok   "Resource ${NEW_RID} (type=${FSTYPE}, dev=${LV_PATH}, mnt=${FS}) added to ${SERVICE}." ;;
        *) update_status err  "Failed to add resource ${NEW_RID}. Check 'om ${SERVICE} print resinfo'." ;;
    esac
else
    run_command -l "om ${SERVICE} print status --node ${NODE} | grep ${NEW_RID}" || update_status err "Unexpected error in the print status (RC=${RC})."
    update_status skip "Resource ${NEW_RID} already exists in ${SERVICE} - skipping om set command."
fi

phase "Creating mount point"
if [[ ! -d "${FS}" ]]; then
    NODE=${PRIMARY}
    run_command "mkdir -p ${FS}"; RC=$?
    case $RC in
        0) update_status ok   "Directory ${FS} created." ;;
        *) update_status err  "Failed to create directory ${FS} on ${PRIMARY}." ;;
    esac
else
    run_command "ls -ld ${FS}" || update_status err "Unexpected error during ls command (RC=${RC})."
    update_status skip "Directory ${FS} already exists."
fi

phase "Creating ${FSTYPE} Filesystem"
if [[ -z "${EXISTING_FS}" ]]; then
    NODE=${PRIMARY}
    make_mkfs; RC=$?
    case $RC in
        0)   update_status ok   "Filesystem ${FSTYPE} created successfully on ${LV_PATH}." ;;
        2|3) update_status err  "mkfs.${FSTYPE} failed on ${LV_PATH} (RC=${RC})." ;;
        *)   update_status err  "Unexpected error during mkfs (RC=${RC})." ;;
    esac
else
    run_command "blkid ${LV_PATH}" || update_status err "Unexpected error during blkid command (RC=${RC})."
    update_status skip "LV already formatted as ${EXISTING_FS} - mkfs skipped. Data preserved."
fi

phase "Set ${NEW_RID} as provisioned"
if [[ "${FS_EXIST}" == "false" ]]; then
    run_command -l "om ${SERVICE} set provision --node ${NODES_CSV}"; RC=$?
    case $RC in
        0) update_status ok   "Resource ${NEW_RID} marked as provisioned on all nodes." ;;
        *) update_status err  "Failed to set ${NEW_RID} as provisioned." ;;
    esac
else
    run_command -l "om ${SERVICE} print status --node ${NODE} | grep ${NEW_RID}" || update_status err "Unexpected error in the print status (RC=${RC})."
    update_status skip "Resource ${NEW_RID} already exists - provisioning state preserved."
fi

phase "Mounting filesystem by the OpenSVC"
run_command -l "om ${SERVICE} start --rid ${NEW_RID} --node ${PRIMARY}"; RC=$?
case $RC in
    0) update_status ok   "Resource ${NEW_RID} started successfully." ;;
    *) update_status err  "Failed to start ${NEW_RID}. Check 'om ${SERVICE} print status -r'." ;;
esac

phase "Verify filesystem is mounted"
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
write_log "$(report_block)"
exit 0
