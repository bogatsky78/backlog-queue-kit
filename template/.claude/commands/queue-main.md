---
allowed-tools: Bash(bin/backlog:*)
description: Активна черга — те, що робимо зараз і робимо далі
---

Активна черга (`To Do` і `In Progress`) у порядку `ordinal`:

!`bin/backlog task list --exclude-status "Later,Done" --plain --sort ordinal`

Перша задача в `To Do` — наступна робота, якщо власник не сказав інакше.
