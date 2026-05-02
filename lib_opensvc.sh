#!/bin/bash
# lib_opensvc.sh - OpenSVC cluster helper functions
# Source this file; do not execute it directly.

[[ "${BASH_SOURCE[0]}" == "$0" ]] && { echo "This file must be sourced, not executed."; exit 1; }

#######################################################################
# INDEX
#######################################################################
#
#  resolve_svc_nodes()      Parse SVC_STATUS and set PRIMARY / STANDBY / NODE
#  refresh_ml_status()      Refresh OpenSVC service status variables from om
#  opensvc_freeze()         Freeze the cluster node via om node freeze
#  opensvc_unfreeze()       Unfreeze the cluster node or service via om thaw
#  opensvc_start_rid()      Start a RID
#  try_to_fix()             Fix service issues: sync | umount | prstart | provisioned | application
#  check_ml_status()        Print and classify service status (standard version)
#
#######################################################################

#######################################################################
# OpenSVC Cluster Helpers
#######################################################################

# -------------------
resolve_svc_nodes()
# -------------------
# Description: Parse the output of "om <svc> print status" to determine
#              which node is PRIMARY (up/warn) and which is STANDBY (down).
#              Sets NODE to PRIMARY.
#
#   SVC_STATUS  - global, must be set before calling (output of om print status)
#
# Globals set:
#   PRIMARY  - node where the service is currently active
#   STANDBY  - node where the service is currently down
#   NODE     - set to PRIMARY
#
# RC:
#   0  = both nodes resolved successfully
#   1  = PRIMARY could not be determined
#   2  = STANDBY could not be determined
# -------------------
{
    PRIMARY="$(awk '/^\s+`-/ || /^\s+\|-/ {node=$2} node && $3~/^(up|warn)/ {print node; exit}' <<< "${SVC_STATUS}")"
    [[ -z "$PRIMARY" ]] && return 1
    STANDBY="$(awk '/^\s+`-/ || /^\s+\|-/ {node=$2} node && $3=="down" {print node; exit}' <<< "${SVC_STATUS}")"
    [[ -z "$STANDBY" ]] && return 2
    NODE="${PRIMARY}"
    return 0
}

# -------------------
refresh_ml_status()
# -------------------
# Description: Collect service status from "om print status" and "om daemon
#              status" and populate ML_* global variables. A specific variable
#              group can be refreshed by passing its name as $1.
#
#   $1        = VAR selector: all | ML_STARTED | ML_WARN | ML_FROZEN |
#               ML_DISK | ML_PROV | ML_SYNC | ML_DOWN  (default: all)
#   SERVICE   - global, service name
#   NODE      - global, node to query
#
# Globals set:
#   ML_STARTED    - "1" if service is started on NODE, "0" otherwise
#   ML_WARN       - comma-separated resources in warn state
#   ML_FROZEN     - freeze label if frozen ("frozen" | "node frozen" | empty)
#   ML_DISK       - "true" if disk#1pr is not up, "false" otherwise
#   ML_PROV       - comma-separated resources not yet provisioned
#   ML_SYNC       - "true" if any sync resource is not up, "false" otherwise
#   ML_DOWN       - newline-separated resources in down state
# 
# RC:
#   0  = status collected successfully
#   1  = om output was empty (service or node unreachable)
# -------------------
{
    local VAR="${1:-all}" ML_RAW 
    ML_RAW="$(om "${SERVICE}" print status -r --node="${NODE}" 2>/dev/null)"
    [[ -z "$ML_RAW" ]] && return 1

    case "$VAR" in all|ML_STARTED)
	ML_STARTED="$(awk '/started/ && !/down/ {c++} END {print c+0}' <<< "${ML_RAW}")"
        ML_STARTED="${ML_STARTED:-0}" ;; esac
    case "$VAR" in all|ML_WARN)
        ML_WARN="$(awk '$3 ~ /W/ { print $2 }' <<< "${ML_RAW}")" ;; esac
    case "$VAR" in all|ML_FROZEN)
        ML_FROZEN="$(awk '/frozen/' <<< "${ML_RAW}" | sed 's/node frozen/node_frozen/' | xargs | cut -d' ' -f4- | cut -d',' -f1)" ;; esac
    case "$VAR" in all|ML_DISK)
	ML_DISK="$(awk '$2=="disk#1pr" && $4!="up" {print 1; exit}' <<< "${ML_RAW}")"
	ML_DISK="${ML_DISK:-0}" ;; esac
    case "$VAR" in all|ML_DISA)
        ML_DISA="$(awk '$4=="n/a" && substr($3,3,1)=="D" { print $2 }' <<< "${ML_RAW}")" ;; esac
    case "$VAR" in all|ML_PROV)
        ML_PROV="$(awk '! / up / && /provisioned/ {print $2}' <<< "${ML_RAW}" | xargs | tr ' ' ',')" ;; esac
    case "$VAR" in all|ML_DOWN)
	ML_DOWN="$(awk '$3 ~ /X/ { print $2 }' <<< "${ML_RAW}")"
	ML_DOWN_OPT="$(awk '$4=="down" && substr($3,4,1)=="O" { print $2 }' <<< "${ML_RAW}")" ;; esac
    case "$VAR" in all|ML_SYNC)
	ML_SYNC="$(awk '/sync#.*rsync/ && $4!="up" {print $2}' <<< "${ML_RAW}" | while read -r R; do grep -qw "${R}" <<< "${ML_DOWN_OPT}" || echo 1; done | grep -c 1)"
	ML_SYNC="${ML_SYNC:-0}" ;; esac
    return 0
}

