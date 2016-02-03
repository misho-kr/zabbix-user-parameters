#!/bin/bash
# ----------------------------------------------------------------------
#                  Execute tests with Swift container
# ----------------------------------------------------------------------

set -e

ZABBIX_AGENT_CONF="/etc/zabbix/zabbix_agentd.conf"
DEFAULT_ZABBIX_CONF_DIR="/etc/zabbix/zabbix_agentd.conf.d/"

ZABBIX_CONF_DIR="$(grep '^Include=' ${ZABBIX_AGENT_CONF} | cut -d= -f2)"
ZABBIX_CONF_DIR="${ZABBIX_CONF_DIR:-${DEFAULT_ZABBIX_CONF_DIR}}"

CREDFILE="$(dirname "${ZABBIX_AGENT_CONF}")/openrc.sh"

WORKDIR="/tmp"
CACHE_FORCE_UPDATE="no"
CACHE_TTL=55               # seconds
CACHE_RETRY_PAUSE=10       # seconds
CACHE_RETRY_TIMES=10
SWIFT_TESTFILE_SIZE="1K"    # Bytes, KBtytes, MBytes, etc.

function usage() {
  echo "usage: $0 -c <openstack cred file> -d <workdir> -f swift-command"
  echo

  exit 1
}

# Swift operations -----------------------------------------------------

# read openstack credentials from environment, fallback to credentials file
function load_openstack_credentials() {
  local cred_file="${1}"

  os_auth_url="${OS_AUTH_URL}"
  os_tenant_name="${OS_TENANT_NAME}"
  os_username="${OS_USERNAME}"
  os_password="${OS_PASSWORD}"

  source "${cred_file}"

  os_auth_url="${os_auth_url:-${OS_AUTH_URL}}"
  os_tenant_name="${os_tenant_name:-${OS_TENANT_NAME}}"
  os_username="${os_username:-${OS_USERNAME}}"
  os_password="${os_password:-${OS_PASSWORD}}"
}

function swift_op() {
  swift \
      --os-auth-url    ${os_auth_url}    \
      --os-tenant-name ${os_tenant_name} \
      --os-username    ${os_username}    \
      --os-password    ${os_password}    \
          $*

  # 0 = success, 1 = fail
}

# execute swift operation and send all output to /dev/null
function swift_op_noout() {
  swift_op $* > /dev/null 2>&1
  echo $?
}

# 1. Create swift container
function create_container() {
  local container="${1}"

  swift_op_noout post "${container}"
}

# 2. List swift container
function list_container() {
  local container="${1}"

  swift_op_noout list --lh "${container}"
}

# 3. Upload to swift container
function upload_container() {
  local container="${1}"
  local local_file="${2}"
  local container_file="${3}"

  swift_op_noout upload "${container}" "${local_file}" --object-name "${container_file}"
}

# 4. Download from swift container
function download_container() {
  local container="${1}"
  local container_file="${2}"
  local datafile="${3}"

  swift_op_noout download "${container}" "${container_file}" -o "${datafile}"
}

# 5. Verify swift container
function verify_container() {
  local datafile="${1}"
  local datafile_copy="${2}"

  cmp -s "${datafile}" "${datafile_copy}"
  echo $?
}

# 6. Stat swift container
function stats_container() {
  local container="${1}"

  swift_op_noout stat "${container}"
}

# 7. Delete swift container
function delete_container() {
  local container="${1}"

  swift_op_noout delete "${container}"
}

# cache operations ----------------------------------------------------

function refresh_cache_file() {
  local cache="${1}"
  local lock="${2}"

  # truncate the cache file
  cat /dev/null > "${cache}"

  # execute all swift tests and record the results
  c="ZABBIX_SWIFT_TEST_container:$(hostname)"
  f="${lock}/testfile.dat"
  f2="$(basename "${f}")"
  fcopy="${lock}/testfile-copy.dat"

  dd if=/dev/urandom of="${f}" count=1 bs=${SWIFT_TESTFILE_SIZE} &> /dev/null

  set +e
  echo "create:$(create_container $c)"  >> ${cache}
  echo "list:$(list_container $c)"      >> ${cache}

  echo "upload:$(upload_container $c ${f} ${f2})"        >> ${cache}
  echo "download:$(download_container $c ${f2} ${fcopy})" >> ${cache}
  echo "verify:$(verify_container ${f} ${fcopy})"         >> ${cache}

  rm -f "${f}" "${fcopy}"

  echo "stats:$(stats_container $c)"    >> ${cache}
  echo "delete:$(delete_container $c)"  >> ${cache}
  set -e
}

function query_cache_file {
  local cache="${1}"
  local lock="${2}"
  local op="${3}"

  declare -i now=$(date +%s)
  declare -i cache_ts=0

  if test -f "${cache}"; then
    cache_ts=$(stat -c%Z ${cache})
  fi

  if [[ "${CACHE_FORCE_UPDATE}" == "yes" ]] || (( now > (cache_ts + CACHE_TTL) )); then
    refresh_cache_file $*
  fi

  value="$(cat "${cache}" | grep "^${op}:" | cut -d: -f2)"
  echo "${value:--1}"
}

# lock operations -----------------------------------------------------
#
# simplified version of: http://wiki.bash-hackers.org/howto/mutex
#

function acquire_lock_wait() {
  local lock="${1}"
  declare -i retry=${CACHE_RETRY_TIMES}

  while (( retry > 0 )); do

    if test -d "${lock}"; then
      # 1. lock exists
      set +e
      lockpid="$(cat "${lock}/pid")"
      set -e
      if (( $? == 0 )); then
        if ! kill -0 ${lockpid} &> /dev/null; then
          # lock is stale, lock holder is not running
          rm -r "${lock}"
          (( retry -= 1 ))
          continue
        # else -> lock is still active
        fi
      # else -> failed to read pidfile? race condition?
      fi

    elif mkdir "${lock}" &> /dev/null; then
      # 2. lock acquired
      trap 'on_error_handler "${lock}" $?' SIGINT SIGTERM SIGHUP
      echo $$ > "${lock}"/pid
      break
    # else 3. lock missed, i.e. some other process grabbed it before us, bummer
    fi

    (( retry -= 1 ))
    sleep ${CACHE_RETRY_PAUSE}
  done
}

function release_lock() {
  rm -r "${1}"
}

function on_error_handler() {
  local lock="${1}"
  local exit_code="${2}"

  release_lock "${lock}"
  exit "${exit_code}"
}

# main ----------------------------------------------------------------

function get_swift_op_code() {
  local swift_op="${1}"
  shift

  local cache="${WORKDIR}/zabbix-swift-monitor.cache"
  local lock="${WORKDIR}/zabbix-swift-monitor.lock"

  acquire_lock_wait "${lock}"
  query_cache_file "${cache}" "${lock}" "${swift_op}" $*
  release_lock "${lock}"
}

while getopts "c:d:fh" opt; do
  case "${opt}" in
    c) CREDFILE="${OPTARG}"     ;;
    d) WORKDIR="${OPTARG}"      ;;
    f) CACHE_FORCE_UPDATE="yes" ;;
    h|*) usage                  ;;
  esac
done

shift $((OPTIND-1))

load_openstack_credentials "${CREDFILE}"
get_swift_op_code $*

# ---------------------------------------------------------------------
# eof
#