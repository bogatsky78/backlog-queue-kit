"""Test suite for enforce-queue-cli.py.

    python3 .claude/hooks/enforce-queue-cli.test.py

Exits non-zero if any case fails. Run it after every change to the hook.

Each case is (tool, payload_bits, expected). The ALLOW cases matter as much as
the DENY ones: a queue guard that blocks `grep "rm backlog/x" file`, or reading
a task file out to /tmp, or `bin/backlog` itself, gets switched off — and a hook
that is switched off protects nothing.

The clarification-gate cases write real files into a temporary queue tree, since
the gate's whole job is to read the task file before letting the status change.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HOOK_DIR, "enforce-queue-cli.py")
PROJECT_ROOT = os.path.abspath(os.path.join(HOOK_DIR, "..", ".."))
QUEUE = os.path.join(PROJECT_ROOT, "backlog")


def run(payload):
    p = subprocess.run([sys.executable, HOOK], input=json.dumps(payload),
                       capture_output=True, text=True)
    if p.stdout.strip():
        return "DENY", json.loads(p.stdout)["hookSpecificOutput"]["permissionDecisionReason"]
    return "ALLOW", p.stderr.strip()


def bash(cmd):
    return {"tool_name": "Bash", "tool_input": {"command": cmd}}


def write(path, tool="Write"):
    key = "notebook_path" if tool == "NotebookEdit" else "file_path"
    return {"tool_name": tool, "tool_input": {key: path}}


CASES = [
    # --- the CLI is the way in, and must never be blocked ---
    (bash("bin/backlog task list --plain"), "ALLOW"),
    (bash('bin/backlog task edit TASK-3 --append-notes "виміряне значення пливе"'), "ALLOW"),
    (bash('bin/backlog task create "Нова задача" -s "To Do"'), "ALLOW"),
    (bash("bin/backlog task archive TASK-3"), "ALLOW"),
    (bash("bin/backlog doc create 'Розбір' -p research"), "ALLOW"),
    (bash("./bin/backlog board"), "ALLOW"),

    # --- direct edits to queue storage ---
    (write(os.path.join(QUEUE, "tasks", "task-3 - Щось.md")), "DENY"),
    (write("backlog/tasks/task-3 - Щось.md"), "DENY"),
    (write("backlog/drafts/draft-1 - Ідея.md", tool="Edit"), "DENY"),
    (write("backlog/completed/task-9 - Зроблено.md", tool="Edit"), "DENY"),
    (write("backlog/archive/tasks/task-4 - Покинуто.md", tool="Edit"), "DENY"),
    (write("backlog/tasks/notes.ipynb", tool="NotebookEdit"), "DENY"),

    # --- docs and decisions are stub-and-free-body: `doc create` /
    #     `decision create` take a title and nothing else, and no later command
    #     rewrites the body, so hand-editing is the ONLY way to fill them ---
    (write("backlog/docs/research/doc-1 - Розбір.md", tool="Edit"), "ALLOW"),
    (write("backlog/docs/doc-2 - Нотатка.md"), "ALLOW"),
    (write("backlog/decisions/decision-1 - Рішення.md"), "ALLOW"),
    (bash("echo x >> backlog/docs/research/doc-1.md"), "ALLOW"),
    # but the queue itself is still off limits by the same shell verb
    (bash("echo x >> backlog/tasks/task-3.md"), "DENY"),

    # --- config.yml is exempt: `config set` refuses statuses and
    #     definition_of_done outright, so the file is the only way ---
    (write("backlog/config.yml", tool="Edit"), "ALLOW"),
    (write(os.path.join(QUEUE, "config.yml")), "ALLOW"),

    # --- files outside the queue are none of this hook's business ---
    (write("README.md", tool="Edit"), "ALLOW"),
    (write("docs/notes.md", tool="Edit"), "ALLOW"),
    (write("/tmp/backlog/tasks/task-1 - X.md"), "ALLOW"),

    # --- mutating shell verbs aimed at the queue ---
    (bash("echo x > backlog/tasks/task-3 - Щось.md"), "DENY"),
    (bash("echo x >> 'backlog/tasks/task-3 - Щось.md'"), "DENY"),
    (bash("rm backlog/tasks/task-3.md"), "DENY"),
    (bash("rm -rf backlog/drafts"), "DENY"),
    (bash("mv /tmp/x.md backlog/tasks/x.md"), "DENY"),
    (bash("cp /tmp/x.md backlog/tasks/x.md"), "DENY"),
    (bash("sed -i 's/To Do/Done/' backlog/tasks/task-3.md"), "DENY"),
    (bash("touch backlog/tasks/task-9.md"), "DENY"),
    (bash("cat /tmp/x | tee backlog/tasks/task-3.md"), "DENY"),
    (bash("ls && rm backlog/tasks/task-3.md"), "DENY"),
    (bash("echo $(rm backlog/tasks/task-3.md)"), "DENY"),

    # --- reading the queue stays free ---
    (bash("cat backlog/tasks/task-3.md"), "ALLOW"),
    (bash("ls backlog/tasks/"), "ALLOW"),
    (bash("grep -r 'NEEDS CLARIFICATION' backlog/"), "ALLOW"),
    (bash("wc -l backlog/tasks/*.md"), "ALLOW"),
    # a task file copied *out* is a backup, not a queue write
    (bash("cp backlog/tasks/task-3.md /tmp/x.md"), "ALLOW"),
    (bash("sed -n '1,20p' backlog/tasks/task-3.md"), "ALLOW"),

    # --- quoting: an operator inside quotes is text, not a command ---
    (bash('grep "rm backlog/tasks/x.md" /tmp/notes.txt'), "ALLOW"),
    (bash("grep '> backlog/tasks/x.md' /tmp/notes.txt"), "ALLOW"),
    (bash('echo "не чіпай rm backlog/tasks/x.md"'), "ALLOW"),

    # --- mutating verbs pointed somewhere else ---
    (bash("rm /tmp/backlog-copy.md"), "ALLOW"),
    (bash("echo x > /tmp/scratch.md"), "ALLOW"),
    (bash("sed -i 's/a/b/' README.md"), "ALLOW"),
]

# --- clarification gate, against a real queue tree ---------------------------
# The Definition of Done the CLI stamps into EVERY task quotes the marker
# verbatim. Scanning it denied every task in the project the first time this
# ran, so a clean task carries the real boilerplate here on purpose.
DOD_BOILERPLATE = """
## Definition of Done
<!-- DOD:BEGIN -->
- [ ] #1 Перевірки з Acceptance Criteria відмічені (--check-ac)
- [ ] #5 Незакритих [NEEDS CLARIFICATION: ...] у задачі не лишилось
<!-- DOD:END -->
"""

CLEAN_TASK = """---
id: TASK-901
title: Чиста задача
status: To Do
---

