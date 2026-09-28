#!/usr/bin/python3
"""Replace SSH in disposable Git fixtures with a local receive-pack process."""
import json
import os
import pathlib
import sys

state = json.loads((pathlib.Path.cwd() / ".git/github-fixture.json").read_text())
if sys.argv[-1] != "git-receive-pack 'sample/project.git'" or "git@github.com" not in sys.argv:
    sys.exit("Unexpected Git transport request")
os.execv("/usr/bin/git", ["git", "receive-pack", state["remotePath"]])
