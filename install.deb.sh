#!/bin/bash

# defaults
echo "- BRANCH [${BRANCH:=main}]"
NAME="avahi-backup"
VERSION="1.0.0"
HEADHASH="$(date +%s)"
TARGET_BASE="/usr/local/share/${NAME}"
REPO="https://github.com/hastmu/avahi-backup"

# workdir
T_DIR=$(mktemp -d)
trap 'rm -Rf "${T_DIR}"' EXIT

# create debian structure
# TODO get metric information out of github.
(
    cd "${T_DIR}" || exit
    mkdir DEBIAN
    cat <<EOF > DEBIAN/control
Package: ${NAME}
Version: ${VERSION}-${BRANCH}-${HEADHASH}
Section: base 
Priority: optional 
Architecture: all 
Depends: coreutils, sudo, grep, mawk, avahi-utils, rsync, procps
Optional: zfsutils-linux
Maintainer: nomail@nomail.no
Description: avahi based backup as a service
EOF

   # clone repo
   (
      mkdir -p "${T_DIR}/.src"
      cd "${T_DIR}/.src" || exit
      git clone -b "${BRANCH}" "${REPO}"
   )

   # move client part
   mv "${T_DIR}/.src/${REPO##*/}/etc" "${T_DIR}/."
   mv "${T_DIR}/.src/${REPO##*/}/lib" "${T_DIR}/."
   cp -va ${T_DIR}/.src/${REPO##*/}/DEBIAN/* "${T_DIR}/DEBIAN/."
   
   mkdir -p "${T_DIR}/${TARGET_BASE}"
   mkdir -p "${T_DIR}/${TARGET_BASE}/bin"
   mv "${T_DIR}/.src/${REPO##*/}/avahi-backup.d" "${T_DIR}/${TARGET_BASE}/bin/."
   mv "${T_DIR}/.src/${REPO##*/}/avahi-backup.sh" "${T_DIR}/${TARGET_BASE}/bin/."
   mv "${T_DIR}/.src/${REPO##*/}/avahi-backup.sh.client" "${T_DIR}/${TARGET_BASE}/bin/."
   mv "${T_DIR}/.src/${REPO##*/}/avahi-backup.sh.server" "${T_DIR}/${TARGET_BASE}/bin/."

   mkdir -p "${T_DIR}/usr/local/bin"
   mkdir -p "${T_DIR}/usr/local/sbin"
   ln -s "../share/${NAME}/bin/avahi-backup.sh" "${T_DIR}/usr/local/bin/avahi-backup.sh"
   ln -s "../share/${NAME}/bin/avahi-backup.sh" "${T_DIR}/usr/local/sbin/avahi-backup.sh"
   
   rm -Rf "${T_DIR}/.src"

   find ${T_DIR}


)

if dpkg -b "${T_DIR}" "${NAME}_${VERSION}_${HEADHASH}.deb"
then
   sudo apt-get install -y "$(pwd)/${NAME}_${VERSION}_${HEADHASH}.deb"
   rm -fv "$(pwd)/${NAME}_${VERSION}_${HEADHASH}.deb"
   dpkg -l "${NAME}"
fi

