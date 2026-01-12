#!/usr/bin/env bash
set -euo pipefail

# Remote Docker app startup check via SSH.
#
# Example:
#   ./scripts/remote_startup_check.sh \
#     --ssh-user "$SERVER_USERNAME" \
#     --ssh-host "$SERVER_HOST" \
#     --ssh-key  "$HOME/.ssh/id_rsa" \
#     --server-path "$SERVER_PATH" \
#     --container-name "${ENV}-edu-trainer-api" \
#     --success-grep "Started \S+ in [0-9]+(\.[0-9]+)? seconds" \
#     --failure-grep "APPLICATION FAILED TO START" \
#     --max-retries 10 \
#     --retry-interval 10 \
#     --log-lines 12
#
# log-lines:
#   - number: tail last N lines on failure/timeout
#   - all|full|0: print full logs on failure/timeout

SSH_USER=""
SSH_HOST=""
SSH_PORT="22"
SSH_KEY_PATH=""
SERVER_PATH=""
CONTAINER_NAME=""

MAX_RETRIES="10"
RETRY_INTERVAL="10"

LOG_LINES="12"
FAILURE_GREP="APPLICATION FAILED TO START"
SUCCESS_GREP="Started \S+ in [0-9]+(\.[0-9]+)? seconds"

STRICT_HOST_KEY_CHECKING="true"

usage() {
  cat <<'USAGE'
remote_startup_check.sh parameters:

Required:
  --ssh-user <user>
  --ssh-host <host>
  --ssh-key <path-to-private-key>
  --server-path <remote-path>
  --container-name <docker-container-name>

Optional:
  --ssh-port <22>
  --max-retries <10>
  --retry-interval <10>
  --log-lines <12|all|full|0>
  --failure-grep <text>   (default: "APPLICATION FAILED TO START")
  --success-grep <text>   (default: "Started EduTrainerApplication in")
  --strict-host-key-checking <true|false> (default: true)

Exit codes:
  0  - success message found
  1  - failure message found OR timeout
  2  - invalid arguments / misconfiguration
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-user) SSH_USER="$2"; shift 2 ;;
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --ssh-key) SSH_KEY_PATH="$2"; shift 2 ;;
    --server-path) SERVER_PATH="$2"; shift 2 ;;
    --container-name) CONTAINER_NAME="$2"; shift 2 ;;

    --max-retries) MAX_RETRIES="$2"; shift 2 ;;
    --retry-interval) RETRY_INTERVAL="$2"; shift 2 ;;
    --log-lines) LOG_LINES="$2"; shift 2 ;;
    --failure-grep) FAILURE_GREP="$2"; shift 2 ;;
    --success-grep) SUCCESS_GREP="$2"; shift 2 ;;
    --strict-host-key-checking) STRICT_HOST_KEY_CHECKING="$2"; shift 2 ;;

    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$SSH_USER" ]]; then
  echo "Missing SSH_USER ." >&2
  usage
  exit 2
fi
if [[ -z "$SSH_HOST" ]]; then
  echo "Missing SSH_HOST." >&2
  usage
  exit 2
fi
if [[ -z "$SSH_KEY_PATH" ]]; then
  echo "Missing SSH_KEY_PATH." >&2
  usage
  exit 2
fi
if [[ -z "$SERVER_PATH" ]]; then
  echo "Missing SERVER_PATH." >&2
  usage
  exit 2
fi
if [[ -z "$CONTAINER_NAME" ]]; then
  echo "Missing CONTAINER_NAME." >&2
  usage
  exit 2
fi

if [[ -z "$SSH_USER" || -z "$SSH_HOST" || -z "$SSH_KEY_PATH" || -z "$SERVER_PATH" || -z "$CONTAINER_NAME" ]]; then
  echo "Missing required parameter(s)." >&2
  usage
  exit 2
fi

if [[ ! -f "$SSH_KEY_PATH" ]]; then
  echo "SSH private key file not found: $SSH_KEY_PATH" >&2
  exit 2
fi

is_number() { [[ "$1" =~ ^[0-9]+$ ]]; }

should_print_full_logs() {
  case "$LOG_LINES" in
    all|full|0) return 0 ;;
    *) return 1 ;;
  esac
}

# Escape single quotes for safe embedding into single-quoted strings used in remote command.
sq_escape() {
  # '  ->  '\''   (close quote, escaped quote, reopen)
  printf "%s" "$1" | sed "s/'/'\\\\''/g"
}

failure_esc="$(sq_escape "$FAILURE_GREP")"
success_esc="$(sq_escape "$SUCCESS_GREP")"
path_esc="$(sq_escape "$SERVER_PATH")"
container_esc="$(sq_escape "$CONTAINER_NAME")"

ssh_opts=(-i "$SSH_KEY_PATH" -p "$SSH_PORT" -o BatchMode=yes)
if [[ "$STRICT_HOST_KEY_CHECKING" == "true" ]]; then
  ssh_opts+=(-o StrictHostKeyChecking=yes)
else
  ssh_opts+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
fi

remote_grep_failure="cd '$path_esc' && docker logs '$container_esc' 2>&1 | grep -qP '$failure_esc'"
remote_grep_success="cd '$path_esc' && docker logs '$container_esc' 2>&1 | grep -qP '$success_esc'"

print_logs() {
  if should_print_full_logs; then
    echo "Full application logs:"
    ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
      "cd '$path_esc' && docker logs '$container_esc' 2>&1"
  else
    if ! is_number "$LOG_LINES"; then
      echo "Invalid --log-lines '$LOG_LINES'. Use a number or one of: all|full|0." >&2
      exit 2
    fi
    echo "Last $LOG_LINES lines of application logs:"
    ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
      "cd '$path_esc' && docker logs '$container_esc' 2>&1 | tail -n $LOG_LINES"
  fi
}

echo "Checking application startup status..."
echo "Container: $CONTAINER_NAME"
echo "Max retries: $MAX_RETRIES, Retry interval: ${RETRY_INTERVAL}s"
echo "Failure grep: $FAILURE_GREP"
echo "Success grep: $SUCCESS_GREP"
echo "Log lines: $LOG_LINES"

RETRY_COUNT=0
while [[ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]]; do
  # Failure check
  if ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "$remote_grep_failure"; then
    echo "::error::Application failed to start. Check logs for details."
    print_logs
    exit 1
  fi

  # Success check
  if ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "$remote_grep_success"; then
    echo "Application started successfully."
    exit 0
  fi

  # Timeout
  if [[ "$RETRY_COUNT" -eq $((MAX_RETRIES - 1)) ]]; then
    echo "::error::Application did not start within the expected time. Check logs for details."
    print_logs
    exit 1
  fi

  echo "Application still starting... Waiting for $RETRY_INTERVAL seconds before next check. (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)"
  sleep "$RETRY_INTERVAL"
  RETRY_COUNT=$((RETRY_COUNT + 1))
done

echo "::error::Unexpected loop exit."
exit 1
