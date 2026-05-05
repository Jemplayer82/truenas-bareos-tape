#!/usr/bin/env bash
# usage: notify-email.sh TO SUBJECT [BODY_FILE|-]
# Sends a plain-text email via msmtp using /etc/msmtprc.
set -euo pipefail
TO=${1:?to address required}
SUBJ=${2:?subject required}
BODY=${3:-/dev/stdin}
[[ $BODY == - ]] && BODY=/dev/stdin

if ! command -v msmtp >/dev/null 2>&1; then
  echo "notify-email.sh: msmtp not installed" >&2
  exit 127
fi

{ printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=utf-8\n\n' "$TO" "$SUBJ"
  cat "$BODY"
} | msmtp -t --read-envelope-from
