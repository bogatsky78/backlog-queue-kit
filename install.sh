#!/usr/bin/env bash
# Ставить і оновлює чергу задач на Backlog.md у вказаному проєкті.
#
#   ./install.sh [--dry-run] /шлях/до/проєкту
#       Перше встановлення. Наявних файлів НЕ ЧІПАЄ — перелічує в кінці.
#
#   ./install.sh --update [--dry-run] [--force] /шлях/до/проєкту
#       Оновлення. Перезаписує файли комплекту (обгортка, гачок, тести,
#       команди, скіл) і не торкається проєктного: .claude/queue-project.md,
#       .claude/settings.json (тільки злиття), backlog/ (це дані черги).
#
# Що вважається «комплектовим» — усе дерево template/, крім явного списку
# PROJECT_OWNED нижче. Тобто новий файл у комплекті стає оновлюваним сам, і про
# нього не треба згадувати у двох місцях.
#
# Оновлення відмовляється затирати файл, який у цільовому репозиторії має
# незакомічені зміни: локальна правка гачка зникла б без слідів. --force
# знімає цю перевірку.
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG_MD_HOME="${BACKLOG_MD_HOME:-/data/backlog.md}"
BACKLOG_MD_TAG="v1.50.1"

# Файли, які належать проєкту, а не комплекту: `--update` їх не чіпає, але
# створює, якщо їх ще немає (проєкт, поставлений старішою версією комплекту).
PROJECT_OWNED=(".claude/queue-project.md")

die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
add()  { printf '  \033[32m+\033[0m %s\n' "$*"; }
upd()  { printf '  \033[36m~\033[0m %s\n' "$*"; }
same() { printf '  \033[90m=\033[0m %s\n' "$*"; }
keep() { printf '  \033[33m=\033[0m %s %s\n' "$1" "${2:-}"; }

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=install
FORCE=0
DRY=0
args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--update)  MODE=update; shift ;;
		--force)   FORCE=1; shift ;;
		--dry-run) DRY=1; shift ;;
		-h|--help) usage; exit 0 ;;
		-*)        die "невідомий ключ: $1" ;;
		*)         args+=("$1"); shift ;;
	esac
