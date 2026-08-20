#!/usr/bin/env bash
# Ставить і оновлює чергу задач на Backlog.md у проєкті.
#
#   ./install.sh [--dry-run] [--no-unit] [/шлях/до/проєкту]
#       Перше встановлення. Наявних файлів НЕ ЧІПАЄ — перелічує в кінці.
#
#   ./install.sh --update [--dry-run] [--force] [--no-unit] [/шлях/до/проєкту]
#       Оновлення. Перезаписує файли комплекту (обгортка, гачок, тести,
#       команди, скіл) і не торкається проєктного: .claude/queue-project.md,
#       .claude/settings.json (тільки злиття), backlog/ (це дані черги).
#
# Шлях можна не вказувати. Тоді проєкт — поточна тека, а якщо скрипт запущено
# зсередини комплекту (комплект склонований у проєкт) — тека над комплектом.
# Виведений так шлях мусить бути git-репозиторієм: інакше легко поставити чергу
# на пів каталогу вище й не помітити.
#
# Наприкінці скрипт ставить systemd-юніт користувача, який тримає веб-UI черги
# піднятим: підбирає вільний порт, закріплює його за проєктом і вмикає сервіс.
# --no-unit це пропускає.
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

usage() { sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

MODE=install
FORCE=0
DRY=0
WANT_UNIT=1
args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--update)  MODE=update; shift ;;
		--force)   FORCE=1; shift ;;
		--dry-run) DRY=1; shift ;;
		--no-unit) WANT_UNIT=0; shift ;;
		-h|--help) usage; exit 0 ;;
		-*)        die "невідомий ключ: $1" ;;
		*)         args+=("$1"); shift ;;
	esac
