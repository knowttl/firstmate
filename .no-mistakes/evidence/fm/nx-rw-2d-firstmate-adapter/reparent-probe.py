import os
import subprocess
import sys

# Release the child only after its original parent has exited.
reader, writer = os.pipe()
parent = subprocess.Popen([sys.executable, '-c', '''
import os, sys
fd = int(sys.argv[1])
if os.fork():
    os._exit(0)
os.read(fd, 1)
print('adopted orphan ppid:', os.getppid(), flush=True)
''', str(reader)], pass_fds=(reader,), stdout=subprocess.PIPE, text=True)
parent.wait(timeout=5)
os.write(writer, b'x')
os.close(writer)
os.close(reader)
print(parent.stdout.read(), end='')
