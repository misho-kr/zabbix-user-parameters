#!/bin/bash
# ----------------------------------------------------------------------
#                  Execute tests with Docker client
# ----------------------------------------------------------------------

set -ae

ZABBIX_CONF_DIR="/etc/zabbix"
# ZABBIX_AGENT_CONF="${ZABBIX_CONF_DIR}/zabbix_agentd.conf"
ZABBIX_AGENT_SCRIPTS="${ZABBIX_CONF_DIR}/scripts"

source "${ZABBIX_AGENT_SCRIPTS}/docker-client/docker_ops.conf"

function now() { echo "$(date +%s)" ; }
function log() { echo "$(date +%Y, %h %d %H:%M:%S) > $*"; }

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#                         Docker operations
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------

function docker_pull() {
  log docker-pull $*

  # NB: clean up so the following pull operation will download new image
  docker rmi ${DOCKER_TEST_IMAGE} &> /dev/null

  # test, i.e. pull
  docker pull ${DOCKER_TEST_IMAGE}
}

function docker_push() {
  log docker-push $*

  # NB: unless the image is removed from the remore repo, this push
  # operation will not upload new content to the remote repo
  docker push ${DOCKER_TEST_IMAGE}
}

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#                          cache operations
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------

# time-stamp should be obtained AFTER the value is computed
function make_ts_entry() { echo "${1}:$(now):${2}"; }

function get_cache_state_from_ts() {
  local op=${1}
  declare -i cache_ts=${2}

  is_io_test ${op}
  declare -i is_io_test_op=$?
  declare -i io_ttl=${CACHE_IO_TEST_TTL}

  if (( $(now) > (cache_ts + (CACHE_MAX_TTL_AGE * CACHE_TEST_TTL)) )); then
    echo "obsolete"

  elif (( $(now) > (cache_ts + CACHE_TEST_TTL) )); then
    echo "stale"

  else
    echo "current"
  fi
}

function get_cache_state_only() {
  local cache_state="$(get_cache_state $*)"
  echo "${cache_state%%:*}"
}

function get_cache_state() {
  local cache="${1}"
  local op="${2}"

  local cache_value="nan"
  declare -i cache_ts=0

  if test -f "${cache}"; then
    local cache_entry=$(sed -n "s/^$op:\(.*\):\(.*\)$/\1:\2/p" "${cache}")
    cache_ts="${cache_entry%%:*}"
    cache_value="${cache_entry#*:}"
  fi

  echo "$(get_cache_state_from_ts ${op} ${cache_ts:-0}):${cache_value}"
}

function query_cache_file {
  local cache="${1}"
  local op="${2}"

  local cache_state="$(get_cache_state ${cache} ${op})"
  case "${cache_state%%:*}" in
    "obsolete" ) echo "${CACHE_OBSOLETE_RET_VALUE}"; update_cache_file_background $* ;;
    "stale"    ) echo "${cache_state#*:}" ;          update_cache_file_background $* ;;
    "current"  ) echo "${cache_state#*:}"
                 [[ ${CACHE_FORCE_UPDATE} == "yes" ]] && update_cache_file_background $*
                 ;;
    *)
        echo "${SWIFT_OP_UNKNOWN_RET_VALUE}" ;;
  esac
}

function update_cache_file_background() {
  local logfile="/dev/null"

  if [[ "${TEST_LOGGING}" == "yes" ]]l; then
    logfile="${WORKDIR}/${LOG_FILENAME}"
  fi

  nohup bash -c "update_cache_file $*" < /dev/null &> "${logfile}" &
  # update_cache_file $*
}

function update_cache_file() {
  local cache="${1}"
  local docker_op="${2}"
  shift 2

  local lock="${WORKDIR}/zabbix-docker-client-monitor.lock"

  if acquire_lock_wait "${lock}"; then
    # check if update is required, in case this process had to wait and
    # another process refreshed the values
    if [[ ${CACHE_FORCE_UPDATE} == "yes" || \
          "$(get_cache_state_only ${cache} ${docker_op})" != "current" ]]
    then
      refresh_cache_file "${cache}" "${lock}" ${docker_op} $*
    fi
    release_lock "${lock}"
  else
    echo "$$ -- failed to acquire lock !!!"
  fi
}

