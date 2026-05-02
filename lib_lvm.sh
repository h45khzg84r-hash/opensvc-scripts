#!/bin/bash
# lib_lvm.sh - LVM, multipath and filesystem helper functions
# Source this file; do not execute it directly.

[[ "${BASH_SOURCE[0]}" == "$0" ]] && { echo "This file must be sourced, not executed."; exit 1; }

#######################################################################
# INDEX
#######################################################################
#
#  refresh_lvm_status()  Populate LV, VG and PV status variables via lvs/vgs/pvs
#  get_vgs_status()      Display and validate VG attributes
#  get_lvs_status()      Display and validate LV attributes
#  get_pvs_status()      Display and validate PV attributes
#  check_lvm_status()    Full LVM check with size calculations
#  make_lv_extension()   Extend LV to target size and resize filesystem
#  make_pvcreate()       Create PVs from new LUNs
#  make_vg_extension()   Extend VG with new LUNs
#  make_rescan()         Rescan SCSI bus and refresh multipath
#  select_luns()         Interactive selection of new LUNs from multipath diff
#  refresh_lv_status()   Populate single LV status variables for add_fs
#  check_lv_status()     Validate LV is ready to receive a new filesystem
#  make_mkfs()           Create filesystem on LV (skips if already formatted)
#  cleanup_lvm_on_node() Remove LVs/VG/PVs/multipath on a given node
#
#######################################################################

#######################################################################
# LVM / Extension Functions
#######################################################################

# -------------------
refresh_lvm_status()
# -------------------
# Description: Collect LV, VG and PV status from the primary node and
#              populate global variables used by get_*_status functions.
#
#   LV_NAME  - global, logical volume name (e.g. /dev/mapper/vg-lv)
#   VG_NAME  - global, volume group name
#
# Globals set:
#   LV_DM_PATH   - device-mapper path of the LV
#   LV_PATH      - canonical LV path
#   LV_ATTR      - LV attribute string from lvs
#   LV_SIZE      - LV size in bytes
#   PV_COUNT     - number of PVs in the VG
#   LV_COUNT     - number of LVs in the VG
#   VG_ATTR      - VG attribute string from vgs
#   VG_SIZE      - VG size in bytes
#   VG_FREE      - VG free space in bytes
#   PV_LIST      - raw pvs output for VG PVs
#   PV_LV_LIST   - raw pvs segment output for LV PVs
#
# RC:
#   0  = all data collected successfully
#   1  = lvs command failed
#   2  = LV output fields missing
#   3  = vgs command failed
#   4  = VG output fields missing
#   5  = pvs (VG) command failed
#   6  = PV list empty
#   7  = pvs (LV segments) command failed
#   8  = PV segment list empty
# -------------------
{
    local OUT
    OUT=$(remote "lvs ${LV_NAME} --noheadings --units b --nosuffix -o lv_dm_path,lv_path,lv_attr,lv_size") || return 1
    read -r LV_DM_PATH LV_PATH LV_ATTR LV_SIZE <<< "${OUT}"
    [[ -z "$LV_DM_PATH" || -z "$LV_PATH" || -z "$LV_SIZE" ]] && return 2

    OUT=$(remote "vgs ${VG_NAME} --noheadings --units b --nosuffix -o pv_count,lv_count,vg_attr,vg_size,vg_free") || return 3
    read -r PV_COUNT LV_COUNT VG_ATTR VG_SIZE VG_FREE <<< "${OUT}"
    [[ -z "$PV_COUNT" || -z "$LV_COUNT" || -z "$VG_ATTR" || -z "$VG_SIZE" || -z "$VG_FREE" ]] && return 4

    OUT=$(remote "pvs --select vg_name=${VG_NAME} --noheadings -o pv_name,pv_attr,pv_size,pv_free 2>/dev/null") || return 5
    PV_LIST="${OUT}"
    [[ -z "$PV_LIST" ]] && return 6

    OUT=$(remote "pvs --select lv_path=${LV_PATH} --segments --noheadings -o pv_name,vg_name,lv_path,pv_size,pv_free,pvseg_start,pvseg_size 2>/dev/null") || return 7
    PV_LV_LIST="${OUT}"
    [[ -z "$PV_LV_LIST" ]] && return 8

    return 0
}

