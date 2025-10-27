#!/usr/bin/env bash
# log.sh — sistema de mensagens, logs coloridos, spinner e download com progress
# Versão: 2025-10
# Uso: source ./log.sh; configurar PKG_NAME, LOGFILE, THEME_ICON, TOTAL_STEPS antes de usar.

# ----------- cores (portável via tput quando tty) -----------
if test -t 1; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); MAGENTA=$(tput setaf 5); CYAN=$(tput setaf 6)
  BOLD=$(tput bold); RESET=$(tput sgr0)
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi

# ----------- configuração padrão (sobrescrever externamente) -----------
VERBOSE=${VERBOSE:-1}             # 0=quiet,1=normal,2=verbose,3=debug
PKG_NAME=${PKG_NAME:-"system"}
THEME_ICON=${THEME_ICON:-"🔧"}
LOGDIR=${LOGDIR:-logs}
mkdir -p "$LOGDIR"
LOGFILE=${LOGFILE:-"$LOGDIR/${PKG_NAME}.log"}
STEP=0
TOTAL_STEPS=${TOTAL_STEPS:-0}

# ----------- utilitários de log -----------
_log_to_file() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOGFILE"
}

_print_console() {
  # imprime no console conforme VERBOSE; mensagens de erro sempre aparecem
  local level=$1; shift
  local msg="$*"
  case "$level" in
    ERROR) echo -e "${RED}✖${RESET} ${msg}" >&2;;
    WARN)  [ "$VERBOSE" -ge 1 ] && echo -e "${YELLOW}!${RESET} ${msg}" ;;
    INFO)  [ "$VERBOSE" -ge 1 ] && echo -e "${BLUE}→${RESET} ${msg}" ;;
    OK)    [ "$VERBOSE" -ge 1 ] && echo -e "${GREEN}✔${RESET} ${msg}" ;;
    DEBUG) [ "$VERBOSE" -ge 3 ] && echo -e "${MAGENTA}🐞${RESET} ${msg}" ;;
    *)     [ "$VERBOSE" -ge 1 ] && echo -e "${msg}" ;;
  esac
  _log_to_file "[$level] $msg"
}

msg_info()  { _print_console INFO "$*"; }
msg_ok()    { _print_console OK "$*"; }
msg_warn()  { _print_console WARN "$*"; }
msg_error() { _print_console ERROR "$*"; }
msg_debug() { _print_console DEBUG "$*"; }

# ----------- banner e resumo -----------
banner() {
  local title=${1:-"$PKG_NAME"}
  echo -e "\n${BOLD}${BLUE}──────────────────────────────────────────${RESET}"
  echo -e "${BLUE}${THEME_ICON} ${BOLD}${title}${RESET}"
  echo -e "${BOLD}${BLUE}──────────────────────────────────────────${RESET}\n"
  _log_to_file "=== START: $title ==="
}

summary() {
  local result=${1:-"DONE"} elapsed=${2:-""}
  echo -e "\n${BOLD}${BLUE}──────────────────────────────────────────${RESET}"
  echo -e "${THEME_ICON} ${BOLD}$PKG_NAME${RESET} build summary"
  echo -e "Result:  ${result}"
  [ -n "$elapsed" ] && echo -e "Time:    ${elapsed}s"
  echo -e "Logs:    ${LOGFILE}"
  echo -e "${BOLD}${BLUE}──────────────────────────────────────────${RESET}\n"
  _log_to_file "=== END: $PKG_NAME => $result (time=${elapsed}s) ==="
}

# ----------- passos numerados e temporizador -----------
step() {
  STEP=$((STEP+1))
  msg_info "[$STEP/$TOTAL_STEPS] $*"
  start_timer
}

start_timer() { _t0=$(date +%s); }
end_timer() {
  local _t1=$(date +%s)
  local _dt=$((_t1 - _t0))
  msg_ok "Concluído em ${_dt}s"
  _log_to_file "[TIMER] step=${STEP} duration=${_dt}s"
}

