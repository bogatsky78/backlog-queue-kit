---
allowed-tools: Bash(bin/backlog:*)
description: Уся черга — активне, відкладене й зроблене, без історії
---

Черга проєкту в порядку `ordinal`:

!`bin/backlog task list --plain --sort ordinal`

Це повний стан черги. Не читай файли в `backlog/` — усе, що потрібно далі,
дістається через `bin/backlog task view <id> --plain`.
