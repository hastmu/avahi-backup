# shellcheck disable=SC2148

#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

declare -A HASH_DATA
declare -A HASHER_CFG
declare -A HASHER_QUEUE
declare -A REMOTE_QUEUE
declare -A HASHER_DELTA_LAST_OK

HASHER_QUEUE_FILE=""
REMOTE_QUEUE_FILE=""

#HASHER_CFG["FILEHASHER"]="/export/disk-1/home/loc_adm/Syncthing/src/avahi-backup/filehasher.py"
HASHER_CFG["FILEHASHER"]="filehasher.py"

HASHER_CFG["local.version"]="$("${HASHER_CFG["FILEHASHER"]}" --version)"

function remote.hasher.version() {
   # $1 ... remote hostname
   if [ -z "${HASHER_CFG["remote.$1.version"]}" ]
   then
      HASHER_CFG["remote.$1.version"]="$(ssh.cmd "${1}" filehasher.py --version)"
   fi

   if [ "${HASHER_CFG["local.version"]}" == "${HASHER_CFG["remote.$1.version"]}" ]
   then
      # match
      output "- filehasher version match local[${HASHER_CFG["local.version"]}] remote[${HASHER_CFG["remote.$1.version"]}]"
      return 0
   else
      # false
      output "- filehasher version mismatch local[${HASHER_CFG["local.version"]}] remote[${HASHER_CFG["remote.$1.version"]}]"
      return 1
   fi
}

function hash.remote.add2queue() {
   # $1 ... name
   # $2+ .. all attributes
   if [ ! -z "${REMOTE_QUEUE_FILE}" ]
   then
      touch "${REMOTE_QUEUE_FILE}"
      source "${REMOTE_QUEUE_FILE}"
      local item="${1}"
      shift 
      REMOTE_QUEUE["${item}"]="{ 'args': '${@}' }"
      output "- save remote queue[${REMOTE_QUEUE_FILE}] with #${#REMOTE_QUEUE[@]} entries"
      declare -p REMOTE_QUEUE > "${REMOTE_QUEUE_FILE}"
   fi
}

function hash.remote.remove_from_queue() {
   # $1 ... name
   if [ ! -z "${REMOTE_QUEUE_FILE}" ]
   then
      touch "${REMOTE_QUEUE_FILE}"
      source "${REMOTE_QUEUE_FILE}"
      unset REMOTE_QUEUE["${1}"]
      output "- save remote queue[${REMOTE_QUEUE_FILE}] with #${#REMOTE_QUEUE[@]} entries"
      declare -p REMOTE_QUEUE > "${REMOTE_QUEUE_FILE}"
   fi
}

function hash.remote.revisit.queue() {

   # $1 ... define queue file
   REMOTE_QUEUE_FILE="${1}"

   if [ -e "${REMOTE_QUEUE_FILE}" ]
   then
      # shellcheck disable=SC1091
      if source "${REMOTE_QUEUE_FILE}"
      then
         output "- sourcing hasher queue[${REMOTE_QUEUE_FILE}]..."
         declare -p REMOTE_QUEUE
      else
         rm -f "${REMOTE_QUEUE_FILE}"
      fi
   else
      output "- no hasher queue[${REMOTE_QUEUE_FILE}]..."
   fi

   # execute
   local -i item_max="${#REMOTE_QUEUE[@]}"
   if [ ${item_max} -gt 0 ]
   then
      local item=""
      local -i count=0
      local -i item_count=0
      local -i time_left=600
      local chunk_size=""
      local hash_file=""
      local -i s_time=0
      s_time=$(date +%s)

      for item in "${!REMOTE_QUEUE[@]}"
      do
         local -i scan_time=$(( time_left / (item_max-item_count) ))
         if [ ${scan_time} -lt 10 ]
         then
            scan_time=10
         fi
         # remove from local list
         output "- remote patching[${count}] item[${item_count}/${item_max}] time left[${time_left} sec] scan time per item[${scan_time}]"
         output "  - ${item}"

         # remove missing items
         if [ ! -e "${item}" ]
         then
            hash.remote.remove_from_queue "${item}"
         else
            timeout ${scan_time} filehasher.py $(echo "${REMOTE_QUEUE[${item}]//\'/\"}" | jq -r '."args"') 
            stat=${PIPESTATUS[0]}
            output "stat: ${stat}"
            if [ ${stat} -eq 124 ]
            then
               output "- timeout...keep"
            elif [ ${stat} -eq 0 ]
            then
               output "  - complete. drop from list."
               hash.remote.remove_from_queue "${item}"
            fi
         fi
         item_count=$(( item_count + 1 ))

         e_time=$(date +%s)
         time_left=$(( 600 - ( e_time - s_time ) ))
         if [ ${time_left} -lt 0 ]
         then
            break
         fi

         if check.blacklisted.process
         then
            break
         fi

      done
   fi

}


