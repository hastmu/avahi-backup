
#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

declare -A _PVELXC
_PVELXC["cfg.min-chunk-size"]=$(( 8 * 1024 * 1024 )) # 8MB
_PVELXC["summary.hash.up-to-date"]=0
_PVELXC["summary.hash.updating"]=0

function type.pvelxc.init() {

   output "init - type - pvelxc"
   # "type=pvelxc,pvelxc=101:105:110:113:119:120,stop_hours=5,every_sec=86400"
   # may show up, therefore one has to push the items to the stack
   if [[ ${RUNTIME_ITEM["pvelxc"]} =~ : ]]
   then
      output "- splitting item: ${RUNTIME_ITEM["pvelxc"]}"
      local item=""
      local new_item=""
      local -i first=1
      local keep_item=""
      local keep_pvelxc=""
      for item in ${RUNTIME_ITEM["pvelxc"]//:/ }
      do
         new_item=${RUNTIME_ITEM["item"]//${RUNTIME_ITEM["pvelxc"]}/${item}}
         #declare -p RUNTIME_ITEM
         if [ ${first} -eq 1 ]
         then
            first=0
            output "- keep first: ${item} as current"
            keep_pvelxc="${item}"
            keep_item="${new_item}"
         else
            output "- queue:    ${item}"
            output "  new item: ${new_item}"
            items[${#items[@]}]="${new_item}"
         fi
      done
      RUNTIME_ITEM["pvelxc"]="${keep_pvelxc}"
      RUNTIME_ITEM["item"]="${keep_item}"
      output "- proceed with ${RUNTIME_ITEM["pvelxc"]}"
#      declare -p RUNTIME_ITEM
   fi
}

# Generally you can consume any item in RUNTIME and RUNTIME_ITEM

function type.pvelxc.outline.prefix() {
   # configure the prefix during runtime
   echo "#${RUNTIME["BACKUP_CLIENTNAME"]}/${RUNTIME_ITEM["type"]}[${RUNTIME_ITEM["pvelxc"]}]# "
}

function type.pvelxc.logbase.name() {
   # set how your logs are structured
   echo "LXC-${RUNTIME_ITEM["pvelxc"]//\//_}"
}

function type.pvelxc.logfile.postfix() {
   # set how your new logs are structured
   echo ".$(date +%Y-%m-%d_%H:%M).log"
}

function type.pvelxc.subvol.name() {
   # set how your subvol below the node subvol shall be called.
   local tmpstr=""
   tmpstr="LXC-${RUNTIME_ITEM["pvelxc"]#*/}"
   tmpstr="${tmpstr//\//_}"
   echo "${tmpstr}"
}

function type.pvelxc.summary() {
   # what you like to add to the summary after all runs.
   declare -p _PVELXC >&2 
   SUMMARY[${#SUMMARY[@]}]="S.PVELXC: skipped[${_PVELXC["skip_counter"]}] (stop_hour)"
   SUMMARY[${#SUMMARY[@]}]="S.PVELXC: hash up-to-date[${_PVELXC["summary.hash.up-to-date"]}] updating[${_PVELXC["summary.hash.updating"]}]"

}

function type.pvelxc.check.preflight() {
   # pre-flight check return != 0 will not execute perform.backup
   local -i error_count=0
   local -i stat=0
   local -A STATUS={}
   # first check - stopping hour?
   #declare -p RUNTIME
   #declare -p RUNTIME_ITEM
   #declare -p RUNTIME_NODE
   local hour="$(date +%H)"
   local t_hour=${RUNTIME_ITEM["stop_hours"]:=5}
   local h_item=""
   STATUS["stop_hour_match"]=0
   for h_item in ${t_hour//,/ }
   do
      if [ ${h_item} -eq ${hour} ]
      then
         STATUS["stop_hour_match"]=1
         break
      fi
   done

   # second check - pvelxc exists
   if ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct status "${RUNTIME_ITEM["pvelxc"]}" >> /dev/null 2>&1
   then
      STATUS["lxc_status"]=1
      RUNTIME_ITEM["lxc_status"]="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct status "${RUNTIME_ITEM["pvelxc"]}" | awk '{ print $2 }')"
#      output "- LXC[${RUNTIME_ITEM["pvelxc"]}] exists status[${RUNTIME_ITEM["lxc_status"]}]"
      stat=0
   else
      STATUS["lxc_status"]=0
      SUMMARY[${#SUMMARY[@]}]="S.PVELXC: WARNING ${RUNTIME["BACKUP_HOSTNAME"]} LXC[${RUNTIME_ITEM["pvelxc"]}] does not exist or node vanished."
      stat=1
   fi
   error_count=$(( error_count + stat ))

   if [ ${STATUS["stop_hour_match"]} -eq 1 ] || [ "${RUNTIME_ITEM["lxc_status"]}" == "stopped" ]
   then
      output "- LXC[${RUNTIME_ITEM["pvelxc"]}] exists status[${RUNTIME_ITEM["lxc_status"]}] STOP_HOURS[${t_hour}=?${hour}] -> backup"
      # stop hours match
      stat=0

      # check filehasher version
      local local_version
      if [ -z "${RUNTIME_NODE["filehasher.remote_version.stat"]}" ]
      then
         if remote.hasher.version "${RUNTIME["BACKUP_HOSTNAME"]}"
         then
            # match
            RUNTIME_NODE["filehasher.remote_version.stat"]=0
         else
            # mismatch
            SUMMARY[${#SUMMARY[@]}]="S.PVELXC: ${RUNTIME["BACKUP_HOSTNAME"]} filehasher version mismatch local[${local_version}] remote[${RUNTIME_NODE["filehasher.remote_version"]}]"
            output "! filehasher check local[${local_version}] remote[${RUNTIME_NODE["filehasher.remote_version"]}]"
            RUNTIME_NODE["filehasher.remote_version.stat"]=1
         fi
      fi
      error_count=$(( error_count + ${RUNTIME_NODE["filehasher.remote_version.stat"]} ))

   else
      output "- LXC[${RUNTIME_ITEM["pvelxc"]}] exists status[${RUNTIME_ITEM["lxc_status"]}] STOP_HOURS[${t_hour}=?${hour}] -> local hashing..."
      # out of stop hours
      _PVELXC["skip_counter"]=$(( ${_PVELXC["skip_counter"]:0} + 1 ))
      stat=1
      # refresh hashes
      # TODO: make this check the exit status of hasher if update of hashes took place or not
      #       in order to know if the full file was hashed.
      # TODO: adapt timeout ? maybe a good way, on the other hand low frequency backups would have no need.
      local item=""
      local -a TO_CACHE
      #mapfile TO_CACHE <(find "${RUNTIME_ITEM["zfs.subvol.target.dir"]}" -name "*.raw")
      declare -p TO_CACHE

      for item in $(find "${RUNTIME_ITEM["zfs.subvol.target.dir"]}" -name "*.raw")
      do
         if hash.local_file "10s" "${_PVELXC["cfg.min-chunk-size"]}" "${item}"
         then
            _PVELXC["summary.hash.up-to-date"]=$(( ${_PVELXC["summary.hash.up-to-date"]} + 1 ))
         else
            SUMMARY[${#SUMMARY[@]}]="S.PVELXC: ${RUNTIME["BACKUP_HOSTNAME"]} ${RUNTIME_ITEM["pvelxc"]} local hash updating ${item}"
            _PVELXC["summary.hash.updating"]=$(( ${_PVELXC["summary.hash.updating"]} + 1 ))
         fi
      done
   fi
   error_count=$(( error_count + stat ))
   # result
   return ${error_count}

}

function type.pvelxc.perform.backup() {
   # perform your backup return 0 indicates all was fine, != 0 something was wrong.
   local -i stat=0
   # check if we need to shutdown
   local lxc_restart=0
   if [ "${RUNTIME_ITEM["lxc_status"]}" == "running" ]
   then
      lxc_restart=1
      output "- shutting down lxc..." | tee -a "${RUNTIME_ITEM["logfile"]}"
      ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct shutdown "${RUNTIME_ITEM["pvelxc"]}"
   fi
   # get config
   output "- target dir: ${RUNTIME_ITEM["zfs.subvol.target.dir"]}" | tee -a "${RUNTIME_ITEM["logfile"]}"
   output "  - get lxc config (pct config)" | tee -a "${RUNTIME_ITEM["logfile"]}"
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct config "${RUNTIME_ITEM["pvelxc"]}" > "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/lxc.config"
   # get storage config
   if [ -z "${RUNTIME_NODE["pve.storage"]}" ]
   then
      output "  - fetching storage config..." | tee -a "${RUNTIME_ITEM["logfile"]}"
      eval $(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pvesm status | grep " active " | awk '{ printf("RUNTIME_NODE[%s]=\"%s\"; \n","pve.storage." $1,$2) } END { printf("RUNTIME_NODE[%s]=\"%s\"; \n","pve.storage","done")}')
   fi

   # backup storage items
   local storage_item=""
   local storage_path=""
   output "  - backup storage items..." | tee -a "${RUNTIME_ITEM["logfile"]}"
   # TODO: pct df always changes the volume.
   for storage_item in $(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct df "${RUNTIME_ITEM["pvelxc"]}" | grep -E "(^rootfs|^mp)" | awk '{ print $2 }')
   do
      if [ -z "${RUNTIME_NODE["pve.storage.${storage_item%%:*}"]}" ]
      then
         output "    - storage item: ${storage_item} -> no storage config" | tee -a "${RUNTIME_ITEM["logfile"]}"
      else
         output "    - storage item: ${storage_item} -> ${storage_item%%:*} type[${RUNTIME_NODE["pve.storage.${storage_item%%:*}"]}]" | tee -a "${RUNTIME_ITEM["logfile"]}"
         storage_path="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pvesm path "${storage_item}")"
         ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" ls -lah "${storage_path}"
         output "      path: ${storage_path}" | tee -a "${RUNTIME_ITEM["logfile"]}"
         # copy
         trg="${storage_item//\//_}"
         if [ "${RUNTIME_NODE["pve.storage.${storage_item%%:*}"]}" == "dir" ]
         then
            output "      log: ${RUNTIME_ITEM["zfs.subvol.target.dir"]}/log.${trg}.txt"  | tee -a "${RUNTIME_ITEM["logfile"]}"
            s_time=$(date +%s)
            if [ 1 -eq 1 ]               
            then
               output "      backup_name: ${trg} ... filehasher..." | tee -a "${RUNTIME_ITEM["logfile"]}"
               # filehasher way
               # check local hashs
               # TODO: change back to 10s
               if [ ! -e "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}" ]
               then
                  # create new empty file
                  touch "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}"
               fi

               # new hash lib function
               hash.transfer_remote_file \
                  "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}" \
                  "$(( 8 * 1024 * 1024 ))" \
                  "${storage_path}" \
                  "${RUNTIME["BACKUP_HOSTNAME"]}"
                  # >> "${RUNTIME_ITEM["logfile"]}" 2>&1

               if [ 1 -eq 0 ]
               then

               # copy local hash to remote and trigger compare
               local local_hash_file=""
               local_hash_file="$(filehasher.py --inputfile "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}" --report-used-hashfile "--min-chunk-size=${_PVELXC["cfg.min-chunk-size"]}")"
               T_DIR=$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" mktemp -d)
               local remote_hash_file
               remote_hash_file="${RUNTIME["BACKUP_HOSTNAME"]}:${T_DIR}/${trg}.hash.${RUNTIME_ITEM["pvelxc"]}"
               # TODO: Think what is the right local hash location? default or inside the backup data?
               # output "      - local:  ${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}.hash.${_PVELXC["cfg.min-chunk-size"]}"
               output "      - local:  ${local_hash_file}"
               output "      - remote: ${remote_hash_file}"

               scp.cmd "${local_hash_file}" "${remote_hash_file}"
               output "      - create delta file..."

               ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" filehasher.py \
                  "--min-chunk-size=${_PVELXC["cfg.min-chunk-size"]}" \
                  --inputfile "${storage_path}" \
                  --verify-against "${T_DIR}/${trg}.hash.${RUNTIME_ITEM["pvelxc"]}" --delta-file "${storage_path}.delta" --chunk-limit 1024
               stat=$?
               # TODO: detect if there is no delta file.
               output "        - stat: ${stat}"

               if [ ${stat} -eq 0 ]
               then
                  # delta
                  output "      - delta update..."
                  # copy back delta files
                  rsync.file "${RUNTIME["BACKUP_HOSTNAME"]}:${storage_path}.delta" "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}.delta" "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/log.${trg}.txt" --remove-source-files  
                  rsync.file "${RUNTIME["BACKUP_HOSTNAME"]}:${storage_path}.delta.hash" "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}.delta.hash" "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/log.${trg}.txt" --remove-source-files

                  # patch local file
                  filehasher.py \
                     "--min-chunk-size=${_PVELXC["cfg.min-chunk-size"]}" \
                     --inputfile "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}" \
                     --apply-delta-file "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/${trg}.delta"
               else
                  output "      - no delta - no patching."
               fi
               ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" rm -Rf "${T_DIR}"
               fi
            fi
            e_time=$(date +%s)
            output "      took: $(( e_time - s_time )) sec. / $(( (e_time - s_time)/60 )) min."
         fi

      fi
   done
   # cleanup old items.
   output "TODO - cleanup old items"
   find "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/" ! -newer "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/lxc.config"
   output "TODO - cleanup old items"


   # restart if we shutdown the lxc
   if [ ${lxc_restart} -eq 1 ]
   then
      output "- starting lxc..."
      ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct start "${RUNTIME_ITEM["pvelxc"]}"
   fi
   # end
   # mark broken for dev.
   #stat=1
   return ${stat}
}

function dummy() {

         # pvelxc
         if [ "${RUNTIME_ITEM["type"]}" == "xxxxpvelxc" ]
         then
            output "here we go..."
            declare -p RUNTIME_ITEM
            for lxc_id in ${RUNTIME_ITEM["pvelxc"]//:/ }
            do

               output "TODO: based on lxc state trigger shutdown"
               lxc_restart=0
               if ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct status ${lxc_id} >> /dev/null 2>&1
               then
#                  lxc_status="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct status ${lxc_id} | awk '{ print $2 }')"
#                  output "- LXC[${lxc_id}] exists status[${lxc_status}]"
#                  # mark to restart if running
#                  if [ "${lxc_status}" == "running" ]
#                  then
#                     lxc_restart=1
#                     output "- shutting down lxc..."
#                     ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct shutdown ${lxc_id}
#                  fi
#                  output "TODO: get BOM"
#                  output "- get lxc config (pct config)"
#                  ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct config ${lxc_id} > "${BACKUP_TARGET_DIR}/lxc.config"
                  output "TODO: get BOM - get storage items"
#                  if [ -z "${RUNTIME_NODE["pve.storage"]}" ]
#                  then
#                     output "- fetching storage config..."
#                     eval $(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pvesm status | grep " active " | awk '{ printf("RUNTIME_NODE[%s]=\"%s\"; \n","pve.storage." $1,$2) } END { printf("RUNTIME_NODE[%s]=\"%s\"; \n","pve.storage","done")}')
#                  fi
                  declare -p RUNTIME_NODE
                  for storage_item in $(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct df ${lxc_id} | grep -E "(^rootfs|^mp)" | awk '{ print $2 }')
                  do
                     if [ -z "${RUNTIME_NODE["pve.storage.${storage_item%%:*}"]}" ]
                     then
                        output "- storage item: ${storage_item} -> no storage config"
                     else
                        output "- storage item: ${storage_item} -> ${storage_item%%:*} type[${RUNTIME_NODE["pve.storage.${storage_item%%:*}"]}]"
                        storage_path="$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pvesm path "${storage_item}")"
                        output "  path: ${storage_path}"
                        # copy
                        trg="${storage_item//\//_}"
                        if [ "${RUNTIME_NODE["pve.storage.${storage_item%%:*}"]}" == "dir" ]
                        then
                           output "  backup_name: ${trg} ... rsyncing..."
                           s_time=$(date +%s)
                           rsync.file "${RUNTIME["BACKUP_HOSTNAME"]}:${storage_path}" "${BACKUP_TARGET_DIR}/${trg}" "${logfile}"
                           output "  took: $(( $(date +%s) - s_time )) sec."
                        fi

                     fi
                  done
                  # cleanup old items.
                  output "TODO - cleanup old items"
                  find "${BACKUP_TARGET_DIR}/" ! -newer "${BACKUP_TARGET_DIR}/lxc.config"
                  ls -hla "${BACKUP_TARGET_DIR}/"
                  output "TODO: based on lxc state start it again"
#                  if [ ${lxc_restart} -eq 1 ]
#                  then
#                     output "- starting lxc..."
#                     ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" pct start ${lxc_id}
#                  fi
               else
                  output "ERROR: can not get status for LXC[${lxc_id}] - please fix it"
               fi
            done
            # cleanup
            zfs.clean.snapshots "${ZFS_NAME_OF_SUBVOL}"
            continue
         fi


}