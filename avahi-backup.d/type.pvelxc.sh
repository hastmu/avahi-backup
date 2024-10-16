
#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

function type.pvelxc.init() {
   output "init - type - pvelxc"
}

# Generally you can consume any item in RUNTIME and RUNTIME_ITEM

function type.template.init() {
   # do what is needed for a init of your type
   output "init - type - path"
   # uncomment for info #
   # declare -p RUNTIME
   # declare -p RUNTIME_ITEM
}

function type.template.outline.prefix() {
   # configure the prefix during runtime
   echo "#${RUNTIME["BACKUP_CLIENTNAME"]}/${RUNTIME_ITEM["type"]}[${RUNTIME_ITEM["path"]}]# "
}

function type.template.logbase.name() {
   # set how your logs are structured
   echo "${RUNTIME_ITEM["path"]//\//_}"
}

function type.template.logfile.postfix() {
   # set how your new logs are structured
   echo ".$(date +%Y-%m-%d_%H:%M).log"
}

function type.template.subvol.name() {
   # set how your subvol below the node subvol shall be called.
   local tmpstr=""
   tmpstr="${RUNTIME_ITEM["path"]#*/}"
   tmpstr="${tmpstr//\//_}"
   echo "${tmpstr}"
}

function type.template.summary() {
   # what you like to add to the summary after all runs.
   SUMMARY[${#SUMMARY[@]}]="S.TEMPLATE: was used."
}

function type.template.check.preflight() {
   # pre-flight check return != 0 will not execute perform.backup
   local -i error_count=0
   local -i stat=0
   # first check
   /bin/true
   stat=$?
   error_count=$(( error_count + stat ))
   # second check
   /bin/true
   stat=$?
   error_count=$(( error_count + stat ))
   # result
   return ${error_count}
}

function type.template.perform.backup() {
   # perform your backup return 0 indicates all was fine, != 0 something was wrong.
   local -i stat=0
   /bin/true
   stat=$?
   return ${stat}
}
