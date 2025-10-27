#!/usr/bin/env bash
source ./log.sh
PKG_NAME="example"
LOGFILE="logs/${PKG_NAME}.fetch.log"
THEME_ICON="📥"
banner "Baixando source do ${PKG_NAME}"

URL="https://example.org/sources/example-1.0.tar.xz"
OUT="cache/distfiles/example-1.0.tar.xz"

download_with_progress "$URL" "$OUT" || {
  msg_error "Download falhou para $URL"
  exit 1
}
msg_ok "Fonte disponível em $OUT"
