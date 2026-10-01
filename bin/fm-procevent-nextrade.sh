#!/usr/bin/env bash
# Nextrade experiment adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-nextrade.sh arm <experiment-id> --for <task-id> [--agent-reply-file <path>]
#   fm-procevent-nextrade.sh classify|terminal|silent|answers|reconciles|read <result-file>
#   fm-procevent-nextrade.sh source-id|retire <experiment-id> [--for <task-id>]
#   fm-procevent-nextrade.sh poll <experiment-id> [--worktree <path> --target <name>] [--agent-reply-file <path>]
#   fm-procevent-nextrade.sh deliver-reply poll <experiment-id> --worktree <path> --target <name> --agent-reply-file <path>
#
# arm resolves the task's worktree metadata and its nearest .nextrade-axi/target.
# The listener retains that worktree and explicit target, never the supervisor's
# ambient selection. source-id and retire use the same task context with --for,
# or the current directory without it. Identity includes the target name and
# experiment UUID; dev also includes the physical worktree because each dev
# stack is independent. Named remote targets retain nextrade-axi's host config.
#
# poll is the registered blocking command, not a conversational-turn command.
# It runs nextrade-axi experiment poll <id> --owner firstmate --json. The CLI
# owns the server wait and listener lease; this adapter keeps no cursor, takes
# over no lease, and adds no retry loop. deliver-reply posts a staged reply with
# experiment reply --file synchronously under the generic registration lock.
# This is the only write command: the adapter never answers or consumes a decision.
#
# classify prints feedback, ended, waiting, missing, or unknown. terminal
# succeeds for end=true (including a final answer batch) or HTTP_404. silent
# succeeds only for a valid empty batch. Unknown or malformed output is announced.
# read presents all messages and decisions with prefixed untrusted body lines.
# answers emits key<TAB>selection<TAB>label<TAB>close_mode from captain-answered
# decisions only; a free-text-only answer uses answer_text, and a selection's
# answer_text is retained as a note. label is the selected option's visible label.
# reconcile selections use reconciles, never answers. Neither command checks or
# mutates held tasks: binding and keyed-answer intake belong to fm-captain-hold.sh.
# Ownership, capture, wake delivery, re-arm and terminal acknowledgement belong
# to fm-procevent.sh. Server delivery marks can advance before local capture;
# this adapter provides no source-side no-loss guarantee.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit "${1:-2}"; }

context() {  # [task-id]; sets worktree and target
  local task=${1-} dir
  worktree=$(pwd -P)
  if [ -n "$task" ]; then
    fm_pr_task_id_valid "$task" || die "invalid task id: $task"
    [ -f "$STATE/$task.meta" ] && [ ! -L "$STATE/$task.meta" ] || die "missing task metadata: $task"
    worktree=$(awk '/^worktree=/ { sub(/^worktree=/, ""); print; exit }' "$STATE/$task.meta")
    [ -n "$worktree" ] || die "task has no worktree: $task"
    worktree=$(cd "$worktree" && pwd -P) || die "task worktree is unavailable: $task"
  fi
  dir=$worktree
  target=''
  while :; do
    if [ -f "$dir/.nextrade-axi/target" ]; then
      target=$(cat "$dir/.nextrade-axi/target")
      break
    fi
    [ "$dir" != / ] || break
    dir=$(dirname "$dir")
  done
  case "$target" in ''|*[!A-Za-z0-9._-]*) die "no valid Nextrade target selected in task context" ;; esac
}

