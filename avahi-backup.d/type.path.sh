# shellcheck disable=SC2148

#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

function type.path.init() {
   output "init - type - path"
}

function type.path.outline.prefix() {
   echo "#${RUNTIME["BACKUP_CLIENTNAME"]}/${RUNTIME_ITEM["type"]}[${RUNTIME_ITEM["path"]}]# "
}

function type.path.logbase.name() {
   echo "${RUNTIME_ITEM["path"]//\//_}"
}

function type.path.logfile.postfix() {
   echo ".$(date +%Y-%m-%d_%H:%M).log"
}

function type.path.subvol.name() {
   local tmpstr=""
   tmpstr="${RUNTIME_ITEM["path"]#*/}"
   tmpstr="${tmpstr//\//_}"
   echo "${tmpstr}"
}

function type.path.summary() {
   SUMMARY[${#SUMMARY[@]}]="S.PATH: was used."
}

function type.path.check.preflight() {
   local -i error_count=0
   local -i stat=0
   
   local src=""
   src="${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["path"]}"

   RUNTIME["RSYNC_ARGS"]=""

   # check if rsync is available
   if [ -z "${RUNTIME_NODE["rsync.stat"]}" ]
   then
      ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" which rsync >> /dev/null 2>&1
      stat=$?
      if [ ${stat} -eq 0 ]
      then
         output "- rsync available"
      else
         SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} pre-flight check failed - please fix - rsync missing."
      fi
      RUNTIME_NODE["rsync.stat"]=${stat}
   fi
   error_count=$(( error_count + ${RUNTIME_NODE["rsync.stat"]} ))
   # check if source is available
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" stat -c %n "${RUNTIME_ITEM["path"]}" >> /dev/null 2>&1
   stat=$?
   if [ ${stat} -eq 0 ]
   then
      output "- source available"
   else
      output "! source unavailable"
#      output "$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" stat -c %n ${RUNTIME_ITEM["path"]})"
#      output "exit: ${stat}"
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} pre-flight check failed - please fix - source unavailable."
   fi
   error_count=$(( error_count + stat ))

   # check for sshfs mounts
   local source_path=""
   source_path="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" cd "${RUNTIME_ITEM["path"]}" \; pwd -P)"
   local item=""
   for item in $(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" mount -t fuse.sshfs | awk '{ print $3 }' | grep "${source_path}")
   do
      # exclude 
      output "! excluding sshfs mount: ${item}"
      RUNTIME["RSYNC_ARGS"]="${RUNTIME["RSYNC_ARGS"]} --exclude=$(echo "${item}" | sed "s:^${source_path}/::g")"
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-WARNING:${src} pre-flight excluded sshfs mount: ${item}"
   done

   # build summary
   if [ ${error_count} -gt 0 ]
   then
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} pre-flight check failed - please fix"
   fi
   return ${error_count}
}

