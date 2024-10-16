
#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

function type.zfs.init() {
   output "init - type - zfs"
}

# dummy functions for alternative types
# zfs_resume     - resume token found
# zfs_enc_full   - encrypted zfs fs full
# zfs_enc_inc    - encrypted zfs fs incremental
# zfs_unenc_full - unencrypted zfs fs
# zfs_unenc_inc  - unencrypted zfs fs incremental

for item in zfs_resume zfs_enc_full zfs_enc_inc zfs_unenc_full zfs_unenc_inc
do
   for funcname in init outline.prefix logbase.name logfile.postfix subvol.name summary check.preflight
   do
      eval "\
      function type.${item}.${funcname}() { \
          type.zfs.${funcname} \"\${1+\"\$@\"}\" ; \
      }"
   done
done

function type.zfs.outline.prefix() {
   echo "#${RUNTIME["BACKUP_CLIENTNAME"]}/${RUNTIME_ITEM["type"]}[${RUNTIME_ITEM["zfs"]}]# "
}

function type.zfs.logbase.name() {
   echo "${RUNTIME_ITEM["zfs"]//\//_}"
}

function type.zfs.logfile.postfix() {
   echo ".$(date +%Y-%m-%d_%H:%M).log"
}

function type.zfs.subvol.name() {
   local tmpstr=""
   tmpstr="${RUNTIME_ITEM["zfs"]}"
   tmpstr="${tmpstr//\//_}"
   echo "zfs.${tmpstr}"
}

