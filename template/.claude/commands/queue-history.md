---
allowed-tools: Bash(ls:*), Bash(bin/backlog:*)
description: Історія — задачі, прибрані в backlog/completed/
---

Історія (`backlog/completed/`):

!`ls -1 backlog/completed/`

Тут `ls`, а не `task list`, свідомо: прибрані задачі випадають зі списків і з
пошуку, але лишаються доступними за ID — `bin/backlog task view <id> --plain`
читає їх так само, як активні.

Покинуті задачі — це не історія: вони йдуть у `backlog/archive/` через
`task archive` і зникають з системи назовсім.
