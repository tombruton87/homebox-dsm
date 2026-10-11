# Homebox's hooks for the chassis core (sourced by run-core.sh). The core
# gives: say, env_get/env_set, rand, compose, in_volume, cname, svc_up,
# leave_secret, notify, fresh, now, for_window, wait_ready, make_backup,
# record_backup, MSG, VAR, APP, LOG, PKG_NAME, PKG_TITLE, IMAGE_UPDATE.
#
# Homebox has no admin API. The package works through Homebox itself where it
# can — its sign-up endpoint for your account at the first start, and its own
# password reset (`api reset-password` inside its container, then the reset
# endpoint, which also signs the person out everywhere) — and reads the window's
# numbers read-only from its SQLite database. Passwords are never stored.
#
# The image is pinned to a tested Homebox release (ghcr.io, which the core's
# Docker Hub check can't read): the package looks for newer releases itself and
# moves the pin when you press Update in the window.

HB=""
HB_REPO=ghcr.io/sysadminsmedia/homebox
HB_PINNED=$HB_REPO:0.26.2          # the release this package was tested with

app_validate() {   # key value → 0 if the value has the key's shape
  case "$1" in
    OWNER_EMAIL) [[ "$2" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && (( ${#2} <= 120 )) ;;
    OWNER_NAME)  [[ "$2" =~ ^[A-Za-z0-9._@+-]+$ ]] && (( ${#2} <= 60 )) ;;   # spaces arrive as +
    USER_ID)     [[ "$2" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ;;
    WARN_DAYS)   [[ "$2" =~ ^(0|7|14|30|60|90)$ ]] ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------ talking to Homebox
hb_url() { echo "http://127.0.0.1:$(env_get HTTP_PORT)"; }
strong_password() { echo "$(rand 5)-$(rand 5)-$(rand 5)-$(rand 5)"; }
unplus() { tr '+' ' ' <<< "$1"; }
hb_tag() { local i=${1:-$(env_get HB_IMAGE)}; [[ "$i" =~ ^ghcr\.io/sysadminsmedia/homebox:([0-9]+\.[0-9]+\.[0-9]+)$ ]] && echo "${BASH_REMATCH[1]}"; true; }
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }   # is release $1 newer than $2?
hb_status() { curl -s --max-time 5 "$(hb_url)/api/v1/status" 2>/dev/null; }

# Homebox's SQLite database, read-only. It's in WAL mode, so the volume is
# mounted read-write (a reader writes the -shm file) and sqlite3 opens it -readonly.
hb_sql() {   # SQL on stdin → sqlite3's output
  local out err rc=0
  err=$(mktemp)
  out=$(in_volume data rw -- 'test -f /vol/homebox.db && sqlite3 -readonly -bail /vol/homebox.db' 2>"$err") || rc=$?
  # Said once per new error (callers capture stdout, so the note goes to the log only, and is remembered in a file).
  if (( rc )) && [[ -s "$err" && "$(head -c 200 "$err")" != "$(cat "$VAR/.db-err" 2>/dev/null)" ]]; then head -c 200 "$err" > "$VAR/.db-err"; say "✗ Homebox's database couldn't be read: $(cat "$VAR/.db-err")" >/dev/null; fi
  (( rc )) || rm -f "$VAR/.db-err"
  rm -f "$err"; printf '%s' "$out"; return $rc
}
hb_query() {   # days → one JSON document: the people, the collections and the warranties ending within that many days
  local n=$1
  cat <<SQL
WITH items AS (
  SELECT e.* FROM entities e JOIN entity_types et ON et.id = e.entity_type_entities
  WHERE et.is_location = 0 AND e.archived = 0
)
SELECT json_object(
  'users', json(COALESCE((SELECT json_group_array(json_object(
      'id', u.id, 'name', u.name, 'email', u.email,
      'created', CAST(strftime('%s', substr(u.created_at, 1, 19)) AS INTEGER),
      'password', (u.password IS NOT NULL AND u.password <> ''),
      'oidc', (u.oidc_subject IS NOT NULL AND u.oidc_subject <> ''),
      'sessions', (SELECT count(*) FROM auth_tokens t WHERE t.user_auth_tokens = u.id AND substr(t.expires_at, 1, 19) > datetime('now')),
      'collections', json(COALESCE((SELECT json_group_array(json_object('name', g.name, 'role', ug.role))
                                    FROM user_groups ug JOIN groups g ON g.id = ug.group_id WHERE ug.user_id = u.id), '[]'))))
    FROM (SELECT * FROM users ORDER BY created_at) u), '[]')),
  'collections', json(COALESCE((SELECT json_group_array(json_object(
      'id', g.id, 'name', g.name, 'currency', g.currency,
      'items', (SELECT count(*) FROM items i WHERE i.group_entities = g.id),
      'locations', (SELECT count(*) FROM entities e JOIN entity_types et ON et.id = e.entity_type_entities WHERE e.group_entities = g.id AND et.is_location = 1),
      'value', (SELECT round(COALESCE(sum(i.purchase_price * i.quantity), 0), 2) FROM items i WHERE i.group_entities = g.id),
      'warranty', (SELECT count(*) FROM items i WHERE i.group_entities = g.id AND (i.lifetime_warranty = 1 OR substr(i.warranty_expires, 1, 10) >= date('now'))),
      'files', (SELECT count(*) FROM attachments a JOIN entities e ON e.id = a.entity_attachments WHERE e.group_entities = g.id AND a.type <> 'thumbnail'),
      'people', (SELECT count(*) FROM user_groups ug WHERE ug.group_id = g.id)))
    FROM (SELECT * FROM groups ORDER BY created_at) g), '[]')),
  'ending', json(COALESCE((SELECT json_group_array(json_object('id', x.id, 'name', x.name, 'collection', x.gname, 'location', x.pname, 'ends', x.ends, 'days', x.days)) FROM (
      SELECT i.id, i.name, g.name AS gname, p.name AS pname, substr(i.warranty_expires, 1, 10) AS ends,
             CAST(julianday(substr(i.warranty_expires, 1, 10)) - julianday(date('now')) AS INTEGER) AS days
      FROM items i JOIN groups g ON g.id = i.group_entities LEFT JOIN entities p ON p.id = i.entity_children
      WHERE i.lifetime_warranty = 0 AND i.warranty_expires IS NOT NULL
        AND substr(i.warranty_expires, 1, 10) BETWEEN date('now') AND date('now', '+$n days')
      ORDER BY i.warranty_expires LIMIT 100) x), '[]')),
  'ended', (SELECT count(*) FROM items i WHERE i.lifetime_warranty = 0 AND substr(i.warranty_expires, 1, 10) BETWEEN date('now', '-30 days') AND date('now', '-1 day')),
  'within', $n,
  'schema', (SELECT max(version_id) FROM goose_db_version));
SQL
}
hb_db() { local n=${1:-30}; [[ "$n" =~ ^[0-9]{1,3}$ ]] || n=30; hb_query "$n" | hb_sql; }
hb_users() { local c; c=$(printf 'SELECT count(*) FROM users;\n' | hb_sql) || true; printf '%s' "$c" | tr -cd '0-9'; }

# Who may reach Homebox and sign up: while the first account is made, only this
# Synology (127.0.0.1) with sign-ups open; after that, everyone, with sign-ups as you set them.
hb_access() {
  if [[ -f "$VAR/.needs-user" ]]; then env_set HB_REGISTER true; env_set HB_BIND "127.0.0.1:"
  else env_set HB_REGISTER "$([[ "$(env_get SIGNUPS)" == 1 ]] && echo true || echo false)"; env_set HB_BIND ""; fi
  env_set HB_TRUST_PROXY "$([[ "$(env_get SSL_PROXY)" == 1 ]] && echo true || echo false)"
}

# ------------------------------------------------------------ lifecycle hooks
app_first_env() {
  env_set HB_IMAGE "$HB_PINNED"
  env_set HB_PEPPER "$(rand 48)"
  env_set OWNER_EMAIL "${OWNER_EMAIL:-admin@example.com}"; env_set OWNER_NAME "${OWNER_NAME:-Owner}"
  env_set SIGNUPS 0; env_set WARN_DAYS 30
  touch "$VAR/.needs-user"
  hb_access
}
app_load_env() {
  HB=$(cname server)
  # A newer package brings a newer tested Homebox: move the pin forward (never back), with a backup first.
  local cur pin=${HB_PINNED##*:}
  cur=$(hb_tag)
  if [[ -n "$cur" ]] && newer "$pin" "$cur"; then
    say "this package brings Homebox $pin (installed: $cur) — a backup first"
    if make_backup pre-update; then record_backup true "$MADE"; env_set HB_IMAGE "$HB_PINNED"; say "Homebox moves to $pin; the state from before is in $MADE"
    else say "✗ couldn't back up first, so Homebox stays at $cur for now"; fi
  fi
  return 0
}
app_before_up() { hb_access; }
app_health() { [[ "$(hb_status | jq -r '.health // empty' 2>/dev/null)" == true ]]; }
app_version() {
  local v; v=$(hb_status | jq -r '.build.version // empty' 2>/dev/null) || true
  [[ -n "$v" ]] || v=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$HB" 2>/dev/null) || true
  printf '%s' "${v#v}" | tr -cd '0-9A-Za-z.-' | head -c 30
}
app_after_up() { make_user 120; }
make_user() {   # [tries] — the first time: your account, then Homebox opened to the network with sign-ups closed
  [[ -f "$VAR/.needs-user" ]] || return 0
  local i pw email name code n
  email=$(env_get OWNER_EMAIL); name=$(unplus "$(env_get OWNER_NAME)")
  for i in $(seq 1 "${1:-1}"); do app_health && break; sleep 2; done
  app_health || { say "Homebox isn't answering yet — your account is made when it does"; return 0; }
  n=$(hb_users)
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then say "Homebox already has $n account(s) — left as they are"
  else
    pw=$(strong_password)
    code=$(jq -cn --arg n "$name" --arg e "$email" --arg p "$pw" '{name: $n, email: $e, password: $p}' \
      | curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H 'Content-Type: application/json' --data-binary @- "$(hb_url)/api/v1/users/register" 2>/dev/null) || true
    [[ "$code" == 204 ]] || { say "✗ your Homebox account couldn't be made (Homebox answered HTTP ${code:-nothing}) — trying again shortly"; return 0; }
    leave_secret "Homebox ($email)" "$pw" users
    say "first start: your Homebox account ($email) was made; the password is shown once in the window"
  fi
  rm -f "$VAR/.needs-user" "$VAR/.db.json"
  say "opening Homebox to the network, with sign-ups closed"
  hb_access
  compose up -d >> "$LOG" 2>&1 || say "✗ Homebox couldn't be started again with sign-ups closed — see the lines above"
  for i in $(seq 1 60); do app_health && break; sleep 2; done
  return 0
}

# ------------------------------------------------------------ what the window shows
app_status() {
  svc_up server || { echo '{"up": false}'; return 0; }
  local data days
  days=$(env_get WARN_DAYS); [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )) || days=30
  if fresh "$VAR/.db.json" 20; then data=$(cat "$VAR/.db.json")
  else data=$(hb_db "$days")
    if jq -e '.users' <<< "$data" >/dev/null 2>&1; then printf '%s' "$data" > "$VAR/.db.json.tmp" && chmod 600 "$VAR/.db.json.tmp" && mv "$VAR/.db.json.tmp" "$VAR/.db.json"; else data='{}'; fi
  fi
  jq -c --arg url "$(env_get APP_URL)" --arg signups "$(env_get SIGNUPS)" --arg warn "$(env_get WARN_DAYS)" --arg image "$(env_get HB_IMAGE)" \
     --argjson pending "$([[ -f "$VAR/.needs-user" ]] && echo true || echo false)" \
     '. + {up: true, url: $url, signups: ($signups == "1"), first_account_pending: $pending, warn_days: ($warn | tonumber? // 30), image: $image}' <<< "$data" 2>/dev/null || echo '{"up": true}'
}

# ------------------------------------------------------------ warranties: a DSM notification before one ends
check_warranties() {   # each item once per end date, WARN_DAYS before it
  local days rows new n told="$VAR/warranty-told"
  days=$(env_get WARN_DAYS); [[ "$days" =~ ^[0-9]+$ ]] && (( days > 0 )) || return 0
  rows=$(hb_db "$days" | jq -c '.ending' 2>/dev/null); [[ "$rows" == \[* ]] || return 0
  touch "$told"
  new=$(jq -c --rawfile seen "$told" '($seen | split("\n")) as $s | [.[] | select((.id + "|" + .ends) as $k | any($s[]; . == $k) | not)]' <<< "$rows")
  n=$(jq 'length' <<< "$new" 2>/dev/null); [[ "$n" =~ ^[0-9]+$ ]] && (( n )) || return 0
  jq -r '.[] | .id + "|" + .ends' <<< "$new" >> "$told"
  tail -n 2000 "$told" > "$told.tmp" && mv "$told.tmp" "$told"
  if (( n > 3 )); then notify warrantymany 0 "$n" "$days"; return 0; fi
  jq -c '.[]' <<< "$new" | while read -r r; do
    notify warrantyends 0 "$(jq -r '.name' <<< "$r")" "$(date -d "$(jq -r '.ends' <<< "$r")" '+%-d %B %Y' 2>/dev/null || jq -r '.ends' <<< "$r")"
  done
  true
}

# ------------------------------------------------------------ updates: the pinned release, moved on when you say so
hb_check_image() {   # the newest Homebox release on GitHub whose image is on ghcr.io → IMAGE_UPDATE for the window
  local cur latest tok code avail=false note=""
  cur=$(hb_tag)
  [[ -n "$cur" ]] || { IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get HB_IMAGE)" '{checked: $at, image: $img, error: "the image is not a Homebox release the package knows"}'); return 0; }
  # GitHub's releases/latest redirect names the newest release without using the (rate-limited) API; the API is the fallback.
  latest=$(curl -sSI --max-time 15 https://github.com/sysadminsmedia/homebox/releases/latest 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "location:" {print $2}' | sed -n 's|.*/releases/tag/v\{0,1\}\([0-9][0-9.]*\)$|\1|p' | tail -n 1)
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || latest=$(curl -fsS --max-time 15 https://api.github.com/repos/sysadminsmedia/homebox/releases/latest 2>/dev/null | jq -r '.tag_name // ""' 2>/dev/null | sed 's/^v//')
  if ! [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get HB_IMAGE)" '{checked: $at, image: $img, error: "GitHub could not be reached"}'); return 0; fi
  if newer "$latest" "$cur"; then
    tok=$(curl -fsS --max-time 15 "https://ghcr.io/token?scope=repository:sysadminsmedia/homebox:pull" 2>/dev/null | jq -r '.token // ""' 2>/dev/null)
    code=$(curl -s -o /dev/null -I -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $tok" \
      -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
      "https://ghcr.io/v2/sysadminsmedia/homebox/manifests/$latest" 2>/dev/null)
    if [[ "$code" == 200 ]]; then avail=true; else note="Homebox $latest is out, but its image isn't on ghcr.io yet"; fi
  fi
  IMAGE_UPDATE=$(jq -nc --argjson at "$(now)" --arg img "$(env_get HB_IMAGE)" --arg cur "$cur" --arg latest "$latest" --argjson avail "$avail" --arg note "$note" \
    '{checked: $at, image: $img, available: $avail, current: $cur, latest: $latest, note: $note, remote: $latest, local: $cur,
      page: ("https://github.com/sysadminsmedia/homebox/releases/tag/v" + $latest)}')
  say "Homebox: newest release $latest, this is $cur$([[ "$avail" == true ]] && echo " — an update is available")"
}
app_check_updates() { hb_check_image; }
hb_update() {   # to the newest release found by hb_check_image (never a value from the request)
  local cur latest old img
  cur=$(hb_tag); latest=$(jq -r '.latest // ""' <<< "$IMAGE_UPDATE" 2>/dev/null)
  if ! [[ -n "$cur" && "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! newer "$latest" "$cur" || ! jq -e '.available == true' <<< "$IMAGE_UPDATE" >/dev/null 2>&1; then
    MSG="There's no newer Homebox to install — look for updates first."; return 1; fi
  old=$(env_get HB_IMAGE); img="$HB_REPO:$latest"
  say "updating Homebox $cur → $latest — first, a backup"
  make_backup pre-update || { MSG="Couldn't back up first, so Homebox wasn't updated."; return 1; }
  record_backup true "$MADE"
  say "pulling $img"
  docker pull "$img" 2>&1 | grep -vE '^\s*$' | tail -n 5 | tee -a "$LOG" >/dev/null
  docker image inspect "$img" >/dev/null 2>&1 || { MSG="Homebox $latest couldn't be downloaded; it stays at $cur."; return 1; }
  env_set HB_IMAGE "$img"
  compose up -d --remove-orphans 2>&1 | tee -a "$LOG" >/dev/null || { MSG="Homebox $latest didn't start — see the log. The state from before is in $MADE."; return 1; }
  wait_ready 600 || { MSG="Homebox $latest hasn't answered yet — see the log. The state from before is in $MADE."; return 1; }
  [[ "$old" != "$img" ]] && { docker image rm "$old" >> "$LOG" 2>&1 && say "removed the old image $old" || true; }
  rm -f "$VAR/.db.json"; hb_check_image
  MSG="Homebox is updated to $(app_version). The state from before is in $MADE."
}

app_tick() {
  make_user 1
  svc_up server || return 0
  # The core's own image check only reads Docker Hub; after its update path, ours puts the answer back.
  jq -e '.error == "only Docker Hub images are checked"' <<< "$IMAGE_UPDATE" >/dev/null 2>&1 && hb_check_image
  fresh "$VAR/.warranty-check" 3600 || { touch "$VAR/.warranty-check"; check_warranties || true; }
  return 0
}

# ------------------------------------------------------------ settings, logs, storage, backups, report
app_settings() { hb_access; return 0; }   # behind DSM's reverse proxy: Homebox trusts its X-Forwarded headers
app_after_settings() { rm -f "$VAR/.db.json"; }
app_logs() {   # Homebox colours its log; the window shows plain text
  [[ -f "$VAR/logs/server.log" ]] || return 0
  sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$VAR/logs/server.log" > "$VAR/logs/server.log.tmp" && for_window "$VAR/logs/server.log"
}
app_storage() {
  in_volume data ro -- 'printf "database\t%s\n" "$(du -cm /vol/homebox.db* 2>/dev/null | tail -n 1 | cut -f1)"; printf "files\t%s\n" "$(du -sm --exclude="homebox.db*" /vol 2>/dev/null | cut -f1)"; true' </dev/null 2>/dev/null \
    | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {key: .[0], value: (.[1] | tonumber? // 0)}) | from_entries' 2>/dev/null || echo "{}"
}
app_backup() {   # dir — a consistent copy of the database (checked), and every attached file
  in_volume data rw -- 'set -e; sqlite3 -readonly /vol/homebox.db ".backup /tmp/hb.db"; test "$(sqlite3 /tmp/hb.db "pragma quick_check;")" = ok; gzip -c /tmp/hb.db' \
    > "$1/database.sqlite.gz" 2>>"$LOG" </dev/null && gzip -t "$1/database.sqlite.gz" 2>/dev/null || { say "✗ Homebox's database couldn't be copied"; return 1; }
  in_volume data ro -- 'tar -C /vol -czf - --exclude=./homebox.db --exclude=./homebox.db-wal --exclude=./homebox.db-shm --exclude=./homebox.db-journal .' \
    > "$1/files.tar.gz" 2>>"$LOG" </dev/null && tar -tzf "$1/files.tar.gz" >/dev/null 2>&1 || { say "✗ Homebox's files didn't tar"; return 1; }
}
app_restore() {   # dir — the core has stopped the containers
  [[ -s "$1/database.sqlite.gz" && -f "$1/files.tar.gz" ]] || { MSG="That backup has no Homebox database or files."; return 1; }
  in_volume data rw -- 'find /vol -mindepth 1 -delete && tar -C /vol -xzf -' < "$1/files.tar.gz" 2>>"$LOG" || { MSG="Homebox's files didn't unpack."; return 1; }
  in_volume data rw -- 'gzip -dc > /vol/homebox.db' < "$1/database.sqlite.gz" 2>>"$LOG" || { MSG="Homebox's database didn't unpack."; return 1; }
  rm -f "$VAR/.needs-user" "$VAR/.db.json"; hb_access   # the restored accounts are the ones that count
}
app_report() {
  local d; d=$(hb_db 30); jq -e '.users' <<< "$d" >/dev/null 2>&1 || d='{}'
  echo "== Homebox: $(jq '.users | length' <<< "$d" 2>/dev/null) accounts, $(jq '.collections | length' <<< "$d" 2>/dev/null) collections; sign-ups $([[ "$(env_get SIGNUPS)" == 1 ]] && echo open || echo closed); database schema $(jq -r '.schema // "?"' <<< "$d")"
  jq -r '.collections | to_entries[]? | "collection \(.key + 1): \(.value.items) items, \(.value.locations) locations, worth \(.value.value) \(.value.currency), \(.value.warranty) under warranty, \(.value.files) files, \(.value.people) people"' <<< "$d" 2>/dev/null
  echo "== warranties: $(jq '.ending | length' <<< "$d" 2>/dev/null) end within 30 days, $(jq '.ended // 0' <<< "$d") ended in the last 30; DSM is told $(env_get WARN_DAYS) days before (0: never)"
  echo "== image: $(env_get HB_IMAGE); newest release: $(jq -r '.latest // .error // "?"' <<< "$IMAGE_UPDATE" 2>/dev/null)"
  :
}

# ------------------------------------------------------------ the window's actions
app_act() {   # action (request vars are set)
  local email name out tok pw code
  case "$1" in
    signups)
      env_set SIGNUPS "${ON:-0}"; hb_access
      compose up -d >> "$LOG" 2>&1 && wait_ready 120 || { MSG="Homebox didn't come back — see the log."; return 1; }
      MSG=$([[ "${ON:-0}" == 1 ]] && echo "Sign-ups are open: anyone who can reach Homebox can make an account. Close them again when everyone's in." || echo "Sign-ups are closed: new people join through an invitation to a collection.") ;;
    userpw)
      out=$(printf "SELECT json_object('email', email, 'name', name, 'password', (password IS NOT NULL AND password <> '')) FROM users WHERE id = '%s';\n" "$USER_ID" | hb_sql)
      email=$(jq -r '.email // empty' <<< "$out" 2>/dev/null); name=$(jq -r '.name // empty' <<< "$out" 2>/dev/null)
      [[ -n "$email" ]] || { MSG="There's no such account in Homebox."; return 1; }
      [[ "$email" =~ ^[^[:space:]]+@[^[:space:]]+$ && ${#email} -le 255 ]] || { MSG="That account's email doesn't look like one, so Homebox can't reset it."; return 1; }
      jq -e '.password == 1' <<< "$out" >/dev/null 2>&1 || { MSG="$name signs in through single sign-on (OpenID Connect): their password is kept there, not in Homebox."; return 1; }
      # Homebox's own reset: its CLI mints a one-time token (stdout only, never logged), its reset endpoint sets the password and signs them out everywhere.
      out=$(docker exec "$HB" /app/api reset-password "--email=$email" 2>>"$LOG")
      tok=$(sed -n 's/.*[?&]token=\([A-Za-z0-9._~%-]\{16,200\}\).*/\1/p' <<< "$out" | tail -n 1)
      [[ -n "$tok" ]] || { MSG="Homebox didn't make a reset token — see the log."; return 1; }
      pw=$(strong_password)
      code=$(jq -cn --arg t "$tok" --arg p "$pw" '{token: $t, password: $p}' \
        | curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H 'Content-Type: application/json' --data-binary @- "$(hb_url)/api/v1/users/reset-password" 2>/dev/null)
      [[ "$code" == 204 ]] || { MSG="Homebox refused the new password (HTTP ${code:-nothing})."; return 1; }
      leave_secret "Homebox ($email)" "$pw" users; rm -f "$VAR/.db.json"
      MSG="The new password for $name is shown below, once. They were signed out everywhere and sign in again with it." ;;
    warranty)
      env_set WARN_DAYS "${WARN_DAYS:-30}"; rm -f "$VAR/.warranty-check" "$VAR/.db.json"
      MSG=$([[ "${WARN_DAYS:-30}" == 0 ]] && echo "No DSM notifications about warranties." || echo "DSM tells you $WARN_DAYS days before a warranty ends.") ;;
    hbupdate) hb_update ;;
    *) MSG="Unknown request."; return 1 ;;
  esac
}
