# Homebox's actions, validated by the CGI before they become a request file.
# Nothing here is free text: an account is picked by its id from the list the window shows.
app_cgi_post() {   # action body → sets $lines, or error
  local a=$1 body=$2 v id
  case "$a" in
    hbupdate) lines="ACTION='hbupdate'" ;;
    signups) v=$(param on "$body"); [[ "$v" =~ ^[01]$ ]] || error "400 Bad Request" "Open or closed."; lines="ACTION='signups'
ON='$v'" ;;
    warranty) v=$(param days "$body"); [[ "$v" =~ ^(0|7|14|30|60|90)$ ]] || error "400 Bad Request" "Pick how long before."; lines="ACTION='warranty'
WARN_DAYS='$v'" ;;
    userpw)
      id=$(param id "$body")
      [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || error "400 Bad Request" "Pick someone from the list."
      jq -e --arg id "$id" 'any(.app.users[]?; .id == $id)' "$VAR/status.json" >/dev/null 2>&1 || error "400 Bad Request" "Pick someone from the list."
      lines="ACTION='userpw'
USER_ID='$id'" ;;
  esac
}