# -------------------
opensvc_freeze()
# -------------------
# Description: Freeze the cluster node using "om node freeze --wait".
#              Checks current freeze state before and after the command.
#
# Globals used: SERVICE (via refresh_ml_status), ML_FROZEN
#
# RC:
#   0  = node frozen successfully
#   1  = refresh_ml_status failed
#   2  = node is already frozen (no action taken)
#   3  = freeze command failed
#   4  = refresh after freeze failed
#   5  = node does not show as frozen after command
# -------------------
{
    local TARGET="${1:-$SERVICE}"
    local SAVED_NODE="${NODE}"
    NODE="${PRIMARY}"
    refresh_ml_status ML_FROZEN                   || return 1
    [[ -z "${ML_FROZEN}" ]]                       || return 2
    run_command -l "om ${TARGET} freeze --wait"   || return 3
    refresh_ml_status ML_FROZEN                   || return 4
    [[ -n "${ML_FROZEN}" ]]                       || return 5
    NODE="${SAVED_NODE}"
    return 0
}

# -------------------
opensvc_unfreeze()
# -------------------
# Description: Unfreeze the cluster node or service using "om thaw --wait".
#              If frozen state is "node frozen", runs "om node thaw";
#              otherwise runs "om <SERVICE> thaw".
#
# Globals used: SERVICE, ML_FROZEN
#
# RC:
#   0  = unfrozen successfully
#   1  = refresh_ml_status failed
#   2  = node/service is not frozen (no action taken)
#   3  = thaw command failed
#   4  = refresh after thaw failed
#   5  = node/service still shows as frozen after command
# -------------------
{
    local SAVED_NODE="${NODE}"
    NODE="${PRIMARY}"

    refresh_ml_status ML_FROZEN || return 1
    [[ -n "${ML_FROZEN}" ]] || return 2

    # Loop até não haver mais frozen states
    local MAX=3 ITER=0
    while [[ -n "${ML_FROZEN}" ]] && (( ITER < MAX )); do
        (( ITER++ ))
        if [[ "${ML_FROZEN}" == "node_frozen" ]]; then
            run_command -l "om node thaw --wait" || return 3
        else
            run_command -l "om ${SERVICE} thaw --wait" || return 3
        fi
        refresh_ml_status ML_FROZEN || return 4
    done

    [[ -z "${ML_FROZEN}" ]] || return 5
    NODE="${SAVED_NODE}"
    return 0
}

# -------------------
opensvc_start_rid()
# -------------------
{
    local RID_STATUS RID_DOWN

    RID_DOWN="$(echo "${1}" | xargs)"
    ( [[ -f $DIR/res_down ]] && grep -wq "${RID_DOWN}" "$DIR"/res_down ) && return 1
    run_command -l "om ${SERVICE} start --rid ${RID_DOWN} --node ${PRIMARY} --wait" || update_status err "Unexpected ERROR starting ${RID_DOWN} (RC=$?)."
    # Verify if it started
    RID_STATUS="$(om "${SERVICE}" print status -r --node "${PRIMARY}" 2>/dev/null| awk -v rid="${RID_DOWN}" '$2==rid {print $4}')"
    [[ -z "${RID_STATUS}" ]] && update_status err "RID_STATUS is empty. Unexpected ERROR."
    [[ "${RID_STATUS}" == "up" ]] && return 0 || return 2
}

