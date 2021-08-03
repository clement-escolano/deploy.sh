# deploy.sh

Shell utility to deploy a git repository to a remote SSH server.

## Requirements

`deploy.sh` focuses on having minimal dependencies:

- SSH access to the remote server
- `bash` installed on client
- `git` installed on server

## Getting started

The script can be copied in the working directory and called with `./deploy.sh` or in a directory in the `PATH` and called with `deploy.sh`.

## Example with command line options

To deploy the repository `git@example.com:me/deploy.sh.git` to the directory `/home/me` on the server `host`,
you can run the command:
```bash
./deploy.sh -r git@example.com:me/deploy.sh.git -d /home/me -h host
```

## Example with configuration file

You can also specify options with a configuration file named `.deploy` in the working directory.
The file will be sourced, so it follows the environment file format:

```bash
# .deploy
DEPLOYMENT_DIRECTORY=/home/me
GIT_REPOSITORY=git@example.com:me/deploy.sh.git
SSH_HOST=user@host
FRAMEWORKS="python django=static"
SHARED_PATHS=db.sqlite3
```

You can then run the script:

```bash
deploy.sh
```

If you need to specify a secret in the configuration (a token to fetch the git repository for instance),
you can do so in the `.deploy-secret` file which follows the same format as `.deploy` file.
This file should not be committed in your git repository.

## Advanced usage

Running `deploy.sh --help` displays a complete documentation of `deploy.sh` (which is also readable at the beginning of the script).

The following features are detailed:

* hooks (ability to run custom code before or after steps)
* rollback
* supported frameworks (python, django, npm, sqlite)