function hash.add2queue() {
   # $1 ... name
   # $2 ... chunk size
   # $3 ... hashfile
   touch "${HASHER_QUEUE_FILE}"
   source "${HASHER_QUEUE_FILE}"
   HASHER_QUEUE["${1}"]="{ 'chunk-size': ${2}, 'hashfile': '${3}' }"
   output "- save hasher queue[${HASHER_QUEUE_FILE}] with #${#HASHER_QUEUE[@]} entries"
   declare -p HASHER_QUEUE > "${HASHER_QUEUE_FILE}"
}

function hash.remove_from_queue() {
   # $1 ... name
   touch "${HASHER_QUEUE_FILE}"
   source "${HASHER_QUEUE_FILE}"
   unset HASHER_QUEUE["${1}"]
   output "- save hasher queue[${HASHER_QUEUE_FILE}] with #${#HASHER_QUEUE[@]} entries"
   declare -p HASHER_QUEUE > "${HASHER_QUEUE_FILE}"
}

function hash.gen_hash_filename() {
   # $1 ... input filename
   echo "${1//\//_}"
}

function hash.gen_full_hash_filename() {
   # $1 ... input filename
   echo "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/$(hash.gen_hash_filename "${1}")"
}

function hash.local_file() {

   # $1 ... timeout
   # $2 ... chunk-size
   # $3 ... inputfile
   # $4 ... WIP where to store hashes
   local -i stat
   output "# hashing[$3:$2]"
   local hashfile=""
   if [ -z "${4}" ]
   then
      # use default location
      hashfile="$(hash.gen_full_hash_filename "${3}")"
   else
      # with hashfile location
      hashfile="${4}"
   fi
   HASH_DATA["${3}"]="${hashfile}"

   echo timeout --preserve-status "$1" "${HASHER_CFG["FILEHASHER"]}" "--min-chunk-size=$2" \
                  --inputfile "${3}" --thread-mode 1 \
                  --hashfile "${hashfile}"


   timeout --preserve-status "$1" "${HASHER_CFG["FILEHASHER"]}" "--min-chunk-size=$2" \
                  --inputfile "${3}" --thread-mode 1 \
                  --hashfile "${hashfile}"

   stat=$?
   if [ ${stat} -eq 0 ]
   then
      output "  - are up-to-date"
      hash.remove_from_queue "${3}"
      return 0
   elif [ ${stat} -eq 1 ]
   then
      output "  - got updated."
      hash.remove_from_queue "${3}"
      return 0
   else
      hash.add2queue "${3}" "${2}" "${hashfile}"
      output "  ! local hashes are not up-to-date. add to queue."
      return 1
   fi

}

