import os
from pathlib import Path
import subprocess
import threading

root = Path.cwd()
evidence = Path('/home/brytton/.no-mistakes/evidence/01M3W3HY36EH5FBN14VJDPAN4M')
evidence.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, PYTHONPATH=f'{root}/.test-nextrade-stack/backend:{root}/.test-nx-lab',
           POSTGRES_USER='lab', POSTGRES_DB='lab', POSTGRES_HOST='127.0.0.1', POSTGRES_PORT='55439')
python = str(root/'.test-nx-py14/bin/python')
server = subprocess.Popen([python, '-m', 'uvicorn', 'serve:app', '--host', '127.0.0.1', '--port', '55440'],
                          env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    with (evidence/'nextrade-backend.log').open('w') as log:
        for line in server.stdout:
            log.write(line)
            log.flush()
            print(line, end='', flush=True)
            if 'Uvicorn running on' in line:
                break
        else:
            raise RuntimeError('Backend did not start')
        def drain():
            for line in server.stdout:
                log.write(line)
                log.flush()
        thread = threading.Thread(target=drain)
        thread.start()
        result = subprocess.run([python, str(root/'.test-nx-lab/drive.py')])
        server.terminate()
        server.wait(timeout=20)
        thread.join()
        raise SystemExit(result.returncode)
finally:
    if server.poll() is None:
        server.terminate()
        server.wait(timeout=20)
