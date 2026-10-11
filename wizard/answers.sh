    echo "OWNER_EMAIL='$(printf '%s' "${wizard_owner_email:-}" | tr -cd 'A-Za-z0-9._+@-' | head -c 120)'"
    echo "OWNER_NAME='$(printf '%s' "${wizard_owner_name:-}" | tr -cd 'A-Za-z0-9 ._@-' | sed 's/^ *//; s/ *$//' | tr -s ' ' '+' | head -c 60)'"
