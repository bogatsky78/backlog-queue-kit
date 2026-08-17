#!/usr/bin/env python3
"""
PreToolUse guard for the project task queue in `backlog/`.

The queue is driven by the Backlog.md CLI through `bin/backlog`. Task, draft,
doc, decision and milestone files are the CLI's own storage: it rewrites the
frontmatter from its internal model on every edit, so anything written into
those files by hand is dropped without a word. (Verified on v1.50.1: custom
frontmatter keys vanish on the next `task edit`. The markdown body survives,
but the CLI owns the section order, so hand-editing is still a coin flip.)

Three checks:

1. WRITE TOOLS  — `Write` / `Edit` / `NotebookEdit` into `backlog/` are denied
                  with the command to use instead. `backlog/config.yml` is
                  exempt: `statuses` and `definition_of_done` cannot be set via
                  `config set` at all and have to be edited in the file.

2. SHELL        — a mutating shell verb (`>`, `>>`, `mv`, `cp`, `rm`, `sed -i`,
                  `tee`, `touch`, …) aimed at a protected path is denied.
                  `bin/backlog` itself passes. This is a heuristic: it reliably
                  catches the accidental direct edit it is written for, and does
                  not pretend to stop a deliberate bypass.

3. CLARIFY GATE — moving a task to `In Progress` is denied while unresolved
                  `[NEEDS CLARIFICATION: ...]` markers remain in its file. This
                  is the one place the "an agent does not guess" rule stops
                  being an agreement and becomes a check.

On an unexpected internal error the hook fails OPEN (exit 0) and appends a
traceback to .claude/hooks/enforce-queue-cli.error.log, so a bug here can never
brick the queue. The decisions themselves fail CLOSED.


EXTENDING THIS HOOK
-------------------

Run the suite after every change:

    python3 .claude/hooks/enforce-queue-cli.test.py

The quote-aware segmenter is imported from ~/.claude/hooks/enforce-repo-agent.py
rather than reimplemented — every parsing trap it handles (operators inside
quotes, `$(...)` substitutions, heredoc bodies, wrapper programs) applies here
word for word, and a second copy would drift. If that hook is absent the shell
branch is skipped and the write-tool branch still runs; the reason lands in
.claude/hooks/enforce-queue-cli.error.log.

- **Exempt another path**: add it to EXEMPT_PATHS, with a comment saying why
  the CLI cannot manage it.
- **Catch another mutating verb**: add it to MUTATING_VERBS (any positional
  argument counts) or DEST_ONLY_VERBS (only the last one does, so that copying
  a task file *out* of the queue stays allowed).
"""

import importlib.util
import json
import os
import re
import sys
import traceback

HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(HOOK_DIR, "..", ".."))

# Everything under here is CLI-owned storage.
PROTECTED_ROOT = os.path.join(PROJECT_ROOT, "backlog")

# Not everything under backlog/ is CLI-owned in the same way.
#
# `statuses` and `definition_of_done` are rejected by `backlog config set`
# ("cannot be set directly"), so the config file is the supported way to change
# them. Note the CLI drops YAML comments whenever it rewrites this file — the
# explanations live in .claude/skills/queue/SKILL.md instead.
#
# Docs and decisions are stub-and-free-body: `doc create` / `decision create`
# take a title and nothing else — there is no content flag, and no later command
# ever rewrites the body (verified on v1.50.1: hand-written text survives every
# doc/decision/search command and gets indexed by search). Guarding them would
# make both features unusable, since hand-editing is the only way to fill them.
#
# Tasks, drafts, completed and archive stay protected: those DO have full CLI
# write paths (--plan, --ac, --append-notes, --final-summary, status), and there
# the CLI rebuilds frontmatter from its own model on every edit.
EXEMPT_PATHS = {os.path.join(PROTECTED_ROOT, "config.yml")}
EXEMPT_DIRS = (
    os.path.join(PROTECTED_ROOT, "docs"),
    os.path.join(PROTECTED_ROOT, "decisions"),
)

SKILL_HINT = (
    "Use `bin/backlog` instead — see .claude/skills/queue/SKILL.md. "
    "`bin/backlog task view <id> --plain` reads, `bin/backlog task edit <id> ...` writes."
)

# Verbs where any protected path among the arguments is a write.
MUTATING_VERBS = {
    "rm", "rmdir", "truncate", "touch", "tee", "dd", "shred", "unlink",
    "chmod", "chown", "ln", "split", "patch",
}

