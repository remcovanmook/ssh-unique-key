# ssh-unique-key
tools to customize ssh to create, use and delete  a specific key per [user@host] combination.


## How to install

run ./install.sh.

## How to use

To create a key, copy it over and log in in one go: ~/bin/ssh-new [user@]host 

If a key already exists, it will NOT be overwritten. If it hasn't been copied to the remote system, it will try to do so.

To remove a key from the remote host and delete it locally: ~/bin/ssh-del [user@]host. It wil ask for confirmation.
