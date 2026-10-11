# Homebox's CGI checks (sourced by chassis/tests/test-api.sh).
expect "hbupdate" 202 "$(post "$me" hbupdate 'action=hbupdate')"; request_is "hbupdate request" "ACTION='hbupdate'
BY='$me'"
expect "signups open" 202 "$(post "$me" signups 'action=signups&on=1')"; request_is "signups request" "ACTION='signups'
ON='1'
BY='$me'"
expect "signups bad" 400 "$(post "$me" signups 'action=signups&on=yes')"
expect "warranty good" 202 "$(post "$me" warranty 'action=warranty&days=14')"; request_is "warranty request" "ACTION='warranty'
WARN_DAYS='14'
BY='$me'"
expect "warranty never" 202 "$(post "$me" warranty 'action=warranty&days=0')"; rm -f "$CHASSIS_VAR/request"
expect "warranty bad" 400 "$(post "$me" warranty 'action=warranty&days=5')"
# A new password only for someone the window lists.
uid=0b8f3c2e-4a1d-4c6e-9f2a-7d5e1b3c9a40
jq -c --arg id "$uid" '. + {app: {users: [{id: $id, name: "Ada", email: "ada@example.com"}], collections: [{id: "11111111-2222-4333-8444-555555555555"}]}}' "$CHASSIS_VAR/status.json" > "$CHASSIS_VAR/status.json.tmp" && mv "$CHASSIS_VAR/status.json.tmp" "$CHASSIS_VAR/status.json"
expect "userpw listed" 202 "$(post "$me" userpw "action=userpw&id=$uid")"; request_is "userpw request" "ACTION='userpw'
USER_ID='$uid'
BY='$me'"
expect "userpw not listed" 400 "$(post "$me" userpw 'action=userpw&id=0b8f3c2e-4a1d-4c6e-9f2a-7d5e1b3c9a41')"
expect "userpw a collection's id" 400 "$(post "$me" userpw 'action=userpw&id=11111111-2222-4333-8444-555555555555')"
expect "userpw not an id" 400 "$(post "$me" userpw "action=userpw&id=x'%3B\$(id)")"
expect "userpw uppercase" 400 "$(post "$me" userpw 'action=userpw&id=0B8F3C2E-4A1D-4C6E-9F2A-7D5E1B3C9A40')"
expect "viewer userpw → 403" 403 "$(CHASSIS_ADMINS=no-such-group post "$me" userpw "action=userpw&id=$uid")"
