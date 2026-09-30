#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.test-clock-tmp/live.XXXXXX")
export HOME="$LAB/account" FM_HOME="$LAB/mate" FM_REMOTE_JOB_STATE_ROOT="$LAB/jobs"
export XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data" XDG_CACHE_HOME="$LAB/cache"
export FM_ROOT_OVERRIDE="$ROOT" TMPDIR="$ROOT/.test-clock-tmp"
mkdir -p "$HOME" "$FM_HOME/state" "$XDG_CONFIG_HOME"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_CONFIG_OVERRIDE="$FM_HOME/config"
export FM_DATA_OVERRIDE="$FM_HOME/data" FM_PROJECTS_OVERRIDE="$FM_HOME/projects"
mkdir -p "$FM_CONFIG_OVERRIDE" "$FM_DATA_OVERRIDE" "$FM_PROJECTS_OVERRIDE"
chmod 700 "$HOME"
. "$ROOT/bin/fm-remote-job-lib.sh"
sender=
cleanup() {
  [ -z "$sender" ] || kill "$sender" 2>/dev/null || true
  if [ -f "$LAB/jobs/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$LAB/jobs/worker.pid")" || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT
fm_remote_job_ensure_worker "$ROOT" "$HOME"
pid=$(cat "$LAB/jobs/worker.pid")
stable_start=$(cat "$LAB/jobs/worker.lock/start")
stable_command=$(cat "$LAB/jobs/worker.lock/command")
printf 'ready worker pid=%s identity=%s\n' "$pid" "$stable_start"
printf 'starttime=0\n' > "$LAB/jobs/worker.lock/start"
if fm_remote_job_lock_owner_matches_process "$HOME"; then echo 'wrong start ticks accepted'; exit 1; fi
echo 'wrong start ticks rejected for the live worker'
printf 'Mon Jan  5 03:04:05 2026\n' > "$LAB/jobs/worker.lock/start"
printf 'unrelated command\n' > "$LAB/jobs/worker.lock/command"
if fm_remote_job_lock_owner_matches_process "$HOME"; then echo 'unrelated command accepted'; exit 1; fi
echo 'unrelated command rejected even with a legacy start record'
printf '%s\n' "$stable_command" > "$LAB/jobs/worker.lock/command"
if ( . <(git show 65c75b0:bin/fm-remote-job-lib.sh); fm_remote_job_lock_owner_matches_process "$HOME" ); then
  echo 'baseline unexpectedly recognized drifted owner'; exit 1
fi
echo 'baseline rejects the still-running owner with a drifted legacy record'
fm_remote_job_lock_owner_matches_process "$HOME"
echo 'current code recognizes the same live legacy owner'
for attempt in 1 2 3 4; do
  fm_remote_job_ensure_worker "$ROOT" "$HOME"
  [ "$(cat "$LAB/jobs/worker.pid")" = "$pid" ]
  echo "ensure $attempt kept worker pid=$pid"
done
supervisors=$(pgrep -f -x "/bin/bash $ROOT/bin/fm-remote-job-worker.sh" | wc -l | tr -d ' ')
printf 'supervisor count after repeated ensure=%s\n' "$supervisors"
[ "$supervisors" = 1 ]
printf 'clock recovery job completed\n' > "$FM_HOME/state/replies.log"
empty_hash=$(printf '' | sha256sum | cut -d ' ' -f1)
fm_remote_job_stage "$HOME" "$ROOT" "$FM_HOME" fm-remote-delta-read.sh state/replies.log 0 "$empty_hash" 0 >/dev/null
fm_remote_job_wait "$HOME" "$FM_REMOTE_JOB_ID"
printf 'job exit=%s\n' "$FM_REMOTE_JOB_EXIT"
cat "$LAB/jobs/jobs/$FM_REMOTE_JOB_ID/stdout"
[ "$FM_REMOTE_JOB_EXIT" -eq 0 ]
fm_remote_job_reap "$HOME" "$FM_REMOTE_JOB_ID"
. "$ROOT/bin/fm-pending-reply-lib.sh"
sleep 120 & sender=$!
corr=$(fm_pending_reply_create "$FM_HOME" "$FM_HOME/state" labmate 'live sender identity')
rec=$(fm_pending_reply_path "$FM_HOME/state" "$corr")
fm_pending_reply_mark_delivered "$FM_HOME/state" "$corr"
fm_pending_reply_mark_turn_completed "$FM_HOME/state" "$corr" request
fm_pending_reply_set "$rec" recovery_attempted_epoch "$(date +%s)"
fm_pending_reply_set "$rec" recovery_sender_pid "$sender"
identity=$(fm_pending_reply_pid_identity "$sender")
fm_pending_reply_set "$rec" recovery_sender_identity "$identity"
fm_pending_reply_set "$rec" phase recovery_sending
legacy=$(fm_pending_reply_ps_identity "$sender")
mkdir -p "$LAB/shims"
cp "$(dirname "$0")/clock-ps-shim" "$LAB/shims/ps"
chmod +x "$LAB/shims/ps"
export FM_CLOCK_REAL_PS=$(command -v ps) FM_CLOCK_STEP="$LAB/clock-stepped"
export PATH="$LAB/shims:$PATH"
touch "$FM_CLOCK_STEP"
if [ "$(fm_pending_reply_ps_identity "$sender")" = "$legacy" ]; then
  echo 'legacy ps identity unexpectedly survived the simulated clock step'; exit 1
fi
echo 'legacy ps sender identity changes when ps renders a clock step'
watch_once() {
  local status=0
  timeout 4s env FM_POLL=1 "$ROOT/bin/fm-watch.sh" || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 124 ]
  [ -f "$FM_HOME/state/.last-watcher-beat" ]
}
watch_once
printf 'live sender identity=%s phase=%s\n' "$identity" "$(fm_pending_reply_get "$rec" phase)"
[ "$(fm_pending_reply_get "$rec" phase)" = recovery_sending ]
rm "$FM_CLOCK_STEP"
fm_pending_reply_set "$rec" recovery_sender_identity "$legacy"
fm_pending_reply_sender_alive "$rec"
echo 'legacy ps sender record still recognizes the real live process'
fm_pending_reply_set "$rec" recovery_sender_identity "${identity}changed"
if fm_pending_reply_sender_alive "$rec"; then echo 'mismatched sender accepted'; exit 1; fi
echo 'mismatched sender identity rejected'
fm_pending_reply_set "$rec" recovery_sender_identity "$identity"
kill "$sender"
wait "$sender" 2>/dev/null || true
sender=
if fm_pending_reply_sender_alive "$rec"; then echo 'dead sender accepted'; exit 1; fi
watch_once
printf 'dead sender outcome=%s phase=%s\n' "$(fm_pending_reply_get "$rec" recovery_delivery_outcome)" "$(fm_pending_reply_get "$rec" phase)"
fm_remote_job_stop_worker_tree "$pid"
echo 'worker tree stopped through the product cleanup interface'
