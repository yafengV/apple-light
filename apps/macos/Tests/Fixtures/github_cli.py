#!/usr/bin/python3
"""Local GitHub CLI process fixture. Never accesses a network or user credentials."""
import json
import os
import pathlib
import sys
import subprocess
import urllib.parse

root = pathlib.Path.cwd() / ".git"
state_path = root / "github-fixture.json"
state = json.loads(state_path.read_text())
args = sys.argv[1:]
log = {"args": args}

def arg(flag):
    return args[args.index(flag) + 1]

if args[:2] == ["pr", "create"] or (args[:2] == ["pr", "edit"] and "--body-file" in args):
    body_file = pathlib.Path(arg("--body-file"))
    log["body"] = body_file.read_bytes().decode("utf-8")
    log["bodyMode"] = oct(body_file.stat().st_mode & 0o777)
    log["folderMode"] = oct(body_file.parent.stat().st_mode & 0o777)
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
    if state.get("detailReadDelay"):
        import time
        time.sleep(state["detailReadDelay"])
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
               "statusCheckRollup": state.get("statusCheckRollup", []),
               "headRefOid": state.get("detailHead", state.get("head")),
               "mergeStateStatus": state.get("mergeStateStatus", "CLEAN")}
    if state.get("detailFailureAfterAction") and state.get("actionAccepted"):
        sys.exit("Cannot refresh after action")
    if state.get("detailMismatch"):
        details["url"] = "https://github.com/other/project/pull/42"
    print(json.dumps(details))
elif args and args[0] == "api":
    if args[1] == "graphql":
        if state.get("metadataFailure"):
            sys.exit("Metadata unavailable")
        item = next((item for item in state.get("pullRequests", [])
                     if "number=" + str(item.get("number")) in args), None)
        if item is None:
            sys.exit("PR not found")
        request = {**item, "state": state.get("detailState", "OPEN"),
                   "headRefOid": state.get("metadataHead", state.get("detailHead", state.get("head"))),
                   "author": {"login": state.get("author", "fixture-author")},
                   "autoMergeRequest": {"enabledAt": "2026-09-29T00:00:00Z"} if state.get("autoMerge") else None}
        response = {"data": {"viewer": {"login": state.get("viewer", "fixture-author")},
                    "repository": {"nameWithOwner": state.get("metadataRepository", "sample/project"),
                    "mergeCommitAllowed": state.get("allowMerge", True),
                    "squashMergeAllowed": state.get("allowSquash", True), "pullRequest": request}}}
        if state.get("graphqlError"):
            response["errors"] = [{"message": "Fixture partial error"}]
        print(json.dumps(response))
        sys.exit(0)
    endpoint = next(value for value in args if value.startswith("repos/"))
    if "/commits/" in endpoint and any(kind in endpoint for kind in ["/check-runs?", "/status?", "/check-suites?"]):
        kind = "checkRuns" if "/check-runs?" in endpoint else "checkSuites" if "/check-suites?" in endpoint else "commitStatuses"
        if state.get(kind + "Delay"):
            import time
            time.sleep(state[kind + "Delay"])
        if state.get(kind + "Failure"):
            sys.exit("Fixture checks unavailable")
        head = endpoint.split("/commits/", 1)[1].split("/", 1)[0]
        page = int(urllib.parse.parse_qs(urllib.parse.urlparse(endpoint).query).get("page", ["1"])[0])
        if kind == "checkRuns":
            payload = state.get("checkRunsPages", [{"total_count": 0, "check_runs": []}])
        elif kind == "commitStatuses":
            payload = state.get("commitStatusesPages", [{"sha": head, "state": "success", "total_count": 0, "statuses": []}])
        else:
            payload = state.get("checkSuites", {"total_count": 0, "check_suites": []})
        if isinstance(payload, list):
            payload = payload[page - 1] if len(payload) >= page else {"total_count": 0, "check_runs": []}
        if state.get(kind + "FailurePage") == page:
            sys.exit("Fixture later page unavailable")
        if state.get("headAfterChecks") and kind == "checkRuns":
            state["detailHead"] = state["headAfterChecks"]
            state_path.write_text(json.dumps(state))
        if state.get("baseAfterChecks") and kind == "checkRuns":
            state["pullRequests"][0]["baseRefName"] = state["baseAfterChecks"]
            state_path.write_text(json.dumps(state))
        print(payload if isinstance(payload, str) else json.dumps(payload))
        sys.exit(0)
    if state.get("remotePath"):
        branch = urllib.parse.unquote(endpoint.split("/git/ref/heads/", 1)[1])
        result = subprocess.run(["/usr/bin/git", "--git-dir=" + state["remotePath"],
                                 "rev-parse", "--verify", "refs/heads/" + branch], capture_output=True, text=True)
        if result.returncode:
            sys.exit("Remote branch not found")
        print(result.stdout.strip())
    else:
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
elif args[:2] == ["pr", "merge"]:
    if state.get("mutationDelay"):
        import time
        time.sleep(state["mutationDelay"])
    if state.get("mergeRestriction") and "--merge" in args:
        state["allowMerge"] = False
        state_path.write_text(json.dumps(state))
        sys.exit("Merge commits are not allowed on this repository")
    if state.get("mutationFailure"):
        sys.exit("Merge failed")
    if state.get("raceHead"):
        state["detailHead"] = state["raceHead"]
        state_path.write_text(json.dumps(state))
    if "--match-head-commit" in args and arg("--match-head-commit") != state.get("detailHead", state["head"]):
        sys.exit("Head commit does not match")
    if "--disable-auto" in args:
        state["autoMerge"] = False
    elif "--auto" in args:
        state["autoMerge"] = True
    elif not state.get("mergeQueue"):
        state["detailState"] = "MERGED"
    state["actionAccepted"] = True
    state_path.write_text(json.dumps(state))
    if state.get("failAfterAction"):
        sys.exit("Connection interrupted after server accepted request")
    print("Fixture action accepted")
elif args[:2] == ["pr", "edit"]:
    if state.get("editDelay"):
        import time
        time.sleep(state["editDelay"])
    if state.get("editFailure"):
        sys.exit("Fixture edit denied")
    item = next((item for item in state.get("pullRequests", []) if str(item.get("number")) == args[2]), None)
    if item is None or arg("--repo") != "sample/project":
        sys.exit("Wrong PR")
    if "--title" in args:
        item["title"] = arg("--title")
    if "--body-file" in args:
        state["detailBody"] = pathlib.Path(arg("--body-file")).read_bytes().decode("utf-8")
    state["actionAccepted"] = True
    state_path.write_text(json.dumps(state))
    if state.get("failAfterAction"):
        sys.exit("Connection interrupted after server accepted request")
    print("Fixture edit accepted")
elif args[:2] == ["pr", "diff"]:
    if state.get("diffFailure"):
        sys.exit("Fixture diff unavailable")
    if state.get("headAfterDiff"):
        state["detailHead"] = state["headAfterDiff"]
        state_path.write_text(json.dumps(state))
    print(state.get("prDiff", "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new"))
else:
    print("Unsupported fixture command", args, file=sys.stderr)
    sys.exit(2)
