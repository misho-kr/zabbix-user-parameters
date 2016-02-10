#!/bin/bash
# ----------------------------------------------------------------------
#                  Execute tests with Swift container
# ----------------------------------------------------------------------

set -e

ZABBIX_CONF_DIR="/etc/zabbix"
# ZABBIX_AGENT_CONF="${ZABBIX_CONF_DIR}/zabbix_agentd.conf"
ZABBIX_AGENT_SCRIPTS="${ZABBIX_CONF_DIR}/scripts"

source "${ZABBIX_AGENT_SCRIPTS}/swift/container_ops.conf"

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#                         Swift operations
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------

# read openstack credentials from environment, override in openrc file
function load_openstack_credentials() {
  local cred_file="${1}"

  os_auth_url="${OS_AUTH_URL}"
  os_tenant_name="${OS_TENANT_NAME}"
  os_username="${OS_USERNAME}"
  os_password="${OS_PASSWORD}"

  if [[ "$(basename ${cred_file})" == "${cred_file}" && ! -r "${cred_file}" ]]; then
    cred_file="${ZABBIX_AGENT_SCRIPTS}/${cred_file}"
  fi

  if test -r "${cred_file}"; then
    source "${cred_file}"
  fi

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
  swift_op $* &> /dev/null
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
function verify_container() { cmp -s "${1}" "${2}"; echo $?; }

# ---------------------------------------------------------------------
# ---------------------------------------------------------------------
#                          cache operations
# ---------------------------------------------------------------------
# ---------------------------------------------------------------------

declare -a IO_TEST_COMMANDS=(upload download verify delete_o)

function now() { echo "$(date +%s)" ; }
function is_io_test() {
  local op=${1}

  for i in $(seq 0 $(( ${#IO_TEST_COMMANDS[@]} -1 )) ); do
    if [[ "${IO_TEST_COMMANDS[i]}" == ${op} ]]; then
      return 0 # found, i.e. op is io-test
    fi
  done

  return 1 # not found, i.e. op is not io-test
}

function get_cache_state() {
  local op=${1}
  declare -i cache_ts=${2}

  is_io_test ${op}
  declare -i is_io_test_op=$?

  if \
    (( $is_io_test_op == 0 && $(now) > (cache_ts + (CACHE_MAX_TTL_AGE * CACHE_IO_TEST_TTL)) )) || \
    (( $(now) > (cache_ts + (CACHE_MAX_TTL_AGE * CACHE_TEST_TTL)) ))
  then
    echo "obsolete"

  elif \
    (( $is_io_test_op == 0 && $(now) > (cache_ts + CACHE_IO_TEST_TTL) )) || \
    (( $(now) > (cache_ts + CACHE_TEST_TTL) ))
  then
    echo "stale"
  else
    echo "current"
  fi
}

function query_cache_file {
  local cache="${1}"
  local op="${2}"

  local cache_entry=""
  local cache_value=""
  declare -i cache_ts=0

  if test -f "${cache}"; then
    cache_entry=$(sed -n "s/^$op:\(.*\):\(.*\)$/\1:\2/p" "${cache}")
    cache_ts="${cache_entry%%:*}"
    cache_value="${cache_entry#*:}"
  fi

  case "$(get_cache_state ${op} ${cache_ts:-0})" in
    "obsolete" ) update_cache_file_background $* ; echo "1" ;;
    "stale"    ) update_cache_file_background $* ; echo "${cache_value}" ;;
    "current"  )
        [[ "${CACHE_FORCE_UPDATE}" == "yes" ]] && update_cache_file_background $*
        echo "${cache_value}"
        ;;
    *)
        echo "-1"
        ;;
  esac
}

function update_cache_file_background() {
  (update_cache_file $*) &
}

function update_cache_file() {
  local cache="${1}"
  local swift_op="${2}"
  shift 2

  trap '' HUP

  local lock="${WORKDIR}/zabbix-swift-monitor.lock"
  local container="${SWIFT_TEST_CONTAINER}:$(hostname)"

  if is_io_test ${swift_op}; then
    container="${SWIFT_TEST_IO_CONTAINER}:$(hostname)"
  fi

  if acquire_lock_wait "${lock}"; then
    refresh_cache_file "${cache}" "${lock}" ${container} ${swift_op} $*
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

function refresh_cache_file() {
  local cache="${1}"
  local lock="${2}"
  local container="${3}"
  local op="${4}"

  # temp files
  local cache_new="${cache}-new"

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
  echo "delete_o:$(now):$(delete_container $container ${f2})"            >> ${cache_new}

  rm -f "${f}" "${fcopy}"

  if ! is_io_test ${op}; then
    echo "stats:$(now):$(stats_container $container)"     >> ${cache_new}
    echo "delete_c:$(now):$(delete_container $container)" >> ${cache_new}
  fi

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

function get_swift_op_code() {
  load_openstack_credentials "${CREDFILE}"
  query_cache_file "${WORKDIR}/${CACHE_FILENAME}" $*
}

function usage() {
  echo "usage: $0 -c <openstack cred file> -d <workdir> -s <test-file size> -z <zabbix-dir> -f swift-command"
  echo

  exit 1
}

while getopts "c:d:s:z:fh" opt; do
  case "${opt}" in
    c) CREDFILE="${OPTARG}"             ;;
    d) WORKDIR="${OPTARG}"              ;;
    f) CACHE_FORCE_UPDATE="yes"         ;;
    s) ZABBIX_CONF_DIR="${OPTARG}"      ;;
    s) SWIFT_TESTFILE_SIZE="${OPTARG}"  ;;
    h|*) usage                          ;;
  esac
done

shift $((OPTIND-1))

get_swift_op_code $*

# ---------------------------------------------------------------------
# eof
#