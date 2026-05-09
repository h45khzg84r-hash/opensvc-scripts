#!/bin/bash
# lib_common.sh - Generic shell utilities: output, logging, execution
# Source this file; do not execute it directly.
# Author.: adriano.costa
# Version: 20260508

[[ "${BASH_SOURCE[0]}" == "$0" ]] && { echo "This file must be sourced, not executed."; exit 1; }

#######################################################################
# INDEX
#######################################################################
#
#  show()              Print colored text to stdout and TEMP_LOG
#  phase()             Print a numbered phase header and register it in PHASE_LOG
#  stage()             Print a section separator in PHASE_LOG
#  update_status()     Update the last phase status in PHASE_LOG; print message
#  multipath_status()  Run multipath -ll, detect path issues, prompt on warn
#  init_logs()         Initialize log paths and derive SCRIPT name
#  write_log()         Strip ANSI, assemble and write the final log file
#  remote()            Execute a command on NODE via SSH or locally
#  run_command()       Execute, display and log a command with RC capture
#  prompt_continue()   Prompt to confirm information (yes/no) with status update
#  select_bool()       Prompt to select a boolean value (true/false).
#  select_numeric()    Prompt to select a numeric value. 0 disables it.
#
#######################################################################

#######################################################################
# Colors & Globals
#######################################################################
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; BLUE="\e[34m"; RESET="\e[0m"

#######################################################################
# Output & Logging
#######################################################################

# -------------------
show()
# -------------------
# Description: Print a colored message to stdout and append it to TEMP_LOG.
#
#   $1  = COLOR  - variable name (RED | GREEN | YELLOW | BLUE)
#   $2  = TEXT   - message to display
#
# Globals used: TEMP_LOG
#
# RC: (none - always succeeds)
# -------------------
{
    local COLOR="$1" TEXT="$2"
    echo -e "${!COLOR}${TEXT}${RESET}" | tee -a "${TEMP_LOG}"
}

# -------------------
phase()
# -------------------
# Description: Print a numbered phase header to stdout and register the phase
#              as [Running] in PHASE_LOG. Increments NUM.
#
#   $1  = TITLE  - phase description
#
# Globals used:  TEMP_LOG, PHASE_LOG
# Globals set:   PHASE (current phase label), NUM (incremented)
#
# RC: (none - always succeeds)
# -------------------
{
    local SEP
    SEP="\n$(printf '%*s' 60 '' | tr ' ' '=')"
    PHASE="$(printf "%02d" "$NUM"). $1"
    echo -e "\n${BLUE}${SEP}\n${PHASE}${SEP}${RESET}" | tee -a "${TEMP_LOG}"
    echo -e "[Running] ${PHASE}" >> "${PHASE_LOG}"
    (( NUM++ ))
}

# -------------------
stage()
# -------------------
# Description: Write a labeled section separator to PHASE_LOG.
#              Used to group phases into named stages (PRE-CHECK, MAIN, etc.).
#              If called with no argument, writes an unlabeled separator.
#
#   $1  = TITLE  - stage label (optional)
#
# Globals used: PHASE_LOG
#
# RC: (none - always succeeds)
# -------------------
{
    local SEP
    SEP="$(printf '%*s' 60 '' | tr ' ' '-')"
    [[ -n "$1" ]] && echo -e "${SEP}\n$1\n${SEP}" >> "${PHASE_LOG}" || echo -e "${SEP}"               >> "${PHASE_LOG}"
}

