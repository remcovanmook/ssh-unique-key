# ssh-unique-key

Do you have too many keys sitting in your ~/.ssh directory? Would you like 

tools to customize ssh to create, use and delete  a specific key per [user@host] combination.


## How to install

run ./install.sh.

## How to use

To create a key, copy it over and log in in one go: `ssh-new [user@]host`. 
If you don't specify a user name, your current username will be used (just like ssh).

If a key already exists, it will NOT be overwritten. If it hasn't been copied to the remote system, it will try to do so.

To remove a key from the remote host and delete it locally: `ssh-del [user@]host`. 
It wil ask for confirmation.

### TODO
- Get proper argument parsing, add a replace function
- Figure out how to make this work together with ssh-agent and passphrases without adding crazy overhead.
- Instead of actually generating a separate key for every connection, create a picker and a list of keys like 'work', 'big project', 'personal', 'aws'