# -------------------
get_vgs_status()
# -------------------
# Description: Run "vgs" on NODE, display VG summary and validate VG attributes.
#              Handles expected partial/inactive states on standby nodes.
#
#   -q          = quiet mode: suppress informational output, show errors only
#   VG_NAME     - global
#   VG_ATTR     - global (set by refresh_lvm_status)
#   VG_SIZE_G   - global (set by check_lvm_status)
#   VG_FREE_G   - global (set by check_lvm_status)
#   PV_COUNT    - global
#   LV_COUNT    - global
#   NODE        - global
#   STANDBY     - global
#
# RC:
#   0  = VG attributes are valid
#   1  = bad VG attributes on primary node
#   2  = bad VG attributes (generic)
# -------------------
{
    local QUIET=0
    [[ "$1" == "-q" ]] && { QUIET=1; shift; }

    run_command "vgs" || return 1
    (( QUIET == 0 )) && show GREEN "[Success]\tVG ${VG_NAME} - pvs: ${PV_COUNT}, lvs: ${LV_COUNT}, size: ${VG_SIZE_G}G, free: ${VG_FREE_G}G, attributes: ${VG_ATTR}."

    if [[ "${VG_ATTR}" == wz-?n- ]]; then
        (( QUIET == 0 )) && show GREEN "[Success]\tVG ${VG_NAME} attributes look good (${VG_ATTR})."
        (( QUIET == 0 )) && show GREEN "[Success]\tVG ${VG_NAME} shows as writeable (w) and as resizeable (z)."
        if [[ "${VG_ATTR:3:1}" == "p" ]]; then
            if [[ "${NODE}" == "${STANDBY}" ]]; then
                (( QUIET == 0 )) && show GREEN "[Success]\tVG ${VG_NAME} shows as partial (p) on the standby node."
                (( QUIET == 0 )) && show GREEN "\t\tThat's expected - some PVs are active on the primary node."
            else
                show RED "[ Error ]\tBad VG attributes to VG ${VG_NAME} on primary node: ${VG_ATTR}"
                return 1
            fi
        fi
        if [[ "${VG_ATTR:4:1}" == "n" ]]; then
            (( QUIET == 0 )) && show GREEN "[Success]\tVG ${VG_NAME} shows as inactive (n)."
            (( QUIET == 0 )) && show GREEN "\t\tThat's expected with OpenSVC clusters - LVs are activated directly with lvchange -ay."
        fi
    else
        show RED "[ Error ]\tBad VG attributes to VG ${VG_NAME}: ${VG_ATTR}"
        return 2
    fi
    show GREEN ""
    return 0
}

# -------------------
get_lvs_status()
# -------------------
# Description: Run "lvs" on NODE, display LV summary and validate LV attributes.
#              Handles expected inactive state on standby nodes.
#
#   -q          = quiet mode: suppress informational output, show errors only
#   LV_NAME     - global
#   LV_ATTR     - global (set by refresh_lvm_status)
#   LV_SIZE_G   - global (set by check_lvm_status)
#   VG_NAME     - global
#   NODE        - global
#   PRIMARY     - global
#   STANDBY     - global
#
# RC:
#   0  = LV attributes are valid
#   1  = LV is inactive on primary node
#   2  = pvmove in progress
#   3  = LV is read-only
#   4  = LV is suspended
#   5  = unrecognised LV attributes
# -------------------
{
    local QUIET=0
    [[ "$1" == "-q" ]] && { QUIET=1; shift; }

    run_command "lvs ${VG_NAME}" || return 2
    (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_NAME} - size: ${LV_SIZE_G}G, attributes: ${LV_ATTR}."
    if [[ "${LV_ATTR}" == -wi-ao---- && "${NODE}" == "${PRIMARY}" ]]; then
        (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_NAME} is writeable (w), active (a) and open/in use (o)."
        (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_NAME} attributes look good (${LV_ATTR})."
    elif [[ "${LV_ATTR}" == -wi------- ]]; then
        if [[ "${NODE}" == "${STANDBY}" ]]; then
            (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_NAME} is writeable (w) but inactive on standby node."
            (( QUIET == 0 )) && show GREEN "\t\tThat's expected - the LV is active on the primary node (${PRIMARY})."
            (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_NAME} attributes look good (${LV_ATTR})."
        else
            show RED "[ Error ]\tLV ${LV_NAME} is inactive on primary node (got: ${LV_ATTR}). Check OpenSVC service status."
            return 1
        fi
    else
        [[ "${LV_ATTR:0:1}" == "p" ]] && { show RED "[ Error ]\tLV ${LV_NAME} pvmove in progress (got: ${LV_ATTR})."; return 2; }
        [[ "${LV_ATTR:1:1}" == "r" ]] && { show RED "[ Error ]\tLV ${LV_NAME} is read-only (got: ${LV_ATTR}).";       return 3; }
        [[ "${LV_ATTR:5:1}" == "s" ]] && { show RED "[ Error ]\tLV ${LV_NAME} is suspended (got: ${LV_ATTR}).";       return 4; }
        show RED "[ Error ]\tBad LV attributes to LV ${LV_NAME}: ${LV_ATTR}"
        return 5
    fi
    show GREEN ""
}

