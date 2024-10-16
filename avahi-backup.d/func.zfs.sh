
#
# (c) 2024 by hastmu
# checkout https://github.com/hastmu/avahi-backup 
#

function zfs.snapshot() {

   # $1 ... zfs volume or pwd
   # $2 ... snapshot name or default


   if [ "$(find $0 -printf "%F\n")" = "zfs" ]
   then
      local subvol=""
      local snapshot=""
      if [ -z "$2" ]
      then
         snapshot="backup-$(date +%Y-%m-%d_%H:%M)"
      else
         snapshot="$2"
      fi
      if [ -z "$1" ]
      then
         subvol="$(zfs list -Ho name "$(pwd)")"
      else
         subvol="$1"
      fi
      output "- global zfs snapshot: ${snapshot} @ ${subvol}"
      zfs snapshot -r ${subvol}@${snapshot}
   fi

}

function zfs.create_subvol() {

   # check if we are on a zfs fs
   if [ "$(find $(pwd) -maxdepth 0 -type d -printf "%F\n")" = "zfs" ]
   then
      if zfs list "${1//\/\//\/}" >> /dev/null 2>&1
      then
         output "- using subvol: $1"
      else
         zfs create "${1//\/\//\/}"
	      output "- create subvol: $1"
      fi
   else
      output "Error: ask to create a subvol on a non zfs cwd!"
      exit 1
   fi

}

function zfs.mount() {

   # $1 ... mount and check if mounted
   if [ "$(zfs get -H -o value "mounted" "${1}")" != "yes" ]
   then
      if zfs mount "${1}"
      then
         output "- zfs mounting: ${1}"
      else
         output "! zfs mount failed."
         output "! fatal failure in order to avoid shadowed files in zfs."
         exit 1
      fi
   else
      output "- zfs already mounted: ${1}"
   fi

}


function zfs.get_dataset.name() {
   # $1 ... path
   zfs list -Ho name "${1}"
}

function zfs.get.mountpoint() {
   # $1 ... subvol
   zfs get -H -o value mountpoint "${1}"
}

function zfs.exists() {
   # $1 ... dataset
   if zfs list "${1}" >> /dev/nul 2>&1
   then
      return 0
   else
      return 1
   fi
}

function zfs.get.properties() {
   # $1 ... zfs object
   local -A data
   eval $(zfs get -H -o property,value all "$1" | awk -F"\t" '{ print("data[\""$1"\"]=\""$2"\"" ) }')
   declare -p data | cut -d= -f2-
}

declare -A retention
declare -A retention_field
declare -A retention_sep
retention["clean_to_h_older_than"]=$(( 60 * 60 * 24 * 7 ))       # older than 7 we need no mintues.
retention["clean_to_day_older_than"]=$(( 60 * 60 * 24 * 30 ))    # older than 30 we need no hours.
retention["clean_to_month_older_than"]=$(( 60 * 60 * 24 * 90 ))  # older than 90 we need no days.
retention["clean_to_years_older_than"]=$(( 60 * 60 * 24 * 366 )) # older than 365 we need no month.

retention_field["clean_to_h_older_than"]="1"
retention_field["clean_to_day_older_than"]="1"
retention_field["clean_to_month_older_than"]="-3"
retention_field["clean_to_years_older_than"]="-2"

retention_sep["clean_to_h_older_than"]=":"
retention_sep["clean_to_day_older_than"]="_"
retention_sep["clean_to_month_older_than"]="-"
retention_sep["clean_to_years_older_than"]="-"