# merge files $1 and $2, and store the result in $1
# note: file $2 will be used as temp file and will be removed at end
function merge_cache_files() {
  local old="${1}"
  local new="${2}"
  local tmp="$(mktemp)"

  test -f "${old}" || touch "${old}"

  sort ${new} > ${tmp}
  ( join -t: -j1 -v1 ${old} ${tmp} ; \
      join -t: -j1 -v2 ${old} ${tmp} ; \
        (join -t: -j1    ${old} ${tmp} | cut -d: -f1,4,5 | sort -u)) | sort > ${new}

  rm ${tmp} && mv ${new} ${old}
}

# execute all docker-client tests and record the results
function refresh_cache_file() {
  local cache="${1}"
  local lock="${2}"
  local op="${3}"

  # temp file
  local cache_new="${cache}-new"

  # docker op may fail, and that is OK
  set +e

  docker_pull; make_ts_entry docker_pull $? >> ${cache_new}
  docker_push; make_ts_entry docker_push $? >> ${cache_new}

  set -e

  # merge the files, save the result in $cache, and remove $cache_new
  merge_cache_files ${cache} ${cache_new}
}

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#
#                           lock operations
#
# simplified version of: http://wiki.bash-hackers.org/howto/mutex
#
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------

function on_error_handler() {
  local lock="${1}"
  local exit_code="${2}"

  release_lock "${lock}"
  exit "${exit_code}"
}

function acquire_lock_wait() {
  local lock="${1}"
  declare -i pid=${BASHPID}

  for i in $(seq ${LOCK_RETRY_TIMES}); do
    if test -d "${lock}"; then
      # 1. lock exists
      set +e
      lockpid="$(cat "${lock}/pid")"
      set -e
      if (( $? == 0 )); then
        if ! kill -0 ${lockpid} &> /dev/null; then
          # lock is stale, lock holder is not running
          rm -r "${lock}"
          continue
        # else -> lock is still active
        fi
      # else -> failed to read pidfile? race condition?
      fi

    elif mkdir "${lock}" &> /dev/null; then
      # 2. lock acquired
      trap 'on_error_handler "${lock}" 127' SIGINT SIGTERM SIGHUP
      echo $pid > "${lock}"/pid
      return 0
    # else 3. lock missing, i.e. some other process grabbed it before us, bummer
    fi

    sleep ${LOCK_RETRY_PAUSE}
  done

  # max retries reached, failed to acquire lock
  return 1
}

function release_lock() {
  rm -r "${1}"
}

# ---------------------------------------------------------------------
#  main
# ---------------------------------------------------------------------

function get_docker_op_code() {
  query_cache_file "${WORKDIR}/${CACHE_FILENAME}" $*
}

function usage() {
  echo "usage: $0 -c <docker config dif> -d <workdir> -f -i <docker image> -l -n <repo namespace> -z <zabbix-dir> swift-command"
  echo

  exit 1
}

while getopts "c:d:fhi:ln:s:z:" opt; do
  case "${opt}" in
    c) DOCKER_CONF_DIR="${OPTARG}"       ;;
    d) WORKDIR="${OPTARG}"               ;;
    f) CACHE_FORCE_UPDATE="yes"          ;;
    i) DOCKER_TEST_IMAGE="${OPTARG}"     ;;
    l) TEST_LOGGING="yes"                ;;
    n) DOCKER_TEST_NAMESPACE="${OPTARG}" ;;
    z) ZABBIX_CONF_DIR="${OPTARG}"       ;;
    h|*) usage                           ;;
  esac
done

shift $((OPTIND-1))

get_docker_op_code $*

# ---------------------------------------------------------------------
# eof
#