# -------------------
check_ml_status()
# -------------------
# Description: Print service status and classify the result.
#              Designed for pre/post-checks around maintenance operations.
#              Scripts that need extra RC codes (e.g. ML_DOWN_FS) define
#              their own local override.
# Description: Attempt to fix service issues by running one or more targeted
#              operations. Always runs sync from PRIMARY regardless of NODE.
#              Default target when called without arguments is "sync".
#
#   $@  = TARGET list (optional): sync | umount | prstart | provisioned
#         Default: sync | umount | prstart | provisioned
#         All targets can be combined: try_to_fix umount sync prstart provisioned
#
# Globals used: SERVICE, PRIMARY, NODE, ML_DOWN_FS, ML_SYNC, ML_DISK, ML_PROV,
#               RID, FS (for umount target)
#
# RC:
#   0   = all targets fixed successfully
#   11  = om start --rid failed (umount fix)
#   12  = refresh after umount fix failed
#   13  = om sync all failed
#   14  = refresh after sync failed
#   15  = om prstart failed
#   16  = refresh after prstart failed
#   17  = om set provisioned failed
#   18  = refresh after provisioned fix failed
#   51  = resource still DOWN after umount fix
#   52  = sync issues persist after fix
#   53  = SCSI reservation issue persists after fix
#   54  = provisioning state persists after fix
#   55  = application persists down after fix
# -------------------
{
    local TARGETS="$*"
    local FIXED=0 RC=0 SAVED_NODE="${NODE}"
    local RID_DOWN RID_TO_START="" RID_OPT="" FAIL_RID="" SKIP_RID="" FIX_RID="" OPT=0 
    local FAIL_SYNC=0 FAIL_DISK=0 FAIL_PROV=0

    run_command -l "om ${SERVICE} print status -r --node=${NODE}" || RC=1
    refresh_ml_status || RC=2

    NODE="${PRIMARY}"

    if [[ -n "${TARGETS}" ]] ; then
        for TARGET in ${TARGETS}; do
            case $TARGET in

                rid)
                    [[ -n "$ML_DOWN" ]] || continue
                    update_status warn 

		    RID_DOWN=""
                    for RID_DOWN in $(echo "$ML_DOWN" | tr ' ' '\n' | grep -E "${RID_FILTER}")
                    do
		        # Check if RID is optional
                        grep -wq "${RID_DOWN}" <<< "$ML_DOWN_OPT" && OPT=1 || OPT=0
                        if (( OPT )); then
			    # Set as Intentional DOWN RID.
                            RID_OPT="${RID_OPT:+$RID_OPT }$RID_DOWN"
                        else
                            show RED "[Warning]\tResource ${RID_DOWN} is considered CRITICAL (optional = false or inexistent)."
                            show RED "\t\tIt will try to start it..."
			    # Create list of RID to start
                            RID_TO_START="${RID_TO_START:+$RID_TO_START }$RID_DOWN"
                        fi
                    done
                    if [[ -n ${RID_TO_START} ]]; then
	               # Start critical RID		
		       RID_DOWN=""
                       for RID_DOWN in ${RID_TO_START}
                       do
                           phase "Fixing issue: Starting critical resource ${RID_DOWN}"
                           opensvc_start_rid "${RID_DOWN}"
                           case $? in
			           0) update_status fix "The resource [${RID_DOWN}] have been started successfully." 
				      FIX_RID="${FIX_RID:+$FIX_RID }$RID_DOWN"
			              FIXED=1 ;;
			           1) update_status skip "The resource [${RID_DOWN}] have been memorized remain DOWN and was skipped."
				      SKIP_RID="${SKIP_RID:+$SKIP_RID }$RID_DOWN" ;;
			           2) update_status nofix "The resource [${RID_DOWN}] didn't start successfully."
	                              FAIL_RID="${FAIL_RID:+$FAIL_RID }$RID_DOWN" ;;
	                   esac		       
			   RC=10
                       done
                    fi
                    echo "${RID_OPT}" >> "$DIR"/res_down
		    refresh_ml_status                                                ||  RC=2
                    ;;

                sync)
                    (( ML_SYNC ))  || continue
                    update_status warn "Cluster must be in sync."
                    phase "Fix: Sync configurations between nodes"
                    run_command -l "om ${SERVICE} sync all --wait"             || RC=3
		    refresh_ml_status                                                ||  RC=2
		    if (( ML_SYNC )); then
                        update_status nofix
                        (( FAIL_SYNC++ ))
                    else
                        update_status fix
                        FIXED=1
                    fi

                    ;;

                prstart)
		    (( ML_DISK )) || continue
                    update_status warn "SCSI reservation must be applied."
                    phase "Fixing issue: Applying SCSI reservation (prstart)"
                    run_command -l "om ${SERVICE} prstart --node=${NODE} --wait"  || RC=4
		    refresh_ml_status                                                ||  RC=2
                    if (( ML_DISK )); then
                        update_status nofix
                        (( FAIL_DISK++ ))
                    else
                        update_status fix
                        FIXED=1
                    fi
                    ;;

                provisioned)
                    [[ -n  "${ML_PROV}" ]]                                           || continue
                    update_status warn "Some resources must be set as provisioned."
                    phase "Fixing issue: Setting provisioned state"
                    run_command -l "om ${SERVICE} set provisioned --node ${ML_PROV} --wait" || RC=5
		    refresh_ml_status                                                ||  RC=2
                    if [[ "${ML_PROV}" == "true" ]]; then
                        update_status nofix 
                        (( FAIL_PROV++ ))
                    else
                        update_status fix
                        FIXED=1
                    fi
                    ;;
            esac
        done

        if (( FIXED > 0 )); then
	   show GREEN ""
	   sleep 1
           phase "Status of ${SERVICE} on primary (${NODE})"
           run_command -l "om ${SERVICE} print status -r --node=${NODE}" || RC=1
           refresh_ml_status || RC=2
        fi
    fi	

    NODE="${SAVED_NODE}"

    if (( ML_STARTED > 0 )); then
       show GREEN  "[Success]\tThe service ${SERVICE} is UP on primary node (${PRIMARY})"
       [[ "${NODE}" == "${STANDBY}" ]] &&   show GREEN  "\t\tIt's expected for some service resources to be unavailable on the standby node."
    else   
       show YELLOW    "[Warning]\tThe service ${SERVICE} seems to be DOWN in both nodes."
       RC=11
    fi
    if (( RC == 0 || RC == 10 )) && [[ "${NODE}" == "${PRIMARY}" ]]; then
        if [[ -n "${ML_WARN}" ]]; then
	    show YELLOW "[Warning]\tThere are resources in WARN state: $(echo "${ML_WARN}"|xargs)"
	    RC=16
	fi    
        if [[ -n "${ML_DOWN}" ]]; then
            show YELLOW "[Warning]\tThere are resources in DOWN state: $(echo "${ML_DOWN}"|xargs)"
	    RC=17
	fi    
    fi	

    RID_DOWN=""
    for RID_DOWN in ${RID_OPT}
    do	    
        show YELLOW "[Warning]\tResource ${RID_DOWN} is marked as OPTIONAL (optional = true) meaning it's not critical."
        show YELLOW "\t\tYou can start it manually with command: om ${SERVICE} start --rid ${RID_DOWN} --node ${PRIMARY}"
    done	

    (( FAIL_SYNC ))       && { show RED    "[Failure]\tThe data synchronization issue persists after fix.";                   RC=12; }
    (( FAIL_DISK ))       && { show RED    "[Failure]\tThe SCSI reservation issue persists after fix.";                       RC=13; }
    (( FAIL_PROV ))       && { show RED    "[Failure]\tThe provisioning state issue persists after fix.";                     RC=14; }
    [[ -n "${FIX_RID}"      ]]    &&   show GREEN  "[Success]\tThe resource(s) [${FIX_RID}] have been started successfully." 
    [[ -n "${SKIP_RID}"     ]]    &&   show YELLOW "[Skipped]\tThe resource(s) [${SKIP_RID}] have been memorized remain DOWN and was skipped."
    [[ -n "${FAIL_RID}"     ]]    && { show RED    "[Failure]\tThe resource(s) [${FAIL_RID}] didn't start successfully.";     RC=15; }

    return $RC
}