function type.path.perform.backup() {

   local src=""
   local -i stat=0

   src="${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["path"]}"
   output "- source ok:  ${src}"
   output "- target:     ${RUNTIME_ITEM["zfs.subvol.target.dir"]}"
   output "- RSYNC_ARGS: ${RUNTIME["RSYNC_ARGS"]}"
      
   # TODO: check if there is an options to detect which sub-stage failed last time
   output "- syncing...up to 1GB files..."

# TODO: think about symlinks in src tree.
#--links, -l              copy symlinks as symlinks
#--copy-links, -L         transform symlink into referent file/dir
#--copy-unsafe-links      only "unsafe" symlinks are transformed
#--safe-links             ignore symlinks that point outside the tree
#--munge-links            munge symlinks to make them safe & unusable
#--copy-dirlinks, -k      transform symlink to dir into referent dir
#--keep-dirlinks, -K      treat symlinked dir on receiver as dir
#--omit-link-times, -J    omit symlinks from --times


   timeout -s INT 10m rsync -e "ssh -i .ssh/backup" \
      ${RUNTIME["RSYNC_ARGS"]} --max-size=$(( 1 * 1024 * 1024 * 1024)) -i \
      -av --bwlimit=40000 --delete --exclude="lost+found" \
      --info=progress2 --stats --inplace --partial \
      "${src}/." \
      "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/." 2>&1 \
      | tee "${RUNTIME_ITEM["logfile"]}" | stdbuf -i0 -o0 -eL tr "\r" "\n" \
      | stdbuf -i0 -oL -eL grep -- "-chk=" |  stdbuf -i0 -o0 -eL tr "\n" "\r"

   # shellcheck disable=SC2046
   eval local -A pstat=$(declare -p PIPESTATUS | cut -d= -f2-)
   echo ""
#   declare -p pstat

   if [ "${pstat[0]}" -ne 0 ]
   then
      touch "$0.log"
      touch "${RUNTIME_ITEM["logname.base"]}.error"
      echo "RSYNC-ERROR: ${src} - ${RUNTIME_ITEM["logfile"]}" >> $0.log
      echo ""
      output "! RSYNC Error - schedule again - fix the issue. backup runs at any cycle again."
      stat=1
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} <=1GB had issues"
   else
      echo ""
   fi

   # find files > 1GB to build infiles
   output "- file listing >=1G files..."
   large_file_tmp="$(mktemp)"
   # remote large files
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" find "${RUNTIME_ITEM["path"]}/." -size +$(( 1 * 1024 * 1024 * 1024 - 1 ))c -printf \"%P\\n\" \
   >> "${large_file_tmp}"
   item_max=$(wc -l < "${large_file_tmp}")
   local -a FLIST
   mapfile -t FLIST < "${large_file_tmp}"
   # local large files
   find "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/." -size +$(( 1 * 1024 * 1024 * 1024 - 1 ))c -printf "%P\n" \
   > "${large_file_tmp}"
   local_item_max=$(wc -l < "${large_file_tmp}")
   local -a LLIST
   mapfile -t LLIST < "${large_file_tmp}"
   # report
   output "- found large files local[#${local_item_max}] remote[#${item_max}]"
   local -A LLLIST
   for item in "${LLIST[@]}"
   do
      echo "- item: ${item}"
      LLLIST["${item}"]=1
   done
   rm -f "${large_file_tmp}"

   output "- rsyncing...>1GB files..."
   # build local hashes...
   local -i count=0
   local -i s_time=0
   s_time=$(date +%s)
   local -i e_time=0
   local -i item_count=0
   local -i item_max=0
   local -i hstat=0
   local -i time_left=600


   local -a HASHED_FILES

   for LINE in "${FLIST[@]}"
   do
      # remove from local list
      unset "LLLIST[${LINE}]"
      output "  - local hashing scanned[${count}] item[${item_count}/${item_max}] time left[${time_left} sec]"
      if [ ! -e "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${LINE}" ]
      then
         # create it if it is a new file
         touch "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${LINE}"
      fi

      # as the number is quite high we shorten the runtime to 1m and max of 10 files
      # TODO: output to log
      hash.local_file "1m" "$(( 8 * 1024 * 1024 ))" "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${LINE}" >> "${RUNTIME_ITEM["logfile"]}" 2>&1
      hstat=$?
      stat=$(( stat + ${hstat} ))
      if [ ${hstat} -ne 0 ]
      then
         count=$(( count + 1 ))
         if [ ${count} -eq 10 ]
         then
            stat=$(( stat + 1 ))
            output "  ! reached limit of 10 to hash... more next time..."
            SUMMARY[${#SUMMARY[@]}]="B.BACKUP-WARNING:${src} >= 1GB more files to hash locally"
            break
         fi
      else
         HASHED_FILES[${#HASHED_FILES[@]}]="${LINE}"
      fi

      item_count=$(( item_count + 1 ))
      e_time=$(date +%s)
      if [ $(( e_time - s_time )) -gt $(( 10 * 60 )) ] && [ ${count} -ne 0 ]
      then
         # check if we exceeded 10 mins and we scanned at least one file.
         output "- end of 10 min slot"
         SUMMARY[${#SUMMARY[@]}]="B.BACKUP-WARNING:${src} >= 1GB more files to hash locally - exceeded 10 min slot"
         break
      else
         time_left=$(( 600 - ( e_time - s_time ) ))
      fi
   done

   # delete # not needed as rsync --delete also removes large files out of scope for coping
#   for item in "${!LLLIST[@]}"
#   do
#      output "- deleting vanished files: ${item}"
#      rm -fv "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${item}"
#   done

#   # stop >1GB
   if [ ${#HASHED_FILES[@]} -ne 0 ]
   then
      output "   - delta syncing..."
      local -i item_stat=0
      for item in "${HASHED_FILES[@]}"
      do
         output "     ${item}"
         hash.transfer_remote_file \
            "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${item}" \
            "$(( 8 * 1024 * 1024 ))" \
            "${RUNTIME_ITEM["path"]}/${item}" \
            "${RUNTIME["BACKUP_HOSTNAME"]}" \
            >> "${RUNTIME_ITEM["logfile"]}" 2>&1
         item_stat=$?
         stat=$(( stat + item_stat ))
         if [ ${item_stat} -ne 0 ]
         then
            output "- there was an issue with ${item}..."
            SUMMARY[${#SUMMARY[@]}]="B.BACKUP-WARNING:${src} large file syncing had an issue with ${item}"
         fi
      done

   fi

   return ${stat}
}