# -------------------
update_status()
# -------------------
# Description: Replace the status prefix of the last phase line in PHASE_LOG
#              and optionally print a colored message. On err/no_go, calls
#              create_log() and exits with code 1.
#
#   $1  = PHASE_STATUS  - token: ok | fix | nofix | warn | skip | err | no_go |
#                         running | prompt
#   $2  = MESSAGE - optional message to display
#
# Globals used: TEMP_LOG, PHASE_LOG
#
# RC:
#   (exits 1 on err or no_go)
# -------------------
{
    local COLOR PREFIX
    local PHASE_STATUS=$1 MESSAGE=$2
    case "${PHASE_STATUS}" in
        ok)      COLOR="${GREEN}"  PREFIX="[Success]" ;;
        fix)     COLOR="${GREEN}"  PREFIX="[ Fixed ]" ;;
        nofix)   COLOR="${RED}"    PREFIX="[Failure]" ;;
        warn)    COLOR="${YELLOW}" PREFIX="[Warning]" ;;
        skip)    COLOR="${YELLOW}" PREFIX="[Skipped]" ;;
        err)     COLOR="${RED}"    PREFIX="[ Error ]" ;;
        no_go)   COLOR="${RED}"    PREFIX="[Aborted]" ;;
        running) COLOR="${BLUE}"   PREFIX="[Running]" ;;
        prompt)  COLOR="${YELLOW}" PREFIX="[Prompt ]" ;;
    esac
    [[ -n "${MESSAGE}" ]] && echo -e "\n${COLOR}${PREFIX}\t${MESSAGE}${RESET}" | tee -a "${TEMP_LOG}"
    tac "${PHASE_LOG}" | sed "0,/^[^]]*]/s/^[^]]*]/${PREFIX}/" | tac > "${PHASE_LOG}.tmp" && mv "${PHASE_LOG}.tmp" "${PHASE_LOG}"
    sleep 1
    case "${PHASE_STATUS}" in
        err)   stage "Activity finished with ERROR in $(date +'%d/%m/%Y %H:%M')"
               show BLUE "\n\t\tLog: ${FINAL_LOG}"
               create_log
               exit 1
               ;;
        no_go) stage "Activity EXITED by user in $(date +'%d/%m/%Y %H:%M')"
               show BLUE "\n\t\tLog: ${FINAL_LOG}"
               create_log
               exit 1
               ;;
    esac
}

# -------------------
multipath_status()
# -------------------
# Description: Run "multipath -ll" on NODE and scan the output for known
#              failure keywords. On first call saves output to multipath-ll.before;
#              on subsequent calls saves to multipath-ll.after (used by select_luns).
#              Prompts operator to continue if issues are found.
#
# Globals used: HOST, NODE, DIR, TEMP_LOG
#
# RC:
#   0  = no issues detected
#   1  = multipath command failed
#   2  = multipath returned no output
#   3  = issues detected, operator confirmed to continue
#   4  = issues detected, operator chose to abort
# -------------------
{
    local LOG OUTPUT ISSUE
    [[ -f "${DIR}/multipath-ll.before" ]] && LOG="${DIR}/multipath-ll.after" || LOG="${DIR}/multipath-ll.before"
    if [[ "${HOST}" != "${NODE}" ]]; then
        echo -e "[root@${HOST}]:~ # ssh root@${NODE} multipath -ll" | tee -a "${TEMP_LOG}"
    else
        echo -e "[root@${HOST}]:~ # multipath -ll" | tee -a "${TEMP_LOG}"
    fi
    OUTPUT=$(remote "multipath -ll") || return 1
    [[ -z "${OUTPUT}" ]] && return 2
    echo "${OUTPUT}" | tee -a "${TEMP_LOG}"
    echo "${OUTPUT}" > "${LOG}"

    ISSUE="$(grep -E "failed|faulty|offline|shaky|removed|down" "${LOG}")"
    if [[ -n "$ISSUE" ]]; then
        update_status warn "There's an issue with some path in the multipath output:"
        while IFS= read -r LINE; do
            show YELLOW "\t\t${LINE}"
        done <<< "${ISSUE}"
        prompt_continue && return 3
        return 4
    fi
    return 0
}

