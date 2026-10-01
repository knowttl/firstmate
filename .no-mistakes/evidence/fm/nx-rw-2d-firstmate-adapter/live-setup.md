Live validation used the installed nextrade-axi CLI and unmodified Nextrade backend routes from origin/main commit 3edbe892e5bdda9740d103b83826407391693c3f.
The disposable FastAPI host mounted the real experiments, decisions, messages, and catalog routers with a PostgreSQL 16.15 database, entirely within the gate workspace.
No CLI, route, service, database, or lifecycle owner was mocked in this live round.
Task delivery was verified through the persisted steering inbox, without launching an LLM worker or using shared fleet panes.
The setup scripts are retained as launch.py, serve.py, and drive.py beside the CLI/API transcript nextrade-live.txt and HTTP server log nextrade-backend.log.
Python dependencies and extracted PostgreSQL packages were installed only into disposable directories in the worktree.
Initial setup attempts encountered Python 3.12 incompatibility and group-writable fixture directories; using the available Python 3.14 and a 022 fixture umask resolved both before the successful round.
The app Workspace page is absent from this source version, so answers were entered through the real public decision API.
The Workspace-page interaction remains the programme's deferred W4 acceptance check.
No renderer code changed in this slice; the reviewer-visible evidence is the CLI transcript, public API responses, and persisted task state.