# -------------------
get_pvs_status()
# -------------------
# Description: Run "pvs" on NODE, display PV summary and validate PV attributes.
#              Reports allocatability and missing PV issues. Also shows how many
#              PVs the target LV is spread across.
#
#   -q          = quiet mode: suppress informational output, show errors only
#   VG_NAME     - global
#   PV_LIST     - global (set by refresh_lvm_status)
#   PV_LV_LIST  - global (set by refresh_lvm_status)
#   PV_COUNT    - global
#   LV_PATH     - global (set by refresh_lvm_status)
#
# RC:
#   0    = all PVs healthy
#   1    = pvs command failed
#   2    = pvs segments command failed
#   N+2  = N PV issues found (not allocatable or missing)
# -------------------
{
    local QUIET=0
    [[ "$1" == "-q" ]] && { QUIET=1; shift; }

    run_command "pvs --select vg_name=${VG_NAME}" || return 1
    local PV_ISSUES=0
    while read -r PV_NAME PV_ATTR PV_SIZE PV_FREE; do
        if [[ "${PV_ATTR}" == "a--" ]]; then
            (( QUIET == 0 )) && show GREEN "[Success]\tPV ${PV_NAME} - size: ${PV_SIZE}, free: ${PV_FREE}, attributes: ${PV_ATTR}."
        else
            [[ "${PV_ATTR:0:1}" != "a" ]] && { show RED "[ Error ]\tPV ${PV_NAME} is not allocatable (got: ${PV_ATTR})."; (( PV_ISSUES++ )); }
            [[ "${PV_ATTR:2:1}" == "m" ]] && { show RED "[ Error ]\tPV ${PV_NAME} is missing (got: ${PV_ATTR}).";         (( PV_ISSUES++ )); }
        fi
    done <<< "${PV_LIST}"
    (( QUIET == 0 )) && show GREEN "[Success]\tVG ${VG_NAME} has ${PV_COUNT} PV(s)."
    (( PV_ISSUES > 0 )) && { show RED "[ Error ]\tFound ${PV_ISSUES} PV issue(s) in VG ${VG_NAME}."; return $(( PV_ISSUES + 2 )); }
    show GREEN ""
    run_command "pvs --select lv_path=${LV_PATH} --segments -o pv_name,vg_name,lv_path,pv_size,pv_free,pvseg_start,pvseg_size" || return 2
    local PV_SPREAD
    PV_SPREAD=$(awk '{print $1}' <<< "${PV_LV_LIST}" | sort -u | wc -l)
    (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_PATH} is spread across ${PV_SPREAD} PV(s)."
    show GREEN ""
}

# -------------------
check_lvm_status()
# -------------------
# Description: Orchestrate a full LVM status check. Calls refresh_lvm_status
#              to collect raw data, converts sizes to GB, calculates how much
#              space is needed and whether a new LUN is required, then validates
#              VG, LV and PV health via get_*_status functions.
#
#   LV_NAME      - global
#   VG_NAME      - global
#   SIZE_B       - global, target LV size in bytes
#   OLD_LV_SIZE_G - global, set to "0" on first call, then frozen
#
# Globals set:
#   VG_SIZE_G    - VG total size in GB
#   VG_FREE_G    - VG free space in GB
#   LV_SIZE_G    - current LV size in GB
#   OLD_LV_SIZE_G - original LV size (captured on first call)
#   NEED_SIZE    - bytes needed to reach target size
#   NEED_SIZE_G  - NEED_SIZE in GB
#   LUN_SIZE_G   - minimum new LUN size required (if NEED_SIZE > VG_FREE)
#
# RC:
#   0  = LVM healthy, sufficient space available
#   1  = refresh_lvm_status failed
#   2  = VG issue (get_vgs_status failed)
#   3  = LV issue (get_lvs_status failed)
#   4  = PV issue (get_pvs_status failed)
#   5  = insufficient VG free space (new LUN required)
#   6  = target size is not greater than current LV size
# -------------------
{
    refresh_lvm_status || return 1
    VG_SIZE_G=$(printf "%.2f" "$(bc -l <<< "scale=4; ${VG_SIZE} / 1024^3")")
    VG_FREE_G=$(printf "%.2f" "$(bc -l <<< "scale=4; ${VG_FREE} / 1024^3")")
    LV_SIZE_G=$(printf "%.2f" "$(bc -l <<< "scale=4; ${LV_SIZE} / 1024^3")")
    [[ "${OLD_LV_SIZE_G}" == "0" ]] && OLD_LV_SIZE_G="${LV_SIZE_G}"
    NEED_SIZE=$(bc -l <<< "scale=2; ${SIZE_B} - ${LV_SIZE}")
    NEED_SIZE_G=$(printf "%.2f" "$(bc -l <<< "scale=4; ${NEED_SIZE} / 1024^3")")
    LUN_SIZE_G=$(printf "%.2f" "$(bc -l <<< "scale=4; ${NEED_SIZE_G} - ${VG_FREE_G}")")
    get_vgs_status || return 2
    get_lvs_status || return 3
    get_pvs_status || return 4

    [[ $(bc -l <<< "${VG_FREE} < ${NEED_SIZE}") -eq 1 ]] && return 5
    [[ $(bc -l <<< "${SIZE_B} <= ${LV_SIZE}")   -eq 1 ]] && return 6
    return 0
}