done
[[ ${#args[@]} -eq 1 ]] || { usage; exit 1; }

TARGET="$(cd "${args[0]}" 2>/dev/null && pwd)" || die "немає такої теки: ${args[0]}"
[[ "$TARGET" != "$KIT" ]] || die "цільова тека — це сам комплект"

is_project_owned() {
	local f="$1" p
	for p in "${PROJECT_OWNED[@]}"; do
		[[ "$f" == "$p" ]] && return 0
	done
	return 1
}

# Незакомічені зміни у файлі цільового репозиторію. Порожньо — чисто або не git.
dirty() { git -C "$TARGET" status --porcelain --untracked-files=all -- "$1" 2>/dev/null; }

echo "Комплект: $KIT"
echo "Проєкт:   $TARGET"
printf 'Режим:    %s' "$MODE"
[[ $DRY -eq 1 ]] && printf ' (пробний прогін, нічого не пишу)'
printf '\n\n'

# --- двигун -----------------------------------------------------------------
if [[ ! -f "$BACKLOG_MD_HOME/src/cli.ts" ]]; then
	die "немає клону Backlog.md у $BACKLOG_MD_HOME. Спершу:
  git clone --branch $BACKLOG_MD_TAG --depth 1 https://github.com/MrLesk/Backlog.md.git $BACKLOG_MD_HOME
  cd $BACKLOG_MD_HOME && bun install --frozen-lockfile --omit=optional"
fi
[[ -d "$BACKLOG_MD_HOME/node_modules" ]] || die "у $BACKLOG_MD_HOME не встановлені залежності:
  cd $BACKLOG_MD_HOME && bun install --frozen-lockfile --omit=optional"
add "двигун на місці: $BACKLOG_MD_HOME"

# --- файли ------------------------------------------------------------------
mapfile -t FILES < <(cd "$KIT/template" && find . -type f -printf '%P\n' | sort)

# Крок 1 (лише --update): що змінилось і чи нічого не затремо.
to_write=""
blocked=()
if [[ "$MODE" == update ]]; then
	for rel in "${FILES[@]}"; do
		src="$KIT/template/$rel"; dst="$TARGET/$rel"
		if is_project_owned "$rel"; then
			[[ -e "$dst" ]] || to_write+="|$rel"
			continue
		fi
		if [[ ! -e "$dst" ]] || ! cmp -s "$src" "$dst"; then
			if [[ -e "$dst" && $FORCE -eq 0 && -n "$(dirty "$rel")" ]]; then
				blocked+=("$rel")
			else
				to_write+="|$rel"
			fi
		fi
	done

	if [[ ${#blocked[@]} -gt 0 ]]; then
		printf '\n\033[31mНезакомічені зміни у файлах, які оновлення затерло б:\033[0m\n' >&2
		printf '  %s\n' "${blocked[@]}" >&2
		die "
Закомітьте або відкатіть їх — і повторіть. Якщо це правка, яку варто мати в
комплекті, перенесіть її туди, а не тримайте локальною: наступне оновлення
поставить те саме питання. Затерти навмисно — --force."
	fi
fi

echo
echo "Файли:"
existing=()
changed=0
for rel in "${FILES[@]}"; do
	src="$KIT/template/$rel"; dst="$TARGET/$rel"
	label=add

	if [[ "$MODE" == update ]]; then
		if is_project_owned "$rel" && [[ -e "$dst" ]]; then
			keep "$rel" "(проєктний, не чіпаю)"
			continue
		fi
		if [[ "$to_write" != *"|$rel"* ]]; then
			same "$rel"
			continue
		fi
		[[ -e "$dst" ]] && label=upd
	else
		if [[ -e "$dst" ]]; then
			keep "$rel" "(уже є, не чіпаю)"
			existing+=("$rel")
			continue
		fi
	fi

	if [[ $DRY -eq 0 ]]; then
		mkdir -p "$(dirname "$dst")"
		cp "$src" "$dst"
		[[ "$rel" == bin/* ]] && chmod +x "$dst"
	fi
	$label "$rel"
	changed=$((changed + 1))
done
[[ $changed -eq 0 ]] && echo "  (нічого змінювати)"

# --- settings.json (злиття, ніколи не перезапис) ----------------------------
echo
echo "Дозволи й гачок:"
if [[ $DRY -eq 1 ]]; then
	echo "  (пробний прогін — settings.json не чіпаю)"
else
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
if any(h.get("command") == cmd for entry in pre for h in entry.get("hooks", [])):
    print("  = гачок уже зареєстрований")
else:
    pre.append(wanted)
    changed.append("реєстрація гачка PreToolUse")

# Писати лише коли справді є що додати. json.dump нормалізує весь файл —
# порожні рядки, якими розділені групи дозволів, зникають, — тож зайвий
# перезапис коштує людині її ж форматування ні за що.
if changed:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(settings, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    for c in changed:
        print(f"  + {c}")
    print("  ! файл перезаписаний json-ом: групування порожніми рядками втрачено")
else:
    print("  = нічого не змінилось, файл не чіпав")
PY
fi

# --- .gitignore (дописування, ніколи не перезапис) --------------------------
gi="$TARGET/.gitignore"
for line in "backlog/.locks/" ".claude/hooks/*.error.log"; do
	if [[ -f "$gi" ]] && grep -qxF "$line" "$gi"; then
		continue
	fi
	[[ $DRY -eq 0 ]] && printf '%s\n' "$line" >> "$gi"
	add ".gitignore: $line"
done

# --- решта ------------------------------------------------------------------
if [[ "$MODE" == update ]]; then
	cat <<EOF

────────────────────────────────────────────────────────────────────────
Оновлено. Проєктного не торкався: .claude/queue-project.md і backlog/,
а settings.json тільки дозливався.

Перевірити:

     cd $TARGET
     python3 .claude/hooks/enforce-queue-cli.test.py
     bin/backlog task list --plain

Новий текст скіла й зміни в settings.json почнуть діяти з **наступної** сесії
Claude Code.
EOF
else
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
		echo "Не перезаписано. Якщо це оновлення комплекту, а не перше"
		echo "встановлення — повторіть із \`--update\`:"
		printf '  %s\n' "${existing[@]}"
	fi
fi
