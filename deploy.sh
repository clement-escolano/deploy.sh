#!/usr/bin/env bash
set -E # Propagate errors from functions to trap
set -e # Fail on first failed command
set -u # Treat undefined variable as an error
IFS=$'\n\t'

#/ Usage: Deploy a git repository to a remote SSH server
#/ Description:
#/     With configuration via command line or the file .deploy in the working
#/     directory, deploy a git repository safely to a remote SSH server,
#/     keeping old releases and running additional commands to install
#/     frameworks required by the deployed software.
#/ Example: ./deploy.sh -r git@example.com:me/deploy.sh.git -d /home/me -h host
#/ Configuration file:
#/     To use a configuration file, creates a `.deploy` file following the
#/     environment file format. You can also copy-paste the options logged
#/     by the script when running from the command line. You can also use the
#/     `.deploy-secret` file which behaves the same way for secret options
#/     (the repository address with an access token for instance).
#/ Configuration file example:
#/     DEPLOYMENT_DIRECTORY=/home/me
#/     GIT_REPOSITORY=git@example.com:me/deploy.sh.git
#/     SSH_HOST=user@host
#/     FRAMEWORKS="python django"
#/     SHARED_PATHS=db.sqlite3
#/ Adding hooks to steps:
#/     Sometimes, basic options are not enough. If you need a specific
#/     behaviour, you can create a .deploy-hooks.sh file and write hooks.
#/     The hooks are defined by creating methods called pre_<step>_hook or
#/     post_<step>_hook. These methods should use remote_command to run a
#/     command in the remote host. An additional pre_<step>_hook_description
#/     or post_<step>_hook_description variable can be set to describe the
#/     hook. The following steps, ordered as run by the script, can be hooked:
#/         - fetch_repository
#/         - shared_paths
#/         - npm
#/         - sqlite
#/         - python
#/         - django
#/         - publish
#/ Options (corresponding option for configuration file within brackets):
#/     -b (GIT_BRANCH)
#/         Git branch to deploy (default: master)
#/     -d (DEPLOYMENT_DIRECTORY)
#/         Directory where repository is deployed in remote server (required)
#/     -f (FRAMEWORKS)
#/         Specify frameworks that needs to be installed. Can be set multiple
#/         times. Current frameworks are:
#/             - django (run migrations and collect static files if option
#/               'static' is set)
#/             - npm (install dependencies and run `npm run build`, the path
#/               to the directory to run the commands can be set via an option)
#/             - python (set up a virtualenv and install requirements)
#/             - sqlite (back up the database)
#/         Must me within quotes in the configuration file.
#/         Options can be set using the '=' sign, for instance: django=static.
#/     -h (SSH_HOST)
#/         SSH host to deploy (required)
#/     -k (KEEP_RELEASES)
#/         Number of releases to keep (default: 3)
#/     -r (GIT_REPOSITORY)
#/         Git repository address (required)
#/     -s (SHARED_PATHS)
#/         Shared path that should be symlinked to a canonical value. Can be
#/         set multiple times. The shared path will be symlinked in the
#/         release directory. The canonical value should be in the `shared`
#/         directory inside the deployment directory on the remote server.
#/     -t (TYPE)
#/         Deployment type, may be either:
#/             - deploy (default) which deploys the git repository to the
#/               SSH host
#/             - rollback which reverts the current release to the previous one
#/     --help: Display this help message

usage() {
	grep '^#/' "$0" | cut -c4-
	exit 0
}
expr "$*" : ".*--help" >/dev/null && usage

# Log utilities
readonly LOG_FILE="/tmp/$(basename "$0")-$(date +"%Y%m%d").log"
debug() { echo "[DEBUG]	$*" | tee -a "$LOG_FILE" >/dev/null; }
info() { echo "[INFO]	$*" | tee -a "$LOG_FILE"; }
warning() { echo "[WARN]	$*" | tee -a "$LOG_FILE" >&2; }
error() { echo "[ERROR]	$*" | tee -a "$LOG_FILE" >&2; }
fatal() {
	echo "[FATAL]	$*" | tee -a "$LOG_FILE" >&2
	false  # Returns an error to force the trap to work
	exit 1 # Make sure the script exits even if there is an issue with the trap
}