# -------------------
make_lv_extension()
# -------------------
# Description: Extend the LV to the target size using lvextend -r (which also
#              resizes the filesystem). If NEED_LUN is set, prompts the operator
#              to confirm before proceeding (LUN must have been pre-allocated).
#
#   NEED_LUN    - global, 1 if VG lacks space (set by check_lvm_status RC 5)
#   FS          - global, mount point
#   SIZE        - global, target size in GB (string)
#   SIZE_G      - global, target size in GB (float)
#   SIZE_B      - global, target size in bytes
#   LV_DM_PATH  - global (set by refresh_lvm_status)
#   VG_SIZE_G   - global
#   VG_FREE_G   - global
#   LUN_SIZE_G  - global
#
# Globals updated: LV_SIZE, LV_SIZE_G (via refresh_lvm_status after extend)
#
# RC:
#   0  = LV extended successfully
#   1  = get_vgs_status -q failed
#   2  = get_lvs_status -q failed
#   3  = NEED_LUN=1 and operator confirmed to continue (caller handles LUN path)
#   4  = NEED_LUN=1 and operator aborted
#   5  = lvextend command failed
#   6  = refresh_lvm_status after extend failed
#   7  = LV size after extend is less than expected
#   8  = get_lvs_status after extend failed
#   9  = get_vgs_status after extend failed
# -------------------
{
    get_vgs_status -q || return 1
    get_lvs_status -q || return 2
    if (( NEED_LUN == 1 )); then
        update_status warn "Insufficient space to extend ${FS} to ${SIZE_G}G."
        show YELLOW "\t\tVG size: ${VG_SIZE_G}G, free: ${VG_FREE_G}G."
        show YELLOW "\t\tNeeds a new LUN of at least ${LUN_SIZE_G}G (see SIT-SAN001)."
        show BLUE   "\t\tOnly proceed if the new LUN has already been allocated."
        show BLUE   ""
        prompt_continue "No space enough. Can search for new LUN?" && return 3 || return 4
    fi
    show GREEN "\n[Success]\tEverything is OK to extend ${FS} to ${SIZE}G."
    show GREEN ""

    run_command "lvextend -L ${SIZE}G -r ${LV_DM_PATH}" || return 5
    refresh_lvm_status || return 6

    [[ $(bc -l <<< "${LV_SIZE} >= ${SIZE_B}") -eq 1 ]] || return 7
    get_lvs_status || return 8
    get_vgs_status || return 9
}

# -------------------
make_pvcreate()
# -------------------
# Description: For each LUN in LUNS, update the LVM cache and create a new PV.
#              Refreshes LVM status after all PVs are created.
#
#   LUNS  - global, space-separated list of device-mapper LUN names
#
# RC:
#   0  = all PVs created and status refreshed
#   1  = pvscan --cache failed
#   2  = pvcreate failed
#   3  = refresh_lvm_status after pvcreate failed
# -------------------
{
    for LUN in ${LUNS}; do
        run_command "pvscan --cache /dev/mapper/${LUN}" || return 1
        run_command "pvcreate /dev/mapper/${LUN}"       || return 2
    done
    refresh_lvm_status || return 3
}