function hash.revisit.queue() {

   # $1 ... define queue file
   HASHER_QUEUE_FILE="${1}"

   if [ -e "${HASHER_QUEUE_FILE}" ]
   then
      # shellcheck disable=SC1091
      if source "${HASHER_QUEUE_FILE}"
      then
         output "- sourcing hasher queue[${HASHER_QUEUE_FILE}]..."
         declare -p HASHER_QUEUE
      else
         rm -f "${HASHER_QUEUE_FILE}"
      fi
   else
      output "- no hasher queue[${HASHER_QUEUE_FILE}]..."
   fi

   # execute
   local -i item_max="${#HASHER_QUEUE[@]}"
   if [ ${item_max} -gt 0 ]
   then
      local item=""
      local -i count=0
      local -i item_count=0
      local -i time_left=600
      local chunk_size=""
      local hash_file=""
      local -i s_time=0
      s_time=$(date +%s)

      for item in "${!HASHER_QUEUE[@]}"
      do
         local -i scan_time=$(( time_left / (item_max-item_count) ))
         if [ ${scan_time} -lt 10 ]
         then
            scan_time=10
         fi
         # remove from local list
         output "- local hashing scanned[${count}] item[${item_count}/${item_max}] time left[${time_left} sec] scan time per item[${scan_time}]"
         output "  - ${item}"

         chunk_size="$(echo "${HASHER_QUEUE[${item}]//\'/\"}" | jq -r '."chunk-size"')"
         hash_file="$(echo "${HASHER_QUEUE[${item}]//\'/\"}" | jq -r '."hashfile"')"

         # remove missing items
         if [ ! -e "${item}" ]
         then
            hash.remove_from_queue "${item}"
         else
            hash.local_file "${scan_time}s" "${chunk_size}" "${item}" "${hash_file}" 
         fi
         item_count=$(( item_count + 1 ))

         e_time=$(date +%s)
         time_left=$(( 600 - ( e_time - s_time ) ))
         if [ ${time_left} -lt 0 ]
         then
            break
         fi

         if check.blacklisted.process
         then
            break
         fi

      done
   fi

}

function hash.remote_file() {

   # $1 ... timeout
   # $2 ... chunk-size
   # $3 ... inputfile
   # $4 ... WIP where to store hashes
   local -i stat
   # shellcheck disable=SC2034
   HASH_DATA["${3}"]="${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/${3//\//_}"
   output "# input[$3:$2]"
   timeout "$1" filehasher.py "--min-chunk-size=$2" \
                  --inputfile "${3}" \
                  --hashfile "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/${3//\//_}"

   stat=$?
   if [ ${stat} -eq 0 ]
   then
      output "  - are up-to-date" 
      return 0
   elif [ ${stat} -eq 1 ]
   then
      output "  - got updated."
      return 0
   else
      output "  ! local hashes are not up-to-date."
      return 1
   fi

}


function hash.lastok.delta() {

   # $1 ... file
   # $2 ... age limit
   if [ ${#HASHER_DELTA_LAST_OK[@]} -eq 0 ]
   then
      if [ -e "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/.cache" ]
      then
         if source "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/.cache"
         then
            :
         else
            rm -f "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/.cache"
         fi
      fi
   fi

   local -i age=0
   local -i ret=0
   local hash_file_name="$(hash.gen_full_hash_filename "${1}")"
   if [ -n "${HASHER_DELTA_LAST_OK["${hash_file_name}"]}" ]
   then
      age=$(( $(date +%s) - "${HASHER_DELTA_LAST_OK["${hash_file_name}"]}" ))
      if [ ${age} -gt ${2} ]
      then
         ret=1
      else
         ret=0
      fi
   else
      age=-1
      ret=1
   fi
   output "- last-ok age: ${age} sec -> $(( age / 60 )) min"
   return ${ret}

}

function hash.transfer_remote_file() {
   # $1 ... local file
   # $2 ... chunk-size
   # $3 ... remote file
   # $4 ... remote host

   # return 0 ... fall fine
   # return 1 ... timeout reached - complete next time
   # return 2 ... hasher version mismatch
   # return 5 ... some error happened - take care

   # 1. checks
   # 1.1. local file hashing complete?
   local -i stat=0
   local -A pstat
   # create if not there
   if [ ! -e "${1}" ]
   then
      touch "${1}"
   fi
   # hash
   if hash.local_file "10s" "${2}" "${1}"
   then
      #echo "- local hashing complete..."
      if ! hash.lastok.delta "${1}" "$(( 24 * 60 * 60 ))"
      then
         # 1.2. check remote version
         if remote.hasher.version "${4}"
         then
            export FILEHASHER_SKIP_VERSION=1
   #        echo "- version match"
            # 2. copy hash to remote - done via stdin
            # 3. gen patch set
            echo timeout --preserve-status 60s "${HASHER_CFG["FILEHASHER"]}" \
               "--min-chunk-size=${2}" \
               --inputfile "${1}" \
               --hashfile "$(hash.gen_full_hash_filename "${1}")" \
               --remote-patching \
               --remote-host "${4}" \
               --remote-username "$(id -un)" \
               --remote-ssh-key ".ssh/backup" \
               --remote-src-file "${3}"

            timeout --preserve-status 60s "${HASHER_CFG["FILEHASHER"]}" \
               "--min-chunk-size=${2}" \
               --inputfile "${1}" \
               --hashfile "$(hash.gen_full_hash_filename "${1}")" \
               --remote-patching \
               --remote-host "${4}" \
               --remote-username "$(id -un)" \
               --remote-ssh-key ".ssh/backup" \
               --remote-src-file "${3}" | tee "$(hash.gen_full_hash_filename "${1}").log" 2>&1
            P=$(declare -p PIPESTATUS)
            echo ${P}
            eval declare -a status=$(echo ${P} | cut -d= -f2-)
            stat=${status[0]}
            echo "stat: ${stat}"
            #local -i unchanged=0
            #unchanged=$(grep -ci unchanged "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/${1//\//_}.log")
            if [ ${stat} -eq 0 ]
            then
               # mark as successful - skip next 24h
               output "- mark as done."
               touch "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/.cache"
               source "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/.cache"
               HASHER_DELTA_LAST_OK["$(hash.gen_full_hash_filename "${1}")"]=$(date +%s)
               output "- write ${#HASHER_DELTA_LAST_OK[@]} caches"
               declare -p HASHER_DELTA_LAST_OK > "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/.cache"
               hash.remote.remove_from_queue "$1"
               return 0
            else
               # add to queue
               hash.remote.add2queue "$1" "--min-chunk-size=${2}" \
               --inputfile "${1}" \
               --hashfile "$(hash.gen_full_hash_filename "${1}")" \
               --remote-patching \
               --remote-host "${4}" \
               --remote-username "$(id -un)" \
               --remote-ssh-key ".ssh/backup" \
               --remote-src-file "${3}"
               return 1
            fi
         # 4. apply patch
         # 5. cleanup
         else
            # mismatch in version
            return 2
         fi
      else
         output "- skipped as last_ok < 24h"
         return 0
      fi
   else
      # local hash not complete
      return 1
   fi

}

