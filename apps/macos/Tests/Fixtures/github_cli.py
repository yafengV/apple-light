#!/usr/bin/python3
"""Local GitHub CLI process fixture. Never accesses a network or user credentials."""
import json
import os
import pathlib
import sys

root = pathlib.Path.cwd() / ".git"
state_path = root / "github-fixture.json"
state = json.loads(state_path.read_text())
args = sys.argv[1:]
log = {"args": args}

def arg(flag):
    return args[args.index(flag) + 1]

if args[:2] == ["pr", "create"]:
    body_file = pathlib.Path(arg("--body-file"))
    log["body"] = body_file.read_text()
    log["bodyMode"] = oct(body_file.stat().st_mode & 0o777)
with (root / "github-requests.jsonl").open("a") as handle:
    handle.write(json.dumps(log) + "\n")

if args[:2] == ["auth", "status"]:
    if state.get("authFailure") or (state.get("inactiveFailure") and "--active" not in args):
        print("Please run gh auth login", file=sys.stderr)
        sys.exit(4)
    print("Authenticated fixture")
elif args[:2] == ["repo", "view"]:
    print(json.dumps({"nameWithOwner": "sample/project", "defaultBranchRef": {"name": "main"}}))
elif args[:2] == ["pr", "list"]:
    print(json.dumps(state.get("pullRequests", [])))
elif args[:2] == ["pr", "view"]:
    if arg("--repo") != "sample/project":
        print("Wrong repository", file=sys.stderr)
        sys.exit(2)
    item = next((item for item in state.get("pullRequests", [])
                 if str(item.get("number")) == args[2]), None)
    if item is None:
        print("PR not found", file=sys.stderr)
        sys.exit(1)
    details = {**item, "body": state.get("detailBody", ""),
               "state": state.get("detailState", "OPEN"),
               "reviewDecision": state.get("reviewDecision"),
               "mergeable": state.get("mergeable"),
               "statusCheckRollup": state.get("statusCheckRollup", [])}
    if state.get("detailMismatch"):
        details["url"] = "https://github.com/other/project/pull/42"
    print(json.dumps(details))
elif args and args[0] == "api":
    endpoint = next(value for value in args if value.startswith("repos/"))
    print(state["base"] if endpoint.endswith("/main") else state.get("published", state["head"]))
elif args[:2] == ["pr", "create"]:
    if state.get("createFailure"):
        print("Creation failed", file=sys.stderr)
        sys.exit(1)
    item = {"number": 42, "url": "https://github.com/sample/project/pull/42",
            "title": arg("--title"), "isDraft": "--draft" in args,
            "headRefName": arg("--head"), "baseRefName": arg("--base"), "isCrossRepository": False}
    state["pullRequests"] = [item]
    state_path.write_text(json.dumps(state))
    if state.get("failAfterCreate"):
        print("Connection interrupted after server accepted request", file=sys.stderr)
        sys.exit(1)
    print(state.get("resultURL", item["url"]))
else:
    print("Unsupported fixture command", args, file=sys.stderr)
    sys.exit(2)
