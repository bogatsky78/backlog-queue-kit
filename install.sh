#!/usr/bin/env bash
# Ставить чергу задач на Backlog.md у вказаний проєкт.
#
#   ./install.sh /шлях/до/проєкту
#
# Копіює шаблон, зливає дозволи й гачок у .claude/settings.json, і друкує ті
# кроки, які мусить зробити людина: `backlog init` (він інтерактивний навіть із
# --defaults настільки, що краще бачити його вивід) і два ключі в config.yml,
# яких CLI не дає поставити командою.
#
# Нічого не перезаписує без запиту: наявні файли пропускає й перелічує в кінці.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG_MD_HOME="${BACKLOG_MD_HOME:-/data/backlog.md}"
BACKLOG_MD_TAG="v1.50.1"

die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
ok()  { printf '  \033[32m+\033[0m %s\n' "$*"; }
skip(){ printf '  \033[33m=\033[0m %s (уже є, не чіпаю)\n' "$*"; }

[[ $# -eq 1 ]] || die "Використання: $0 /шлях/до/проєкту"
TARGET="$(cd "$1" 2>/dev/null && pwd)" || die "немає такої теки: $1"
[[ "$TARGET" != "$KIT" ]] || die "цільова тека — це сам комплект"

echo "Комплект: $KIT"
echo "Проєкт:   $TARGET"
echo

# --- 1. клон двигуна --------------------------------------------------------
if [[ ! -f "$BACKLOG_MD_HOME/src/cli.ts" ]]; then
	die "немає клону Backlog.md у $BACKLOG_MD_HOME. Спершу:
  git clone --branch $BACKLOG_MD_TAG --depth 1 https://github.com/MrLesk/Backlog.md.git $BACKLOG_MD_HOME
  cd $BACKLOG_MD_HOME && bun install --frozen-lockfile --omit=optional"
fi
[[ -d "$BACKLOG_MD_HOME/node_modules" ]] || die "у $BACKLOG_MD_HOME не встановлені залежності:
  cd $BACKLOG_MD_HOME && bun install --frozen-lockfile --omit=optional"
ok "двигун на місці: $BACKLOG_MD_HOME"

# --- 2. файли шаблону -------------------------------------------------------
echo
echo "Файли:"
existing=()
while IFS= read -r rel; do
	src="$KIT/template/$rel"
	dst="$TARGET/$rel"
	if [[ -e "$dst" ]]; then
		skip "$rel"
		existing+=("$rel")
		continue
	fi
	mkdir -p "$(dirname "$dst")"
	cp "$src" "$dst"
	[[ "$rel" == bin/* ]] && chmod +x "$dst"
	ok "$rel"
done < <(cd "$KIT/template" && find . -type f -printf '%P\n' | sort)

# --- 3. settings.json -------------------------------------------------------
echo
echo "Дозволи й гачок:"
python3 - "$TARGET" "$KIT/snippets/settings.json" <<'PY'
import json, os, sys

target, snippet_path = sys.argv[1], sys.argv[2]
path = os.path.join(target, ".claude", "settings.json")
snippet = json.load(open(snippet_path, encoding="utf-8"))
snippet.pop("_comment", None)

if os.path.exists(path):
    settings = json.load(open(path, encoding="utf-8"))
else:
    settings = {"$schema": "https://json.schemastore.org/claude-code-settings.json"}

changed = []

allow = settings.setdefault("permissions", {}).setdefault("allow", [])
for rule in snippet["permissions"]["allow"]:
    if rule not in allow:
        allow.insert(0, rule)
        changed.append(f"дозвіл {rule}")

pre = settings.setdefault("hooks", {}).setdefault("PreToolUse", [])
wanted = snippet["hooks"]["PreToolUse"][0]
cmd = wanted["hooks"][0]["command"]
already = any(h.get("command") == cmd
              for entry in pre for h in entry.get("hooks", []))
if already:
    print("  = гачок уже зареєстрований")
else:
    pre.append(wanted)
    changed.append("реєстрація гачка PreToolUse")

os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(settings, fh, ensure_ascii=False, indent=2)
    fh.write("\n")

for c in changed:
    print(f"  + {c}")
if not changed:
    print("  = нічого не змінилось")
PY

# --- 4. .gitignore ----------------------------------------------------------
gi="$TARGET/.gitignore"
for line in "backlog/.locks/" ".claude/hooks/*.error.log"; do
	if [[ -f "$gi" ]] && grep -qxF "$line" "$gi"; then
		continue
	fi
	printf '%s\n' "$line" >> "$gi"
	ok ".gitignore: $line"
done

# --- 5. решта — людині -----------------------------------------------------
cat <<EOF

────────────────────────────────────────────────────────────────────────
Лишилось три кроки, які скрипт свідомо не робить сам.

1. Ініціалізувати чергу (\`--agent-instructions none\` обов'язково, інакше
   майстер допише в ваш CLAUDE.md англійський блок із вимогою бігати
   \`backlog instructions overview\` перед кожним запитом):

     cd $TARGET
     bin/backlog init "<назва проєкту>" --defaults \\
       --agent-instructions none --integration-mode cli

2. Дописати в \`backlog/config.yml\` два ключі, яких \`config set\` не приймає —
   зразок і пояснення у \`$KIT/snippets/config.yml\`:

     statuses: ["To Do", "In Progress", "Later", "Done"]
     definition_of_done: [...]

3. Заповнити \`.claude/queue-project.md\` — рішення власника, чого тут не
   делегують, куди йде багатослівний вивід. Скіл посилається туди по
   фіксованому шляху.

Перевірити, що все стало:

     python3 .claude/hooks/enforce-queue-cli.test.py
     bin/backlog task list --plain

Гачок почне діяти з **наступної** сесії Claude Code: settings.json читається
при старті.
EOF

if [[ ${#existing[@]} -gt 0 ]]; then
	echo
	echo "Не перезаписано (порівняйте руками, якщо оновлюєте комплект):"
	printf '  %s\n' "${existing[@]}"
fi