explain_error() {
	printf "\033[31m"
	echo "------------"
	echo "Deployment failed. You may find information in the log file $LOG_FILE. Below are the last 3 lines:"
	echo ""
	printf "\033[39m"
	tail -n 3 "$LOG_FILE"
	exit 1
}

fail_with_details() {
	original_command=$1
	error=$2
	fatal "The following SSH command failed:
	Command: $original_command
	Error details: $error"
}

declare -A FRAMEWORKS
declare -A DEFAULT_FRAMEWORK_VALUES
set_default_options() {
	GIT_BRANCH=master
	KEEP_RELEASES=3
	SHARED_PATHS=()
	TYPE=deploy
	DEFAULT_FRAMEWORK_VALUES[npm]="/"
}

parse_framework() {
	IFS="=" read -r framework_name framework_option <<<"$1"
	default_framework_value="${DEFAULT_FRAMEWORK_VALUES[$framework_name]:-1}"
	FRAMEWORKS["$framework_name"]="${framework_option:-$default_framework_value}"
}

parse_options_file() {
	if [ -f "$PWD/.deploy" ]; then
		source "$PWD/.deploy"
	fi
	if [ -f "$PWD/.deploy-hooks.sh" ]; then
		source "$PWD/.deploy-hooks.sh"
	fi
	if [ -f "$PWD/.deploy-secret" ]; then
		source "$PWD/.deploy-secret"
	fi
	IFS=" " read -r -a SHARED_PATHS <<<"${SHARED_PATHS-}"
	IFS=" " read -r -a FRAMEWORK_LIST <<<"${FRAMEWORKS-}"
	FRAMEWORKS=()
	for FRAMEWORK in "${FRAMEWORK_LIST[@]}"; do
		parse_framework "$FRAMEWORK"
	done
}

# Print frameworks with value only if not default value
pretty_print_frameworks() {
	print_frameworks() {
		for key in "${!FRAMEWORKS[@]}"; do
			printf "%s" "$key"
			if [ "${DEFAULT_FRAMEWORK_VALUES[$key]-1}" != "${FRAMEWORKS[$key]}" ]; then
				printf "=%s" "${FRAMEWORKS[$key]}"
			fi
			printf " "
		done
	}

	raw_output=$(print_frameworks)
	echo "${raw_output::-1}" # Remove last space character
}

parse_options() {
	while getopts :b:d:f:h:k:r:s:t: option; do
		case "$option" in
			b) GIT_BRANCH="$OPTARG" ;;
			d) DEPLOYMENT_DIRECTORY="$OPTARG" ;;
			f) parse_framework "$OPTARG" ;;
			h) SSH_HOST="$OPTARG" ;;
			k) KEEP_RELEASES="$OPTARG" ;;
			r) GIT_REPOSITORY="$OPTARG" ;;
			s) SHARED_PATHS+=("$OPTARG") ;;
			t) TYPE="$OPTARG" ;;
			\?) fatal "Invalid option $OPTARG found" ;;
		esac
	done

	if [[ -z "${DEPLOYMENT_DIRECTORY+x}" ]]; then fatal "Website directory not specified. Use the option '-d'"; fi
	if [[ -z "${GIT_REPOSITORY+x}" ]]; then fatal "Git repository not specified. Use the option '-r'"; fi
	if [[ -z "${SSH_HOST+x}" ]]; then fatal "SSH host not specified. Use the option '-h'"; fi

	local IFS=$' '
	info "Running script at $(date +"%Y/%m/%d %H:%M:%S") logging to $LOG_FILE with options:
	TYPE=$TYPE
	DEPLOYMENT_DIRECTORY=$DEPLOYMENT_DIRECTORY
	GIT_REPOSITORY=$GIT_REPOSITORY
	SSH_HOST=$SSH_HOST
	KEEP_RELEASES=$KEEP_RELEASES
	GIT_BRANCH=$GIT_BRANCH
	FRAMEWORKS=\"$(pretty_print_frameworks)\"
	SHARED_PATHS=\"${SHARED_PATHS[*]}\"
	"
}

