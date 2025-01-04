
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
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" which rsync >> /dev/null 2>&1
   stat=$?
   if [ ${stat} -eq 0 ]
   then
      output "- rsync available"
   else
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} pre-flight check failed - please fix - rsync missing."
   fi
   error_count=$(( error_count + stat ))
   # check if source is available
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" stat -c %n ${RUNTIME_ITEM["path"]} >> /dev/null 2>&1
   stat=$?
   if [ ${stat} -eq 0 ]
   then
      output "- source available"
   else
      output "! source unavailable"
      output "$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" stat -c %n ${RUNTIME_ITEM["path"]})"
      output "exit: ${stat}"
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} pre-flight check failed - please fix - source unavailable."
   fi
   error_count=$(( error_count + stat ))

   # check for sshfs mounts
   local source_path=""
   source_path="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" cd ${RUNTIME_ITEM["path"]} \; pwd -P)"
   local item=""
   for item in $(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" mount -t fuse.sshfs | awk '{ print $3 }' | grep "${source_path}")
   do
      # exclude 
      output "! excluding sshfs mount: ${item}"
      RUNTIME["RSYNC_ARGS"]="${RUNTIME["RSYNC_ARGS"]} --exclude=$(echo ${item} | sed "s:^${source_path}/::g")"
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
      
   # check if already backuped latley
   output "- rsyncing...up to 1GB files..."
   timeout -s INT 10m rsync -e "ssh -i .ssh/backup" \
      ${RUNTIME["RSYNC_ARGS"]} --max-size=$(( 1 * 1024 * 1024 * 1024)) -i \
      -av --bwlimit=40000 --delete --exclude="lost+found" \
      --info=progress2 --stats --inplace --partial \
      "${src}/." \
      "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/." 2>&1 \
      | tee "${RUNTIME_ITEM["logfile"]}" | stdbuf -i0 -o0 -eL tr "\r" "\n" \
      | stdbuf -i0 -oL -eL grep -- "-chk=" |  stdbuf -i0 -o0 -eL tr "\n" "\r"

   eval local -A pstat=$(declare -p PIPESTATUS | cut -d= -f2-)
   echo ""
   declare -p pstat

   if [ "${pstat[0]}" -ne 0 ]
   then
      touch $0.log
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
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" find "${src#*:}/." -size +$(( 1 * 1024 * 1024 * 1024 - 1 ))c -printf \"%P\\n\" \
   >> "${large_file_tmp}"
   output "- found $(wc -l < "${large_file_tmp}") large files"

   output "- rsyncing...>1GB files..."
   # build local hashes...
   local -i count=0
   local -i s_time=0
   s_time=$(date +%s)
   local -i e_time=0
   local -i item_count=0
   local -i item_max=0
   item_max=$(wc -l < "${large_file_tmp}")
   local -i hstat=0
   local -i time_left=600

   local -a FLIST
   mapfile -t FLIST < "${large_file_tmp}"

   local -a HASHED_FILES

   for LINE in "${FLIST[@]}"
   do
      output "  - local hashing scanned[${count}] item[${item_count}/${item_max}] time left[${time_left} sec]: ${LINE}"
      if [ -e "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${LINE}" ]
      then
         # as the number is quite high we shorten the runtime to 1m and max of 10 files
         # TODO: output to log
         hash.local_file "1m" "$(( 8 * 1024 * 1024 ))" "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${LINE}"
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

   # stop >1GB
   if [ ${#HASHED_FILES[@]} -ne 0 ]
   then
      output "- new large file sync..."
      declare -p HASHED_FILES

      local TDIR=""
      TDIR="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" mktemp -d)"
      if [ -z "${TDIR}" ]
      then
         # remote temp not ready (disk full?)
         output "  - remote tmp not ready! - please fix"
         SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} >= 1GB - remote tmp not ready - please fix."
         stat=1
      else
         TDF="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" df --output=avail "${TDIR}" | tail -1)"
         # get 20% of free space in chunk slices
         T_DELTA_CHUNKS=$(( ( TDF / ( 8 * 1024 * 1024 )) * 100 / 20 ))
         
         #FIELD_LIST  is a comma-separated list of columns to be included.  Valid field names are: 'source', 'fstype', 'itotal', 'iused', 'iavail', 'ipcent', 'size', 'used', 'avail',
         #  'pcent', 'file' and 'target' (see info page)

         output "- remote TDIR: ${TDIR} - free[${TDF}] - delta chunks[${T_DELTA_CHUNKS}]"
         # todo: create tmp -> get free space -> take 20% -> build deltas. -> copy them ->

         for item in "${HASHED_FILES[@]}"
         do
            local uuid="$(uuidgen)"

            output "- ${uuid}: ${item}"
            
            # copy hash data to remote
            output "  - local hash data: ${HASH_DATA["${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${item}"]}"
            if [ -e "${HASH_DATA["${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${item}"]}" ]
            then
               # incremental copy

               scp.cmd "${HASH_DATA["${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${item}"]}" "${RUNTIME["BACKUP_HOSTNAME"]}:${TDIR}/${uuid}.hash"
               
               # TODO: remote file hash location
               ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" filehasher.py \
                  "--min-chunk-size=$(( 8 * 1024 * 1024 ))" \
                  --inputfile \"${src#*:}/${item}\" \
                  --verify-against "${TDIR}/${uuid}.hash" --delta-file "${TDIR}/${uuid}.delta" --chunk-limit "${T_DELTA_CHUNKS}"
               
               if [ $? -eq 0 ]
               then
                  output "  - patching..."
                  # copy delta files from remote
                  # TODO: better local tmp location
                  scp.cmd "${RUNTIME["BACKUP_HOSTNAME"]}:${TDIR}/${uuid}.delta" "./${uuid}.delta"
                  scp.cmd "${RUNTIME["BACKUP_HOSTNAME"]}:${TDIR}/${uuid}.delta.hash" "./${uuid}.delta.hash"

                  # patch 
                  filehasher.py \
                     "--min-chunk-size=$(( 8 * 1024 * 1024 ))" \
                     --inputfile "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${item}" \
                     --apply-delta-file "./${uuid}.delta"

                  output "- patching exit: $?"

                  rm -fv "./${uuid}.delta" "./${uuid}.delta.hash"

                  stat=1
                  SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} >= 1GB new implementation not complete"
                  break
               else
                  output "  - no patching"
                  # cleanup hash file
                  ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" rm -fv "${TDIR}/${uuid}.hash"
               fi
            else
               # first time new file
               output "  - new item: ${item}..."
               timeout -s INT 1m rsync -e "ssh -i .ssh/backup" \
                  ${RUNTIME["RSYNC_ARGS"]} -i \
                  -av --bwlimit=40000 \
                  --info=progress2 --stats --inplace --partial \
                  "${src}/${item}" \
                  "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${item}" 2>&1 \
                  | tee "${RUNTIME_ITEM["logfile"]}" | stdbuf -i0 -o0 -eL tr "\r" "\n" \
                  | stdbuf -i0 -oL -eL grep -- "-chk=" |  stdbuf -i0 -o0 -eL tr "\n" "\r"
         
               # TODO: check if really incomplete
               stat=1

           fi

         done

         ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" rm -Rfv "${TDIR}"
      fi

      # TODO: error handling

   elif [ 1 -eq 1 ]
   then
      :
   else
      # 1m kill it as fast as possible
      timeout 1m rsync -e "ssh -i .ssh/backup" \
         --files-from=${large_file_tmp}  \
         ${RUNTIME["RSYNC_ARGS"]} --min-size=$(( 1 * 1024 * 1024 * 1024)) -i \
         -av --bwlimit=40000 --delete --exclude="lost+found" \
         --info=progress2 --debug=deltasum2 --stats --inplace --partial \
         "${src}/." \
         "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/."  2>&1 \
         | tee "${RUNTIME_ITEM["logfile"]}" | stdbuf -i0 -o0 -eL tr "\r" "\n" \
         | stdbuf -i0 -oL -eL grep -- "-chk=" |  stdbuf -i0 -o0 -eL tr "\n" "\r"

      eval local -A pstat=$(declare -p PIPESTATUS | cut -d= -f2-)
      rm -fv "${large_file_tmp}"
      echo ""
      declare -p pstat

      if [ "${pstat[0]}" -ne 0 ]
      then
         touch $0.log
         touch "${RUNTIME_ITEM["logname.base"]}.error"
         echo "RSYNC-ERROR: ${src} - ${RUNTIME_ITEM["logfile"]}" >> $0.log
         echo ""
         output "! RSYNC Error - schedule again - fix the issue. backup runs at any cycle again."
         stat=1
         declare -p PIPESTATUS
         SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} >= 1GB had issues"
      else
         echo ""
      fi
   fi


   return ${stat}
}