# Verbs where only the destination (the last positional) is written to, so that
# `cp backlog/tasks/x.md /tmp/` — reading a task out — stays allowed.
DEST_ONLY_VERBS = {"cp", "mv", "install", "rsync"}

# In-place editors: the file named is rewritten, whichever position it is in.
INPLACE = {
    "sed": {"-i", "--in-place"},
    "perl": {"-i"},
    "ruby": {"-i"},
}

CLARIFICATION_MARKER = "[NEEDS CLARIFICATION:"

# The Definition of Done is boilerplate the CLI stamps into every task from
# backlog/config.yml, and one of our DoD items is literally "no unresolved
# [NEEDS CLARIFICATION: ...] left". Scanning it would deny every task in the
# project — which is exactly what happened the first time this ran. The gate
# reads the parts a human wrote, not the checklist the tool generated.
GENERATED_BLOCKS = re.compile(
    r"<!--\s*(DOD|ACCEPTANCE_CRITERIA):BEGIN\s*-->.*?<!--\s*\1:END\s*-->",
    re.S,
)

# `bin/backlog task edit TASK-12 -s "In Progress"` and its long/equals forms.
STATUS_FLAG = re.compile(r"(?:^|\s)(?:-s|--status)(?:\s+|=)(?P<q>['\"]?)(?P<value>[^'\"\s]+(?:\s+[^'\"\s]+)*?)(?P=q)(?=\s|$)")

# Subtasks are hierarchical — `TASK-2.9` is subtask 9 of TASK-2 — so the number
# is not simply \d+. Miss the dotted form and the gate silently never fires on
# a subtask, which is where the detailed work actually lives.
TASK_ID = re.compile(r"\b([A-Za-z][A-Za-z0-9_]*)-(\d+(?:\.\d+)*)\b")


def _log(message):
    try:
        with open(os.path.join(HOOK_DIR, "enforce-queue-cli.error.log"), "a") as fh:
            fh.write(message.rstrip() + "\n")
    except OSError:
        pass