# -------------------
init_logs()
# -------------------
# Description: Derive SCRIPT name from the calling script, create a temp
#              working directory and initialize all log file paths.
#              Must be called early in MAIN before any phase/stage calls.
#
#   $1  = SUFFIX  - optional suffix appended to log filenames (e.g. service name)
#
# Globals set:
#   SCRIPT    - calling script basename without .sh extension
#   DIR       - temp working directory (/tmp/$$)
#   PHASE_LOG - phase status log  (/tmp/phase.log)
#   TEMP_LOG  - colored session log (${DIR}/${SCRIPT}[_SUFFIX].log)
#   FINAL_LOG - final assembled log (/tmp/${SCRIPT}[_SUFFIX].log)
#
# RC: (none - always succeeds)
# -------------------
{
    # NUM: phase counter, incremented by phase() on each call
    NUM=1

    local SUFFIX="${1:+_$1}"
    SCRIPT="${BASH_SOURCE[1]##*/}"
    SCRIPT="${SCRIPT%.sh}"
    DIR=$(mktemp -d /tmp/opensvc_"${SCRIPT}"_XXXXXX)
    PHASE_LOG="/tmp/phase.log"
    TEMP_LOG="${DIR}/${SCRIPT}${SUFFIX}.log"
    FINAL_LOG="/tmp/${SCRIPT}${SUFFIX}.log"
    cp /dev/null "${PHASE_LOG}"
    cp /dev/null "${TEMP_LOG}"
    cp /dev/null "${FINAL_LOG}"
}

# -------------------
write_log()
# -------------------
# Description: Strip ANSI escape codes from TEMP_LOG, then assemble the
#              final log (header + PHASE_LOG + clean session log) into
#              FINAL_LOG. Removes the temp DIR afterwards.
#              Called by create_log() in each script.
#
#   $1  = HEADER  - plain-text activity header block (no ANSI colors)
#
# Globals used: TEMP_LOG, PHASE_LOG, FINAL_LOG, DIR
#
# RC: (none - always succeeds)
# -------------------
{
    local HEADER="$1" CLEAN_LOG SEP
    SEP="$(printf '%*s' 60 ''| tr ' ' '-')"
    CLEAN_LOG="${DIR}/clean.log"
    sed -r 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g; s/\r//g' "${TEMP_LOG}" > "${CLEAN_LOG}"
    {
        echo "${SEP}"
        echo -e "${HEADER}"
        echo "${SEP}"
        cat "${PHASE_LOG}"
        cat "${CLEAN_LOG}"
    } >> "${FINAL_LOG}"
    rm -rf "${DIR}" 2>/dev/null
}

