#!/usr/bin/env python3
"""A stand-in for the `chaos workspace` / `chaos plan` commands soulshouse-plan
uses, holding state in $FAKE_CHAOS_STATE. It enforces the rules the real CLI
enforced when probed (Chaos 47.14.8, 11 Nov): structural changes need the plan
revision, transitions need the task revision and a reason, and a plan with
open tasks cannot complete."""
import json
import os
import sys
import uuid

path = os.environ["FAKE_CHAOS_STATE"]
try:
    state = json.load(open(path))
except (OSError, ValueError):
    state = {"workspaces": [], "plans": {}, "attachments": {}}
args = sys.argv[1:]
MOVES = {"start": ("pending", "in_progress"), "complete": ("in_progress", "completed"),
         "block": ("in_progress", "blocked"), "unblock": ("blocked", "in_progress"),
         "cancel": (None, "cancelled")}


def save():
    json.dump(state, open(path, "w"))


def fail(message):
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def find(ref):
    for plan in state["plans"].values():
        if ref in (plan["id"], plan["reference"]):
            return plan
    fail("plan not found")


def view(plan):
    head = {key: plan[key] for key in ("id", "reference", "title", "status", "revision")}
    return {"capabilities": {"available": True}, "plan": head,
            "tasks": [dict(task, depth=0) for task in plan["tasks"]], "next_offset": None}


if args[:2] == ["workspace", "list"]:
    print(json.dumps({"items": state["workspaces"], "next_offset": None}))
elif args[:2] == ["workspace", "create"]:
    item = {"id": str(uuid.uuid4()), "code": f"{len(state['workspaces']):06d}", "name": args[2], "revision": 1}
    state["workspaces"].append(item)
    save()
    print(json.dumps(item))
elif args[:2] == ["plan", "read"]:
    print(json.dumps(view(find(args[-1]))))
elif args[:2] == ["plan", "attach"]:
    state["attachments"][args[2]] = find(args[3])["id"]
    save()
    print(json.dumps(state["attachments"][args[2]]))
elif args[:2] == ["plan", "detach"]:
    state["attachments"].pop(args[2], None)
    save()
    print("null")
elif args[:2] == ["plan", "change"]:
    change = json.loads(args[2])
    action = change["action"]
    if action == "create":
        plan = {"id": str(uuid.uuid4()), "reference": f"{change['workspace']}/{len(state['plans']):04d}",
                "title": change["title"], "status": "active", "revision": 1, "tasks": []}
        state["plans"][plan["id"]] = plan
        save()
        print(json.dumps({"plan": view(plan)["plan"], "task": None}))
        sys.exit(0)
    plan = find(change["plan"])
    structural = action in ("add_task", "complete", "cancel", "edit")
    if structural and change.get("expected_revision") != plan["revision"]:
        fail(json.dumps({"error": "revision_conflict", "current_revision": plan["revision"]}))
    task = None
    if action == "add_task":
        task = {"id": str(uuid.uuid4()), "reference": f"T{len(plan['tasks']) + 1}", "title": change["title"],
                "status": "pending", "revision": 1, "parent_id": None, "position": change["position"]}
        plan["tasks"].append(task)
    elif action == "transition":
        if not change.get("reason"):
            fail("a transition requires a reason")
        task = next((t for t in plan["tasks"] if t["reference"] == change["task"]), None) or fail("task not found")
        if change["task_revision"] != task["revision"]:
            fail("task revision conflict")
        before, after = MOVES[change["event"]]
        if before and task["status"] != before:
            fail(f"cannot {change['event']} a {task['status']} task")
        task["status"] = after
        task["revision"] += 1
    elif action == "complete":
        if any(t["status"] in ("pending", "in_progress", "blocked") for t in plan["tasks"]):
            fail("plan has unfinished tasks")
        plan["status"] = "completed"
    elif action == "cancel":
        plan["status"] = "cancelled"
    if structural:
        plan["revision"] += 1
    save()
    print(json.dumps({"plan": view(plan)["plan"], "task": task}))
else:
    fail(f"unsupported fake command {args}")
