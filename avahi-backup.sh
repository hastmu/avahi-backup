#!/bin/bash

# copyright 2024 by gh-hastmu@gmx.de
# homed at: https://github.com/hastmu/avahi-backup

# v1  ... added semaphore locking to block concurrent execution

export LC_ALL="C"

export PATH=${PATH}:/usr/local/bin:/usr/local/sbin:

declare -A RUNTIME
RUNTIME["_me"]="$(cd "$(dirname "$0")" || exit 0 ; pwd)/$(basename "$0")"
while [ -h "${RUNTIME["_me"]}" ]
do
   RUNTIME["_me"]="$(readlink -f "${RUNTIME["_me"]}")"
done
RUNTIME["INCLUDE_DIR"]="${RUNTIME["_me"]%.*}.d"
RUNTIME["output.prefix"]=""

function lock() {
   # $1 ... lockname
   if [ -z "${_LOCKED_}" ]
   then
      local lockname="$1"
      shift
      #echo -n "locking ..."
      export _LOCKED_=1
      exec flock -x -n ${RUNTIME["_me"]}.${lockname} ${RUNTIME["_me"]} ${1+"$@"}
      exit 1
   fi
}

function age.of.file.older.than() {
   # $1 ... file
   # $2 ... age threshold

   local -i mtime=0
   if [ -e "${1}" ]
   then
      mtime=$(stat -c %Y "${1}")
   fi

   if [ ${mtime} -eq 0 ] || [ $(( $(date +%s) - mtime )) -gt ${2} ]
   then
      return 0
   else
      return 1
   fi

}

# avahi-publish -s "backup-host" _backup._tcp 1111 path=/tmp path=/tmp2 path=/tmp3
declare -A CFG
CFG["name"]="avahi-backup"
CFG["zfs-metadata-prefix"]="${CFG["name"]}"
CFG["avahi.service_name"]="_backup._tcp"
CFG["avahi.service_name.server"]="_${CFG["name"]}-server._tcp"
# TODO
CFG["skip.backup.younger.than"]=86400
CFG["zfs.zero_size_snapshot_cleanup_limit"]=1000

# TODO: ssh compression off -o "Compression no" also in rsyncs
# TODO: turn off rsync compression

# declare -p RUNTIME
#declare -p CFG

# legacy # service_name="_backup._tcp"

export _LOGGER=${_LOGGER:=$(pgrep -P $PPID logger | wc -l)}

if [ ${_LOGGER} -eq 0 ]
then
   # no logger therefore date
   function output() {
      echo "[$(date +%Y-%m-%d_%H:%M:%S)]: ${RUNTIME["output.prefix"]}${1+"$@"}"
   }
else
   # logger therefore date
   function output() {
      echo "${RUNTIME["output.prefix"]}${1+"$@"}"
   }
fi

