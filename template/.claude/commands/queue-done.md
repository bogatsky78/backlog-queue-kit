---
allowed-tools: Bash(bin/backlog:*)
description: Зроблене, що ще лежить на дошці
---

Зроблене (`Done`), ще не прибране в історію:

!`bin/backlog task list -s Done --plain --sort ordinal`

Прибирає звідси в `backlog/completed/` команда `bin/backlog task complete <id>` —
**лише за явним словом власника**. Чернетки й ідеї — окремо: `bin/backlog draft list`.
