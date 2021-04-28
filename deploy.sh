#!/usr/bin/env bash
set -E # Propagate errors from functions to trap
set -e # Fail on first failed command
set -u # Treat undefined variable as an error
IFS=$'\n\t'

#/ Usage: Deploy a git repository to a remote SSH server
#/ Description: With configuration via command line or the file
#/              .deploy-configuration in the working directory, deploy a git
#/              repository safely to a remote SSH server, keeping old releases
#/              and running additional commands to install frameworks required
#/              by the deployed software.
#/ Example: ./deploy.sh -r git@example.com:me/deploy.sh.git -d /home/me -h host
#/ Options:
#/       -b: Git branch to deploy (default: master)
#/       -d: Directory where repository is deployed in remote server
#/       -r: Repository address
#/       -h: SSH host to deploy
#/       -k: Number of releases to keep (default: 3)
#/   --help: Display this help message

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

parse_options() {
	while getopts :b:d:r:h:k: option; do
		case "$option" in
			b) GIT_BRANCH="$OPTARG" ;;
			d) DEPLOYMENT_DIRECTORY="$OPTARG" ;;
			r) GIT_REPOSITORY="$OPTARG" ;;
			h) SSH_HOST="$OPTARG" ;;
			k) KEEP_RELEASES="$OPTARG" ;;
			\?) fatal "Invalid option $OPTARG found" ;;
		esac
	done

	if [[ -z "${DEPLOYMENT_DIRECTORY+x}" ]]; then fatal "Website directory not specified. Use the option '-d'"; fi
	if [[ -z "${GIT_REPOSITORY+x}" ]]; then fatal "Git repository not specified. Use the option '-r'"; fi
	if [[ -z "${SSH_HOST+x}" ]]; then fatal "SSH host not specified. Use the option '-h'"; fi
	if [[ -z "${KEEP_RELEASES+x}" ]]; then KEEP_RELEASES=3; fi
	if [[ -z "${GIT_BRANCH+x}" ]]; then GIT_BRANCH=master; fi

	local IFS=$' '
	info "Running script at $(date +"%Y/%m/%d %H:%M:%S") with options:
	DEPLOYMENT_DIRECTORY=$DEPLOYMENT_DIRECTORY
	GIT_REPOSITORY=$GIT_REPOSITORY
	SSH_HOST=$SSH_HOST
	KEEP_RELEASES=$KEEP_RELEASES
	GIT_BRANCH=$GIT_BRANCH
	LOG_FILE=$LOG_FILE
	"
}

remote_command_with_log() {
	mode=$1
	shift
	local IFS=$' '
	debug "$@"
	set +e
	# shellcheck disable=SC2029 # Parameters needs to be expanded before being sent to the server
	if ! output=$(ssh "$SSH_HOST" "bash -c '$*'" 2>&1); then
		fail_with_details "$*" "$output"
	fi

	case "$mode" in
		warning) if [ -n "$output" ]; then warning "$output"; fi ;;
		error) if [ -n "$output" ]; then error "$output"; fi ;;
		fatal) if [ -n "$output" ]; then fatal "$output"; fi ;;
		*) echo "$output" >>"$LOG_FILE" ;;
	esac
}

remote_command_with_warning() {
	remote_command_with_log "warning" "$@"
}

remote_command() {
	remote_command_with_log "file" "$@"
}

fetch_repository() {
	info "Fetching git repository $GIT_REPOSITORY (branch $GIT_BRANCH) into $RELEASE_DIRECTORY"
	remote_command "mkdir -p $RELEASE_DIRECTORY"
	remote_command "git clone --single-branch --branch $GIT_BRANCH --depth 1 $GIT_REPOSITORY $RELEASE_DIRECTORY 2>&1"
	remote_command "cd $RELEASE_DIRECTORY && git rev-parse $GIT_BRANCH > REVISION"
}

run_python_tasks() {
	info "Creating Virtual environment"
	remote_command "cd $RELEASE_DIRECTORY && python3 -m venv venv"
	remote_command "cd $RELEASE_DIRECTORY && source venv/bin/activate && pip install pip --upgrade"
	info "Installing dependencies from requirements.txt"
	remote_command "cd $RELEASE_DIRECTORY && source venv/bin/activate && pip install -r requirements.txt"
}

run_django_tasks() {
	info "Backing up database"
	remote_command_with_warning "cd $RELEASE_DIRECTORY && test -f db.sqlite3 || echo No existing database found."
	remote_command "cd $RELEASE_DIRECTORY && test -f db.sqlite3 && cp db.sqlite3 db.sqlite3.bak || true"
	info "Running Django migrations"
	remote_command "cd $RELEASE_DIRECTORY && source venv/bin/activate && python manage.py migrate"
	info "Collecting static files"
	remote_command "cd $RELEASE_DIRECTORY && source venv/bin/activate && python manage.py collectstatic"
}

publish() {
	info "Publishing new release"
	remote_command "cd $DEPLOYMENT_DIRECTORY && if [ -d current ] && [ ! -L current ]; then echo Error: could not make symbolic link && exit 1; fi"
	remote_command "cd $DEPLOYMENT_DIRECTORY && ln -nfs $RELEASE_DIRECTORY current_tmp && mv -fT current_tmp current"
}

clean_old_releases() {
	info "Cleaning old releases"
	# Display the latest backups and all the backups, then keep only the backups displayed once and delete them
	remote_command "cd $DEPLOYMENT_DIRECTORY/releases && (find . -mindepth 1 -maxdepth 1 | sort | head -n $KEEP_RELEASES; find . -mindepth 1 -maxdepth 1) | sort | uniq -u | xargs rm -rf"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	trap explain_error ERR
	parse_options "$@"
	RELEASE_DIRECTORY="$DEPLOYMENT_DIRECTORY/releases/$(date +"%Y%m%d%H%M%S")"
	fetch_repository
	run_python_tasks
	run_django_tasks
	publish
	clean_old_releases
fi