function check.blacklisted.process() {
   # do not run backups when those processes are around
   local -a blacklist
   blacklist[${#blacklist[@]}]="steamlink"
   blacklist[${#blacklist[@]}]="moonlight"
   blacklist[${#blacklist[@]}]="remote-viewer"

   for item in ${blacklist[@]}
   do
      if pgrep ${item} >> /dev/null 2>&1
      then 
         output "- blacklist process[${item}] found."
         return 0
      fi
   done
   return 1

}

function fn_exists() { declare -F "$1" > /dev/null; }

# source functions
source "${RUNTIME["INCLUDE_DIR"]}/func.zfs.sh"
source "${RUNTIME["INCLUDE_DIR"]}/func.hashing.sh"

function check.log() {
   # $1 ... logfile_basename
   local logfile_basename="$1"

   if [ -e "${logfile_basename}.error" ]
   then
      # there was a error - retry for sure
      output "! last backup flagged error, retry."
      rm -f "${logfile_basename}.error"
   else
      # check if already backuped latley
      local latest_log=""
      latest_log="$(ls -t ${logfile_basename}.*.log | head -1)"
      output "- lastest log: ${latest_log}"
      if [ -n "${latest_log}" ]
      then
         local -i latest_mtime=0
         latest_mtime="$(stat -c %Y "${latest_log}")"
         if [ $(( $(date +%s) - latest_mtime )) -lt 86400 ]
         then
            # only once a day
            output "- last backup finsihed around: $(stat -c %y "${latest_log}")"
            output "- last backup log younger than a day. skipping backup."
            return 1
         else
            output "- lastest log age: $(( $(date +%s) - latest_mtime ))"
         fi
      fi
   fi
   return 0

}

function ssh.cmd() {
   ssh -i .ssh/backup ${1+"$@"}
}

function scp.cmd() {
   scp -i .ssh/backup ${1+"$@"}
}


function ssh.check() {
   # $1 ... ssh target
   if ssh.cmd -o StrictHostKeyChecking=accept-new "${1}" true
   then
      output "- ssh check: OK"
      return 0
   else
      output "- ssh check: FAILED. Please fix."
      return 1
   fi

}

function create.rsync.restore.metadata() {
   # $1 ... zfs name of subvol to expose

   local -A zfs_metadata="$(zfs.get.properties "$1")"
   #declare -p metadata

   # check if values are exist
   local -A metadata=( "${CFG["zfs-metadata-prefix"]}:user" "-" "${CFG["zfs-metadata-prefix"]}:pass" "-" )
   local item=""
   local -i failed=0
   for item in ${!metadata[@]}
   do
      #echo "meta: ${item} - ${zfs_metadata[${item}]}"
      if [ -z "${zfs_metadata[${item}]}" ]
      then
         failed=1
      fi
   done

   if [ ${failed} -eq 1 ]
   then
      # gen new metadata
      output "- generate new restore metadata..."
      local username=""
      local password=""
      # TODO
   fi
}

function rsync.file() {
   # $1 ... source
   # $2 ... target
   # $3 ... logfile
   # $4+... rsync args
   local src="$1"
   local trg="$2"
   local log="$3"
   shift
   shift
   shift
   rsync -e "ssh -i .ssh/backup" "${1+"$@"}" \
      -avc --bwlimit=40000 --delete --exclude="lost+found" \
      --stats --progress --inplace --partial --block-size=$(( 128 * 1024 )) \
      "${src}" \
      "${trg}" \
      | tee "${log}" | stdbuf -i0 -o0 -eL tr "\r" "\n" \
      | stdbuf -i0 -oL -eL grep "%" |  stdbuf -i0 -o0 -eL tr "\n" "\r"
}

function rsync.file2() {
   # $1 ... source
   # $2 ... target
   # $3 ... logfile
   timeout --foreground 1m rsync -e "ssh -i .ssh/backup" \
      -avc --bwlimit=40000 --delete --exclude="lost+found" \
      --info=progress2 --stats --inplace --partial --block-size=$(( 128 * 1024 )) \
      "${1}" \
      "${2}" \
      | tee "${3}" | stdbuf -i0 -o0 -eL tr "\r" "\n" \
      | stdbuf -i0 -oL -eL grep "%" |  stdbuf -i0 -o0 -eL tr "\n" "\r"
}


function create.rsync.restore.conf() {
   :
}

function output.storagesize() {

   # $1 ... size
   local -a name
   name[${#name[@]}]="B"
   name[${#name[@]}]="KB"
   name[${#name[@]}]="MB"
   name[${#name[@]}]="GB"
   name[${#name[@]}]="TB"
   name[${#name[@]}]="PB"

   local -i idx=0
   local -i size=$1
   
   while [ ${size} -gt 1024 ]
   do
      #echo "pre size: ${size} - ${idx}" >&2
      size=$(( size / 1024 ))
      idx=$(( idx +1 ))
   done

   #echo "final size: ${size} - ${idx}" >&2
   printf "%4s %s" "${size}" "${name[${idx}]}"

}



case "$1"
in

init-backup-root) { 
   ##help## init-backup-root   ... marks the current directory as root of backups (currently it has to be a zfs based setup)
   output ""
   output "Setup ${CFG["name"]} Server..."
   output "(if not already cd into your backup root, a zfs filesystem)"
   output ""
   output "init backup root: $(pwd)"
   # TODO: check if ZFS
   RUNTIME["BACKUP_DATASET_ROOT"]="$(zfs.get_dataset.name "$(pwd)")"
   output "ZFS: ${RUNTIME["BACKUP_DATASET_ROOT"]}"
   declare -A data=$(zfs.get.properties "${RUNTIME["BACKUP_DATASET_ROOT"]}")
   output "     encryption[${data["encryption"]}] compression[${data["compression"]}]"
   output ""
   printf "%s" "$(output "Please enter 'yes' to continue, if not something else? ")"
   read LINE
   if [ "${LINE}" == "yes" ]
   then
      output ""
      # put mark
      if [ ! -e ".${CFG["name"]}.root" ]
      then
         output "- marking as root with '.${CFG["name"]}.root'"
         touch ".${CFG["name"]}.root"
      else
         output "- already found root mark ('.${CFG["name"]}.root')"
      fi
      # check .ssh key
      if [ ! -e ".ssh/${CFG["name"]}" ]
      then
         # create
         output "- generate ssh key..."
         mkdir -p .ssh
         ssh-keygen -N "" -f ".ssh/${CFG["name"]}" -C "${CFG["name"]}-$(uuidgen)" >> /dev/null 2>&1
      fi
      output "- Please ensure clients allow root access via this key..."
      output "---------------------------------------------------------"
      output "Sever-Key: $(ssh-keygen -l -f ".ssh/${CFG["name"]}")"
      output "---------------------------------------------------------"
      #
      set +e
      ( 
      (crontab -l || true) | grep -v "#${CFG["name"]}#" ;
      echo "*/5 * * * * ${RUNTIME["_me"]} backup-cron "$(pwd)" 2>&1 | logger -t ${CFG["name"]} #${CFG["name"]}#"
      ) | crontab
      set -e
      output "- installed/updated crontab"
      output "---------------------------------------------------------"
      output "$(crontab -l | grep "#${CFG["name"]}#")"
      output "---------------------------------------------------------"
      output "- Done."

   else
      output ""
      output "You entered -${LINE}-. Abort."
      output ""
   fi
   exit 0

   # TODO
   # - create rsyncd.conf with includes
   
} ;;

backup-cron) {

   # $2 ... pwd of actual backup, if exists go and execute

   # exec backup
   if [ -x "$2" ]
   then
      # check server announcement
      if screen -ls "${CFG["name"]}-server"
      then
         : # found
      else
         screen -dmS "${CFG["name"]}-server" ${RUNTIME["_me"]} backup-server-announcement "$2"
      fi
      cd "$2" || exit 1
      exec ${RUNTIME["_me"]} backup
   else
      output "Warning: ${CFG["name"]} backup root is not available. Backup skipped."
   fi

} ;;

backup-server-announcement) {
   
   # $2 ... backup root
   cd "$2"
   declare -a TXT
   TXT[${#TXT[@]}]="\"ssh-key=$(cat ".ssh/${CFG["name"]}.pub")\""
   TXT[${#TXT[@]}]="\"ssh-fingerprint=$(ssh-keygen -l -f ".ssh/${CFG["name"]}")\""
   STR="${TXT[*]}"
   s_time=$(date +%s)
   output "${STR}"
   echo sudo -u nobody timeout 1h avahi-publish -s "backup-$(hostname)" "${CFG["avahi.service_name.server"]}" 1111 ${STR}   
   sudo -u nobody timeout 1h avahi-publish -s "backup-$(hostname)" "${CFG["avahi.service_name.server"]}" 1111 ${STR}   
   age=$(( $(date +%s) - s_time ))
   if [ $age -gt 60 ]
   then
      exec $0 ${1+"$@"}
   else
      output "- restart faster than 60 seconds, something is wrong."
      exit 1
   fi


} ;;

init-backup-client) {
   ##help## init-backup-client ... startup code for client. TODO.
   :
} ;;

browse) { ##help## browse             ... show avahi announcements...
   output "AVAHI-Announcements:"
   avahi-browse -tpr "${CFG["avahi.service_name"]}" \
   | grep "^="
} ;;

backup-client) { 
	
   ##help## backup-client      ... sources config /etc/backup.d and scans all user homes for .backup,
   ##help##                        compiles avahi-publish, refresh after 1h.

   lock client "${1+"$@"}"

   output "${CFG["name"]} client start..."
   declare -a TXT
   # items
   if [ -x "/etc/${CFG["name"]}.d" ]
   then
      # shellcheck disable=SC2044
      for item in $(find /etc/${CFG["name"]}.d -type f -user root -name "*.conf" -printf "%f\n")
      do
         # shellcheck disable=SC1090
         if source "/etc/${CFG["name"]}.d/${item}"
         then
            echo "including ${item}"
         else
            echo "Error: ${item}"
         fi
      done
   fi

   default_next=86400
   default_retention=$(( 30 * default_next ))

   TXT[${#TXT[@]}]="type=path,path=/root,sec_to_next=${default_next},retention_in_sec=${default_retention}"
   TXT[${#TXT[@]}]="type=path,path=/etc,sec_to_next=${default_next},retention_in_sec=${default_retention}"

   # add all user homes which a .backup
   for u_home in $(getent passwd | cut -d: -f6)
   do
      localcfg="${u_home}/.backup"
      if [ -e "${localcfg}" ]
      then
         retention_in_sec="$(cat "${localcfg}" | grep -i "^retention_in_sec=")"
         retention_in_sec=${retention_in_sec:="retention_in_sec=${default_retention}"}
         sec_to_next="$(cat "${localcfg}" | grep -i "^sec_to_next=")"
         sec_to_next=${sec_to_next:="sec_to_next=${default_next}"}
         # TODO: include into config
         # each TXT can be 255 chars 
         # conver to json
         TXT[${#TXT[@]}]="type=path,path=${u_home},${sec_to_next},${retention_in_sec}"
      fi
   done

   # compile publish
   STR="${TXT[*]}"
   output "Concluding to ${STR}"

   if [ -z "$2" ]
   then
      s_time=$(date +%s)
      sudo -u nobody timeout 1h avahi-publish -s "backup-$(hostname)" "${CFG["avahi.service_name"]}" 1111 ${STR}
      age=$(( $(date +%s) - s_time ))
      if [ $age -gt 60 ]
      then
         exec $0 ${1+"$@"}
      else
         output "- restart faster than 60 seconds, something is wrong."
         exit 1
      fi
   else
      echo avahi-publish -s "backup-$(hostname)" "${CFG["avahi.service_name"]}" 1111 ${STR}
   fi

} ;;

backup) {

   if check.blacklisted.process
   then
      exit 1
   fi

   lock server "${1+"$@"}"

   # set io to idle
   ionice -c 3 -t -p $$
   schedtool -D $$
   taskset -cp 0 $$

   taskset -p $$
   schedtool $$
   ionice -p $$

   output "${CFG["name"]} start backup at $(pwd)"
   if [ ! -e ".${CFG["name"]}.root" ]
   then
      output "Error: this folder is not marked as backup root."
      output "Please touch '.${CFG["name"]}.root' to proceed."
      exit 1
   fi

   # set RUNTIME
   RUNTIME["BACKUP_ROOT"]="$(pwd)"
   RUNTIME["BACKUP_ROOT_DATASET"]="$(zfs.get_dataset.name "${RUNTIME["BACKUP_ROOT"]}")"
   output "ZFS dataset root: ${RUNTIME["BACKUP_ROOT_DATASET"]}"

   # revisit hashing queue
   hash.revisit.queue "${RUNTIME["BACKUP_ROOT"]}/.hasher-queue"

   # backup root
   BROOT="$(pwd)"

   # get avahi - clients
   T_DIR=$(mktemp -d)
   trap 'echo -n "cleanup..." ; rm -Rf ${T_DIR} ; echo "done." ' EXIT
   
   # search avahi-announcements...
   output "avahi-browsing..."
   timeout 10 avahi-browse -tpr "${CFG["avahi.service_name"]}" > "${T_DIR}/avahi-resolve.txt"
   
   declare -A AVAHI_IDX
   declare -A AVAHI
   touch "${T_DIR}/avahi.bash"
   cat "${T_DIR}/avahi-resolve.txt" | while read -r LINE
   do
      [[ ! $LINE =~ ^= ]] && continue
      # dns name
      A_HOST="$(echo "${LINE}" | cut -d\; -f7)"
      # from client
      A_D_HOST="$(echo "${LINE}" | cut -d\; -f4 | cut -d- -f2-)"
      A_D_DOMAIN="$(echo "${LINE}" | cut -d\; -f6)"
      A_ADDR="$(echo "${LINE}" | cut -d\; -f8)"
      A_TXT="$(echo "${LINE}" | cut -d\; -f10)"
      [ ! -z "${AVAHI_IDX[${A_HOST}]}" ] && continue
      #echo "L: ${LINE}"
      echo "LINE: ${A_HOST}@${A_ADDR} - ${A_TXT}"
      # shellcheck disable=SC2030
      AVAHI[${A_HOST}.name]="${A_D_HOST}.${A_D_DOMAIN}"
      AVAHI[${A_HOST}.addr]="${A_ADDR}"
      AVAHI[${A_HOST}.txt]="${A_TXT}"
      # shellcheck disable=SC2030
      AVAHI_IDX[${A_HOST}]=1
      declare -p AVAHI >> "${T_DIR}/avahi.bash"
      declare -p AVAHI_IDX >> "${T_DIR}/avahi.bash"
   done

   # general snapshot - cleanup by every subvol retention time
   snapshot_name="backup-$(date +%Y-%m-%d_%H:%M)"

   # exec found ones
   source "${T_DIR}/avahi.bash"
   # create default root of backups
   output "- prepare ${RUNTIME["BACKUP_ROOT"]}/backup.avahi..."
   RUNTIME["DATASET_AVAHI"]="${RUNTIME["BACKUP_ROOT_DATASET"]}/backup.avahi"
   zfs.create_subvol "${RUNTIME["DATASET_AVAHI"]}"
   zfs.mount "${RUNTIME["DATASET_AVAHI"]}"

   # create log dir if needed
   [ ! -x "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/logs" ] && mkdir "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/logs"
   # create hash dir if needed
   [ ! -x "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes" ] && mkdir "${RUNTIME["BACKUP_ROOT"]}/backup.avahi/hashes"

   declare -a SUMMARY
   SUMMARY[${#SUMMARY[@]}]="A.START:$(date)"
   declare -A summary_handler

   for b_host in ${!AVAHI_IDX[@]}
   do

      # stop backup loop when there is a blacklisted process
      if check.blacklisted.process
      then
         exit 1
      fi

      declare -A RUNTIME_NODE=()

      # [ "${b_host}" != "pve-wyse-001.local" ] && continue

      RUNTIME["output.prefix"]=""
      # update RUNTIME
      RUNTIME["BACKUP_HOSTNAME"]="${b_host}"
      RUNTIME["BACKUP_CLIENTNAME"]="${AVAHI[${b_host}.name]}"
      RUNTIME["LOG_BASE"]="backup.avahi/logs/${RUNTIME["BACKUP_CLIENTNAME"]}"
      # print header
      output "--------------------------------------------------------------"
      output "backup-host: DNS[${RUNTIME["BACKUP_HOSTNAME"]}] - CLIENT[${RUNTIME["BACKUP_CLIENTNAME"]}]"
      output "log-base: ${RUNTIME["LOG_BASE"]}"
      RUNTIME["output.prefix"]="#${RUNTIME["BACKUP_CLIENTNAME"]}# "

      # check if ssh works
      ssh.check "${b_host}" || continue
      # create node subvol
      zfs.create_subvol "${RUNTIME["DATASET_AVAHI"]}/${RUNTIME["BACKUP_CLIENTNAME"]}"
      zfs.mount "${RUNTIME["DATASET_AVAHI"]}/${RUNTIME["BACKUP_CLIENTNAME"]}"

      # get config from host 
      declare -a items=( ${AVAHI[${b_host}.txt]} )
      declare -i item_count=0
      while [ ${item_count} -lt ${#items[@]} ]
      do
         item="${items[${item_count}]}"
         item_count=$(( item_count + 1 ))
         output "debug: ${item} - ${#items[@]}"
         RUNTIME["output.prefix"]="#${RUNTIME["BACKUP_CLIENTNAME"]}# "
         
         # new multi attribute scheme
         declare -A RUNTIME_ITEM=()
         RUNTIME_ITEM["item"]="${item}"
         #declare -p RUNTIME

         for s_item in ${item//,/ }
         do
            a_key="$(echo "${s_item//\"/}" | cut -d= -f1)"
            a_value="$(echo "${s_item//\"/}" | cut -d= -f2)"
            RUNTIME_ITEM[${a_key}]="${a_value}"
         done

         if [ -z "${RUNTIME_ITEM["type"]}" ]
         then
            output "$(declare -p RUNTIME_ITEM)"
            output "! LEGACY Announcement ! - please fix"
            SUMMARY[${#SUMMARY[@]}]="W.LEGACY-ANNOUNCEMENT:${RUNTIME["BACKUP_CLIENTNAME"]} shows up with ${item}"
            continue
         fi

         # load type if needed
         if ! fn_exists "type.${RUNTIME_ITEM["type"]}.init"
         then
            if [ -r "${RUNTIME["INCLUDE_DIR"]}/type.${RUNTIME_ITEM["type"]}.sh" ]
            then
               if source "${RUNTIME["INCLUDE_DIR"]}/type.${RUNTIME_ITEM["type"]}.sh"
               then
                  output "- loaded type ${RUNTIME_ITEM["type"]}"
               else
                  output "! sourcing of type.${RUNTIME_ITEM["type"]}.sh suprised with error. Fatal."
                  exit 1
               fi
               # run this for every interration, so the init handler can even push new items to the stack
               "type.${RUNTIME_ITEM["type"]}.init"
            else
               output "type.${RUNTIME_ITEM["type"]}.init not found."
               continue
            fi
         fi

         # register summary handler
         if fn_exists "type.${RUNTIME_ITEM["type"]}.summary"
         then
            summary_handler["type.${RUNTIME_ITEM["type"]}.summary"]=1
         fi

         # Update outline prefix
         if fn_exists "type.${RUNTIME_ITEM["type"]}.outline.prefix"
         then
            RUNTIME["output.prefix"]="$("type.${RUNTIME_ITEM["type"]}.outline.prefix")"
         else
            RUNTIME["output.prefix"]="# not defined # "
         fi

         # update logbasename
         if fn_exists "type.${RUNTIME_ITEM["type"]}.logbase.name"
         then
            RUNTIME_ITEM["logname.base"]="${RUNTIME["LOG_BASE"]}-$("type.${RUNTIME_ITEM["type"]}.logbase.name")"
            if ! check.log "${RUNTIME_ITEM["logname.base"]}" 
            then
               continue
            fi
         else
            output "! type does not define logbase.name"
         fi

         # update subvolname
         if fn_exists "type.${RUNTIME_ITEM["type"]}.subvol.name"
         then
            RUNTIME_ITEM["zfs.subvol.name"]="$("type.${RUNTIME_ITEM["type"]}.subvol.name")"
            RUNTIME_ITEM["zfs.subvol"]="${RUNTIME["DATASET_AVAHI"]}/${RUNTIME["BACKUP_CLIENTNAME"]}/${RUNTIME_ITEM["zfs.subvol.name"]}"
            zfs.create_subvol "${RUNTIME_ITEM["zfs.subvol"]}"
            zfs.mount "${RUNTIME_ITEM["zfs.subvol"]}"
            RUNTIME_ITEM["zfs.subvol.target.dir"]="$(zfs.get.mountpoint "${RUNTIME_ITEM["zfs.subvol"]}")"
         else
            output "! type does not define subvol.name"
         fi

         # preflight check
         if fn_exists "type.${RUNTIME_ITEM["type"]}.check.preflight"
         then
            output "= PRE-FLIGHT ="
            if "type.${RUNTIME_ITEM["type"]}.check.preflight"
            then
               output "- pre-flight check ok"
            else
               output "! pre-flight check failed. - please fix, if needed."
               continue
            fi
         fi

         # update logfilename
         if fn_exists "type.${RUNTIME_ITEM["type"]}.logfile.postfix"
         then
            RUNTIME_ITEM["logfile"]="${RUNTIME_ITEM["logname.base"]}$("type.${RUNTIME_ITEM["type"]}.logfile.postfix")"
            output "- new logfile: ${RUNTIME_ITEM["logfile"]}"
         else
            output "! type does not define logfile.postfix"
         fi

         # update subvolname
         if fn_exists "type.${RUNTIME_ITEM["type"]}.subvol.name"
         then
            output "= PREPARE BACKUP TARGET ="
            zfs.report.usage "${RUNTIME_ITEM["zfs.subvol"]}"
            # check restore 
            create.rsync.restore.conf 
            # snapshot last state
            zfs.snapshot "${RUNTIME_ITEM["zfs.subvol"]}" "${snapshot_name}"
            # generate restore metadata
            output "- zfs_subvol_name: ${RUNTIME_ITEM["zfs.subvol"]}"
            create.rsync.restore.metadata "${RUNTIME_ITEM["zfs.subvol"]}"

            if fn_exists "type.${RUNTIME_ITEM["type"]}.perform.backup"
            then
               output "= PERFORM BACKUP ="
               if "type.${RUNTIME_ITEM["type"]}.perform.backup"
               then
                  output "- backup successful"
               else
                  output "! backup encountered problems - please fix"
                  touch "${RUNTIME_ITEM["logname.base"]}.error" 
               fi
               zfs.clean.snapshots "${RUNTIME_ITEM["zfs.subvol"]}"
               # end of type - next
               continue
            else 
               output "type[${RUNTIME_ITEM["type"]}] does not define .perform.backup"
               # mark as error as implementation is not complete.
               touch "${RUNTIME_ITEM["logname.base"]}.error" 
            fi

         fi

         output "!!! unsupported type: ${RUNTIME_ITEM["type"]}"

         echo ""
      done
   done

   # call hanlders if available
   for item in ${!summary_handler[@]}
   do
      ${item}
   done

   SUMMARY[${#SUMMARY[@]}]="Z.END:$(date)"

   RUNTIME["output.prefix"]="# SUMMARY # "
   output "===================================================="
   for item in "${SUMMARY[@]}"
   do
      output "${item}"
   done

} ;;

*) {
	echo "${CFG["name"]} help"
	echo ""
	echo "usage: $0 ..."
	echo ""
	cat "$0" | grep '##help##' | grep -v grep | cut -d\# -f5-
} ;;

esac 

exit 0