def _load_segmenter():
    """Reuse the quote-aware command parser from the global repository hook.

    Returns None instead of raising when that hook is missing: the shell branch
    is the only part that needs it, and losing the Write/Edit branch as
    collateral would take the protection that actually matters with it.
    """
    path = os.path.expanduser("~/.claude/hooks/enforce-repo-agent.py")
    try:
        spec = importlib.util.spec_from_file_location("enforce_repo_agent", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    except Exception:
        _log(f"segmenter unavailable at {path}; shell checks skipped\n"
             + traceback.format_exc())
        return None


def deny(reason):
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def resolve(path, cwd=None):
    """Absolute path, resolved against the project root for relative input."""
    if not path:
        return ""
    expanded = os.path.expanduser(path)
    if not os.path.isabs(expanded):
        expanded = os.path.join(cwd or PROJECT_ROOT, expanded)
    return os.path.normpath(expanded)


def is_protected(path, cwd=None):
    """True for CLI-owned queue files, false for the config file and outside."""
    full = resolve(path, cwd)
    if not full:
        return False
    if full in EXEMPT_PATHS:
        return False
    for exempt in EXEMPT_DIRS:
        if full == exempt or full.startswith(exempt + os.sep):
            return False
    return full == PROTECTED_ROOT or full.startswith(PROTECTED_ROOT + os.sep)


def looks_like_path(token):
    return not token.startswith("-") and token not in {"<", ">", ">>", "|"}


def redirect_targets(segment):
    """Paths on the right of an unquoted `>` / `>>`.

    Written char by char rather than with a regex because the whole point is to
    ignore redirect operators inside quotes: `grep "> backlog/x" file` reads a
    file, it does not write one.
    """
    targets = []
    quote = None
    i = 0
    n = len(segment)
    while i < n:
        ch = segment[i]
        if quote:
            if ch == "\\" and quote == '"' and i + 1 < n:
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            i += 2
            continue
        if ch == ">":
            j = i + 1
            while j < n and segment[j] == ">":
                j += 1
            while j < n and segment[j] in " \t":
                j += 1
            start = j
            while j < n and segment[j] not in " \t\n><|;&":
                j += 1
            if j > start:
                targets.append(segment[start:j].strip("'\""))
            i = j
            continue
        i += 1
    return targets


def check_write_tool(payload):
    tool = payload.get("tool_name")
    if tool not in {"Write", "Edit", "NotebookEdit"}:
        return
    tool_input = payload.get("tool_input", {}) or {}
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not is_protected(path):
        return
    deny(
        f"`{tool}` may not touch {os.path.relpath(resolve(path), PROJECT_ROOT)} — the queue under "
        "backlog/ is storage owned by the Backlog.md CLI, which rewrites frontmatter "
        f"from its own model and silently drops anything written by hand. {SKILL_HINT}"
    )


def check_shell(payload, seg):
    if payload.get("tool_name") != "Bash":
        return
    command = (payload.get("tool_input", {}) or {}).get("command", "")
    if not command:
        return

    stripped = seg.strip_heredocs(command)
    to_check = list(seg.segments(stripped))
    for inner in seg.substitutions(stripped):
        to_check.extend(seg.segments(inner))

    for segment in to_check:
        tokens = seg.tokenize(segment)
        if not tokens:
            continue
        prog, rest = seg.leading_program(tokens)
        if prog is None:
            continue

        # `bin/backlog` is the sanctioned way in; never block it.
        if prog == "backlog":
            check_clarification_gate(segment, rest)
            continue

        for target in redirect_targets(segment):
            if is_protected(target):
                deny(
                    f"Redirecting into {target} writes a queue file directly. {SKILL_HINT}"
                )

        positional = [t for t in rest if looks_like_path(t)]

        if prog in MUTATING_VERBS:
            hit = next((t for t in positional if is_protected(t)), None)
            if hit:
                deny(f"`{prog} {hit}` modifies a queue file directly. {SKILL_HINT}")

        if prog in DEST_ONLY_VERBS and positional:
            dest = positional[-1]
            if is_protected(dest):
                deny(f"`{prog} ... {dest}` writes into the queue directly. {SKILL_HINT}")

        if prog in INPLACE and (set(rest) & INPLACE[prog] or
                                any(t.startswith("-i") for t in rest if t.startswith("-"))):
            hit = next((t for t in positional if is_protected(t)), None)
            if hit:
                deny(f"`{prog} -i {hit}` rewrites a queue file in place. {SKILL_HINT}")


def task_files(task_id):
    """Every file that could hold this task: active, completed or draft."""
    match = TASK_ID.search(task_id or "")
    if not match:
        return []
    number = match.group(2)   # "12", or "2.9" for a subtask
    found = []
    for sub in ("tasks", "completed", "drafts"):
        directory = os.path.join(PROTECTED_ROOT, sub)
        if not os.path.isdir(directory):
            continue
        prefix = ("draft-" if sub == "drafts" else "task-") + number + " "
        for name in os.listdir(directory):
            if name.lower().startswith(prefix.lower()):
                found.append(os.path.join(directory, name))
    return found


def check_clarification_gate(segment, rest):
    """Refuse to start work that still contains an unanswered question."""
    status = STATUS_FLAG.search(segment)
    if not status or status.group("value").strip().lower() != "in progress":
        return
    if "edit" not in rest:
        return

    task_id = next((t for t in rest if TASK_ID.fullmatch(t)), None)
    if not task_id:
        return

    for path in task_files(task_id):
        try:
            with open(path, encoding="utf-8") as fh:
                body = GENERATED_BLOCKS.sub("", fh.read())
        except OSError:
            continue
        if CLARIFICATION_MARKER in body:
            questions = re.findall(r"\[NEEDS CLARIFICATION:([^\]]*)\]", body)
            listed = "; ".join(q.strip() for q in questions[:3])
            deny(
                f"{task_id} still has {len(questions)} unresolved "
                f"[NEEDS CLARIFICATION] marker(s): {listed}. Work does not start on a "
                "guess — get the answer from the owner or from an agent, replace the "
                "marker with what was decided, then set the status."
            )


def main():
    payload = json.loads(sys.stdin.read())

    # Write/Edit first, and without the segmenter: it is the branch that stops
    # the accidental direct edit this hook exists for.
    check_write_tool(payload)

    seg = _load_segmenter()
    if seg is not None:
        check_shell(payload, seg)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        log = os.path.join(HOOK_DIR, "enforce-queue-cli.error.log")
        try:
            with open(log, "a") as fh:
                fh.write(traceback.format_exc() + "\n")
        except Exception:
            pass
    sys.exit(0)
