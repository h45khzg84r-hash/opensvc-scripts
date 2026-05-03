#!/bin/bash
# opensvc_decommission_cluster.sh - Remove OpenSVC and LVM from all cluster nodes
# Usage: opensvc_decommission_cluster.sh
# Author.:
# Version: 20260502
#
# Validates that no services or LVM resources exist before proceeding.
# Uninstalls OpenSVC packages and cleans up all configuration on all nodes.
# !! THIS ACTION IS IRREVERSIBLE - ALL DATA WILL BE PERMANENTLY LOST !!

#######################################################################
# General Functions
#######################################################################

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT}"
    echo ""
    echo "  Notes:"
    echo "    - ALL services must be decommissioned before running this script."
    echo "    - ALL LVM resources (VGs) must be removed before running."
    echo "    - Script exits without changes if any service or VG is found."
    echo "    - Uninstalls OpenSVC packages and configuration on all nodes."
    echo "    - THIS ACTION IS IRREVERSIBLE."
    echo ""
    exit 1
}

# -------------------
create_log()
# -------------------
{
    local HEADER
    HEADER="Activity...: Complete decommission of OpenSVC cluster
 Nodes.....: ${NODES_CSV}"
    write_log "${HEADER}"
}

# -------------------
check_node_clean()
# -------------------
# Description: Verify no OpenSVC processes or packages remain on a node.
#
#   $1  = TARGET - node hostname
#
# RC:
#   0  = node is clean
#   1  = OpenSVC processes or packages still present
# -------------------
{
    local TARGET="$1"
    local PROCS PKGS
    PROCS=$(remote "${TARGET}" "pgrep -c -f 'opensvc|om ' 2>/dev/null || echo 0")
    PKGS=$(remote  "${TARGET}" "rpm -qa 2>/dev/null | awk '/opensvc/ {c++} END {print c+0}'")
    (( PROCS == 0 && PKGS == 0 ))
}

# -------------------
cleanup_opensvc_on_node()
# -------------------
# Description: Stop OpenSVC daemon, remove packages and clean up
#              all configuration directories on a given node.
#
#   $1  = TARGET - node hostname
#
# RC:
#   0  = cleanup completed
# -------------------
{
    local TARGET="$1"

    phase "Stopping OpenSVC daemon on ${TARGET}"
    run_command "om daemon stop 2>/dev/null; systemctl stop opensvc-agent 2>/dev/null; systemctl disable opensvc-agent 2>/dev/null"
    update_status ok "OpenSVC daemon stopped on ${TARGET}."

    phase "Removing OpenSVC packages on ${TARGET}"
    run_command "dnf remove -y opensvc 2>/dev/null || rpm -e \$(rpm -qa | grep opensvc) 2>/dev/null"; RC=$?
    case $RC in
        0) update_status ok   "OpenSVC packages removed from ${TARGET}." ;;
        *) update_status warn "Package removal returned RC=${RC} on ${TARGET} - may already be removed." ;;
    esac

    phase "Cleaning OpenSVC directories on ${TARGET}"
    run_command "rm -rf /etc/opensvc /var/lib/opensvc /var/log/opensvc /usr/share/opensvc /tmp/opensvc_* 2>/dev/null"
    update_status ok "Configuration directories removed from ${TARGET}."

    return 0
}

#######################################################################
# MAIN
#######################################################################

LIBCOMMON="./lib_common.sh"
if [[ -f "${LIBCOMMON}" ]]; then
    source "${LIBCOMMON}"
else
    echo "Library not found: ${LIBCOMMON}"
    exit 1
fi
LIBOPENSVC="./lib_opensvc.sh"
if [[ -f "${LIBOPENSVC}" ]]; then
    source "${LIBOPENSVC}"
else
    echo "Library not found: ${LIBOPENSVC}"
    exit 1
fi

[[ "$1" == "-h" || "$1" == "--help" ]] && usage
[[ "$(id -u)" -ne 0 ]] && { echo "Error: this script must be run as root."; exit 1; }

HOST=$(hostname)
NODES="$(om node ls 2>/dev/null | sort)"
NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
BACKUP_DIR="/tmp/opensvc_backup_${TIMESTAMP}"