function type.zfs.summary() {
   SUMMARY[${#SUMMARY[@]}]="S.ZFS: was used."
}

function type.zfs.check.preflight() {
   local -i error_count=0
   local -i stat=0
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" which zfs >> /dev/null 2>&1
   stat=$?
   error_count=$(( error_count + stat ))
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs list -H "${RUNTIME_ITEM["zfs"]}" >> /dev/null 2>&1
   stat=$?
   if [ ${stat} -eq 0 ]
   then
      #output "- source available"
      :
   else
      output "! source unavailable"
      output "$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs list -H "${RUNTIME_ITEM["zfs"]}")"
      output "exit: ${stat}"
   fi
   error_count=$(( error_count + stat ))
   if [ ${error_count} -gt 0 ]
   then
      local src=""
      src="${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["path"]}"
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} pre-flight check failed - please fix"
   fi
   # extended test
   if [ ${error_count} -eq 0 ]
   then
      # check encryption state
      if [ "$(ssh.cmd ${RUNTIME["BACKUP_HOSTNAME"]} zfs get -H -o value encryption "${RUNTIME_ITEM["zfs"]}")" = "off" ]
      then
         # unencrypted
         output "- source is unencrypted and available."
         RUNTIME_ITEM["zfs.encrypted"]=0
      else
         # encrypted
         output "- source is encrypted and available."
         RUNTIME_ITEM["zfs.encrypted"]=1
      fi
      # check if resume-token is available
      local tmpstr=""
      tmpstr="${RUNTIME_ITEM["zfs"]##*/}"
      tmpstr="${tmpstr//\//_}"
      local token="-"
      RUNTIME_ITEM["zfs.resume"]=0
      RUNTIME_ITEM["zfs.target.path"]="${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${tmpstr}"
      RUNTIME_ITEM["zfs.target.path.subvol"]="${RUNTIME_ITEM["zfs.subvol"]}/${tmpstr}"
      if zfs.exists "${RUNTIME_ITEM["zfs.target.path.subvol"]}"
      then
         token="$(zfs get -H -o value receive_resume_token "${RUNTIME_ITEM["zfs.target.path.subvol"]}")"
         if [ "${token}" != "-" ]
         then
            RUNTIME_ITEM["zfs.resume"]=1
            RUNTIME_ITEM["zfs.resume.token"]="${token}"
            output "- resume token found."
            SUMMARY[${#SUMMARY[@]}]="I.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} used resume token."
         else
            output "- no resume token."
         fi
      else
         output "- no resume token, as the subvol does not exist."
         output "${RUNTIME_ITEM["zfs.target.path"]}"
      fi
      # check last snapshot if not resume
      if [ ${RUNTIME_ITEM["zfs.resume"]} -eq 0 ]
      then
         RUNTIME_ITEM["zfs.remote.lastsnapshot"]="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs list -H -p -o name,creation -t snapshot -r "${RUNTIME_ITEM["zfs"]}" | sort -r -k2 | grep "@zfsbackup-" | awk '{ print $1 }' | head -1)"
         output "- src last snapshot: ${RUNTIME_ITEM["zfs.remote.lastsnapshot"]}"
         if [ -z "${RUNTIME_ITEM["zfs.remote.lastsnapshot"]}" ]
         then
            # full
            if [ ${RUNTIME_ITEM["zfs.encrypted"]} -eq 0 ]
            then
               output "=> change to zfs_unenc_full type..."
               RUNTIME_ITEM["type"]="zfs_unenc_full"
            else
               output "=> change to zfs_enc_full type..."
               RUNTIME_ITEM["type"]="zfs_enc_full"
            fi
         else
            # inc
            if [ ${RUNTIME_ITEM["zfs.encrypted"]} -eq 0 ]
            then
               output "=> change to zfs_unenc_inc type..."
               RUNTIME_ITEM["type"]="zfs_unenc_inc"
            else
               output "=> change to zfs_enc_inc type..."
               RUNTIME_ITEM["type"]="zfs_enc_inc"
            fi
         fi
      else
         RUNTIME_ITEM["zfs.remote.lastsnapshot"]=""
         output "=> change to zfs_resume type..."
         RUNTIME_ITEM["type"]="zfs_resume"
      fi

   fi
   return ${error_count}
}

function type.zfs_enc_inc.perform.backup() {

   local -i stat=0

   # concept
   # src has an old snapshot
   # check if this is also available at the local storage
   # if yes create a new snapshot at the source and inc to local storage
   # if no  panic.

   RUNTIME_ITEM["zfs.newsnapshot.name"]="zfsbackup-$(date +%s)"

   output "- incremental sync from ${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@}"
   output "                     to ${RUNTIME_ITEM["zfs.newsnapshot.name"]}"

   output "${RUNTIME_ITEM["zfs.target.path.subvol"]}@${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@}"
   if zfs.exists "${RUNTIME_ITEM["zfs.target.path.subvol"]}@${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@}"
   then
      output "- remote snapshot exists locally..."

      if ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs snapshot "${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.newsnapshot.name"]}"
      then
         output "- start incremental send-receive..."
         # encryption
         ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs send -w -i ${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@} ${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.newsnapshot.name"]} \
         | zfs receive -s -v -eF "${RUNTIME_ITEM["zfs.subvol"]}" | tee "${RUNTIME_ITEM["logfile"]}"

         if [ $? -eq 0 ]
         then
            output "- remove old snapshot from remote system..."
            ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs destroy -v "${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@}" \
            | tee "${RUNTIME_ITEM["logfile"]}"
         else
            output "- something went wrong. fix it."
            exit 1
         fi
      else
         output "! ERROR: can not create remote new snapshot."
         SUMMARY[${#SUMMARY[@]}]="E.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} can not create new remote snapshot. Broken."
         stat=1
      fi

   else
      output "- we miss the remote snapshot in the local storage!"
      output "  Something is wrong. fix it.!!!"
      SUMMARY[${#SUMMARY[@]}]="E.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} unable to perform incremental backup. Broken."
      stat=1
   fi

   # stat=1
   return ${stat}

}

function type.zfs_unenc_inc.perform.backup() {

   local -i stat=0

   # concept
   # src has an old snapshot
   # check if this is also available at the local storage
   # if yes create a new snapshot at the source and inc to local storage
   # if no  panic.

   RUNTIME_ITEM["zfs.newsnapshot.name"]="zfsbackup-$(date +%s)"

   output "- incremental sync from ${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@}"
   output "                     to ${RUNTIME_ITEM["zfs.newsnapshot.name"]}"

   output "${RUNTIME_ITEM["zfs.target.path.subvol"]}@${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@}"
   if zfs.exists "${RUNTIME_ITEM["zfs.target.path.subvol"]}@${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@}"
   then
      output "- remote snapshot exists locally..."

      if ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs snapshot "${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.newsnapshot.name"]}"
      then
         output "- start incremental send-receive..."
         # unencryption
         ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs send -i ${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@} ${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.newsnapshot.name"]} \
         | zfs receive -s -x encryption -x keyformat -v -eF "${RUNTIME_ITEM["zfs.subvol"]}" | tee "${RUNTIME_ITEM["logfile"]}"

         if [ $? -eq 0 ]
         then
            output "- remove old snapshot from remote system..."
            ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs destroy -v "${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.remote.lastsnapshot"]##*@}" \
            | tee "${RUNTIME_ITEM["logfile"]}"
         else
            output "- something went wrong. fix it."
            exit 1
         fi
      else
         output "! ERROR: can not create remote new snapshot."
         SUMMARY[${#SUMMARY[@]}]="E.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} can not create new remote snapshot. Broken."
         stat=1
      fi

   else
      output "- we miss the remote snapshot in the local storage!"
      output "  Something is wrong. fix it.!!!"
      SUMMARY[${#SUMMARY[@]}]="E.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} unable to perform incremental backup. Broken."
      stat=1
   fi

   # stat=1
   return ${stat}

}

function type.zfs_unenc_full.perform.backup() {

   local -i stat=0

   # concept
   # src has no old snapshot -> full / first sync
   # if yes create a new snapshot at the source and inc to local storage
   # if no  panic.

   RUNTIME_ITEM["zfs.newsnapshot.name"]="zfsbackup-full"

   output "- full sync of ${RUNTIME_ITEM["zfs.newsnapshot.name"]}"

   if ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs snapshot "${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.newsnapshot.name"]}"
   then
      output "- start full send-receive..."
      local -i z_stat=0
      # unencryption
      ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs send "${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.newsnapshot.name"]}" \
      | timeout --foreground 1m zfs receive -s -x encryption -x keyformat -v -eF "${RUNTIME_ITEM["zfs.subvol"]}" | tee "${RUNTIME_ITEM["logfile"]}"
      z_stat=${PIPESTATUS[1]}
      # status of the receive side
      if [ ${z_stat} -eq 0 ]
      then
         # ok or timeout
         output "- full sync completed..."
      elif [ ${z_stat} -eq 124 ]
      then
         output "- full sync hit timeout... resume next time..."
         SUMMARY[${#SUMMARY[@]}]="W.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} hit time out continue next time."
         stat=1
      else
         output "- something went wrong...removing remote snapshot..."
         ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" zfs destroy -v "${RUNTIME_ITEM["zfs"]}@${RUNTIME_ITEM["zfs.newsnapshot.name"]}" \
         | tee "${RUNTIME_ITEM["logfile"]}"
         stat=1
         SUMMARY[${#SUMMARY[@]}]="E.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} something went wrong with full send."
      fi
   else
      output "! ERROR: can not create remote new snapshot."
      SUMMARY[${#SUMMARY[@]}]="E.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} can not create new remote snapshot. Broken."
      stat=1
   fi

   # stat=1
   return ${stat}

                     output "- no last backup snapshot -> full"
                     # mark it with a snapshot for next increament update
                     output "- create remote snapshot @zfsbackup-full..."
                     if [ -z "${last_snap}" ]
                     then
                        if ssh.cmd "${b_host}" zfs snapshot "${value}@zfsbackup-full"
                        then
                           output "- start send-receive..."
                           if [ ${encryption} -eq 1 ]
                           then
                              # encrypted
                              ssh.cmd "${b_host}" zfs send -w "${value}@zfsbackup-full" \
                              | zfs receive -s -v -eF "${BROOT_TARGET}"
                           else
                              # not encrypted
                              ssh.cmd "${b_host}" zfs send "${value}@zfsbackup-full" \
                              | zfs receive -s -x encryption -x keyformat -v -eF "${BROOT_TARGET}"
                           fi
                           if [ $? -eq 0 ]
                           then
                              continue
                           else
                              output "! failed cleanup just created snapshot"
                              ssh.cmd "${b_host}" zfs destroy -v "${value}@zfsbackup-full"
                              continue
                           fi
                        else
                           output "failed."
                        fi
                     fi               


}

function type.zfs_resume.perform.backup() {

   local -i stat=0

   output "- resuming token[$(echo "${RUNTIME_ITEM["zfs.resume.token"]}" | cut -c-10)...]"
   ssh "${RUNTIME["BACKUP_HOSTNAME"]}" zfs send -vt "${RUNTIME_ITEM["zfs.resume.token"]}" \
   | timeout --foreground 1m zfs receive -s -v -eF "${RUNTIME_ITEM["zfs.subvol"]}" | tee "${RUNTIME_ITEM["logfile"]}"

   z_stat=${PIPESTATUS[1]}
   # status of the receive side
   if [ ${z_stat} -eq 0 ]
   then
      # ok or timeout
      output "- sync completed..."
      SUMMARY[${#SUMMARY[@]}]="I.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} resumed and completed."
   elif [ ${z_stat} -eq 124 ]
   then
      output "- full sync hit timeout... resume next time..."
      SUMMARY[${#SUMMARY[@]}]="W.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} hit time out continue next time."
      stat=1
   else
      output "- something went wrong...removing remote snapshot..."
      stat=1
      SUMMARY[${#SUMMARY[@]}]="E.ZFS: ${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["zfs"]} something went wrong with resume."
   fi

   return ${stat}

}