done
[[ ${#args[@]} -le 1 ]] || { usage; exit 1; }

if [[ ${#args[@]} -eq 1 ]]; then
	TARGET="$(cd "${args[0]}" 2>/dev/null && pwd)" || die "немає такої теки: ${args[0]}"
else
	# Без аргументу: зсередини комплекту цілимось на теку над ним (комплект
	# склонований у проєкт), інакше — на поточну теку.
	if [[ "$PWD" == "$KIT" || "$PWD" == "$KIT"/* ]]; then
		TARGET="$(dirname "$KIT")"
	else
		TARGET="$PWD"
	fi
	# Шлях ніхто не називав уголос, тож потрібна ознака, що це справді проєкт.
	# Без неї комплект, який лежить не в проєкті, поставив би чергу в /data.
	[[ -e "$TARGET/.git" ]] || die "не бачу проєкту: $TARGET — не git-репозиторій.
Вкажіть шлях явно або перейдіть у теку проєкту."
fi
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

# --- systemd-юніт для веб-UI ------------------------------------------------
#
# Порт живе тут, в ExecStart, а не в backlog/config.yml. Причина принципова:
# backlog/ — це дані черги, і install.sh у них не пише (див. CLAUDE.md). Побічно
# це ще й дає реєстр: які порти вже роздані, видно зі списку юнітів, не
# обходячи всі проєкти на диску.
#
# Наслідок, про який варто знати: запущений руками `bin/backlog browser` візьме
# default_port із конфігу (6420 у всіх), побачить його зайнятим і сяде на
# сусідній. Сервіс це не зачіпає — у нього порт свій і закріплений.
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
PORT_FROM=6420
PORT_TO=6520

# Ім'я юніта — з теки проєкту, все стороннє в дефіс: імена юнітів systemd не
# терплять довільних символів, а кирилиця в них читається як сміття.
SLUG="$(basename "$TARGET" | tr -c 'A-Za-z0-9_-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
[[ -n "$SLUG" ]] || SLUG="queue"
UNIT_NAME="backlog-ui-$SLUG.service"

# Хтось слухає порт просто зараз. Без ss і lsof: bash уміє сам.
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# Порти, закріплені за іншими проєктами. Зупинений UI свій порт не звільняє —
# інакше новий проєкт забрав би його, і при старті вони побилися б.
claimed_ports() {
	local f
	shopt -s nullglob
	for f in "$UNIT_DIR"/backlog-ui-*.service; do
		[[ "$(basename "$f")" == "$UNIT_NAME" ]] && continue
		sed -n 's/.*--port \([0-9]\{1,5\}\).*/\1/p' "$f"
	done
	shopt -u nullglob
}

echo
echo "Веб-UI:"
if [[ $WANT_UNIT -eq 0 ]]; then
	echo "  (--no-unit — юніт не чіпаю)"
elif ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
	echo "  ! systemd тут немає — юніт не ставлю, UI піднімати руками:"
	echo "    cd $TARGET && bin/backlog browser --no-open"
elif ! command -v bun >/dev/null; then
	echo "  ! bun не знайдено в PATH — юніт не ставлю"
else
	unit_path="$UNIT_DIR/$UNIT_NAME"

	# Уже призначений порт не переобираємо: адреса, яку людина поклала в
	# закладки, не має плавати від кожного оновлення.
	port=""
	[[ -f "$unit_path" ]] && port="$(sed -n 's/.*--port \([0-9]\{1,5\}\).*/\1/p' "$unit_path" | head -1)"
	taken=" $(claimed_ports | tr '\n' ' ') "
	if [[ -z "$port" || "$taken" == *" $port "* ]]; then
		port=""
		for ((p = PORT_FROM; p <= PORT_TO; p++)); do
			[[ "$taken" == *" $p "* ]] && continue
			port_busy "$p" && continue
			port="$p"; break
		done
		[[ -n "$port" ]] || die "не знайшов вільного порту в діапазоні $PORT_FROM-$PORT_TO"
	fi

	if [[ $DRY -eq 1 ]]; then
		echo "  (пробний прогін) поставив би $UNIT_NAME на порт $port"
	else
		mkdir -p "$UNIT_DIR"
		# PATH задаємо явно: bun зазвичай у ~/.bun/bin, якого в оточенні
		# systemd немає, і обгортка падає з "exec: bun: not found".
		cat > "$unit_path" <<EOF
[Unit]
# Створено $KIT/install.sh — правки тут переживуть лише до наступного запуску.
Description=Backlog.md queue UI — $(basename "$TARGET")
After=network.target

[Service]
Environment=PATH=$(dirname "$(command -v bun)"):/usr/local/bin:/usr/bin:/bin
WorkingDirectory=$TARGET
ExecStart=$TARGET/bin/backlog browser --no-open --port $port
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
		add "$UNIT_NAME (порт $port)"
		systemctl --user daemon-reload

		if [[ -f "$TARGET/backlog/config.yml" ]]; then
			systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1
			systemctl --user restart "$UNIT_NAME"
			for _ in 1 2 3 4 5 6 7 8 9 10; do
				port_busy "$port" && break
				sleep 1
			done
			if port_busy "$port"; then
				add "UI піднято: http://127.0.0.1:$port/"
			else
				echo "  ! сервіс не відповів на $port — подивіться:"
				echo "    journalctl --user -u $UNIT_NAME -n 30"
			fi
			if [[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != "yes" ]]; then
				echo "  ! черга зупиниться при виході з системи. Щоб жила завжди:"
				echo "    sudo loginctl enable-linger $(id -un)"
			fi
		else
			echo "  = чергу ще не ініціалізовано, сервіс не вмикаю"
			echo "    після кроку 1 нижче повторіть: $KIT/install.sh --update $TARGET"
		fi
	fi
fi

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

Веб-UI: \`systemctl --user status $UNIT_NAME\`, логи — \`journalctl --user -u $UNIT_NAME\`.
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

Веб-UI тримає systemd-юніт користувача: \`systemctl --user status $UNIT_NAME\`,
логи — \`journalctl --user -u $UNIT_NAME\`.
EOF

	if [[ ${#existing[@]} -gt 0 ]]; then
		echo
		echo "Не перезаписано. Якщо це оновлення комплекту, а не перше"
		echo "встановлення — повторіть із \`--update\`:"
		printf '  %s\n' "${existing[@]}"
	fi
fi