init_logs

clear

########################################
stage "Activity started in $(date +'%d/%m/%Y %H:%M')"
########################################

########################################
stage "PRE-VALIDATION"
########################################

phase "Checking for remaining services"
REMAINING_SERVICES="$(om svc ls 2>/dev/null)"
if [[ -n "${REMAINING_SERVICES}" ]]; then
    show RED "\t\tThe following services still exist:"
    while IFS= read -r SVC; do
        show RED "\t\t  - ${SVC}"
    done <<< "${REMAINING_SERVICES}"
    update_status err "Services still exist. Run opensvc_decommission_service.sh for each service before proceeding."
else
    update_status ok "No services found. Safe to proceed."
fi

phase "Checking for remaining VGs on all nodes"
ROOT_VG="$(lvs --noheadings -o vg_name / 2>/dev/null | xargs)"
while IFS= read -r TARGET_NODE; do
    [[ -z "${TARGET_NODE}" ]] && continue
    VGS_OUT="$(remote "${TARGET_NODE}" "vgs --noheadings -o vg_name 2>/dev/null | tr -s ' ' '\n' | grep -vw '${ROOT_VG}' | xargs")"
    if [[ -n "${VGS_OUT}" ]]; then
        update_status warn "${TARGET_NODE}: non-system VG(s) found: ${VGS_OUT}"
        show YELLOW "\t\tVerify these are not OpenSVC VGs before continuing."
    else
        update_status ok "${TARGET_NODE}: no non-system VGs found."
    fi
done <<< "${NODES}"

########################################
show RED    "================================================================"
show RED    "        !! WARNING - COMPLETE CLUSTER DECOMMISSION !!"
show RED    "OpenSVC will be PERMANENTLY REMOVED from ALL nodes."
show RED    "================================================================"
show YELLOW "\t Cluster nodes : ${NODES_CSV:-N/A}"
show GREEN  ""
prompt_continue "Confirm COMPLETE DECOMMISSION of OpenSVC cluster?" || update_status no_go "Aborted by operator."

show RED "\t Final confirmation - THIS ACTION CANNOT BE UNDONE."
show GREEN ""
prompt_continue "Are you ABSOLUTELY SURE?" || update_status no_go "Aborted by operator."

SAVED_NODE=${NODE}
while IFS= read -r TARGET_NODE; do
    [[ -z "${TARGET_NODE}" ]] && continue
    NODE="${TARGET_NODE}"

    phase "Backing up OpenSVC configuration"
    run_command "mkdir -vp "${BACKUP_DIR}""; RC=$?

    run_command "tar czf ${BACKUP_DIR}/${TARGET_NODE}_opensvc_backup.tar.gz /etc/opensvc /var/lib/opensvc 2>/dev/null"; RC=$?
    update_status ok "Configuration backed up to ${BACKUP_DIR} (local node only)."

    cleanup_opensvc_on_node "${TARGET_NODE}"
done <<< "${NODES}"
NODE="${SAVED_NODE}"

########################################
stage "POST-CHECK"
########################################

phase "Verifying all nodes are clean"
ALL_CLEAN=true
while IFS= read -r TARGET_NODE; do
    [[ -z "${TARGET_NODE}" ]] && continue
    if check_node_clean "${TARGET_NODE}"; then
        show GREEN "\t\t[Success]\t${TARGET_NODE}: no OpenSVC processes or packages found."
    else
        show YELLOW "\t\t[Warning]\t${TARGET_NODE}: may still have remnants — check manually."
        ALL_CLEAN=false
    fi
done <<< "${NODES}"

if [[ "${ALL_CLEAN}" == "true" ]]; then
    update_status ok  "All nodes confirmed clean."
else
    update_status warn "Some nodes may need manual cleanup."
fi

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE   ""
show GREEN  "\t[Success]\tOpenSVC cluster completely decommissioned."
show YELLOW "\t\t\tConfiguration backup saved to: ${BACKUP_DIR}"
show BLUE   "\n\t\tLog: ${FINAL_LOG}"
create_log
exit 0
