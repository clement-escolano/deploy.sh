# deploy.sh

Shell utility to deploy a git repository to a remote SSH server.

## Requirements

This script is focused to have minimal dependencies:

- SSH access to the remote server
- `bash` installed on client
- `git` installed on server

## Getting started

The script can be copied in the working directory or in a directory in the `PATH`.
This script only requires bash installed on the client and the server.

## Example

To deploy the repository `git@example.com:me/deploy.sh.git` to the directory `/home/me` on the server `host`,
you can run the command:
```bash
./deploy.sh -r git@example.com:me/deploy.sh.git -d /home/me -h host
```