# ----------- spinner para tarefas longas (builds sem progress real) -----------
_spinner_pid=""
_spinner_cleanup() {
  if [ -n "$_spinner_pid" ]; then
    kill "$_spinner_pid" >/dev/null 2>&1 || true
    wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
    printf "\r"  # limpa linha
  fi
}
spinner_start() {
  # $1 = mensagem base
  local msg=${1:-"working"}
  local delay=${2:-0.1}
  # spinner loop in background
  ( while :; do for c in / - \\ \|; do printf "\r${BLUE}⟳${RESET} ${msg} %s" "$c"; sleep "$delay"; done; done ) &
  _spinner_pid=$!
  trap _spinner_cleanup EXIT
}
spinner_stop() {
  _spinner_cleanup
  msg_ok "$*"
  trap - EXIT
}

# ----------- download com barra de progresso (usa curl ou wget quando possível) -----------
# download_with_progress <url> <output-file>
download_with_progress() {
  local url=$1 out=$2
  mkdir -p "$(dirname "$out")"
  msg_info "Baixando: $url -> $out"
  _log_to_file "[FETCH] URL=$url OUT=$out"

  # prefer curl
  if command -v curl >/dev/null 2>&1; then
    # --fail: retorna erro se HTTP >=400; --location: segue redirects
    # --progress-bar imprime barra percentual amigável
    curl --fail --location --progress-bar -o "$out" "$url" 2>>"$LOGFILE" || {
      msg_error "Falha no download via curl: $url (veja $LOGFILE)"
      return 1
    }
    msg_ok "Download concluído: $(stat -c%s "$out" 2>/dev/null || echo '?') bytes"
    _log_to_file "[FETCH_OK] $out"
    return 0
  fi

  # fallback para wget com barra
  if command -v wget >/dev/null 2>&1; then
    # --progress=bar:force gera barra, -O para arquivo
    wget --quiet --show-progress --progress=bar:force -O "$out" "$url" 2>>"$LOGFILE" || {
      msg_error "Falha no download via wget: $url (veja $LOGFILE)"
      return 1
    }
    msg_ok "Download concluído: $(stat -c%s "$out" 2>/dev/null || echo '?') bytes"
    _log_to_file "[FETCH_OK] $out"
    return 0
  fi

  # fallback simples: use /bin/sh fetch via netcat? here just try wget without progress
  if command -v wget >/dev/null 2>&1; then
    wget -O "$out" "$url" 2>>"$LOGFILE" || {
      msg_error "Falha no download via wget (sem barra): $url"
      return 1
    }
    msg_ok "Download concluído (sem barra)"
    _log_to_file "[FETCH_OK] $out"
    return 0
  fi

  # último recurso: use /bin/sh + ftp/other -> não implementado
  msg_warn "Nenhum downloader encontrado (curl/wget). Tentando redirecionar via /dev/tcp (pode falhar)."
  # registra falha e retorna erro
  _log_to_file "[FETCH_FAIL] no downloader"
  return 2
}

# ----------- helper: mostrar progresso estimado (quando % conhecido)
# print_progress_bar <percent_int> <prefix>
print_progress_bar() {
  local percent=${1:-0}
  local prefix=${2:-""}
  local width=30
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local bar=$(printf '%0.s█' $(seq 1 $filled))
  local rest=$(printf '%0.s░' $(seq 1 $empty))
  printf "\r${CYAN}${prefix} [${bar}${rest}] ${percent}%%${RESET}"
  if [ "$percent" -eq 100 ]; then printf "\n"; fi
}

# ----------- exibição reusável de erro com link para log -----------
error_with_log() {
  msg_error "$*"
  msg_info "Ver logs em: $LOGFILE"
}

# ----------- exemplo de wrapper para executar comando com spinner e capture de logs -----------
# run_with_spinner "<mensagem>" <command...>
run_with_spinner() {
  local msg=$1; shift
  start_timer
  spinner_start "$msg"
  # executar comando e enviar stdout/stderr para logfile
  ( "$@" ) >>"$LOGFILE" 2>&1
  local rc=$?
  spinner_stop "$msg"
  end_timer
  return $rc
}

# ----------- fim do log.sh -----------
