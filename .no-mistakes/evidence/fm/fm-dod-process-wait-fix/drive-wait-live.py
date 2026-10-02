import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import time

root = pathlib.Path.cwd()
evidence = pathlib.Path(__file__).parent
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_') and not k.startswith('TASKS_AXI_')}
logs = []

def run(args, **kwargs):
    result = subprocess.run(args, cwd=root, env=env, text=True, capture_output=True, timeout=20, **kwargs)
    logs.append('$ ' + ' '.join(args) + '\n' + result.stdout + result.stderr)
    assert result.returncode == 0, logs[-1]
    return result.stdout

home = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab.', dir=root))
try:
    run(['bash', 'bin/fm-lab-home.sh', 'create', str(home)])
    env['FM_HOME'] = str(home)
    commands = None
    for forge in ('none', 'gerrit'):
        for kind in ('ordinary', 'promoted'):
            task = f'wait-{kind}-{forge}'
            args = ['bash', 'bin/fm-brief.sh', task, 'sample']
            if kind == 'ordinary':
                args += ['--mode', 'no-mistakes', '--forge', forge]
            else:
                args += ['--scout']
            run(args)
            brief = home / 'data' / task / 'brief.md'
            if kind == 'promoted':
                brief.write_text(brief.read_text().replace('{TASK}', 'Verify safe background child waits.').replace('{FIRSTMATE_SPEC}', 'Use a disposable task.'))
                (home / 'state' / f'{task}.meta').write_text(f'kind=scout\nwindow=fm-{task}\nworktree={home}/projects/sample\nproject={home}/projects/sample\n')
                binding = ' forge=gerrit' if forge == 'gerrit' else ''
                (home / 'data' / 'projects.md').write_text(f'- sample [no-mistakes{binding}] - disposable scenario (added 2026-10-02)\n')
                run(['bash', 'bin/fm-promote.sh', task, '--mode', 'no-mistakes', '--yolo', 'off'])
                brief = home / 'data' / task / 'ship-instructions.md'
            output = brief.read_text()
            (evidence / f'{task}.md').write_text(output)
            line = next(line for line in output.splitlines() if line.startswith('Capture the exact PID'))
            warning = next(line for line in output.splitlines() if line.startswith('Never search the process table'))
            assert 'in the shell that launched the child' in line and 'with GNU tail' in line
            emitted = re.findall(r'`([^`]+)`', line)
            assert emitted == ['DRIVE_PID=$!', 'wait $DRIVE_PID', 'tail --pid=$DRIVE_PID -f /dev/null']
            assert 'pgrep' in warning and 'deadlocks' in warning
            if commands is None:
                commands = emitted
            assert commands == emitted
            logs.append(f'{task}: emitted identical child-PID commands and portability/self-match guidance\n{line}\n{warning}\n')

    capture, wait, tail = commands
    for command in (wait, tail):
        code = 'sleep 1 &\n' + capture + '\nprintf "parent=%s child=%s\\n" "$$" "$DRIVE_PID"\n[ "$DRIVE_PID" != "$$" ] || exit 10\n' + command + '\nprintf "child wait returned\\n"\n'
        started = time.monotonic()
        run(['bash', '-c', code, 'axi run safe-wait-adversary'])
        elapsed = time.monotonic() - started
        assert 0.8 < elapsed < 5
        logs.append(f'Emitted {command}: returned after child exit in {elapsed:.2f}s while launcher remained alive.\n')

    code = 'FPID=$(pgrep -f "axi run self-match-692731" | head -1); printf "parent=%s discovered=%s\\n" "$$" "$FPID"; [ "$FPID" = "$$" ] || exit 10; timeout 2 tail --pid=$FPID -f /dev/null; rc=$?; printf "legacy self-wait exit=%s (124 means timeout)\\n" "$rc"; [ "$rc" = 124 ]'
    run(['bash', '-c', code, 'axi run self-match-692731'])
finally:
    shutil.rmtree(home)
    (evidence / 'drive-wait-live.log').write_text('\n'.join(logs))