remote_command_with_log() {
	mode=$1
	shift
	local IFS=$' '
	debug "$@"
	set +e
	# shellcheck disable=SC2029 # Parameters needs to be expanded before being sent to the server
	if ! output=$(ssh "$SSH_HOST" "$*" 2>&1); then
		fail_with_details "$*" "$output"
	fi

	case "$mode" in
		echo) if [ -n "$output" ]; then echo "$output"; fi ;;
		info) if [ -n "$output" ]; then info "$output"; fi ;;
		warning) if [ -n "$output" ]; then warning "$output"; fi ;;
		error) if [ -n "$output" ]; then error "$output"; fi ;;
		fatal) if [ -n "$output" ]; then fatal "$output"; fi ;;
		*) echo "$output" >>"$LOG_FILE" ;;
	esac
}

remote_command_with_echo() {
	remote_command_with_log "echo" "$@"
}

remote_command_with_info() {
	remote_command_with_log "info" "$@"
}

remote_command_with_warning() {
	remote_command_with_log "warning" "$@"
}

remote_command_with_error() {
	remote_command_with_log "error" "$@"
}

remote_command_with_fatal() {
	remote_command_with_log "fatal" "$@"
}

remote_command() {
	remote_command_with_log "file" "$@"
}

run_fetch_repository_step() {
	info "Fetching git repository $GIT_REPOSITORY (branch $GIT_BRANCH) into $RELEASE_DIRECTORY"
	remote_command "mkdir -p $RELEASE_DIRECTORY"
	remote_command "git clone --single-branch --branch $GIT_BRANCH --depth 1 $GIT_REPOSITORY $RELEASE_DIRECTORY 2>&1"
}

run_shared_paths_step() {
	for shared_path in "${SHARED_PATHS[@]}"; do
		info "Linking shared path: $shared_path"
		remote_command "mkdir -p \$(dirname $DEPLOYMENT_DIRECTORY/shared/$shared_path)"
		remote_command "mkdir -p \$(dirname $RELEASE_DIRECTORY/$shared_path)"
		remote_command "ln -s $DEPLOYMENT_DIRECTORY/shared/$shared_path $RELEASE_DIRECTORY/$shared_path"
	done
}

run_django_step() {
	info "Running Django migrations"
	remote_command "cd $RELEASE_DIRECTORY && venv/bin/python manage.py migrate"
	if [ static == "${FRAMEWORKS[django]}" ]; then
		info "Collecting static files"
		remote_command "cd $RELEASE_DIRECTORY && venv/bin/python manage.py collectstatic"
	fi
}

run_npm_step() {
	npm_directory="${FRAMEWORKS[npm]}"
	info "Installing dependencies from package.json"
	remote_command "cd $RELEASE_DIRECTORY$npm_directory && npm ci"
	info "Building website"
	remote_command "cd $RELEASE_DIRECTORY$npm_directory && npm run build"
}

run_python_step() {
	info "Creating Virtual environment"
	remote_command "cd $RELEASE_DIRECTORY && python3 -m venv venv"
	remote_command "cd $RELEASE_DIRECTORY && venv/bin/pip install pip --upgrade"
	info "Installing dependencies from requirements.txt"
	remote_command "cd $RELEASE_DIRECTORY && venv/bin/pip install -r requirements.txt"
}

