# shellcheck disable=SC2148

#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

declare -A HASH_DATA
declare -A HASHER_CFG

HASHER_CFG["local.version"]="$(filehasher.py --version)"

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

function hash.local_file() {

   # $1 ... timeout
   # $2 ... chunk-size
   # $3 ... inputfile
   # $4 ... WIP where to store hashes
   local -i stat
   HASH_DATA["${3}"]="${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/${3//\//_}"
   output "# hashing[$3:$2]"
   if [ -z "${4}" ]
   then
      # use default location
      timeout "$1" filehasher.py "--min-chunk-size=$2" \
                     --inputfile "${3}" \
                     --hashfile "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/${3//\//_}" \
                     >> /dev/null 2>&1
   else
      # with hashfile location
      timeout "$1" filehasher.py "--min-chunk-size=$2" \
                     --inputfile "${3}" \
                     --hashfile "${4}" \
                     >> /dev/null 2>&1
   fi

   stat=$?
   if [ ${stat} -eq 0 ]
   then
      #output "  - are up-to-date" 
      return 0
   elif [ ${stat} -eq 1 ]
   then
      #output "  - got updated."
      return 0
   else
      output "  ! local hashes are not up-to-date."
      return 1
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
         filehasher.py \
            "--min-chunk-size=${2}" \
            --inputfile "${1}" \
            --hashfile "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes/${1//\//_}" \
            --remote-patching \
            --remote-host "${4}" \
            --remote-username "$(id -un)" \
            --remote-ssh-key ".ssh/backup" \
            --remote-src-file "${3}" >> /dev/null
         return 0

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

