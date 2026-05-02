#!/bin/bash
# opensvc_decommission_cluster.sh - Remove OpenSVC and LVM from all cluster nodes
# Usage: opensvc_decommission_cluster.sh
# Author.:
# Version: 20260501
#
# Stops all services, removes all LVM resources on all nodes,
# uninstalls OpenSVC packages and cleans up all configuration.
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
    echo "    - Stops and deletes ALL services and LVM resources on ALL nodes."
    echo "    - Uninstalls OpenSVC packages on ALL nodes."
    echo "    - THIS ACTION IS IRREVERSIBLE - ALL DATA WILL BE LOST."
    echo ""
    exit 1
}

# -------------------
create_log()
# -------------------
{
    local HEADER
    HEADER="Activity...: Complete decommission of OpenSVC cluster
 Nodes.....: ${NODES_CSV}
 Services..: ${SERVICES_LIST:-none}
 Executed..: $(date +'%d/%m/%Y %H:%M') on ${HOST}"
    write_log "${HEADER}"
}




# -------------------
check_node_clean()
# -------------------
{
    local TARGET="$1"
    local PROCS PKGS
    PROCS=$(remote "${TARGET}" "pgrep -c -f 'opensvc|om ' 2>/dev/null || echo 0")
    PKGS=$(remote  "${TARGET}" "rpm -qa 2>/dev/null | awk '/opensvc/ {c++} END {print c+0}'")
    (( PROCS == 0 && PKGS == 0 ))
}

#######################################################################
# MAIN
#######################################################################

LIBCOMMON="./lib_common.sh"
[[ -f "${LIBCOMMON}" ]] || { echo "Library not found: ${LIBCOMMON}"; exit 1; }
source "${LIBCOMMON}"
LIBOPENSVC="./lib_opensvc.sh"
[[ -f "${LIBOPENSVC}" ]] || { echo "Library not found: ${LIBOPENSVC}"; exit 1; }
source "${LIBOPENSVC}"

[[ "$1" == "-h" || "$1" == "--help" ]] && usage
[[ "$(id -u)" -ne 0 ]] && { echo "Error: this script must be run as root."; exit 1; }

HOST=$(hostname)
NODES="$(om node ls 2>/dev/null)"
NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"
SERVICES="$(om svc ls 2>/dev/null)"
SERVICES_LIST="$(echo "${SERVICES}" | tr '\n' ' ')"
TIMESTAMP="$(date +'%Y%m%d_%H%M%S')"
BACKUP_DIR="/tmp/opensvc_backup_${TIMESTAMP}"

init_logs

clear

########################################
stage "Activity started in $(date +'%d/%m/%Y %H:%M')"
########################################

show RED    "================================================================"
show RED    "        !! WARNING - COMPLETE CLUSTER DECOMMISSION !!"
show RED    "OpenSVC and ALL DATA will be PERMANENTLY DESTROYED on ALL nodes."
show RED    "================================================================"
show YELLOW "\t Cluster nodes : ${NODES_CSV:-N/A}"
show YELLOW "\t Services      : ${SERVICES_LIST:-none}"
show GREEN  ""
prompt_continue "Confirm COMPLETE DECOMMISSION of OpenSVC cluster?"
[[ $? -ne 0 ]] && { update_status no_go "Aborted by operator."; }

show RED "\t Final confirmation - ALL DATA WILL BE PERMANENTLY LOST."
show GREEN ""
prompt_continue "Are you ABSOLUTELY SURE? This cannot be undone."
[[ $? -ne 0 ]] && { update_status no_go "Aborted by operator."; }


phase "Backing up OpenSVC configuration"
mkdir -p "${BACKUP_DIR}"
cp -a /etc/opensvc "${BACKUP_DIR}/" 2>/dev/null
cp -a /var/lib/opensvc "${BACKUP_DIR}/" 2>/dev/null
update_status ok "Configuration backed up to ${BACKUP_DIR} (local node only)."


phase "Stopping and freezing all services"
if [[ -z "${SERVICES}" ]]; then
    update_status skip "No services found."
