#!/bin/bash
# opensvc_create_service.sh - Create a new OpenSVC HA service
# Usage: opensvc_create_svc.sh <SERVICE> <INTERFACE> <IP>
# Author.: adriano.costa
# Version: 20260419
#
# Creates a new service with ip#1, disk#1 (VG=SERVICE), disk#1pr,
# sync#i0, sync#p0 and standard ha orchestration.

SERVICE=$1
IFACE=$2
IP=$3

# -------------------
usage()
# -------------------
{
    local SCRIPT="${0##*/}"
    [[ -n "$1" ]] && echo "  Error: $1" && echo ""
    echo "  Usage: ${SCRIPT} <SERVICE> <INTERFACE> <IP>"
    echo ""
    echo "  Arguments:"
    echo "    <SERVICE>     Name of the new OpenSVC service (e.g. server_a)"
    echo "    <INTERFACE>   Network interface for the service IP (e.g. bond0)"
    echo "    <IP>          IP address/mask (e.g. 100.100.100.100/255.255.255.0)"
    echo ""
    echo "  Notes:"
    echo "    - VG name = SERVICE name (must be pre-created on the storage)."
    echo "    - Sync path: /local/p0/<SERVICE>."
    echo "    - Orchestration: ha. SCSI reservation and monitor enabled."
    echo "    - Monitor action is prompted interactively (default: freezestop)."
    echo ""
    echo "  Examples:"
    echo "    ${SCRIPT} sltifraxssvc7 bond0 100.100.100.100/255.255.255.0"
    echo ""
    exit 1
}

# -------------------
report_block()
# -------------------
{
    cat <<EOF

Add a new OpenSVC service:
  Service Name.......: ${SERVICE}
  Primary Node.......: ${PRIMARY} (${IP_PRI})
  Standby Node.......: ${STANDBY} (${IP_STA})
  Interface..........: ${IFACE}
  IP.................: ${IP}
  Netmask............: ${NETMASK}
  Gateway............: ${GATEWAY}
  VG.................: ${SERVICE}
  Sync path..........: /local/p0/${SERVICE}
  Monitor............: ${MONITOR_ACTION}

EOF
}

# -------------------
init_vars()
# -------------------
{
    HOST=$(hostname)
    [[ -z "$SERVICE" ]] && return 1
    # SERVICE must not be a path - catch swapped arguments
    [[ "$SERVICE" == /* ]] && return 11
    [[ -z "$IFACE"   ]] && return 2
    [[ -z "$IP"      ]] && return 3

    # Validate IP/mask format (x.x.x.x/y.y.y.y or x.x.x.x/prefix)
    [[ ! "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]] && return 4

    # Collect cluster nodes
    NODES="$(om node ls 2>&1)"
    [[ -z "$NODES" ]] && return 5
    NODES_CSV="$(xargs <<< "${NODES}" | tr ' ' ',')"

    # Validate service does not already exist
    SERVICES="$(om svc ls 2>&1)"
    grep -Fxq "${SERVICE}" <<< "${SERVICES}" && return 6

    # Validate interface exists on this host
    ip link show "${IFACE}" &>/dev/null || return 7

    # Extract IP and netmask
    IP_ADDR="${IP%%/*}"
    NETMASK="${IP##*/}"

    # Test IP not already active in the cluster
    if ping -c 1 -W 1 "${IP_ADDR}" &>/dev/null; then
        IP_ACTIVE=true
    else
        IP_ACTIVE=false
    fi

    # Validate IP resolves by name (DNS check)
    IP_HOSTNAME="$(getent hosts "${IP_ADDR}" 2>/dev/null | awk '{print $2}' | head -1)"
    [[ -z "$IP_HOSTNAME" ]] && return 8

    # Validate hostname resolves to same IP
    IP_FROM_NAME="$(getent ahostsv4 "${IP_HOSTNAME}" 2>/dev/null | awk '{print $1}' | head -1)"
    [[ "${IP_FROM_NAME}" != "${IP_ADDR}" ]] && return 9

    # Validate VG exists on primary (VG = SERVICE name)
    GATEWAY="$(ip route | awk '/default/ {print $3; exit}')"

    # Resolve cluster primary (use local host as primary for new service)
    PRIMARY="${HOST}"
    NODE="${HOST}"
    STANDBY="$(awk -v h="${HOST}" '$0!=h {print; exit}' <<< "${NODES}")"

    IP_PRI="$(getent ahostsv4 "${PRIMARY}" | head -1 | awk '{print $1}')"
    IP_STA="$(getent ahostsv4 "${STANDBY}" | head -1 | awk '{print $1}')"

    # Check VG exists on primary
    vgs "${SERVICE}" &>/dev/null || return 10

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
[[ $# -lt 3 ]] && usage "Missing arguments. Expected 3, got $#."

init_logs

clear

########################################
stage "Activity started in $(date +'%d/%m/%Y %H:%M')"
########################################
phase "Collecting environment status"
init_vars; RC=$?
case $RC in
    0)  ;;
    1)  update_status err "Variable SERVICE is empty." ;;
    11) update_status err "SERVICE looks like a path (starts with /). Check arguments." ;;
    2)  update_status err "Variable INTERFACE is empty." ;;
    3)  update_status err "Variable IP is empty." ;;
    4)  update_status err "Invalid IP format: ${IP}. Expected x.x.x.x/mask." ;;
    5)  update_status err "Cannot list cluster nodes." ;;
    6)  update_status err "Service ${SERVICE} already exists in the cluster." ;;
    7)  update_status err "Interface ${IFACE} not found on ${HOST}." ;;
    8)  update_status err "IP ${IP_ADDR} has no reverse DNS entry. Check DNS." ;;
    9)  update_status err "Hostname ${IP_HOSTNAME} does not resolve back to ${IP_ADDR}." ;;
    10) update_status err "VG ${SERVICE} not found on ${HOST}. Create VG first." ;;
    *)  update_status err "Unexpected error in init_vars (RC=${RC})." ;;