# -------------------
make_vg_extension()
# -------------------
# Description: Extend the VG by adding each LUN in LUNS as a new PV,
#              then verify the result with a full check_lvm_status call.
#
#   LUNS     - global, space-separated list of device-mapper LUN names
#   VG_NAME  - global
#
# RC:
#   0    = VG extended and LVM status verified
#   9    = vgextend command failed
#   1-6  = propagated from check_lvm_status
# -------------------
{
    for LUN in ${LUNS}; do
        run_command "vgextend ${VG_NAME} /dev/mapper/${LUN}" || return 9
    done
    check_lvm_status || return $?
}

# -------------------
make_rescan()
# -------------------
# Description: Trigger a SCSI bus rescan on all scsi_host adapters, wait for
#              udev to settle, then refresh the multipath table.
#              Used to make newly allocated LUNs visible to the OS.
#
# Globals used: NODE (via remote and run_command)
#
# RC:
#   0  = rescan completed successfully
#   1  = SCSI scan echo failed
#   2  = udevadm settle failed
#   3  = multipath -r failed
# -------------------
{
    mapfile -t SCSI_HOSTS < <(remote "ls /sys/class/scsi_host")
    for HOST_ID in "${SCSI_HOSTS[@]}"; do
        run_command "echo '- - -' > /sys/class/scsi_host/${HOST_ID}/scan" || return 1
    done
    run_command "udevadm settle" || return 2
    run_command "multipath -r"   || return 3
}

