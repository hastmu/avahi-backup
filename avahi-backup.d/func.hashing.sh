# shellcheck disable=SC2148

#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

declare -A HASH_DATA
declare -A HASHER_CFG
declare -A HASHER_QUEUE

HASHER_QUEUE_FILE=""

HASHER_CFG["FILEHASHER"]="/export/disk-1/home/loc_adm/Syncthing/src/avahi-backup/filehasher.py"
#HASHER_CFG["FILEHASHER"]="filehasher.py"

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

function hash.save.queue() {

   if [ ! -z "${HASHER_QUEUE_FILE}" ]
   then
      output "- save hasher queue[${HASHER_QUEUE_FILE}]"
      declare -p HASHER_QUEUE
      declare -p HASHER_QUEUE > "${HASHER_QUEUE_FILE}"
   else
      output "! call hash.save.queue without definition of queue file."
   fi
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
      hashfile="${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/${3//\//_}"
   else
      # with hashfile location
      hashfile="${4}"
   fi
   HASH_DATA["${3}"]="${hashfile}"

   timeout --preserve-status "$1" "${HASHER_CFG["FILEHASHER"]}" "--min-chunk-size=$2" \
                  --inputfile "${3}" \
                  --hashfile "${hashfile}"

   stat=$?
   if [ ${stat} -eq 0 ]
   then
      output "  - are up-to-date"
      unset HASHER_QUEUE["${3}"]
      hash.save.queue
      return 0
   elif [ ${stat} -eq 1 ]
   then
      output "  - got updated."
      unset HASHER_QUEUE["${3}"]
      hash.save.queue
      return 0
   else
      HASHER_QUEUE["${3}"]="{ 'chunk-size': $2, 'hashfile': '${hashfile}' }"
      hash.save.queue
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
      local -i scan_time=$(( time_left / item_max ))
      if [ ${scan_time} -lt 10 ]
      then
         scan_time=10
      fi

      for item in "${!HASHER_QUEUE[@]}"
      do
         # remove from local list
         output "- local hashing scanned[${count}] item[${item_count}/${item_max}] time left[${time_left} sec] scan time[${scan_time}]"

         chunk_size="$(echo "${HASHER_QUEUE[${item}]//\'/\"}" | jq -r '."chunk-size"')"
         hash_file="$(echo "${HASHER_QUEUE[${item}]//\'/\"}" | jq -r '."hashfile"')"
         echo "  - chunk-size: ${chunk_size}"
         echo "  - hash_file: ${hash_file}"

         # remove missing items
         if [ ! -e "${item}" ]
         then
            unset HASHER_QUEUE[${item}]
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
      done
         
      hash.save.queue
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
   if hash.local_file "10s" "${2}" "${1}" || [ ! -e "${1}" ]
   then
#      echo "- local hashing complete..."
      # 1.2. check remote version
      if remote.hasher.version "${4}"
      then
         export FILEHASHER_SKIP_VERSION=1
#        echo "- version match"
         # 2. copy hash to remote - done via stdin
         # 3. gen patch set
         timeout 60s "${HASHER_CFG["FILEHASHER"]}" \
            "--min-chunk-size=${2}" \
            --inputfile "${1}" \
            --hashfile "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/${1//\//_}" \
            --remote-patching \
            --remote-host "${4}" \
            --remote-username "$(id -un)" \
            --remote-ssh-key ".ssh/backup" \
            --remote-src-file "${3}" 
         stat=$?
         echo "stat: $?"
         if [ ${stat} -eq 0 ]
         then
            return 0
         else
            return 1
         fi

         # 4. apply patch
         # 5. cleanup
      else
         # mismatch in version
         return 2
      fi
   else
      # local hash not complete
      return 1
   fi

}

