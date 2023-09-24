#! /bin/bash

mkdir -p ~/bin
cp bin/* ~/bin/

mkdir -p ~/.ssh/keys

if [ i! -f ~/.ssh/config ]
then
  touch .ssh/config
fi

cat << EOF >> ~/.ssh/config
Host *
        IdentityFile ~/.ssh/keys/%r@%h
EOF