# -------------------
select_luns()
# -------------------
# Description: Compare multipath-ll.before and multipath-ll.after to detect
#              newly visible LUNs (Pure/FlashArray). Present numbered list and
#              ask operator to select which ones to use. Writes selection to
#              ${DIR}/luns_selected.
#
# Globals used: DIR, TEMP_LOG
# Globals written: ${DIR}/luns_selected (file)
#
# RC:
#   0  = one or more LUNs selected
#   1  = operator exited (entered 0 or empty)
#   3  = no new LUNs detected in multipath diff
# -------------------
{
    local -a NEW_LUNS
    cp /dev/null "${DIR}/luns_selected"
    run_command -l "diff ${DIR}/multipath-ll.before ${DIR}/multipath-ll.after"
    mapfile -t NEW_LUNS < <(diff "${DIR}/multipath-ll.before" "${DIR}/multipath-ll.after" \
        | awk '/[0-9a-f]{32}/ && /PURE|FlashArray/ {print $2}' | tr -d '\+' | sort -u)
    (( ${#NEW_LUNS[@]} == 0 )) && return 3

    show GREEN "\n${#NEW_LUNS[@]} new LUN(s) detected:"
    for i in "${!NEW_LUNS[@]}"; do
        show GREEN "$(printf '\t\t%d) %s\n' "$((i+1))" "${NEW_LUNS[$i]}")"
    done

    update_status prompt
    local SELECTION VALID SELECTED_LUNS USED
    while true; do
        read -r -p "Select the LUNs (ex: 1 3 4, or 0 to exit): " SELECTION
        [[ -z "$SELECTION" || "$SELECTION" == "0" ]] && return 1

        declare -A USED=()
        SELECTED_LUNS=()
        VALID=true
        for IDX in ${SELECTION}; do
            [[ "$IDX" =~ ^[1-9][0-9]*$ ]]    || { show RED "\t\tInvalid value: $IDX";      VALID=false; break; }
            local REAL=$(( IDX - 1 ))
            (( REAL < ${#NEW_LUNS[@]} ))      || { show RED "\t\tValue out of range: $IDX"; VALID=false; break; }
            [[ -z "${USED[$REAL]}" ]]         || { show RED "\t\tLUN duplicate: $IDX";      VALID=false; break; }
            USED[$REAL]=1
            SELECTED_LUNS+=("${NEW_LUNS[$REAL]}")
        done
        $VALID && break
        echo "Please try again."
    done
    echo "${SELECTED_LUNS[@]}" > "${DIR}/luns_selected"
    return 0
}

#######################################################################
# Filesystem Addition Functions
#######################################################################

# -------------------
refresh_lv_status()
# -------------------
# Description: Collect LV status for a single device path (LV_PATH) as used
#              by the add_fs workflow. Lighter than refresh_lvm_status - does
#              not collect VG or PV data.
#
#   LV_PATH  - global, full device path (e.g. /dev/mapper/vg-lv)
#
# Globals set:
#   LV_DM_PATH    - device-mapper path
#   LV_CHECK_PATH - canonical LV path (sanity check)
#   LV_ATTR       - LV attribute string
#   LV_SIZE       - LV size in bytes
#   LV_SIZE_G     - LV size in GB (2 decimal places)
#
# RC:
#   0  = data collected successfully
#   1  = lvs command failed
#   2  = one or more output fields are empty
# -------------------
{
    local OUT
    OUT=$(remote "lvs ${LV_PATH} --noheadings --units b --nosuffix -o lv_dm_path,lv_path,lv_attr,lv_size 2>/dev/null") || return 1
    read -r LV_DM_PATH LV_ATTR LV_SIZE <<< "${OUT}"
    [[ -z "$LV_DM_PATH" || -z "$LV_ATTR" || -z "$LV_SIZE" ]] && return 2
    LV_SIZE_G=$(printf "%.2f" "$(bc -l <<< "scale=4; ${LV_SIZE} / 1024^3")")
    return 0
}

# -------------------
check_lv_status()
# -------------------
# Description: Validate that the target LV is in a state suitable for adding
#              a new filesystem. Checks LV attributes, detects existing
#              filesystems and warns accordingly.
#
#   -q           = quiet mode: suppress informational output, show errors only
#   LV_PATH      - global
#   VG_NAME      - global
#   NODE         - global
#   EXISTING_FS  - global (set by init_vars via blkid; empty if unformatted)
#   FSTYPE       - global, intended filesystem type
#
# Globals updated: LV_DM_PATH, LV_ATTR, LV_SIZE_G (via refresh_lv_status)
#
# RC:
#   0  = LV is ready for use
#   1  = refresh_lv_status failed
#   2  = lvs command failed
#   3  = LV is inactive
#   4  = LV is already open/in use
#   5  = pvmove in progress
#   6  = LV is read-only
#   7  = LV is suspended
# -------------------
{
    local QUIET=0
    [[ "$1" == "-q" ]] && { QUIET=1; shift; }

    refresh_lv_status || return 1

    run_command "lvs ${VG_NAME}" || return 2
    (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_PATH} - size: ${LV_SIZE_G}G, attributes: ${LV_ATTR}."

    if [[ "${LV_ATTR}" == -wi-a----- ]]; then
        (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_PATH} is writeable (w) and active (a) - ready for use."
    elif [[ "${LV_ATTR}" == -wi------- ]]; then
        show RED "[ Error ]\tLV ${LV_PATH} is inactive on ${NODE} (got: ${LV_ATTR}). Check LVM / OpenSVC state."
        return 3
    elif [[ "${LV_ATTR:5:1}" == "o" ]]; then
        show RED "[ Error ]\tLV ${LV_PATH} is already open/in use (got: ${LV_ATTR}). Is it already mounted?"
        return 4
    else
        [[ "${LV_ATTR:0:1}" == "p" ]] && { show RED "[ Error ]\tLV ${LV_PATH}: pvmove in progress (got: ${LV_ATTR})."; return 5; }
        [[ "${LV_ATTR:1:1}" == "r" ]] && { show RED "[ Error ]\tLV ${LV_PATH} is read-only (got: ${LV_ATTR}).";       return 6; }
        [[ "${LV_ATTR:5:1}" == "s" ]] && { show RED "[ Error ]\tLV ${LV_PATH} is suspended (got: ${LV_ATTR}).";       return 7; }
        (( QUIET == 0 )) && show YELLOW "[Warning]\tUnexpected LV attributes: ${LV_ATTR}. Proceeding with caution."
    fi

    if [[ -n "${EXISTING_FS}" ]]; then
        show YELLOW "[Warning]\tLV ${LV_PATH} already contains a ${EXISTING_FS} filesystem."
        show YELLOW "\t\tData will be preserved - mkfs will be skipped."
    else
        (( QUIET == 0 )) && show GREEN "[Success]\tLV ${LV_PATH} has no existing filesystem - will be formatted as ${FSTYPE}."
    fi
    show GREEN ""
    return 0
}

# -------------------
make_mkfs()
# -------------------
# Description: Create a filesystem of type FSTYPE on LV_DM_PATH.
#              If EXISTING_FS is set (LV already formatted), skips mkfs
#              and marks the phase as skipped to preserve existing data.
#
#   LV_PATH      - global (used by refresh_lv_status to update LV_DM_PATH)
#   LV_DM_PATH   - global (set by refresh_lv_status)
#   EXISTING_FS  - global (set by init_vars; empty if unformatted)
#   FSTYPE       - global: xfs | ext4 | ext3 | ext2
#
# RC:
#   0  = filesystem created successfully (or skipped - already formatted)
#   1  = refresh_lv_status failed
#   2  = mkfs.xfs failed
#   3  = mkfs.<other> failed
# -------------------
{
    refresh_lv_status || return 1
    if [[ -n "${EXISTING_FS}" ]]; then
        update_status skip "LV ${LV_PATH} already formatted as ${EXISTING_FS} - mkfs skipped. Data preserved."
        return 0
    fi
    if [[ "${FSTYPE}" == "xfs" ]]; then
        run_command "mkfs.xfs -f ${LV_DM_PATH}" || return 2
    else
        run_command "mkfs.${FSTYPE} ${LV_DM_PATH}" || return 3
    fi
    return 0
}



# -------------------
cleanup_lvm_on_node()
# -------------------
# Description: Unmount all service FSes, deactivate and remove all LVs,
#              remove the VG, remove PVs, flush multipath and delete SCSI
#              devices on a given node. Safe to call even if resources are
#              partially removed (all steps run with || true).
#
#   $1  = VG_NAME  - VG to remove 
#
# RC: (none - all operations are best-effort)
# -------------------
{
    local VG="$1"
    local SAVED_NODE="${NODE}"
    NODE="${PRIMARY}"

    local LV_LIST PV_LIST ALL_MOUNTS DM_DEV PROCS RC_FUSER RC=0 TOTAL=0  RAW_RUNNING=""

    LV_LIST="$(remote "lvs ${VG} --noheadings -o lv_dm_path 2>/dev/null | xargs")"
    PV_LIST="$(remote "pvs --select vg_name=${VG} --noheadings -o pv_name 2>/dev/null | xargs")"
    ALL_MOUNTS=()

    for LV in ${LV_LIST}; do
        MNT="$(remote "findmnt -n -o TARGET --source ${LV} 2>/dev/null")"
        [[ -z "$MNT" ]] && continue

	ALL_MOUNTS+=("${MNT}")
    done
    mapfile -t ALL_MOUNTS < <(printf "%s\n" "${ALL_MOUNTS[@]}" | sort -r)

    # Checking for RAW devices
    phase "Checking for RAW devices"
    for PV in ${PV_LIST}; do
        DM_DEV="$(remote "readlink -f ${PV} 2>/dev/null")"
        run_command "timeout 3 fuser -v ${PV} ${DM_DEV}"; RC_FUSER=$?
        #PROCS="$(timeout 3 fuser -v "${PV}" "${DM_DEV}" 2>/dev/null)"
        if (( RC_FUSER == 124 )); then
            RAW_RUNNING="${RAW_RUNNING}\n${PV}: (timeout - check manually)"
        elif [[ -n "${OUTPUT}" ]]; then
            RAW_RUNNING="${RAW_RUNNING}\n${PV}:\n${OUTPUT}"
        fi
    done

    if [[ -n "${RAW_RUNNING}" ]]; then
        show YELLOW "[Warning]\tThe following devices are in use by processes:"
        for DEV in ${RAW_RUNNING}; do
            show YELLOW "\t\t\t${DEV}"
        done
        prompt_continue "Raw devices in use - proceed with LVM cleanup anyway?"; RC=$?
        case $RC in
             0) update_status ok  ;;
             *) NODE="${SAVED_NODE}"
		return 1          ;;
        esac
    else	
        update_status skip "No RAW devices identified."	
    fi

    # Unmount active mount points
    phase "Umounting active mount points"
    if (( ${#ALL_MOUNTS[@]} )); then
	TOTAL=0    
        for MNT in "${ALL_MOUNTS[@]}"; do
            [[ -z "$MNT" ]] && continue
	    run_command "umount ${MNT}"; RC=$?
	    case $RC in
                0) show GREEN  "[Success]\tUmount ${MNT} done." ;;
                *) show RED    "[Failure]\tUmount ${MNT} failed (RC=${RC}) - Please, check manually." ;;
            esac
            (( TOTAL += RC ))
        done
	(( TOTAL )) && { NODE="${SAVED_NODE}"; return 2; }
    else
        show YELLOW "[Skipped]\tNo active mount points found."
	update_status skip
    fi	

    # Removing LVOLs from VG
    phase "Removing LVOLs from VG ${VG}"
    if [[ -n "${LV_LIST}" ]]; then
	TOTAL=0    
        for LV in ${LV_LIST}; do
            run_command "wipefs -a ${LV}"; RC=$?
            case $RC in
                0) show GREEN  "[Success]\tFilesystem signature wiped from ${LV}." ;;
                *) show RED    "[Failure]\twipefs failed on ${LV} (RC=${RC})." ;;
            esac
            show GREEN ""
            run_command "lvremove -y ${LV}"; RC=$?
	    case $RC in
                0) show GREEN  "[Success]\t${LV} has been removed successfully." ;;
                *) show RED    "[Warning]\tRemove ${LV} failed (RC=${RC}) - Please, check manually." ;;
            esac
	    (( TOTAL += RC ))
        done
	if (( TOTAL )); then
	    NODE="${SAVED_NODE}"
	    return 3
        else    
	    update_status ok
	fi    
    else	
	show YELLOW "[Skipped]\t${VG} is already empty. No LVOLs found."
	update_status skip
    fi	

    # Deactivating VG
    phase "Deactivating VG ${VG}"
    run_command "vgchange -an ${VG}" || RC=$?
    case $RC in
         0) update_status ok  "${VG} has been deactivated." ;;
         *) show RED          "[Failure]\tFailed to deactivate VG ${VG}(RC=${RC}). Please, check manually." 
            update_status warn ;;
    esac

    # Removing VG
    phase "Removing VG ${VG}"
    run_command "vgs"
    run_command "pvs --select vg_name=${VG}"
    run_command "vgremove -y ${VG}"; RC=$?
    run_command "vgs"
    run_command "pvs --select vg_name=${VG}"
    case $RC in
         0) update_status ok   "${VG} has been removed successfully." ;;
         *) NODE="${SAVED_NODE}"
            return 4 ;;
    esac


    # Remove PVs, flush multipath, delete SCSI devices

    if (( RC )); then
        NODE="${SAVED_NODE}"
        return ${RC}
    else	
	TOTAL=0    

	phase "Checking multipath status"
        run_command "multipath -ll"; RC=$?
        case $RC in
            0) update_status ok ;;
            *) update_status warn "multipath -ll failed (RC=${RC})." ;;
        esac

        for PV in ${PV_LIST}; do
            local LUN="${PV##*/}"

	    phase "Removing ${PV}"
            run_command "pvremove -y ${PV}"; RC=$?
            case $RC in
                 0) update_status ok  "${PV} has been removed sucessfully." ;;
                 *) update_status nok "The removal of the ${PV} failed (RC=${RC})." ;;
            esac		    
	    (( TOTAL += RC ))

            PATHS="$(remote "multipath -ll ${LUN} 2>/dev/null | awk '/sd[a-z]+/ {print \$3}'")"

	    phase "Removing multipath ${LUN}"
            run_command "multipath -f ${LUN}"; RC=$?
	    (( TOTAL += RC ))
            for DEV in ${PATHS}; do
                run_command "echo 1 > /sys/block/${DEV}/device/delete"; RC=$?
	        (( TOTAL += RC ))
                case $RC in
                     0) update_status ok  "Path ${DEV} has been removed sucessfully." ;;
                     *) update_status nok "Failed to remove SCSI device ${DEV} (RC=${RC})." ;;
	        esac	
            done
        done
	(( TOTAL )) && { NODE="${SAVED_NODE}"; return 5; }

	phase "Checking multipath status after changes"
        run_command "multipath -ll"; RC=$?
        case $RC in
            0) update_status ok ;;
            *) update_status warn "multipath -ll failed (RC=${RC})." ;;
        esac

        # Refresh standby
        NODE="${STANDBY}"
	TOTAL=0
	phase "Running vgscan on STANDBY node (${STANDBY})"
        run_command "vgscan"; RC=$?
        case $RC in
             0) update_status ok  "\t\t[Success]\tvgscan has been performed successfully." ;;
             *) show RED          "\t\t[Failure]\tvgscan failed on STANDBY node." ;;
        esac		    
	run_command "vgs"
	(( TOTAL += RC ))

	phase "Running pvscan --cache on STANDBY node (${STANDBY})"
        run_command "pvscan --cache"; RC=$?
        case $RC in
             0) update_status ok  "\t\t[Success]\tpvscan has been performed successfully." ;;
             *) show RED          "\t\t[Failure]\tpvscan failed on STANDBY node." ;;
        esac		    
        run_command "pvs"
	(( TOTAL += RC ))

	phase "Running multipath -r on STANDBY node (${STANDBY})"
        run_command "multipath -r"; RC=$?
        case $RC in
             0) update_status ok  "\t\t[Success]\tmultipath has been performed successfully.";;
             *) show RED          "\t\t[Failure]\tmultipath failed on STANDBY node." ;;
        esac		    
	(( TOTAL += RC ))
	(( TOTAL )) && { NODE="${SAVED_NODE}"; return 6; }
    fi
    return 0
}
