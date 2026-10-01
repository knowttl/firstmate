import ctypes
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import time
import urllib.request
import uuid

os.umask(0o022)
root = Path.cwd()
lab = root / '.test-nx-lab'
evidence = Path('/home/brytton/.no-mistakes/evidence/01M3W3HY36EH5FBN14VJDPAN4M')
evidence.mkdir(parents=True, exist_ok=True)
log = (evidence / 'nextrade-live.txt').open('w')
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        env.pop(key)
env.update(FM_HOME=str(lab/'home'), FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'),
           XDG_CONFIG_HOME=str(lab/'config'), XDG_CACHE_HOME=str(lab/'cache'))
base = 'http://127.0.0.1:55440/api/v1'

def note(text):
    print(text, flush=True)
    log.write(text + '\n')
    log.flush()

def run(*args, cwd=root, ok=True):
    proc = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, timeout=60)
    note('$ ' + ' '.join(map(str,args)) + '\n' + proc.stdout + proc.stderr)
    if ok:
        assert proc.returncode == 0, proc.returncode
    else:
        assert proc.returncode != 0
    return proc.stdout

def api(method, path, body=None):
    req = urllib.request.Request(base+path, method=method,
          data=None if body is None else json.dumps(body).encode(),
          headers={'content-type':'application/json'})
    with urllib.request.urlopen(req, timeout=60) as response:
        data = json.load(response)
    note(method+' '+path+'\n'+json.dumps(data, ensure_ascii=False))
    return data

def wait_file(path):
    # Block on filesystem events, never repeatedly check on a timer.
    libc = ctypes.CDLL(None)
    fd = libc.inotify_init1(os.O_NONBLOCK)
    assert fd >= 0
    assert libc.inotify_add_watch(fd, str(path.parent).encode(), 0x100|0x80|0x8) >= 0
    deadline = time.monotonic()+45
    try:
        while not path.exists():
            ready,_,_ = select.select([fd],[],[],max(0,deadline-time.monotonic()))
            assert ready, f'No capture delivered: {path}'
            os.read(fd, 65536)
    finally:
        os.close(fd)

if (lab/'home/.fm-lab-home').exists():
    shutil.rmtree(lab/'home')