# -------------------
remote()
# -------------------
# Description: Execute a command silently. Uses SSH if needed.
#              remote CMD        - runs on NODE (global)
#              remote TARGET CMD - runs on explicit TARGET
#              Suppresses stderr. For logged output use run_command.
#              runs locally otherwise.
#              Used for data collection (not for logged commands - use run_command).
#
#   $1  = [TARGET] - optional node hostname (default: NODE global)
#   $2  = CMD      - shell command (or $1 if no TARGET given)
#
# Globals used: HOST, NODE (when TARGET not provided)
#
# RC:
#   1   = CMD is empty
#   *   = return code of the executed command
# -------------------
{
    local CMD TARGET
    # remote TARGET CMD  (explicit target)
    # remote CMD         (uses NODE global)
    if [[ $# -eq 2 ]]; then
        TARGET="$1"; CMD="$2"
    else
        TARGET="${NODE}"; CMD="$1"
    fi
    [[ -z "$CMD" ]] && return 1
    if [[ "${HOST}" != "${TARGET}" ]]; then
        ssh -o LogLevel=ERROR root@"${TARGET}" bash <<< "${CMD}" 2>/dev/null
    else
        bash -c "${CMD}" 2>/dev/null
    fi
}

# -------------------
run_command()
# -------------------
# Description: Execute a command with full logging (displays prompt, stdout and
#              stderr to screen and TEMP_LOG). Runs on NODE via SSH unless the
#              -l flag is given, in which case it always runs locally.
#
#   -l  = (optional flag) force local execution regardless of HOST vs NODE
#   $1  = CMD      - shell command (or $1 if no TARGET given)
#
# Globals used: HOST, NODE (when TARGET not provided), TEMP_LOG
#
# RC:
#   1   = CMD is empty
#   *   = return code of the executed command
# -------------------
{
    local RC CMD LOCALITY="" DISPLAY_CMD=""
    [[ "$1" == "-l" ]] && { LOCALITY="local"; shift; }
    CMD="$1"
    [[ -z "$CMD" ]] && return 1
    DISPLAY_CMD="$CMD"

    if [[ "${HOST}" != "${NODE}" && "${LOCALITY}" != "local" ]]; then
        DISPLAY_CMD="ssh root@${NODE} ${CMD}"
        echo -e "[root@${HOST}]:~ # ${DISPLAY_CMD}" | tee -a "${TEMP_LOG}"
        printf '%s\n' "${CMD}" | ssh -o LogLevel=ERROR root@"${NODE}" bash 2>&1 | tee -a "${TEMP_LOG}"
        RC=${PIPESTATUS[1]}
    else
        echo -e "[root@${HOST}]:~ # ${DISPLAY_CMD}" | tee -a "${TEMP_LOG}"
        bash -c "${CMD}" 2>&1 | tee -a "${TEMP_LOG}"
        RC=${PIPESTATUS[0]}
    fi
    echo -e "[root@${HOST}]:~ #\n" | tee -a "${TEMP_LOG}"
    sleep 1
    return "$RC"
}

# -------------------
prompt_continue()
# -------------------
# Description: Display a yes/no prompt to the operator and wait for input.
#              Sets phase status to [Prompt] before reading and back to
#              [Running] after. Logs the answer to TEMP_LOG.
#
#   $1  = MESSAGE  - optional custom prompt label (default: "Continue?")
#
# Globals used: TEMP_LOG
#
# RC:
#   0  = operator answered Y or y
#   1  = operator answered anything else
# -------------------
{
    local PROMPT ANSWER  YORN='<  No   >'

    [[ -z "$1" ]] && PROMPT='Continue?' || PROMPT="$1"
    echo -e "<Prompt > ${PROMPT}" >> "${PHASE_LOG}"
    PROMPT=$'\t\t'"${PROMPT}"$' ([Y]es/[N]o):'

    read -p "${PROMPT}" -n 1 -r ANSWER

    [[ "$ANSWER" =~ ^[Yy]$ ]] && YORN="<  Yes  >"

    tac "${PHASE_LOG}" | sed "0,/<[^>]*>/s/<[^>]*>/${YORN}/" | tac > "${PHASE_LOG}.tmp" && mv "${PHASE_LOG}.tmp" "${PHASE_LOG}"
    PROMPT=$(printf "%s" "$PROMPT" | sed $'s/\t//g; s/://g')
    echo -e "\t\t${PROMPT} ${YORN}" >> "${TEMP_LOG}"

    [[ "$ANSWER" =~ ^[Yy]$ ]] && return 0 || return 1
}

# -------------------
select_bool()
# -------------------
# Description: Prompt operator to select a boolean value (true/false).
#              Pressing Enter accepts the default value.
#
#   $1  = PARAM   - parameter name (for display)
#   $2  = DEFAULT - default value: true | false (default: true)
#
# Globals used: (none)
#
# RC: (none - always succeeds)
# Prints: "true" or "false"
# -------------------
{
    local PARAM="$1" DEFAULT="${2:-true}" OPT

    while true; do
        read -rp $'\t\t'"${PARAM} [1=true / 2=false / Enter=${DEFAULT}]: " OPT
        case "${OPT}" in
            1)  echo "true";        return 0 ;;
            2)  echo "false";       return 0 ;;
            "") echo "${DEFAULT}";  return 0 ;;
            *)  show YELLOW "\t\tInvalid option. Press 1, 2 or Enter." ;;
        esac
    done
}

# -------------------
select_numeric()
# -------------------
# Description: Prompt operator for a numeric value. 0 disables the parameter.
#
#   $1  = PARAM   - parameter name (for display)
#   $2  = DEFAULT - default value
#
# RC: 0  - always succeeds
# Prints: the selected value, or empty string if 0 (disabled)
# -------------------
{
    local PARAM="$1" DEFAULT="${2:-0}" VAL

    while true; do
        read -rp $'\t\t'"${PARAM} [0=disable, Enter=${DEFAULT}]: " VAL
        [[ -z "$VAL" ]] && VAL="${DEFAULT}"
        [[ "$VAL" =~ ^[0-9]+$ ]] && break
        show YELLOW "\t\tInvalid value. Enter a positive integer or 0 to disable."
    done
    (( VAL == 0 )) && echo "" || echo "${VAL}"
}