esac

show GREEN ""
while IFS= read -r LINE; do
    show GREEN "\t\t${LINE}"
done < <(build_report_block)

# Warn if IP is already responding
if [[ "${IP_ACTIVE}" == "true" ]]; then
    show YELLOW "\t\t[Warning] IP ${IP_ADDR} is already responding to ping."
    prompt_continue "IP is active. Continue anyway?" || update_status no_go "Aborted by operator."
else
    prompt_continue || update_status no_go "Aborting - check all information before continuing."
fi    
update_status ok 

# Interactive: ask monitor action
show BLUE "\t\tMonitor action options: freezestop | reboot | switch | crash"
update_status prompt
read -rp "        Monitor action [freezestop]: " MONITOR_ACTION
update_status running
MONITOR_ACTION="${MONITOR_ACTION:-freezestop}"
[[ ! "${MONITOR_ACTION}" =~ ^(freezestop|reboot|switch|crash)$ ]] && \
    update_status err "Invalid monitor action: ${MONITOR_ACTION}."
show BLUE "\t\tMonitor action: ${MONITOR_ACTION}"
show GREEN ""

########################################
stage "PRE-CHECK"
########################################

phase "Checking node ${HOST} is healthy"
run_command -l "om node print status"; RC=$?
case $RC in
    0) update_status ok "Node ${HOST} is healthy." ;;
    *) update_status warn "Node status returned RC=${RC} - proceeding." ;;
esac

phase "Verifying VG ${SERVICE} exists on primary"
run_command "vgs ${SERVICE}"; RC=$?
case $RC in
    0) update_status ok "VG ${SERVICE} found on ${HOST}." ;;
    *) update_status err "VG ${SERVICE} not found. Create VG before running this script." ;;
esac

phase "Verifying sync directory exists"
run_command "mkdir -p /local/p0/${SERVICE}"; RC=$?
case $RC in
    0) update_status ok "Sync directory /local/p0/${SERVICE} is ready." ;;
    *) update_status err "Cannot create sync directory /local/p0/${SERVICE}." ;;
esac

########################################
NODE=${PRIMARY}
stage "On PRIMARY node (${PRIMARY})"
########################################

# Create service with all standard resources
phase "Creating service configuration"
run_command -l "om ${SERVICE} create \
    --kw orchestrate=ha \
    --kw ip#1.ipdev=${IFACE} \
    --kw ip#1.ipname=${IP_ADDR} \
    --kw ip#1.netmask=${NETMASK} \
    --kw ip#1.gateway=${GATEWAY} \
    --kw ip#1.monitor=true \
    --kw disk#1.type=vg \
    --kw disk#1.name=${SERVICE} \
    --kw disk#1.monitor=true \
    --kw disk#1pr.type=disk \
    --kw disk#1pr.prkey=0x$(hostname | cksum | awk '{printf "%08x", $1}') \
    --kw disk#1pr.scsireserv=true \
    --kw sync#i0.type=rsync \
    --kw sync#i0.src=/etc/opensvc/${SERVICE}.conf \
    --kw sync#p0.type=rsync \
    --kw sync#p0.src=/local/p0/${SERVICE}/ \
    --kw monitor_action=${MONITOR_ACTION}"; RC=$?
case $RC in
    0) update_status ok "Service ${SERVICE} created with standard resources." ;;
    *) update_status err "Service creation failed (RC=${RC})." ;;
esac

phase "Setting provisioned on all nodes"
run_command -l "om ${SERVICE} set provisioned --node ${NODES_CSV}"; RC=$?
case $RC in
    0) update_status ok "Service ${SERVICE} marked as provisioned on all nodes." ;;
    *) update_status err "Failed to set provisioned (RC=${RC})." ;;
esac

phase "Sync config to all nodes"
run_command -l "om ${SERVICE} sync all"; RC=$?
case $RC in
    0) update_status ok "Service configuration synced to all nodes." ;;
    *) update_status err "Sync failed. Check cluster connectivity." ;;
esac

phase "Starting service ${SERVICE} on ${PRIMARY}"
run_command -l "om ${SERVICE} start --wait --node ${PRIMARY}"; RC=$?
case $RC in
    0) update_status ok "Service ${SERVICE} started on ${PRIMARY}." ;;
    *) update_status err "Start failed (RC=${RC}). Check 'om ${SERVICE} print status -r'." ;;
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

show GREEN ""
show GREEN "\t[Success]\tService ${SERVICE} created and started."
show BLUE  "\t\t\tIP        : ${IP_ADDR} (${IP_HOSTNAME})"
show BLUE  "\t\t\tVG        : ${SERVICE}"
show BLUE  "\t\t\tMonitor   : ${MONITOR_ACTION}"
show BLUE  "\t\t\tSync path : /local/p0/${SERVICE}"

########################################
stage "Activity done SUCCESSFULLY in $(date +'%d/%m/%Y %H:%M')"
########################################
show BLUE ""
show BLUE "[Success]\tThe new service ${SERVICE} was created successfully."
show BLUE "\t\tThis service is using IP ${IP} and VG ${SERVICE}."
show BLUE "\n\t\tLog: ${FINAL_LOG}"
write_log "$(report_block)"
exit 0
