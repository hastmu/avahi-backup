#!/bin/bash

T_DIR="$(mktemp -d)"
trap 'echo cleanup ; rm -Rf "${T_DIR}"; echo done' EXIT

function gen_file() {
   # $1 ... name
   # $2 ... size
   dd if=/dev/urandom "of=$1" "bs=$2" count=1
}

DEMO_SRC="${T_DIR}/demo.src.img"
DEMO_TRG="${T_DIR}/demo.trg.img"
TOOL="$(dirname "$0")/filehasher.py"

gen_file "${DEMO_SRC}" 1G

declare -i error=0

# $(( 8 * 1024 )) $(( 4 * 1024 * 1024 )) $(( 64 * 1024 * 1024 )) $(( 8 * 1024 * 1024 * 1024 ))

if [ 1 -eq  0 ]
then
   # chunking test
   for mode in 0 1 2
   do
      for CHUNK_SIZE in $(( 8 * 1024 )) $(( 4 * 1024 * 1024 )) $(( 64 * 1024 * 1024 )) $(( 8 * 1024 * 1024 * 1024 ))
      do
         # hashing
         echo -n "- hashing test: ${DEMO_SRC} ${mode} ${CHUNK_SIZE}"
         ${TOOL} --inputfile "${DEMO_SRC}" --hashfile "${DEMO_SRC}.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} --debug \
         > "${T_DIR}/log.1.demo-src.${CHUNK_SIZE}.${mode}.txt" 2>&1 
         # exit has to 1
         [ $? -eq 1 ] && stat=0 || stat=1
         [ ${stat} -ne 0 ] && nedit "${T_DIR}/log.1.demo-src.${CHUNK_SIZE}.${mode}.txt"
         error=$(( error + stat ))
         echo " - return ${stat}"

         # hashing - update
         echo -n "- hashing update test: ${DEMO_SRC} ${mode} ${CHUNK_SIZE}"
         ${TOOL} --inputfile "${DEMO_SRC}" --hashfile "${DEMO_SRC}.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} --debug \
         > "${T_DIR}/log.2.demo-src.${CHUNK_SIZE}.${mode}.txt" 2>&1 
         # exit has to 0
         [ $? -eq 0 ] && stat=0 || stat=1
         [ ${stat} -ne 0 ] && nedit "${T_DIR}/log.2.demo-src.${CHUNK_SIZE}.${mode}.txt"
         error=$(( error + stat ))
         echo " - return ${stat}"

         # verify
         echo -n "- verify test: ${DEMO_SRC} ${mode} ${CHUNK_SIZE}"
         ${TOOL} --inputfile "${DEMO_SRC}" --verify-against "${DEMO_SRC}.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} --debug \
         > "${T_DIR}/log.3.demo-src.${CHUNK_SIZE}.${mode}.txt" 2>&1 
         # exit has to 0
         [ $? -eq 1 ] && stat=0 || stat=1
         [ ${stat} -ne 0 ] && nedit "${T_DIR}/log.3.demo-src.${CHUNK_SIZE}.${mode}.txt"
         error=$(( error + stat ))
         echo " - return ${stat}"

         # local patching
         echo -n "- local patching test: ${DEMO_SRC} ${mode} ${CHUNK_SIZE}"
         cp "${DEMO_SRC}" "${DEMO_TRG}" 
         dd if=/dev/urandom of=${DEMO_TRG} bs=1M count=1 conv=notrunc >> /dev/null 2>&1
         # hashing
         ${TOOL} --inputfile "${DEMO_TRG}" --hashfile "${DEMO_TRG}.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} --debug \
         > "${T_DIR}/log.4.demo-src.${CHUNK_SIZE}.${mode}.txt" 2>&1 
         # exit has to 0
         [ $? -eq 1 ] && stat=0 || stat=1
         [ ${stat} -ne 0 ] && nedit "${T_DIR}/log.4.demo-src.${CHUNK_SIZE}.${mode}.txt"
         error=$(( error + stat ))
         echo " - return ${stat}"

         # hashing
         echo -n "  - gen delta file"
         timeout 60s ${TOOL} --inputfile "${DEMO_SRC}" --hashfile "${DEMO_SRC}.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} \
         --verify-against "${DEMO_TRG}.${CHUNK_SIZE}.${mode}" --delta-file "${DEMO_SRC}.${CHUNK_SIZE}.${mode}.delta" --debug \
         > "${T_DIR}/log.5.demo-src.${CHUNK_SIZE}.${mode}.txt" 2>&1 
         # exit has to 0
         [ $? -eq 1 ] && stat=0 || stat=1
         [ ${stat} -ne 0 ] && nedit "${T_DIR}/log.5.demo-src.${CHUNK_SIZE}.${mode}.txt"
         error=$(( error + stat ))
         echo " - return ${stat}"
         ls -lah "${DEMO_SRC}.${CHUNK_SIZE}.${mode}.delta"

         # hashing
         echo -n "  - patch target"
         ${TOOL} --inputfile "${DEMO_TRG}" --hashfile "${DEMO_TRG}.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} \
         --apply-delta "${DEMO_SRC}.${CHUNK_SIZE}.${mode}.delta" --debug \
         > "${T_DIR}/log.6.demo-src.${CHUNK_SIZE}.${mode}.txt" 2>&1 
         # exit has to 0
         [ $? -eq 0 ] && stat=0 || stat=1
         [ ${stat} -ne 0 ] && nedit "${T_DIR}/log.6.demo-src.${CHUNK_SIZE}.${mode}.txt"
         error=$(( error + stat ))
         echo " - return ${stat}"

         # same check
         echo -n "  - same? "
         same=$(sha512sum "${DEMO_SRC}" "${DEMO_TRG}" | awk ' { print $1 } ' | sort -u | wc -l)
         [ ${same} -eq 1 ] && stat=0 || stat=1
         error=$(( error + stat ))
         echo " - return ${stat}"


         #break
      done
      #break
   done

