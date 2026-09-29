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
if args and args[0] == "api" and "--input" in args:
    input_file = pathlib.Path(arg("--input"))
    log["input"] = json.loads(input_file.read_text())
    log["inputMode"] = oct(input_file.stat().st_mode & 0o777)
    log["folderMode"] = oct(input_file.parent.stat().st_mode & 0o777)
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
    if state.get("detailReadGate"):
        import time
        (root / "detail-read-held").touch()
        deadline = time.monotonic() + 10
        while not (root / "detail-read-release").exists():
            if time.monotonic() >= deadline:
                sys.exit("Detail read gate was not released")
            time.sleep(0.01)
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
    if "--method" in args and arg("--method") == "POST" and args[1].endswith("/pulls/42/comments"):
        assert args[1] == "repos/sample/project/pulls/42/comments"
        fields = log["input"]
        status = state.get("inlineStatus", 201)
        if status != 201:
            print("HTTP/2.0 " + str(status) + " Fixture\nContent-Type: application/json\n\n" + json.dumps({"message": "Fixture rejection"}))
            sys.exit(1)
        if state.get("inlineNoAccept"):
            sys.exit("Connection interrupted before any confirmed result")
        sequence = state.get("discussionSequence", 0) + 1
        identifier = "inline-" + str(sequence)
        viewer = state.get("viewer", "fixture-author")
        code = {"id": identifier, "__typename": "PullRequestReviewComment", "body": fields["body"],
            "createdAt": "2026-09-29T12:00:00Z", "url": "https://github.com/sample/project/pull/42#" + identifier,
            "author": {"login": viewer, "__typename": "User"}, "viewerCanUpdate": True, "viewerCanDelete": True,
            "commit": {"oid": fields["commit_id"]}, "originalCommit": {"oid": fields["commit_id"]}, "diffHunk": state.get("prDiff", "")}
        thread = {"id": "thread-" + identifier, "path": fields["path"], "line": fields["line"], "originalLine": fields["line"],
            "diffSide": fields["side"], "startLine": fields.get("start_line"), "originalStartLine": fields.get("start_line"),
            "startDiffSide": fields.get("start_side"), "isResolved": False, "isOutdated": False,
            "viewerCanReply": True, "viewerCanResolve": True, "viewerCanUnresolve": True, "comments": [code]}
        state.setdefault("discussionThreads", []).append(thread)
        if state.get("inlineDuplicate"):
            duplicate = json.loads(json.dumps(thread)); duplicate["id"] += "-duplicate"; duplicate["comments"][0]["id"] += "-duplicate"
            state["discussionThreads"].append(duplicate)
        state["discussionSequence"], state["discussionAccepted"] = sequence, True
        state_path.write_text(json.dumps(state))
        if state.get("inlineLostResponse"):
            sys.exit("Connection interrupted after accepting comment")
        receipt = {"node_id": identifier, "id": sequence, "body": fields["body"], "user": {"login": viewer},
            "commit_id": fields["commit_id"], "path": fields["path"], "line": fields["line"], "side": fields["side"],
            "start_line": fields.get("start_line"), "start_side": fields.get("start_side"),
            "pull_request_url": "https://api.github.com/repos/sample/project/pulls/42"}
        receipt.update(state.get("inlineReceiptOverride", {}))
        print("HTTP/2.0 201 Created\nContent-Type: application/json\n\n" + json.dumps(receipt))
        sys.exit(0)
    if args[1] == "graphql" and "--input" in args:
        # New discussion queries are isolated from the existing merge metadata fixture.
        import re
        import time
        payload = log["input"]
        query, variables = payload["query"], payload["variables"]
        if "ShipiOSPRGeneratedAttributes" in query:
            if state.get("attributesGate"):
                (root / "attributes-held").touch()
                deadline = time.monotonic() + 10
                while not (root / "attributes-release").exists():
                    if time.monotonic() >= deadline:
                        sys.exit("Attributes read gate was not released")
                    time.sleep(0.01)
            if state.get("attributesFailure"):
                sys.exit("Attributes unavailable")
            objects = {"nameWithOwner": state.get("attributesRepository", "sample/project")}
            for key, expression in variables.items():
                if key in ["owner", "name"]:
                    continue
                revision, path = expression.split(":", 1)
                assert revision == state["head"]
                text = state.get("attributeSources", {}).get(path)
                objects["f" + key[1:]] = None if text is None else {
                    "__typename": "Blob", "text": text, "isBinary": False,
                    "isTruncated": False, "byteSize": len(text.encode("utf-8"))}
            objects.update(state.get("attributesOverride", {}))
            if state.get("attributesOmitAlias"):
                objects.pop("f0", None)
            if state.get("headAfterAttributes"):
                state["detailHead"] = state["headAfterAttributes"]
            if state.get("baseAfterAttributes"):
                state["codeBase"] = state["baseAfterAttributes"]
            state_path.write_text(json.dumps(state))
            response = {"data": {"repository": objects}}
            if state.get("attributesGraphQLError"):
                response["errors"] = [{"message": "Attributes GraphQL failure"}]
            print(json.dumps(response))
            sys.exit(0)
        if "ShipiOSPRCodeIdentity" in query:
            if state.get("codeBaseAtIdentityRead"):
                count = state.get("codeIdentityReadCount", 0) + 1
                state["codeIdentityReadCount"] = count
                if str(count) in state["codeBaseAtIdentityRead"]:
                    state["codeBase"] = state["codeBaseAtIdentityRead"][str(count)]
                state_path.write_text(json.dumps(state))
            if state.get("codeReadFailure"):
                sys.exit("Code identity unavailable")
            item = next(x for x in state["pullRequests"] if x["number"] == variables["number"])
            pr = {**item, "id": state.get("codeNodeID", "pr-node"),
                  "baseRefOid": state.get("codeBase", "b" * 40),
                  "headRefOid": state.get("detailHead", state["head"]),
                  "changedFiles": state.get("codeChangedFiles", 1)}
            if state.get("codeMismatch"):
                pr["url"] = "https://github.com/other/project/pull/42"
            print(json.dumps({"data": {"repository": {
                "nameWithOwner": state.get("metadataRepository", "sample/project"), "pullRequest": pr}}}))
            sys.exit(0)
        if state.get("discussionDelay"):
            time.sleep(state["discussionDelay"])
        if state.get("discussionFailure") or (state.get("discussionFailureAfterAction") and state.get("discussionAccepted")):
            sys.exit("Discussion unavailable")
        timeline = state.get("discussionTimeline", [])
        threads = state.get("discussionThreads", [])
        viewer = state.get("viewer", "fixture-author")

        def comment(identifier, body, kind="IssueComment"):
            return {"id": identifier, "body": body, "__typename": kind,
                    "createdAt": "2026-09-29T12:00:00Z", "url": "https://github.com/sample/project/pull/42#" + identifier,
                    "author": {"login": viewer, "__typename": "User"}, "viewerCanUpdate": True, "viewerCanDelete": True}

        def connection(items, cursor=None):
            size = state.get("discussionPageSize", 100)
            start = int(cursor or 0)
            nodes = items[start:start + size]
            if cursor and state.get("discussionDuplicate"):
                nodes = items[:size]
            total = len(items) + (1 if cursor and state.get("discussionCountDrift") else 0)
            more = start + size < len(items)
            end = str(start + size) if more else None
            if state.get("discussionRepeatCursor") and more:
                end = "1"
            return {"totalCount": total, "nodes": nodes, "pageInfo": {"hasNextPage": more, "endCursor": end}}

        if "ShipiOSPRMentionUsers" in query:
            if state.get("mentionDelay"):
                time.sleep(state["mentionDelay"])
            if state.get("mentionFailure"):
                sys.exit("Mention search unavailable")
            item = next(x for x in state["pullRequests"] if x["number"] == variables["number"])
            participants = state.get("mentionParticipants", [{"login": "reviewer", "avatarUrl": "https://avatars.githubusercontent.com/u/1"}])
            mentionable = state.get("mentionableUsers", [])
            term = variables["search"].lower()
            mentionable = [x for x in mentionable if term in x["login"].lower() or term in x.get("name", "").lower()][:10]
            response = {"data": {"viewer": {"login": state.get("mentionViewer", viewer)}, "repository": {
                "nameWithOwner": state.get("metadataRepository", "sample/project"),
                "mentionableUsers": {"nodes": mentionable}, "pullRequest": {
                    "number": 43 if state.get("mentionMismatch") else item["number"], "url": item["url"],
                    "participants": {"nodes": participants[:100]}}}}}
            if state.get("mentionGraphQLError"):
                response["errors"] = [{"message": "Mention GraphQL error"}]
            print(json.dumps(response))
            sys.exit(0)

        if "mutation ShipiOSPRDiscussionMutation" in query:
            if state.get("discussionMutationDelay"):
                time.sleep(state["discussionMutationDelay"])
            if state.get("discussionMutationFailure"):
                sys.exit("Discussion write denied")
            if state.get("discussionMutationGraphQLError"):
                print(json.dumps({"data": {"action": None}, "errors": [{"message": "Comment rejected by GitHub"}]}))
                sys.exit(0)
            mutation = re.search(r"action:(\w+)\(", query).group(1)
            fields = variables["input"]
            result = {"clientMutationId": fields["clientMutationId"]}
            sequence = state.get("discussionSequence", 0) + 1
            identifier = "created-" + str(sequence)
            target = next((x for x in threads if x["id"] == fields.get("threadId", fields.get("pullRequestReviewThreadId"))), None)
            all_comments = timeline + [x for t in threads for x in t["comments"]]
            node = next((x for x in all_comments if x.get("id") == fields.get("id", fields.get("pullRequestReviewId", fields.get("pullRequestReviewCommentId")))), None)
            if mutation == "addComment":
                assert fields["subjectId"] == "pr-node"
                node = comment(identifier, fields["body"])
                timeline.append(node); result["commentEdge"] = {"node": node}
            elif mutation == "addPullRequestReviewThreadReply":
                assert target is not None
                node = comment(identifier, fields["body"], "PullRequestReviewComment")
                target["comments"].append(node); result["comment"] = node
            elif mutation == "addPullRequestReview":
                assert fields["pullRequestId"] == "pr-node"
                node = comment(identifier, fields.get("body", ""), "PullRequestReview")
                node["state"] = {"COMMENT": "COMMENTED", "APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED"}[fields["event"]]
                node["commit"] = {"oid": fields["commitOID"]}
                timeline.append(node); result["pullRequestReview"] = node
                node["submittedAt"] = node["createdAt"]
                state["reviewDecision"] = node["state"]
            elif mutation.startswith("update"):
                assert node is not None
                node["body"] = fields["body"]
                name = {"updateIssueComment": "issueComment", "updatePullRequestReview": "pullRequestReview",
                        "updatePullRequestReviewComment": "pullRequestReviewComment"}[mutation]
                result[name] = node
            elif mutation.startswith("delete"):
                timeline = [x for x in timeline if x.get("id") != fields["id"]]
                for thread in threads:
                    thread["comments"] = [x for x in thread["comments"] if x["id"] != fields["id"]]
                threads = [x for x in threads if x["comments"]]
            elif mutation in ["resolveReviewThread", "unresolveReviewThread"]:
                assert target is not None
                target["isResolved"] = mutation == "resolveReviewThread"
                result["thread"] = {"id": target["id"], "isResolved": target["isResolved"]}
            else:
                sys.exit("Unsupported discussion mutation")
            state["discussionTimeline"], state["discussionThreads"] = timeline, threads
            state["discussionSequence"], state["discussionAccepted"] = sequence, True
            state_path.write_text(json.dumps(state))
            if state.get("discussionFailAfterAction"):
                sys.exit("Connection interrupted after accepting discussion mutation")
            print(json.dumps({"data": {"action": result}}))
            sys.exit(0)
        if "ShipiOSPRDiscussionReplies" in query:
            target = next((x for x in threads if x["id"] == variables["id"]), None)
            print(json.dumps({"data": {"node": {"id": target["id"], "comments": connection(target["comments"], variables.get("after"))} if target else None}}))
            sys.exit(0)
        assert variables["owner"] == "sample" and variables["name"] == "project" and variables["number"] == 42
        item = next(x for x in state["pullRequests"] if x["number"] == 42)
        pr = {**item, "id": "pr-node", "state": state.get("detailState", "OPEN"),
              "headRefOid": state.get("detailHead", state["head"]), "author": {"login": state.get("author", "fixture-author")},
              "createdAt": state.get("discussionCreatedAt"), "mergedAt": state.get("discussionMergedAt"),
              "mergedBy": {"login": state.get("discussionMergedBy")}}
        if "commits(last:100)" in query:
            commits = state.get("discussionCommits", [x["commit"] for x in timeline if x.get("__typename") == "PullRequestCommit"])
            pr["commits"] = {"nodes": [{"commit": x} for x in commits[-100:]],
                "pageInfo": {"hasPreviousPage": len(commits) > 100}}
            if state.get("discussionMalformedCommits"):
                pr["commits"]["pageInfo"] = {}
        if "comments(first:100,after:" in query:
            pr["comments"] = connection([x for x in timeline if x.get("__typename") == "IssueComment"], variables.get("after"))
        if "reviews(first:100,after:" in query:
            pr["reviews"] = connection([x for x in timeline if x.get("__typename") == "PullRequestReview"], variables.get("after"))
        if "reviewThreads(first:" in query:
            page = connection(threads, variables.get("after"))
            page["nodes"] = [{**x, "comments": connection(x["comments"])} for x in page["nodes"]]
            pr["reviewThreads"] = page
        response = {"data": {"viewer": {"login": viewer}, "repository": {
            "nameWithOwner": state.get("metadataRepository", "sample/project"), "pullRequest": pr}}}
        if state.get("discussionGraphQLError"):
            response["errors"] = [{"message": "Fixture GraphQL discussion error"}]
        if "comments(first:100,after:" in query and state.get("discussionHeadAfterPage"):
            state["detailHead"] = state["discussionHeadAfterPage"]
            state_path.write_text(json.dumps(state))
        if "comments(first:100,after:" in query and state.get("discussionViewerAfterPage"):
            state["viewer"] = state["discussionViewerAfterPage"]
            state_path.write_text(json.dumps(state))
        print(json.dumps(response))
        sys.exit(0)
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
    if state.get("codeDiffGate"):
        import time
        (root / "code-diff-held").touch()
        deadline = time.monotonic() + 10
        while not (root / "code-diff-release").exists():
            if time.monotonic() >= deadline:
                sys.exit("Code diff gate was not released")
            time.sleep(0.01)
        state = json.loads(state_path.read_text())
    if state.get("diffFailure"):
        sys.exit("Fixture diff unavailable")
    if state.get("headAfterDiff"):
        state["detailHead"] = state["headAfterDiff"]
        state_path.write_text(json.dumps(state))
    if state.get("baseAfterDiff"):
        state["codeBase"] = state["baseAfterDiff"]
        state_path.write_text(json.dumps(state))
    print(state.get("prDiff", "diff --git a/file.txt b/file.txt\n--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-old\n+new"))
else:
    print("Unsupported fixture command", args, file=sys.stderr)
    sys.exit(2)
