#! /bin/bash

INSTALLDIR=~/bin
SSHDIR=~/.ssh

mkdir -p ${INSTALLDIR}
cp bin/* ${INSTALLDIR}/
chmod +x ${INSTALLDIR}/ssh-new
chmod +x ${INSTALLDIR}/ssh-del

mkdir -p ${SSHDIR}/keys

if [ ! -f ${SSHDIR}/config ]
then
  touch ${SSHDIR}/config
fi

# This snippet should always be at the END of your local ssh client config
cat >> ${SSHDIR}/config << EOF
Host *
        IdentityFile ~/.ssh/keys/%r@%h
EOF
