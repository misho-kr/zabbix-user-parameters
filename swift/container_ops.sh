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

declare -a IO_TEST_COMMANDS=(upload verify download)

declare -i CACHE_IO_TEST_TTL=50       # seconds
declare -i CACHE_TEST_TTL=240         # seconds

declare -i CACHE_RETRY_PAUSE=10       # seconds
declare -i CACHE_RETRY_TIMES=10       # N times

SWIFT_TESTFILE_SIZE="1K"    # Bytes, KBtytes, MBytes, etc.

SWIFT_TEST_CONTAINER="ZABBIX_SWIFT_TEST_CONTAINER"
SWIFT_TEST_IO_CONTAINER="ZABBIX_SWIFT_IO_TEST_CONTAINER"

function usage() {
  echo "usage: $0 -a -c <openstack cred file> -d <workdir> -f swift-command"
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

# Swift container tests
function create_container() { swift_op_noout post $* ;      }
function list_container()   { swift_op_noout list --lh $* ; }
function stats_container()  { swift_op_noout stat $* ;      }
function delete_container() { swift_op_noout delete $* ;    }

# Swift container I/O tests
function upload_container() {
  local container="${1}"
  local local_file="${2}"
  local container_file="${3}"

  swift_op_noout upload "${container}" "${local_file}" --object-name "${container_file}"
}

# 6. Download from swift container
function download_container() {
  local container="${1}"
  local container_file="${2}"
  local datafile="${3}"

  swift_op_noout download "${container}" "${container_file}" -o "${datafile}"
}

# 7. Verify swift container
function verify_container() {
  local datafile="${1}"
  local datafile_copy="${2}"

  cmp -s "${datafile}" "${datafile_copy}"
  echo $?
}

# cache operations ----------------------------------------------------

function now() { echo "$(date +%s)" ; }
function is_io_test() {
  local op=${1}
  declare -i i

  while [[ "${IO_TEST_COMMANDS[i]}" != "" ]]; do
    if [[ "${IO_TEST_COMMANDS[i]}" == ${op} ]]; then
      return 0 # found, i.e. op is io-test
    fi
    (( i += 1 ))
  done

  return 1 # not found, i.e. op is not io-test
}

function should_cache_be_refreshed() {
  local op=${1}
  declare -i cache_ts=${2}

  is_io_test ${op}
  local is_io_test_op=$?

  [[ "${CACHE_FORCE_UPDATE}" == "yes" ]] || \
  (( is_io_test_op == 0 && $(now) > (cache_ts + CACHE_IO_TEST_TTL) )) || \
  (( $(now) > (cache_ts + CACHE_TEST_TTL) ))
}

function merge_files() {
  join -t: -v1 -11 $1 $2 ; join -t: -v2 -11 $1 $2 ; (join -t: -11 $1 $2 | cut -d: -f1,4,5)
}

function refresh_cache_file() {
  local cache="${1}"
  local lock="${2}"
  local container="${3}"
  local op="${4}"

  # temp files
  local cache_new="${cache}-new"
  local cache_merged="${cache}-merged"

  trap 'rm -f ${cache_new} ${cache_merged}' EXIT

  # execute all swift tests and record the results
  f="${lock}/testfile.dat"
  fcopy="${lock}/testfile-copy.dat"
  f2="$(basename "${f}")"

  dd if=/dev/urandom of="${f}" count=1 bs=${SWIFT_TESTFILE_SIZE} &> /dev/null

  # swift op may fail, and that is OK
  set +e

  if ! is_io_test ${op}; then
    echo "create:$(now):$(create_container $container)"  >> ${cache_new}
    echo "list:$(now):$(list_container $container)"      >> ${cache_new}
  fi

  echo "upload:$(now):$(upload_container $container ${f} ${f2})"         >> ${cache_new}
  echo "download:$(now):$(download_container $container ${f2} ${fcopy})" >> ${cache_new}
  echo "verify:$(now):$(verify_container ${f} ${fcopy})"                 >> ${cache_new}

  rm -f "${f}" "${fcopy}"

  if ! is_io_test ${op}; then
    echo "stats:$(now):$(stats_container $container)"    >> ${cache_new}
    echo "delete:$(now):$(delete_container $container)"  >> ${cache_new}
  fi

  set -e

  test -f ${cache} || touch ${cache}
  merge_files ${cache} ${cache_new} > ${cache_merged} && \
    cp ${cache_merged} ${cache} &&
    rm ${cache_new} ${cache_merged}
}

function query_cache_file {
  local cache="${1}"
  local lock="${2}"
  local container="${3}"
  local op="${4}"

  local cache_ts_key=""
  declare -i cache_ts=0

  if test -f "${cache}"; then
    cache_ts_value=$(sed -n "s/^$op:\(.*\):\(.*\)$/\1:\2/p" "${cache}")
    cache_ts="${cache_ts_value%%:*}"
  fi

  if should_cache_be_refreshed ${op} ${cache_ts}; then
    refresh_cache_file $*

    cache_ts_value=$(sed -n "s/^$op:\(.*\):\(.*\)$/\1:\2/p" "${cache}")
    cache_ts="${cache_ts_value%%:*}"
  fi

  local value="${cache_ts_value#*:}"
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
  local container="${SWIFT_TEST_CONTAINER}:$(hostname)"

  if is_io_test ${swift_op}; then
    container="${SWIFT_TEST_IO_CONTAINER}:$(hostname)"
  fi

  acquire_lock_wait "${lock}"
  query_cache_file "${cache}" "${lock}" ${container} ${swift_op} $*
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