# Homebox's steps for the chassis harness (chassis/tests/e2e.sh <appdir> act).
# Makes a small household inventory through Homebox's own API — one warranty
# ending in 12 days, one in 25, one that ended, one for life — then goes
# through every action the window offers, and a backup and restore of it.
app_e2e_answers() { printf "OWNER_EMAIL='ada@example.com'\nOWNER_NAME='Ada+Lovelace'\n"; }
wait_for() { local i; for i in $(seq 1 "$2"); do touch "$VAR/watching"; jq -e "$1" "$VAR/status.json" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
secret() { local s; s=$(jq -r 'select(.kind == "users") | .password' "$VAR/secret.json" 2>/dev/null); rm -f "$VAR/secret.json"; printf '%s' "$s"; }
HBAPI() { echo "http://127.0.0.1:$PORT/api/v1"; }
login() { curl -s -H 'Content-Type: application/json' -d "$(jq -cn --arg u "$1" --arg p "$2" '{username: $u, password: $p}')" "$(HBAPI)/users/login" | jq -r '.token // empty'; }
register() { curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' -d "$(jq -cn --arg n "$1" --arg e "$2" --arg p "$3" '{name: $n, email: $e, password: $p}')" "$(HBAPI)/users/register"; }
self_code() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: $1" "$(HBAPI)/users/self"; }
hb() { local m=$1 path=$2 tok=$3 body=${4:-}; if [[ -n "$body" ]]; then curl -s -X "$m" -H "Authorization: $tok" -H 'Content-Type: application/json' -d "$body" "$(HBAPI)$path"; else curl -s -X "$m" -H "Authorization: $tok" "$(HBAPI)$path"; fi; }
location() { hb POST /entities "$1" "$(jq -cn --arg n "$2" --arg t "$3" '{name: $n, entityTypeId: $t}')" | jq -r '.id // empty'; }
item() {   # token name location price quantity warranty-end(YYYY-MM-DD|life|"") → id
  local tok=$1 id full w=${6:-}
  id=$(hb POST /entities "$tok" "$(jq -cn --arg n "$2" --arg p "$3" --argjson q "$5" '{name: $n, parentId: $p, quantity: $q}')" | jq -r '.id // empty'); [[ -n "$id" ]] || return 1
  full=$(hb GET "/entities/$id" "$tok")
  hb PUT "/entities/$id" "$tok" "$(jq -c --argjson price "$4" --arg w "$w" '{id, name, description, quantity, archived, insured, assetId, serialNumber, modelNumber, manufacturer, notes,
      parentId: .parent.id, entityTypeId: .entityType.id, tagIds: [], fields: [], purchasePrice: $price, purchaseFrom: "Corner Shop", purchaseDate: "2025-11-02",
      lifetimeWarranty: ($w == "life"), warrantyExpires: (if $w == "life" or $w == "" then "" else $w end), warrantyDetails: ""}' <<< "$full")" | jq -e '.id' >/dev/null || return 1
  echo "$id"
}
told() { grep -cE "told DSM: warrantyends|notification \(warrantyends\)" "$VAR/package.log"; }
app_e2e_act() {
  local fail=0 pw tok lt kitchen garage living coffee fridge receipt bob bobtok bobpw bobpw2 bobid b2 i n0
  log "homebox"
  echo "  (status: $(curl -s "$(HBAPI)/status" | jq -c '{health, version: .build.version, allowRegistration}'), version $(jq -r .version "$VAR/status.json"))"
  # Your account: made at the first start, shown once; then Homebox opened to the network with sign-ups closed.
  pw=$(secret)
  [[ ${#pw} -ge 20 ]] && echo "  ok   a one-time password was left for the window" || { echo "  FAIL no password secret"; fail=1; }
  tok=$(login ada@example.com "$pw"); [[ -n "$tok" ]] && echo "  ok   it signs in to Homebox as ada@example.com" || { echo "  FAIL sign-in"; fail=1; }
  docker port homebox-server 7745 | grep -qv '^127\.' && echo "  ok   published to the network after the first account: $(docker port homebox-server 7745 | paste -sd' ')" || { echo "  FAIL still local only: $(docker port homebox-server 7745)"; fail=1; }
  [[ "$(register Mallory mallory@example.com 'not-invited-123')" == 403 ]] && echo "  ok   sign-ups are closed: a stranger can't make an account" || { echo "  FAIL sign-ups open"; fail=1; }
  wait_for '.app.users | length == 1 and .[0].email == "ada@example.com" and .[0].name == "Ada Lovelace" and .[0].collections[0].role == "owner" and .[0].sessions >= 1' 40 \
    && echo "  ok   the window lists Ada Lovelace, owner of \"$(jq -r '.app.users[0].collections[0].name' "$VAR/status.json")\"" || { echo "  FAIL users: $(jq -c .app.users "$VAR/status.json")"; fail=1; }
  # A household inventory through Homebox's API.
  lt=$(hb GET /entity-types "$tok" | jq -r '[.[] | select(.isLocation)][0].id')
  kitchen=$(location "$tok" Kitchen "$lt"); garage=$(location "$tok" Garage "$lt"); living=$(location "$tok" "Living room" "$lt")
  coffee=$(item "$tok" "Coffee machine" "$kitchen" 249.99 1 "$(date -d '+12 days' +%F)")
  item "$tok" "Cordless drill" "$garage" 89.50 2 "$(date -d '+200 days' +%F)" >/dev/null
  item "$tok" "Television" "$living" 499 1 life >/dev/null
  item "$tok" "Old kettle" "$kitchen" 25 1 "$(date -d '-10 days' +%F)" >/dev/null
  fridge=$(item "$tok" "Fridge" "$kitchen" 650 1 "$(date -d '+25 days' +%F)")
  printf 'Corner Shop — receipt — coffee machine — 249.99\n' > "$E2E/receipt.txt"
  receipt=$(curl -s -H "Authorization: $tok" -F "file=@$E2E/receipt.txt" -F name=receipt.txt -F type=receipt "$(HBAPI)/entities/$coffee/attachments" | jq -r '[.attachments[]? | select(.type == "receipt")][0].path // empty')
  [[ -n "$coffee" && -n "$fridge" && -n "$receipt" ]] && echo "  ok   5 items in 3 locations, a receipt attached (via Homebox's API)" || { echo "  FAIL making items: coffee=$coffee fridge=$fridge receipt=$receipt"; fail=1; }
  wait_for '.app.collections[0] | .items == 5 and .value == 1602.99 and .warranty == 4 and .locations >= 3 and .files >= 1' 60 && wait_for '.app.ended == 1' 5 \
    && echo "  ok   Inventory: $(jq -r '.app.collections[0] | "\(.items) items worth \(.value) \(.currency), \(.warranty) under warranty, \(.files) file(s)"' "$VAR/status.json"), $(jq .app.ended "$VAR/status.json") ended lately" \
    || { echo "  FAIL inventory: $(jq -c '.app.collections, .app.ended' "$VAR/status.json")"; fail=1; }
  wait_for '.app.ending | length == 2 and .[0].name == "Coffee machine" and .[0].location == "Kitchen" and .[0].days == 12 and .[1].name == "Fridge"' 30 \
    && echo "  ok   warranties ending within 30 days: $(jq -r '[.app.ending[] | "\(.name) (\(.location), \(.days) days)"] | join(", ")' "$VAR/status.json")" || { echo "  FAIL ending: $(jq -c .app.ending "$VAR/status.json")"; fail=1; }
  # DSM notifications: two weeks before → only the coffee machine; then a month before → the fridge too, and the coffee machine not again.
  n0=$(told)
  request "ACTION='warranty'" "WARN_DAYS='14'" || fail=1
  for i in $(seq 1 60); do (( $(told) > n0 )) && break; touch "$VAR/watching"; sleep 1; done
  (( $(told) == n0 + 1 )) && grep -q "^$coffee|" "$VAR/warranty-told" && ! grep -q "^$fridge|" "$VAR/warranty-told" \
    && echo "  ok   14 days before: the coffee machine's warranty went to DSM's notifications (only attempted: no DSM here), the fridge's not yet" || { echo "  FAIL notify 14: $(told) vs $n0; $(cat "$VAR/warranty-told" 2>/dev/null | paste -sd' ')"; fail=1; }
  request "ACTION='warranty'" "WARN_DAYS='30'" || fail=1
  for i in $(seq 1 60); do (( $(told) > n0 + 1 )) && break; touch "$VAR/watching"; sleep 1; done
  sleep 12; (( $(told) == n0 + 2 )) && grep -q "^$fridge|" "$VAR/warranty-told" \
    && echo "  ok   30 days before: the fridge too — and the coffee machine wasn't told twice" || { echo "  FAIL notify 30: $(told) vs $n0"; fail=1; }
  # Sign-ups: open for a moment, someone joins, closed again.
  request "ACTION='signups'" "ON='1'" || fail=1
  bobpw='bob-first-password-1'
  [[ "$(curl -s "$(HBAPI)/status" | jq -r .allowRegistration)" == true && "$(register 'Bob Builder' bob@example.com "$bobpw")" == 204 ]] && echo "  ok   sign-ups open: Bob made an account" || { echo "  FAIL signup open"; fail=1; }
  request "ACTION='signups'" "ON='0'" || fail=1
  [[ "$(register Carol carol@example.com 'carol-password-1')" == 403 ]] && echo "  ok   closed again: Carol can't" || { echo "  FAIL signup closed"; fail=1; }
  bobtok=$(login bob@example.com "$bobpw")
  wait_for '.app.users | length == 2 and .[1].name == "Bob Builder" and .[1].collections[0].role == "owner"' 40 && wait_for '.app.collections | length == 2' 5 \
    && echo "  ok   the window lists Bob, with a collection of his own" || { echo "  FAIL users 2: $(jq -c '[.app.users[] | {name, collections}]' "$VAR/status.json")"; fail=1; }
  # A new password through Homebox's own reset: shown once, the old one stops working, and Bob is signed out everywhere.
  bobid=$(jq -r '.app.users[] | select(.email == "bob@example.com") | .id' "$VAR/status.json")
  request "ACTION='userpw'" "USER_ID='$bobid'" || fail=1; bobpw2=$(secret)
  [[ -n "$bobpw2" && -n "$(login bob@example.com "$bobpw2")" && -z "$(login bob@example.com "$bobpw")" ]] && echo "  ok   Bob's new password signs in, the old one doesn't" || { echo "  FAIL userpw"; fail=1; }
  [[ "$(self_code "$bobtok")" == 401 && "$(self_code "$tok")" == 200 ]] && echo "  ok   …Bob's devices were signed out, Ada's weren't" || { echo "  FAIL sessions: bob $(self_code "$bobtok"), ada $(self_code "$tok")"; fail=1; }
  request "ACTION='userpw'" "USER_ID='00000000-0000-4000-8000-000000000000'" >/dev/null && { echo "  FAIL a password for nobody"; fail=1; } || echo "  ok   no such account: $(jq -r .last.message "$VAR/status.json")"
  # A backup with the receipt in it; the coffee machine deleted; restored.
  request "ACTION='backup'" || fail=1; b2=$(jq -r '.backups[0].name' "$VAR/status.json")
  tar -xOf "$APP/backups/$b2" "${b2%.tar}/files.tar.gz" 2>/dev/null | tar -tzf - 2>/dev/null | grep -q "documents/" && tar -tf "$APP/backups/$b2" | grep -q "database.sqlite.gz$" \
    && echo "  ok   $b2: a checked copy of the database, and the attached files" || { echo "  FAIL backup contents: $(tar -tf "$APP/backups/$b2" | paste -sd' ')"; fail=1; }
  hb DELETE "/entities/$coffee" "$tok" >/dev/null
  wait_for '.app.collections[0].items == 4' 40 || { echo "  FAIL delete"; fail=1; }
  request "ACTION='restore'" "BACKUP='$b2'" || fail=1
  tok=$(login ada@example.com "$pw")
  [[ "$(hb GET "/entities/$coffee" "$tok" | jq -r .name)" == "Coffee machine" ]] && docker exec homebox-server test -s "/data/$receipt" \
    && echo "  ok   restored: the coffee machine and its receipt are back" || { echo "  FAIL restore: $(hb GET "/entities/$coffee" "$tok" | head -c 200)"; fail=1; }
  [[ -n "$(login bob@example.com "$bobpw2")" ]] && echo "  ok   …and Bob's new password still signs in" || { echo "  FAIL bob after restore"; fail=1; }
  wait_for '.app.collections[0].items == 5' 40 || { echo "  FAIL items after restore: $(jq -c '.app.collections[0]' "$VAR/status.json")"; fail=1; }
  # Updates: pinned to a release; the window moves it on. Pretend this install is on 0.26.1.
  docker exec "$NAME" sed -i 's|^HB_IMAGE=.*|HB_IMAGE=ghcr.io/sysadminsmedia/homebox:0.26.1|' "$APP/.env"
  request "ACTION='check'" || fail=1
  jq -e '.image_update | .available == true and .current == "0.26.1" and (.latest | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$VAR/status.json" >/dev/null \
    && echo "  ok   a newer Homebox is found on GitHub and ghcr.io: $(jq -r '.image_update | "\(.current) → \(.latest)"' "$VAR/status.json")" || { echo "  FAIL check: $(jq -c .image_update "$VAR/status.json")"; fail=1; }
  request "ACTION='hbupdate'" || fail=1
  local want; want=$(jq -r '.image_update.latest' "$VAR/status.json")
  grep -qx "HB_IMAGE=ghcr.io/sysadminsmedia/homebox:$want" "$APP/.env" 2>/dev/null || docker exec "$NAME" grep -qx "HB_IMAGE=ghcr.io/sysadminsmedia/homebox:$want" "$APP/.env"
  (( $? == 0 )) && jq -e '.image_update.available == false' "$VAR/status.json" >/dev/null && [[ "$(jq -r .version "$VAR/status.json")" == "$want" ]] \
    && echo "  ok   updated: Homebox $want, a backup first ($(jq -r '.backup.last.name' "$VAR/status.json"))" || { echo "  FAIL hbupdate: $(jq -c '{version, image_update}' "$VAR/status.json")"; fail=1; }
  request "ACTION='hbupdate'" >/dev/null && { echo "  FAIL an update with nothing newer"; fail=1; } || echo "  ok   nothing newer: $(jq -r .last.message "$VAR/status.json")"
  # Storage and logs.
  wait_for '.storage.app | has("database") and has("files")' 30 && echo "  ok   storage: $(jq -c .storage.app "$VAR/status.json")" || { echo "  FAIL storage: $(jq -c .storage "$VAR/status.json")"; fail=1; }
  for i in $(seq 1 20); do [[ -s "$VAR/logs/server.log" ]] && break; touch "$VAR/watching"; sleep 1; done
  [[ -s "$VAR/logs/server.log" ]] && ! grep -q $'\x1b' "$VAR/logs/server.log" && echo "  ok   Homebox's log for the window, without colour codes" || { echo "  FAIL server.log"; fail=1; }
  (( fail )) && { echo "  homebox: something FAILED"; return 1; }; echo "  homebox: all passed"
}