fi

# remote patching test

# 
CHUNK_SIZE=$(( 8 * 1024 * 1024 ))
mode=0
${TOOL} --inputfile "${DEMO_SRC}" --hashfile "${DEMO_SRC}.remote.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode}
cp "${DEMO_SRC}" "${DEMO_SRC}.2"
dd if=/dev/urandom of=${DEMO_SRC}.2 bs=1M count=1 conv=notrunc >> /dev/null 2>&1
${TOOL} --inputfile "${DEMO_SRC}.2" --hashfile "${DEMO_SRC}.2.remote.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode}

${TOOL} --inputfile "${DEMO_SRC}" --hashfile "${DEMO_SRC}.remote.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} \
         --verify-against "${DEMO_SRC}.2.remote.${CHUNK_SIZE}.${mode}" --delta-file "${DEMO_SRC}.${CHUNK_SIZE}.remote.${mode}.delta" 

${TOOL} --inputfile "${DEMO_SRC}" --hashfile "${DEMO_SRC}.remote.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} \
         --verify-against "${DEMO_SRC}.2.remote.${CHUNK_SIZE}.${mode}" --remote-delta > "${DEMO_SRC}.${CHUNK_SIZE}.remote-2.${mode}.delta" --debug

cp "${DEMO_SRC}.2" "${DEMO_SRC}.2.file" &
cp "${DEMO_SRC}.2" "${DEMO_SRC}.2.remote" &

ls -lah  "${DEMO_SRC}.${CHUNK_SIZE}.remote.${mode}.delta" "${DEMO_SRC}.${CHUNK_SIZE}.remote-2.${mode}.delta"
md5sum "${DEMO_SRC}.${CHUNK_SIZE}.remote.${mode}.delta" "${DEMO_SRC}.${CHUNK_SIZE}.remote-2.${mode}.delta"
wait

${TOOL} --inputfile "${DEMO_SRC}.2.file" --hashfile "${DEMO_SRC}.2.remote.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} \
--apply-delta "${DEMO_SRC}.${CHUNK_SIZE}.remote.${mode}.delta" --debug 

${TOOL} --inputfile "${DEMO_SRC}.2.remote" --hashfile "${DEMO_SRC}.2.remote2.${CHUNK_SIZE}.${mode}" --min-chunk-size ${CHUNK_SIZE} --thread-mode ${mode} \
--apply-delta "${DEMO_SRC}.${CHUNK_SIZE}.remote-2.${mode}.delta" --debug 

md5sum "${DEMO_SRC}" "${DEMO_SRC}.2.file" "${DEMO_SRC}.2.remote"


echo "error: ${error}"
exit 0
