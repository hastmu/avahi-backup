
#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

declare -A HASH_DATA

function hash.local_file() {

   # $1 ... timeout
   # $2 ... chunk-size
   # $3 ... inputfile
   # $4 ... WIP where to store hashes
   local -i stat
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

function hash.remote_file() {

   # $1 ... timeout
   # $2 ... chunk-size
   # $3 ... inputfile
   # $4 ... WIP where to store hashes
   local -i stat
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
