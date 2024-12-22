
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
   output "- rsyncing..."
   rsync -e "ssh -i .ssh/backup" \
      ${RUNTIME["RSYNC_ARGS"]} \
      -av --bwlimit=40000 --delete --exclude="lost+found" \
      --info=progress2 --stats --inplace --partial \
      "${src}/." \
      "${RUNTIME_ITEM["zfs.subvol.target.dir"]}/." \
      | tee "${RUNTIME_ITEM["logfile"]}" | stdbuf -i0 -o0 -eL tr "\r" "\n" \
      | stdbuf -i0 -oL -eL grep ", to-chk=" |  stdbuf -i0 -o0 -eL tr "\n" "\r"

   if [ "${PIPESTATUS[0]}" -ne 0 ]
   then
      touch $0.log
      touch "${RUNTIME_ITEM["logname.base"]}.error"
      echo "RSYNC-ERROR: ${src} - ${RUNTIME_ITEM["logfile"]}" >> $0.log
      echo ""
      output "! RSYNC Error - schedule again - fix the issue. backup runs at any cycle again."
      stat=1
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} had issues"
   else
      echo ""
   fi

   return ${stat}
}
