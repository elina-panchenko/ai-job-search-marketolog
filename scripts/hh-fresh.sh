#!/usr/bin/env bash
# Утренний поиск свежих вакансий на HH.ru через официальный API.
#
# Что делает:
#   1. Ищет вакансии по конфигу (по умолчанию: маркетинг / полная удалёнка / за сутки).
#   2. Отсеивает те, что уже виделись раньше (data/seen-vacancies.md).
#   3. Для каждой новой вакансии подтягивает полный текст (detail-endpoint API),
#      чтобы аналитику не нужно было ходить на сайт (WebFetch на hh.ru тоже
#      блокируется той же политикой сети).
#   4. Печатает markdown-список новых вакансий с полным описанием.
#
# ВАЖНО: нужен доступ в сеть до api.hh.ru. Если egress закрыт политикой
# окружения, скрипт честно об этом скажет и выйдет с кодом 3 (без мусора).
#
# Параметры можно переопределить переменными окружения (см. ниже) или из
# materials/job-search-config.md — источник правды по тому, ЧТО искать.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEEN_FILE="${SEEN_FILE:-$ROOT/data/seen-vacancies.md}"

# --- Параметры поиска (дефолты; переопределяются env-переменными) ---
HH_TEXT="${HH_TEXT:-NAME:(маркетолог OR email-маркетолог OR CRM-маркетолог OR performance-маркетолог OR digital-маркетолог OR интернет-маркетолог)}"
HH_AREA="${HH_AREA:-113}"          # 113 = Россия
HH_SCHEDULE="${HH_SCHEDULE:-remote}"
HH_PERIOD="${HH_PERIOD:-1}"        # за последние N дней (1 = сутки)
HH_PER_PAGE="${HH_PER_PAGE:-100}"
HH_MAX_DETAIL="${HH_MAX_DETAIL:-15}"  # для скольких новых тянуть полный текст
HH_UA="${HH_UA:-elina-job-search/1.0 (elinapanchenko.mediabuyer@gmail.com)}"

TMP="$(mktemp)"; ERR="$(mktemp)"
trap 'rm -f "$TMP" "$ERR" "$TMP".d.*' EXIT

# --- 1. Поисковый запрос ---
http_code=$(curl -sS --max-time 30 -G "https://api.hh.ru/vacancies" \
  --data-urlencode "text=$HH_TEXT" \
  --data-urlencode "area=$HH_AREA" \
  --data-urlencode "schedule=$HH_SCHEDULE" \
  --data-urlencode "period=$HH_PERIOD" \
  --data-urlencode "per_page=$HH_PER_PAGE" \
  --data-urlencode "order_by=publication_time" \
  -H "User-Agent: $HH_UA" \
  -w '%{http_code}' -o "$TMP" 2>"$ERR") || {
    echo "ОШИБКА: не удалось достучаться до api.hh.ru." >&2
    echo "curl: $(tr -d '\n' <"$ERR")" >&2
    echo "Похоже на закрытый egress (403/CONNECT). Включи доступ до api.hh.ru в сетевой политике окружения и повтори." >&2
    exit 3
  }

if [ "$http_code" != "200" ]; then
  echo "ОШИБКА: HH API вернул HTTP $http_code" >&2
  head -c 500 "$TMP" >&2 || true
  [ "$http_code" = "403" ] && echo "  (403 — вероятно, закрыт egress до api.hh.ru; включи доступ в политике окружения)" >&2
  exit 3
fi

# --- 2. Дедуп по seen-list + список новых id ---
NEW_IDS="$(python3 - "$TMP" "$SEEN_FILE" <<'PY'
import json, sys, re, os
raw, seen_path = sys.argv[1], sys.argv[2]
data = json.load(open(raw, encoding='utf-8'))
seen = set()
if os.path.exists(seen_path):
    seen = set(re.findall(r'\b(\d{6,})\b', open(seen_path, encoding='utf-8').read()))
ids = [str(v['id']) for v in data.get('items', []) if str(v.get('id')) not in seen]
print(",".join(ids))
PY
)"

# --- 3. Полный текст для новых (detail endpoint) ---
i=0
for id in ${NEW_IDS//,/ }; do
  [ -z "$id" ] && continue
  i=$((i+1)); [ "$i" -gt "$HH_MAX_DETAIL" ] && break
  curl -sS --max-time 25 "https://api.hh.ru/vacancies/$id" \
    -H "User-Agent: $HH_UA" -o "$TMP.d.$id" 2>/dev/null || true
done

# --- 4. Сборка markdown ---
python3 - "$TMP" "$SEEN_FILE" "$TMP" <<PY
import json, sys, re, os, glob, html
raw, seen_path = "$TMP", "$SEEN_FILE"
data = json.load(open(raw, encoding='utf-8'))
seen = set()
if os.path.exists(seen_path):
    seen = set(re.findall(r'\b(\d{6,})\b', open(seen_path, encoding='utf-8').read()))
items = data.get('items', [])
new = [v for v in items if str(v.get('id')) not in seen]

def strip_html(s):
    s = re.sub(r'<[^>]+>', ' ', s or '')
    return re.sub(r'\s+', ' ', html.unescape(s)).strip()

def salary(v):
    s = v.get('salary')
    if not s: return 'не указана'
    lo, hi, cur = s.get('from'), s.get('to'), s.get('currency','')
    kind = 'до вычета' if s.get('gross') else 'на руки'
    p = []
    if lo: p.append(f'от {lo}')
    if hi: p.append(f'до {hi}')
    return (' '.join(p) + f' {cur} ({kind})') if p else 'не указана'

print(f"# Свежие вакансии HH — всего по запросу {len(items)}, новых {len(new)}")
print(f"_Запрос: удалёнка, за последние сутки. Источник: api.hh.ru_\n")
for v in new:
    vid = str(v['id'])
    print(f"## {v['name']} — {v.get('employer',{}).get('name','?')}")
    print(f"- id: {vid}")
    print(f"- ЗП: {salary(v)}")
    print(f"- Регион: {v.get('area',{}).get('name','?')}  |  Опубликовано: {str(v.get('published_at',''))[:10]}")
    print(f"- Ссылка: {v.get('alternate_url','')}")
    dfile = f"{raw}.d.{vid}"
    if os.path.exists(dfile):
        try:
            d = json.load(open(dfile, encoding='utf-8'))
            desc = strip_html(d.get('description',''))
            skills = ", ".join(s.get('name','') for s in d.get('key_skills') or [])
            emp = d.get('employer',{}) or {}
            if skills: print(f"- Ключевые навыки: {skills}")
            if emp.get('name'): print(f"- Работодатель: {emp.get('name')} (id {emp.get('id','?')})")
            if desc:
                print(f"- Полный текст:\n\n{desc[:4000]}\n")
        except Exception as e:
            print(f"- (не удалось разобрать полный текст: {e})")
    else:
        sn = v.get('snippet') or {}
        req = strip_html(sn.get('requirement',''))
        if req: print(f"- Требования (сниппет): {req[:300]}")
    print()

print("<!-- NEW_IDS: " + ",".join(str(v['id']) for v in new) + " -->")
PY
