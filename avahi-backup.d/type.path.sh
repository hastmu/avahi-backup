
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
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" which rsync >> /dev/null 2>&1
   stat=$?
   error_count=$(( error_count + stat ))
   ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" stat -c %n ${RUNTIME_ITEM["path"]} >> /dev/null 2>&1
   stat=$?
   if [ ${stat} -eq 0 ]
   then
      output "- source available"
   else
      output "! source unavailable"
      output "$(ssh.cmd "${RUNTIME["BACKUP_HOSTNAME"]}" stat -c %n ${RUNTIME_ITEM["path"]})"
      output "exit: ${stat}"
   fi
   error_count=$(( error_count + stat ))
   if [ ${error_count} -gt 0 ]
   then
      local src=""
      src="${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["path"]}"
      SUMMARY[${#SUMMARY[@]}]="B.BACKUP-ERROR:${src} pre-flight check failed - please fix"
   fi
   return ${error_count}
}

function type.path.perform.backup() {

   local src=""
   local -i stat=0

   src="${RUNTIME["BACKUP_HOSTNAME"]}:${RUNTIME_ITEM["path"]}"
   output "- source ok: ${src}"
   output "- target:    ${RUNTIME_ITEM["zfs.subvol.target.dir"]}"
      
   # check if already backuped latley
   output "- rsyncing..."
   rsync -e "ssh -i .ssh/backup" \
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