else
    while IFS= read -r SVC; do
        [[ -z "$SVC" ]] && continue
        show BLUE "\t\tStopping ${SVC}..."
        om "${SVC}" freeze --wait 2>/dev/null
        om "${SVC}" stop   --wait 2>/dev/null
    done <<< "${SERVICES}"
    update_status ok "All services stopped."
fi


phase "Cleaning LVM for all services on all nodes"
show RED "\t\t!! REMOVING ALL LVs, VGs AND PVs ON ALL NODES !!"
show GREEN ""
if [[ -z "${SERVICES}" ]]; then
    update_status skip "No services - no LVM to clean."
else
    while IFS= read -r SVC; do
        [[ -z "$SVC" ]] && continue
        show BLUE "\t\tService: ${SVC}"
        while IFS= read -r TARGET_NODE; do
            [[ -z "${TARGET_NODE}" ]] && continue
            # Collect LVM info per service for this cleanup call
            #local DISK_RID VG LVLIST PVLIST
            DISK_RID="$(om "${SVC}" print resinfo 2>/dev/null | awk '/ disk#[0-9]+[^p]/ { print $2; exit }')"
            [[ -n "$DISK_RID" ]] && VG="$(om "${SVC}" get --kw "${DISK_RID}".name 2>/dev/null)"
            LVLIST="$(om "${SVC}" print resinfo 2>/dev/null | awk '/fs#/ && /dev/ { print $NF }' | sort -u | tr '\n' ' ')"
            [[ -n "$VG" ]] && PVLIST="$(remote "${TARGET_NODE}" "pvs --select vg_name=${VG} --noheadings -o pv_name 2>/dev/null | xargs")"
            cleanup_lvm_on_node "${TARGET_NODE}" "${SVC}" "${VG}" "${LVLIST}" "${PVLIST}"
        done <<< "${NODES}"
    done <<< "${SERVICES}"
    update_status ok "LVM resources removed on all nodes."
fi


phase "Deleting all services from cluster"
if [[ -z "${SERVICES}" ]]; then
    update_status skip "No services to delete."
else
    while IFS= read -r SVC; do
        [[ -z "$SVC" ]] && continue
        show BLUE "\t\tDeleting ${SVC}..."
        om "${SVC}" delete --unprovision 2>/dev/null
    done <<< "${SERVICES}"
    update_status ok "All services deleted."
fi


while IFS= read -r TARGET_NODE; do
    [[ -z "${TARGET_NODE}" ]] && continue
    phase "Removing OpenSVC from node ${TARGET_NODE}"
    show RED "\t\t!! UNINSTALLING AND CLEANING ${TARGET_NODE} !!"
    cleanup_opensvc_on_node "${TARGET_NODE}"
    update_status ok "OpenSVC removed from ${TARGET_NODE}."
done <<< "${NODES}"

########################################
stage "POST-CHECK"
########################################

phase "Verifying all nodes are clean"
ALL_CLEAN=true
while IFS= read -r TARGET_NODE; do
    [[ -z "${TARGET_NODE}" ]] && continue
    if check_node_clean "${TARGET_NODE}"; then
        show GREEN "\t\t[Success] ${TARGET_NODE}: no OpenSVC processes or packages found."
    else
        show YELLOW "\t\t[Warning] ${TARGET_NODE}: may still have remnants - check manually."
        ALL_CLEAN=false
    fi
done <<< "${NODES}"

if [[ "${ALL_CLEAN}" == "true" ]]; then
    update_status ok   "All nodes confirmed clean."
else
    update_status warn "Some nodes may need manual cleanup."
fi    

show GREEN ""
show GREEN "\t[Success]\tOpenSVC cluster completely decommissioned."
show RED   "\t\t\tAll data has been permanently destroyed."
show YELLOW "\t\t\tConfiguration backup saved to: ${BACKUP_DIR}"

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE ""
show BLUE "[Success]\Complete decommission of OpenSVC cluster in both nodes (${NODES_CSV})."
show BLUE "\t\tTHIS ACTION IS IRREVERSIBLE - ALL DATA HAS BEEN DELETED."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
create_log
exit 0