## Description

Усе визначено.
""" + DOD_BOILERPLATE

# A subtask, to prove the gate fires on the hierarchical `TASK-2.9` form too —
# it did not, because the id pattern only matched a bare \\d+.
DIRTY_SUBTASK = """---
id: TASK-901.3
title: Підзадача з питанням
status: To Do
---

## Implementation Plan

взяти профіль [NEEDS CLARIFICATION: свій чи успадкований?]
""" + DOD_BOILERPLATE

DIRTY_TASK = """---
id: TASK-902
title: Задача з питанням
status: To Do
---

## Description

Усе, крім одного, визначено.

## Implementation Plan

1. взяти ставку [NEEDS CLARIFICATION: з довідника чи з договору?]
2. застосувати
""" + DOD_BOILERPLATE

temp_files = []


def seed():
    tasks = os.path.join(QUEUE, "tasks")
    os.makedirs(tasks, exist_ok=True)
    for number, body in (("901", CLEAN_TASK), ("902", DIRTY_TASK),
                         ("901.3", DIRTY_SUBTASK)):
        path = os.path.join(tasks, f"task-{number} - Тест гачка.md")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        temp_files.append(path)


def unseed():
    for path in temp_files:
        try:
            os.remove(path)
        except OSError:
            pass


seed()
CASES += [
    # no markers left -> work may start
    (bash('bin/backlog task edit TASK-901 -s "In Progress"'), "ALLOW"),
    # an open question -> it may not
    (bash('bin/backlog task edit TASK-902 -s "In Progress"'), "DENY"),
    (bash("bin/backlog task edit TASK-902 --status 'In Progress'"), "DENY"),
    # the gate is about starting work, not about touching the task at all
    (bash('bin/backlog task edit TASK-902 --append-notes "уточнив у власника"'), "ALLOW"),
    (bash('bin/backlog task edit TASK-902 -s "Later"'), "ALLOW"),
    (bash('bin/backlog task edit TASK-902 -s Done'), "ALLOW"),
    (bash("bin/backlog task view TASK-902 --plain"), "ALLOW"),
    # a task that does not exist is not this hook's problem
    (bash('bin/backlog task edit TASK-9999 -s "In Progress"'), "ALLOW"),

    # --- the two regressions this gate shipped with, both caught by running it
    #     against the real migrated queue rather than a hand-made fixture ---
    # the DoD boilerplate quotes the marker in every single task, so scanning it
    # denied the whole project
    (bash('bin/backlog task edit TASK-901 -s "In Progress"'), "ALLOW"),
    # subtask ids are hierarchical; a bare \d+ pattern never matched them, so
    # the gate silently did nothing where the detailed work lives
    (bash('bin/backlog task edit TASK-901.3 -s "In Progress"'), "DENY"),
]

fails = 0
try:
    for payload, expected in CASES:
        got, reason = run(payload)
        ok = got == expected
        if not ok:
            fails += 1
        mark = "ok  " if ok else "FAIL"
        tool = payload["tool_name"]
        detail = payload["tool_input"].get("command") \
            or payload["tool_input"].get("file_path") \
            or payload["tool_input"].get("notebook_path", "")
        flat = detail.replace("\n", "\\n")
        print(f"{mark} [{tool:14}] {expected:5} -> {got:5} | {flat[:62]}")
        if not ok and reason:
            print(f"        {reason[:140]}")
finally:
    unseed()

print(f"\n{len(CASES) - fails}/{len(CASES)} passed")
sys.exit(1 if fails else 0)