run_sqlite_step() {
	info "Backing up database"
	remote_command_with_warning "cd $RELEASE_DIRECTORY && test -f db.sqlite3 || echo No existing database found."
	remote_command "cd $RELEASE_DIRECTORY && test -f db.sqlite3 && cp db.sqlite3 db.sqlite3.bak || true"
}

run_publish_step() {
	info "Publishing release"
	remote_command "cd $DEPLOYMENT_DIRECTORY && if [ -d current ] && [ ! -L current ]; then echo Error: could not make symbolic link && exit 1; fi"
	remote_command "cd $DEPLOYMENT_DIRECTORY && ln -nfs $RELEASE_DIRECTORY current_tmp && mv -fT current_tmp current"
	remote_command "cd $DEPLOYMENT_DIRECTORY && git -C $RELEASE_DIRECTORY log -1 --pretty=%B > CURRENT_COMMIT"
	remote_command "cd $DEPLOYMENT_DIRECTORY && git -C $RELEASE_DIRECTORY rev-parse $GIT_BRANCH > CURRENT_REVISION"
}

clean_old_releases() {
	info "Cleaning old releases"
	# Display the latest backups and all the backups, then keep only the backups displayed once and delete them
	remote_command "cd $DEPLOYMENT_DIRECTORY/releases && (find . -mindepth 1 -maxdepth 1 | sort -r | head -n $KEEP_RELEASES; find . -mindepth 1 -maxdepth 1) | sort | uniq -u | xargs rm -rf"
}

summary() {
	remote_command_with_info "cd $RELEASE_DIRECTORY && echo Successfully deployed to commit: \$(git log -1 --pretty=%B)"
}

is_hook_defined() {
	declare -F "$1" >/dev/null
}

run_step() {
	pre_hook="pre_$1_hook"
	if is_hook_defined "$pre_hook"; then
		pre_hook_description="pre_$1_hook_description"
		info "Running pre hook for $1: ${!pre_hook_description-'User defined hook'}"
		$pre_hook
	fi

	actual_step="run_$1_step"
	$actual_step

	post_hook="post_$1_hook"
	if is_hook_defined "$post_hook"; then
		post_hook_description="post_$1_hook_description"
		info "Running post hook for $1: ${!post_hook_description-'User defined hook'}"
		$post_hook
	fi
}

deploy() {
	RELEASE_DIRECTORY="$DEPLOYMENT_DIRECTORY/releases/$(date +"%Y%m%d%H%M%S")"
	run_step fetch_repository
	if [ "${#SHARED_PATHS[@]}" -gt 0 ]; then run_step shared_paths; fi
	if [ -n "${FRAMEWORKS[npm]-}" ]; then run_step npm; fi
	if [ -n "${FRAMEWORKS[sqlite]-}" ]; then run_step sqlite; fi
	if [ -n "${FRAMEWORKS[python]-}" ]; then run_step python; fi
	if [ -n "${FRAMEWORKS[django]-}" ]; then run_step django; fi
	run_step publish
	clean_old_releases
	summary
}

rollback() {
	info "Analysing releases state"
	current_release=$(remote_command_with_echo "if [ -h $DEPLOYMENT_DIRECTORY/current ]; then basename \$(readlink $DEPLOYMENT_DIRECTORY/current); fi")
	if [[ -z $current_release ]]; then fatal "No current release found. Cannot determine the previous release."; fi
	previous_release=$(remote_command_with_echo "ls $DEPLOYMENT_DIRECTORY/releases | grep -B 1 $current_release | grep -v $current_release || echo")
	if [[ -z $previous_release ]]; then fatal "No previous release available. Cannot rollback."; fi
	info "Beginning rollback to release $previous_release"
	RELEASE_DIRECTORY="$DEPLOYMENT_DIRECTORY/releases/$previous_release"
	run_step publish
	summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	trap explain_error ERR
	set_default_options
	parse_options_file
	parse_options "$@"
	if [[ "$TYPE" == "deploy" ]]; then
		deploy
	else
		rollback
	fi
fi