source_id() {  # <experiment-id>; uses resolved context
  local experiment=$1 scope=$target
  [[ "$experiment" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
    || die "experiment id must be a UUID"
  [ "$target" != dev ] || scope="$scope:$worktree"
  perl -MDigest::SHA=sha256_hex -e 'print "nextrade-", substr(sha256_hex(lc($ARGV[0])."\n".$ARGV[1]),0,32), "\n"' "$experiment" "$scope"
}

cmd_arm() {
  local experiment=${1-} task='' reply='' id listening=0 owner
  local worktree target
  [ -n "$experiment" ] || usage
  shift
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --for) [ -z "$task" ] || usage; task=$2 ;;
      --agent-reply-file) [ -z "$reply" ] || usage; reply=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  [ -n "$task" ] || usage
  context "$task"
  id=$(source_id "$experiment") || exit 1
  command -v nextrade-axi >/dev/null 2>&1 || die "nextrade-axi is not installed"
  local -a listener=("$SCRIPT_DIR/fm-procevent-nextrade.sh" poll "$experiment" --worktree "$worktree" --target "$target")
  [ -z "$reply" ] || listener+=(--agent-reply-file "$reply")
  "$SCRIPT_DIR/fm-procevent.sh" register-task nextrade "$id" "$task" -- "${listener[@]}" || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$id" || listening=$?
  if [ "$listening" -eq 3 ]; then
    printf 'still-listening: %s\n' "$id"
  elif [ "$listening" -eq 0 ]; then
    printf 'armed: %s\n' "$id"
  else
    owner=$("$SCRIPT_DIR/fm-procevent.sh" list 2>/dev/null | awk -v id="$id" '$1 == id { print $3; exit }')
    case "$owner" in
      live|orphaned|task:*/listening|task:*/round-open) ;;
      *) "$SCRIPT_DIR/fm-procevent.sh" retire "$id" >/dev/null 2>&1 || true ;;
    esac
    return 1
  fi
  printf 'experiment: %s\nowner-task: %s\n' "$experiment" "$task"
}

cmd_poll() {  # <poll|reply> <experiment-id> [listener options]
  local action=$1 experiment=${2-} reply='' worktree='' target=''
  [ -n "$experiment" ] || usage
  shift 2
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
      --worktree) [ -z "$worktree" ] || usage; worktree=$2 ;;
      --target) [ -z "$target" ] || usage; target=$2 ;;
      --agent-reply-file) [ -z "$reply" ] || usage; reply=$2 ;;
      *) usage ;;
    esac
    shift 2
  done
  if [ -z "$worktree" ] && [ -z "$target" ]; then context; fi
  [ -n "$worktree" ] && [ -n "$target" ] || usage
  source_id "$experiment" >/dev/null || exit 1
  if [ "$action" = reply ]; then
    [ -n "$reply" ] || usage
    local output
    if ! output=$(cd "$worktree" && nextrade-axi experiment reply "$experiment" --target "$target" --file "$reply" 2>&1); then
      die "Nextrade did not accept the staged reply: $output"
    fi
  else
    local -a argv=(experiment poll "$experiment" --target "$target" --owner firstmate --json)
    [ -z "$reply" ] || argv+=(--agent-reply-file "$reply")
    (cd "$worktree" && exec nextrade-axi "${argv[@]}")
  fi
}