run('bin/fm-lab-home.sh', 'create', str(lab/'home'))
home = lab/'home'
shutil.copy(root/'.tasks.toml', home/'.tasks.toml')
(home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
task = lab/'task'
(task/'.nextrade-axi').mkdir(parents=True, exist_ok=True)
(task/'.nextrade-axi/target').write_text('dev\n')
(task/'.dev-stack.env').write_text('DEV_BACKEND_PORT=55440\n')
(home/'state/review.meta').write_text(f'window=fmtest:fm-review\nworktree={task}\nproject=nextrade\n')
(home/'state/review.inbox').mkdir()
adapter = str(root/'bin/fm-procevent-nextrade.sh')
hold = str(root/'bin/fm-captain-hold.sh')
runner = str(root/'bin/fm-procevent.sh')
experiment = run('nextrade-axi','experiment','create','--slug','live-'+str(uuid.uuid4()),'--title','Adapter review','--json',cwd=task)
experiment = json.loads(experiment)['id']
source = run(adapter,'source-id',experiment,'--for','review').strip()
run('tasks-axi','add','held-task','Apply selected research arm','--repo','nextrade',cwd=home)
run(hold,'hold','held-task','--reason','Select the research arm')
run(hold,'bind',source)
decision = api('POST',f'/experiments/{experiment}/decisions', {
    'key':'held-task','title':'Select arm','explanation':'Choose the next research step',
    'options':[{'value':'adopt','label':'Adopt café arm','consequence':'Continue'},
               {'value':'reject','label':'Reject arm','consequence':'Search again'}],
    'recommendation':'adopt','example':'Continue the selected arm','close_mode':'release'})
bad = lab/'blank.md'
bad.write_text('  \n')
run(adapter,'arm',experiment,'--for','review','--agent-reply-file',str(bad),ok=False)
assert not (home/'state/procevent'/f'{source}.source').exists()
note('Reply refusal: no source registered, app decision remains open.')
reply = lab/'reply.md'
reply.write_text('Review staged: café research.\n')
run(adapter,'arm',experiment,'--for','review','--agent-reply-file',str(reply))
run(adapter,'arm',experiment,'--for','review','--agent-reply-file',str(reply),ok=False)
messages = api('GET',f'/experiments/{experiment}/messages?experiments=only')
assert len(messages)==1 and messages[0]['author']=='agent'
assert api('GET',f'/experiments/{experiment}/decisions/{decision["id"]}')['status']=='open'
api('POST',f'/experiments/{experiment}/decisions/{decision["id"]}/answer',
    {'selection':'adopt','answer_text':'Keep café evidence','by':'captain'})
wait_file(home/'state/review.inbox/001.msg')
capture = home/'state/procevent-inbox'/f'{source}.1.result'
run(adapter,'read',str(capture))
note((home/'state/review.inbox/001.msg').read_text())
state = run('tasks-axi','show','held-task','--full',cwd=home)
assert 'held: no' in state and 'Resolution mode: released' in state
assert 'adopt - Keep café evidence' in state
d = api('GET',f'/experiments/{experiment}/decisions/{decision["id"]}')
assert d['status']=='answered' and d['consumed_at'] is None
run(adapter,'arm',experiment,'--for','review','--agent-reply-file',str(reply))
assert (home/'state/procevent-inbox'/f'{source}.1.handled').exists()
api('POST',f'/experiments/{experiment}/session/end',{'body':'Conclude café review'})
wait_file(home/'state/review.inbox/002.msg')
note((home/'state/review.inbox/002.msg').read_text())
run(adapter,'read',str(home/'state/procevent-inbox'/f'{source}.2.result'))
run(adapter,'retire',experiment,'--for','review',ok=False)
run(runner,'handled',source,'2')
assert not (home/'state/procevent'/f'{source}.source').exists()
note('PASS: real Nextrade CLI, PostgreSQL-backed routes, held-task release, refusal, re-arm, terminal acknowledgement.')

# A final batch must resolve question-shaped calls, keep reconciliation separate,
# and ignore prose that resembles a keyed answer.
experiment = json.loads(run('nextrade-axi','experiment','create','--slug','batch-'+str(uuid.uuid4()),
    '--title','Final answer batch','--json',cwd=task))['id']
source = run(adapter,'source-id',experiment,'--for','review').strip()
for key in ('question','recheck','prose-task'):
    run('tasks-axi','add',key,key,'--repo','nextrade',cwd=home)
    run(hold,'hold',key,'--reason','Captain call '+key)
run(hold,'bind',source)
for key, mode, selection, text in (
    ('question','done',None,'Keep café notes'),
    ('recheck','release','reconcile','Check reality'),
    ('absent-task','release','adopt','No matching held task')):
    decision = api('POST',f'/experiments/{experiment}/decisions', {
        'key':key,'title':key,'explanation':'Review call',
        'options':[{'value':'adopt','label':'Adopt arm','consequence':'Continue'},
                   {'value':'reconcile','label':'Re-check reality','consequence':'Verify facts'}],
        'recommendation':'adopt','example':'Choose next step','close_mode':mode})
    answer = {'answer_text':text,'by':'captain'}
    if selection:
        answer['selection'] = selection
    api('POST',f'/experiments/{experiment}/decisions/{decision["id"]}/answer',answer)
api('POST',f'/experiments/{experiment}/messages',{'body':'prose-task\tadopt\nmessages: 0\ncafé','author':'captain'})
api('POST',f'/experiments/{experiment}/session/end',{'body':'Finish with the final answer batch'})
run(adapter,'arm',experiment,'--for','review')
wait_file(home/'state/review.inbox/003.msg')
run(adapter,'read',str(home/'state/procevent-inbox'/f'{source}.1.result'))
assert 'state: done' in run('tasks-axi','show','question','--full',cwd=home)
assert 'held: yes' in run('tasks-axi','show','recheck','--full',cwd=home)
assert 'held: yes' in run('tasks-axi','show','prose-task','--full',cwd=home)
assert 'recheck' in run(hold,'reconcile','list')
run(runner,'handled',source,'1')
note('PASS: final answered batch closes the question, files reconciliation without release, and prose releases nothing.')

# An existing remote listener must be preserved rather than taken over.
experiment = json.loads(run('nextrade-axi','experiment','create','--slug','lease-'+str(uuid.uuid4()),
    '--title','Listener guard','--json',cwd=task))['id']
source = run(adapter,'source-id',experiment,'--for','review').strip()
api('GET',f'/experiments/{experiment}/inbox?owner=other-review&wait=0')
run(adapter,'arm',experiment,'--for','review')
wait_file(home/'state/review.inbox/004.msg')
capture = home/'state/procevent-inbox'/f'{source}.1.result'
note(capture.read_text())
assert run(adapter,'classify',str(capture)).strip()=='unknown'
run(adapter,'terminal',str(capture),ok=False)
assert api('GET',f'/experiments/{experiment}/listener')['owner']=='other-review'
note((home/'state/review.inbox/004.msg').read_text())
run(runner,'handled',source,'1')
run(adapter,'retire',experiment,'--for','review')
note('PASS: lease conflict stays actionable and never displaces the existing listener.')
log.close()