function zfs.clean.snapshots() {
   # $1 ... zfs volume
   local LINE=""
   local -i size=0
   local -i cnt=0
   local item=""
   output "- snapshot cleanup..."
   local T_FILE="$(mktemp)"
   local LIST_FILE="$(mktemp)"
   zfs list -H -p -o name,used,creation  -t snapshot "$1" > "${LIST_FILE}"
   local snap_count=$(wc -l < "${LIST_FILE}")
   local -A RET_TMP_FILES
   local -A RET_AGE

   # retention idea:
   # general resolution is minutes at any timestamp
   # clean_to_h_older_than     = x sec. -> delete all min in hours if the snapshot is older than x sec.
   # clean_to_day_older_than   = x sec.
   # clean_to_month_older_than = x sec
   # clean_to_years_older_than = x sec.

   # prepare retention
   for item in "${!retention[@]}"
   do
      #echo "rentention: ${item}"
      if [ ${retention[${item}]} -ne 0 ]
      then
         # != 0 ... active retention
         RET_TMP_FILES[${item}]=$(mktemp)
         RET_AGE[${item}]=$(( $(date +%s) - ${retention[${item}]} ))
      fi
   done

   output "  - ${snap_count} snapshots found"
   cat "${LIST_FILE}" | while read LINE 
   do
      # echo "check snapshot: ${LINE}"
      # TODO impove
      local name="$(echo ${LINE} | awk '{ print $1}')"
      local -i size="$(echo ${LINE} | awk '{ print $2}')"
      local -i creation="$(echo ${LINE} | awk '{ print $3}')"
      #output "name: ${name} - ${size} - ${creation}"

      # destroy 0 size snapshots...
      if [ ${size} -eq 0 ] &&  [ ${cnt} -lt ${CFG["zfs.zero_size_snapshot_cleanup_limit"]} ]
      then
         cnt=$(( cnt + 1 ))
         output "- zero size snapshot: ${name}"
         echo "zfs destroy \"${name}\" &" >> ${T_FILE}
         clean[${#clean[@]}]="${name}"
         if [ ${#clean[@]} -gt 10 ]
         then
            echo "wait" >> "${T_FILE}"
            clean=()
         fi
         continue
      fi

      # process retention
      for item in "${!retention[@]}"
      do
#         echo "rentention: ${item}"
         if [ ${retention[${item}]} -ne 0 ]
         then
            # != 0 ... active retention
            if [ ${creation} -lt ${RET_AGE[${item}]} ]
            then
               #output "- retention sorting: ${item} for ${name}"
               echo "${name}" >> "${RET_TMP_FILES[${item}]}"
            fi
         fi

      done

   done

   echo "wait" >> "${T_FILE}"

   # process retention
   local key=""
   output "  - retention processing..."
   local -a snap_list=()
   for item in "${!retention[@]}"
   do
      if [ ${retention[${item}]} -ne 0 ]
      then
         local -i reduction=0
#         echo "rentention: ${item} - $(wc -l < "${RET_TMP_FILES[${item}]}") snapshots"
         for key in $(cat "${RET_TMP_FILES[${item}]}" | cut -d@ -f2- | cut -d${retention_sep[${item}]} -f${retention_field[${item}]} | sort -u)
         do
            #echo "key: ${key}"
            if [ $(grep "@${key}" "${RET_TMP_FILES[${item}]}" | wc -l) -gt 1 ]
            then
               #  more than one
               output "reducing to one [${item}]: ${key}"
               reduction=$(( $(grep "@${key}" "${RET_TMP_FILES[${item}]}" | tail -n +2 | wc -l) + reduction ))
               local tmpstr=""
               for tmpstr in $(grep "@${key}" "${RET_TMP_FILES[${item}]}" | tail -n +2)
               do
                  snap_list[${#snap_list[@]}]="${tmpstr}"
               done
            else
               # output "${key} is already only one"
               :
            fi
         done

         output "  - rentention: ${item} - $(wc -l < "${RET_TMP_FILES[${item}]}") snapshots - reduced by ${reduction}"
      fi
   done

   # put into list
   local -i red_count=0
   local -i max=${#snap_list[@]}
   for key in "${snap_list[@]}"
   do
      red_count=$(( red_count + 1 ))
      echo "echo \"$(output "  - $(printf "%3s" "$(( ${red_count} * 100 / ${max} ))") %: zfs destroy ${key}")\"" >> "${T_FILE}"
      echo zfs destroy ${key} >> "${T_FILE}"
   done

   output "- cleaning snapshots..."
   #cat "${T_FILE}" >&2
   source ${T_FILE}
   output "- waiting for zfs destroy"
   # declare -p RET_TMP_FILES
   rm -f "${T_FILE}" "${LIST_FILE}" "${RET_TMP_FILES[@]}"

   #exit 0

}

function zfs.clean.snapshots.v1() {
   # $1 ... zfs volume
   local LINE=""
   local -i size=0
   local -i cnt=0
   output "- cleanup zero size snapshots..."
   zfs list -H -o name  -t snapshot "$1" | while read LINE 
   do
#      echo "check snapshot: ${LINE}"
      size=$(zfs get -H -p -o value used "${LINE}")
      if [ ${size} -eq 0 ]
      then
         cnt=$(( cnt + 1 ))
         output "- zero size snapshot: ${LINE}"
         zfs destroy "${LINE}"
      fi

      if [ ${cnt} -gt ${CFG["zfs.zero_size_snapshot_cleanup_limit"]} ]
      then 
         output "- Cleanup limit [${CFG["zfs.zero_size_snapshot_cleanup_limit"]}] reached - more next time."
         break
      fi
   done
}

function zfs.report.usage() {
   # $1 ... zfs volume
   local -A ret=()
   local str=""
   str="$(zfs get -H -o property,value -p used,usedbysnapshots,usedbydataset,refcompressratio,logicalused "$1")"
   local item=""
   local key=""
   local -i seq=0
   for item in ${str}
   do
      if [ ${seq} -eq 0 ]
      then
         seq=1
         key="${item}"
      else
         seq=0
         ret[${key}]="${item}"
      fi
   done
   output "zfs vol: $1" 
   output "logicalused/used/dataset/snapshots [$(output.storagesize "${ret[logicalused]}")/$(output.storagesize "${ret[used]}")/$(output.storagesize "${ret[usedbydataset]}")/$(output.storagesize "${ret[usedbysnapshots]}")] compression-ration[${ret["refcompressratio"]}] %snapshots[ $(( (${ret["usedbysnapshots"]} * 100) / ${ret[used]} )) ]" 
#   output "used datset   [$(output.storagesize "${ret[usedbydataset]}")]" 
#   output "used snapshot [$(output.storagesize "${ret[usedbysnapshots]}")]" 

}