cmd_result() {  # <operation> <result-file>
  [ "$#" -eq 2 ] || usage
  [ -f "$2" ] && [ ! -L "$2" ] || die "result file does not exist: $2"
  perl -MJSON::PP -e '
    use strict; use warnings;
    binmode STDOUT, ":encoding(UTF-8)";
    my ($op, $file) = @ARGV;
    open my $fh, "<", $file or die $!; local $/; my $raw = <$fh>;
    my $data = eval { decode_json($raw) };
    my $valid = ref($data) eq "HASH" && ref($data->{messages}) eq "ARRAY"
      && ref($data->{decisions_answered}) eq "ARRAY" && JSON::PP::is_bool($data->{end});
    if (!$valid) {
      my $missing = $raw =~ /\Aerror:[^\n]*\ncode: HTTP_404\s*(?:\n|\z)/;
      if ($op eq "classify") { print $missing ? "missing\n" : "unknown\n"; exit 0 }
      exit($missing ? 0 : 1) if $op eq "terminal";
      exit 1 if $op eq "silent";
      die "invalid Nextrade inbox result\n";
    }
    my $content = @{$data->{messages}} || @{$data->{decisions_answered}};
    if ($op eq "classify") { print $content ? "feedback\n" : $data->{end} ? "ended\n" : "waiting\n"; exit }
    exit($data->{end} ? 0 : 1) if $op eq "terminal";
    exit($content ? 1 : 0) if $op eq "silent";
    sub scalar_text { defined($_[0]) && !ref($_[0]) }
    sub field { my $s = scalar_text($_[0]) ? $_[0] : ""; $s =~ s/[\x00-\x1f\x7f]/ /g; return $s }
    if ($op eq "answers" || $op eq "reconciles") {
      my (@rows, %seen);
      for my $d (@{$data->{decisions_answered}}) {
        next unless ref($d) eq "HASH" && field($d->{status}) eq "answered" && field($d->{answered_by}) eq "captain";
        my ($key, $selection, $note, $mode) = map { $d->{$_} } qw(key selection answer_text close_mode);
        next unless scalar_text($key) && $key =~ /\A[A-Za-z0-9._-]{1,64}\z/;
        next unless scalar_text($mode) && ($mode eq "done" || $mode eq "release");
        next if defined($selection) && !scalar_text($selection) || defined($note) && !scalar_text($note);
        my $label = "";
        if (defined($selection) && length($selection)) {
          next unless ref($d->{options}) eq "ARRAY";
          my @options = grep { ref($_) eq "HASH" && scalar_text($_->{value}) && $_->{value} eq $selection } @{$d->{options}};
          next unless @options == 1 && scalar_text($options[0]->{label});
          $label = $options[0]->{label};
        }
        my $answer = field($selection);
        $answer .= (length($answer) ? " - " : "") . field($note) if defined($note) && length($note);
        next unless length($answer);
        $rows[$seen{$key}] = undef if exists $seen{$key};
        $seen{$key} = scalar @rows;
        push @rows, { key => $key, selection => $selection // "", answer => $answer, label => field($label), mode => $mode };
      }
      for my $r (grep { defined } @rows) {
        if ($op eq "reconciles") { print "$r->{key}\n" if $r->{selection} eq "reconcile" }
        elsif ($r->{selection} ne "reconcile" && $r->{answer} ne "reconcile") { print join("\t", @$r{qw(key answer label mode)}), "\n" }
      }
      exit;
    }
    sub body { my $s = scalar_text($_[0]) ? $_[0] : ""; $s =~ s/[\x00-\x08\x0b-\x1f\x7f]/ /g; print "  | $_\n" for split /\n/, $s, -1 }
    my $json = JSON::PP->new;
    print "end: ", $data->{end} ? "true\n" : "false\n";
    print "messages: ", scalar @{$data->{messages}}, "\n";
    for my $m (@{$data->{messages}}) {
      ref($m) eq "HASH" or die "invalid message\n";
      print "message: ", join(" ", map { field($m->{$_}) } qw(id kind author)), "\n";
      body($m->{body});
      print "refs: ", $json->encode($m->{refs}), "\n";
    }
    print "decisions_answered: ", scalar @{$data->{decisions_answered}}, "\n";
    for my $d (@{$data->{decisions_answered}}) {
      ref($d) eq "HASH" or die "invalid decision\n";
      print "decision: ", join(" ", map { field($d->{$_}) } qw(id key status close_mode)), "\n";
      for my $name (qw(title explanation example selection answer_text)) { print "$name:\n"; body($d->{$name}) }
      print "options: ", $json->encode($d->{options}), "\n";
    }
  ' "$@"
}

command=${1-}
for arg in "$@"; do [ "$arg" != --help ] || usage 0; done
[ "$#" -gt 0 ] && shift
case "$command" in
  arm) cmd_arm "$@" ;;
  poll) cmd_poll poll "$@" ;;
  deliver-reply) [ "${1-}" = poll ] || usage; shift; cmd_poll reply "$@" ;;
  classify|terminal|silent|answers|reconciles|read) cmd_result "$command" "$@" ;;
  source-id|retire)
    [ "$#" -eq 1 ] || { [ "$#" -eq 3 ] && [ "$2" = --for ]; } || usage
    context "${3-}"
    id=$(source_id "$1") || exit 1
    if [ "$command" = source-id ]; then printf '%s\n' "$id"; else "$SCRIPT_DIR/fm-procevent.sh" retire "$id"; fi
    ;;
  *) usage ;;
esac
