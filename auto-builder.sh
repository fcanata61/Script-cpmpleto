#!/usr/bin/env bash
#
# auto-builder.sh
# Mini automated build system (single-file)
#
# Usage:
#   ./auto-builder.sh init         # create dirs + example config + sample package
#   ./auto-builder.sh run          # run full build pipeline (bootstrap optional)
#   ./auto-builder.sh build <pkg>  # build a single package by name
#   ./auto-builder.sh status       # show queue/status summary
#   ./auto-builder.sh clean        # remove work/ temp (keeps sources/artifacts)
#   ./auto-builder.sh help
#
# NOTE: Read header "Observações importantes" in the delivered text before running.
set -euo pipefail
shopt -s lastpipe

# -------- defaults and helper functions --------
ME="$(basename "$0")"
WD="$(pwd)"

# helper: print to stderr
loge() { echo "$@" >&2; }

# load master.conf file (simple KEY = VALUE parsing)
load_config() {
  CONFIG_FILE="${CONFIG_FILE:-master.conf}"
  if [ ! -f "$CONFIG_FILE" ]; then
    loge "Config file '$CONFIG_FILE' not found. Run './$ME init' to create an example."
    return 1
  fi
  # clear variables we will set
  unset ROOT ARCH MODE PARALLELISM SRC_DIR WORK_DIR ARTIFACT_DIR LOG_DIR DB_DIR PKG_DIR \
        MIRRORS RETRY_LIMIT RETRY_BACKOFF CFLAGS MAKEFLAGS CLEAN_ON_START KEEP_LOGS \
        ALLOW_CROSS BOOTSTRAP_MODE ZSTD_BIN TAR_BIN

  while IFS= read -r line || [ -n "$line" ]; do
    # strip comments and trim
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}" # ltrim
    line="${line%"${line##*[![:space:]]}"}" # rtrim
    [ -z "$line" ] && continue
    if [[ "$line" =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # expand simple ${VAR} references
      while [[ "$val" =~ \$\{([A-Za-z0-9_]+)\} ]]; do
        varname="${BASH_REMATCH[1]}"
        repl="${!varname:-}"
        val="${val//\$\{$varname\}/$repl}"
      done
      export "$key"="$val"
    fi
  done < "$CONFIG_FILE"

  # defaults
  PARALLELISM="${PARALLELISM:-2}"
  MAKEFLAGS="${MAKEFLAGS:- -j${PARALLELISM}}"
  CFLAGS="${CFLAGS:- -O2 -pipe}"
  RETRY_LIMIT="${RETRY_LIMIT:-2}"
  RETRY_BACKOFF="${RETRY_BACKOFF:-5}"   # seconds base
  KEEP_LOGS="${KEEP_LOGS:-yes}"
  CLEAN_ON_START="${CLEAN_ON_START:-no}"
  ALLOW_CROSS="${ALLOW_CROSS:-false}"
  BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-auto}"
  ZSTD_BIN="${ZSTD_BIN:-zstd}"
  TAR_BIN="${TAR_BIN:-tar}"
  return 0
}

# ensure dirs exist
ensure_dirs() {
  mkdir -p "$ROOT" "$SRC_DIR" "$WORK_DIR" "$ARTIFACT_DIR" "$LOG_DIR" "$DB_DIR" "$PKG_DIR"
}

# init skeleton + sample config + sample package
cmd_init() {
  if [ -f master.conf ]; then
    loge "master.conf already exists in $(pwd). Aborting init to avoid overwrite."
    exit 1
  fi
  cat > master.conf <<'EOF'
# master.conf - single-file configuration
ROOT = ./auto-builder
ARCH = x86-64
MODE = native
PARALLELISM = 2
SRC_DIR = ${ROOT}/sources
WORK_DIR = ${ROOT}/work
ARTIFACT_DIR = ${ROOT}/artifacts
LOG_DIR = ${ROOT}/logs
DB_DIR = ${ROOT}/db
PKG_DIR = ${ROOT}/packages
MIRRORS = https://ftp.gnu.org/gnu
RETRY_LIMIT = 2
RETRY_BACKOFF = 5
CFLAGS = -O2 -pipe
MAKEFLAGS = -j2
CLEAN_ON_START = no
KEEP_LOGS = yes
ALLOW_CROSS = false
BOOTSTRAP_MODE = auto
TAR_BIN = tar
ZSTD_BIN = zstd
EOF
  mkdir -p auto-builder/{sources,work,artifacts,logs,db,packages}
  # sample package bc (small classic)
  mkdir -p packages/bc
  cat > packages/bc/desc.txt <<'EOF'
NAME = bc
VERSION = 1.08.2
URL = https://ftp.gnu.org/gnu/bc/bc-1.08.2.tar.xz
SHA256 = 76e3a9531c7764bd13c600c1e016e6760d9b8379ba06d1ecc08d5a68
BUILD_DEPS = readline
RUN_DEPS =
BUILD_HINT = autotools
STAGE = 1
PRIORITY = normal
EOF

  cat > README.auto-builder.txt <<'EOF'
auto-builder initialization complete.
Usage examples:
  ./auto-builder.sh init   # (done)
  ./auto-builder.sh run    # run full build for all packages under packages/
  ./auto-builder.sh build bc  # build only bc
Logs and artifacts are under auto-builder/.
EOF

  echo "Initialized skeleton and sample package under ./auto-builder (master.conf created)."
  exit 0
}

# parse a recipe file packages/<pkg>/desc.txt into associative arrays (bash 4+)
declare -A RECIPE_NAME RECIPE_VERSION RECIPE_URL RECIPE_SHA RECIPE_BUILD_DEPS RECIPE_RUN_DEPS RECIPE_HINT RECIPE_STAGE RECIPE_PRIORITY
load_recipes() {
  # load all recipes
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    pkg="$(basename "$d")"
    f="$d/desc.txt"
    [ -f "$f" ] || { loge "Warning: $f missing, skipping"; continue; }
    # reset
    name=version=url=sha=build_deps=run_deps=hint=stage=priority=""
    while IFS= read -r l || [ -n "$l" ]; do
      l="${l%%#*}"
      l="${l#"${l%%[![:space:]]*}"}"
      l="${l%"${l##*[![:space:]]}"}"
      [ -z "$l" ] && continue
      if [[ "$l" =~ ^NAME[[:space:]]*=[[:space:]]*(.*)$ ]]; then name="${BASH_REMATCH[1]}"; fi
      if [[ "$l" =~ ^VERSION[[:space:]]*=[[:space:]]*(.*)$ ]]; then version="${BASH_REMATCH[1]}"; fi
      if [[ "$l" =~ ^URL[[:space:]]*=[[:space:]]*(.*)$ ]]; then url="${BASH_REMATCH[1]}"; fi
      if [[ "$l" =~ ^SHA256?[[:space:]]*=[[:space:]]*(.*)$ ]]; then sha="${BASH_REMATCH[1]}"; fi
      if [[ "$l" =~ ^BUILD_DEPS[[:space:]]*=[[:space:]]*(.*)$ ]]; then build_deps="${BASH_REMATCH[1]}"; fi
      if [[ "$l" =~ ^RUN_DEPS[[:space:]]*=[[:space:]]*(.*)$ ]]; then run_deps="${BASH_REMATCH[1]}"; fi
      if [[ "$l" =~ ^BUILD_HINT[[:space:]]*=[[:space:]]*(.*)$ ]]; then hint="${BASH_REMATCH[1]}"; fi
      if [[ "$l" =~ ^STAGE[[:space:]]*=[[:space:]]*(.*)$ ]]; then stage="${BASH_REMATCH[1]}"; fi
      if [[ "$l" =~ ^PRIORITY[[:space:]]*=[[:space:]]*(.*)$ ]]; then priority="${BASH_REMATCH[1]}"; fi
    done < "$f"
    RECIPE_NAME["$pkg"]="${name:-$pkg}"
    RECIPE_VERSION["$pkg"]="${version:-}"
    RECIPE_URL["$pkg"]="${url:-}"
    RECIPE_SHA["$pkg"]="${sha:-}"
    RECIPE_BUILD_DEPS["$pkg"]="${build_deps// /}"   # comma or space free
    RECIPE_RUN_DEPS["$pkg"]="${run_deps// /}"
    RECIPE_HINT["$pkg"]="${hint:-}"
    RECIPE_STAGE["$pkg"]="${stage:-0}"
    RECIPE_PRIORITY["$pkg"]="${priority:-normal}"
  done
}

# small helper: split deps into array (space or comma separated)
deps_to_array() {
  local s="$1"
  local arr=()
  s="${s//,/ }"
  for token in $s; do
    [ -n "$token" ] && arr+=("$token")
  done
  echo "${arr[@]}"
}

# resolver: greedy topological order (works for reasonable sets)
# outputs list of pkgnames in build order to stdout
resolve_deps_order() {
  declare -A pending
  declare -A have
  local all=()
  # gather all packages
  for pkg in "${!RECIPE_NAME[@]}"; do
    pending["$pkg"]=1
    all+=("$pkg")
  done
  local order=()
  local progress=1
  # mark packages with no BUILD_DEPS as satisfied initially if their deps empty
  while [ ${#pending[@]} -gt 0 ] && [ $progress -eq 1 ]; do
    progress=0
    for p in "${all[@]}"; do
      [ "${pending[$p]:-0}" -eq 1 ] || continue
      # gather build deps
      bdeps="${RECIPE_BUILD_DEPS[$p]:-}"
      bdeps="${bdeps//,/ }"
      ok=1
      if [ -n "$bdeps" ]; then
        for d in $bdeps; do
          [ -z "$d" ] && continue
          if [ "${have[$d]:-0}" -ne 1 ]; then ok=0; break; fi
        done
      fi
      if [ $ok -eq 1 ]; then
        order+=("$p")
        have["$p"]=1
        unset pending["$p"]
        progress=1
      fi
    done
  done

  # if still pending, we have cycles or missing deps — try to append remaining (best-effort)
  if [ ${#pending[@]} -gt 0 ]; then
    loge "Warning: unresolved dependencies or cycle detected. Appending remaining packages in arbitrary order."
    for p in "${all[@]}"; do
      if [ "${pending[$p]:-0}" -eq 1 ]; then
        order+=("$p")
      fi
    done
  fi

  # print order
  for p in "${order[@]}"; do
    echo "$p"
  done
}

# fetch: download source to SRC_DIR and verify SHA256 if provided
fetch_source() {
  local pkg="$1"
  local url="${RECIPE_URL[$pkg]}"
  local sha="${RECIPE_SHA[$pkg]}"
  if [ -z "$url" ]; then
    loge "Package $pkg has no URL in desc.txt"
    return 1
  fi
  local fname
  fname="$(basename "$url")"
  local dest="$SRC_DIR/$fname"
  if [ -f "$dest" ]; then
    if [ -n "$sha" ]; then
      if sha256sum -c <(echo "$sha  $dest") >/dev/null 2>&1; then
        loge "Using cached $dest (sha ok)"
        echo "$dest"
        return 0
      else
        loge "Cached $dest failed checksum, will redownload"
        rm -f "$dest"
      fi
    else
      loge "Using cached $dest (no sha provided)"
      echo "$dest"
      return 0
    fi
  fi

  # try curl then wget
  loge "Downloading $url -> $dest"
  if command -v curl >/dev/null 2>&1; then
    curl -L --retry 3 -o "$dest" "$url" || { loge "curl failed"; rm -f "$dest"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$dest" "$url" || { loge "wget failed"; rm -f "$dest"; return 1; }
  else
    loge "No curl or wget available"
    return 1
  fi

  if [ -n "$sha" ]; then
    if ! sha256sum -c <(echo "$sha  $dest") >/dev/null 2>&1; then
      loge "Downloaded file failed checksum"
      rm -f "$dest"
      return 1
    fi
  fi
  echo "$dest"
  return 0
}

# detect build system heuristics
detect_build_system() {
  local srcdir="$1"
  if [ -f "$srcdir/configure" ]; then
    echo "autotools"
  elif [ -f "$srcdir/CMakeLists.txt" ]; then
    echo "cmake"
  elif [ -f "$srcdir/meson.build" ]; then
    echo "meson"
  elif [ -f "$srcdir/Makefile" ] || [ -f "$srcdir/GNUmakefile" ]; then
    echo "makefile"
  else
    echo "unknown"
  fi
}

# build a single package
build_package() {
  local pkg="$1"
  local attempt="${2:-1}"
  local jobid
  jobid="$(date +%Y%m%d%H%M%S)-${pkg}-${RANDOM%10000}"
  local logjson="$LOG_DIR/${pkg}-${jobid}.jsonl"
  local logtxt="$LOG_DIR/${pkg}-${jobid}.log"
  local work="$WORK_DIR/${pkg}-${jobid}"
  mkdir -p "$work"
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pkg\":\"$pkg\",\"job\":\"$jobid\",\"phase\":\"start\",\"attempt\":$attempt}" >> "$logjson"
  echo "=== BUILD START $pkg (job $jobid) attempt $attempt ===" > "$logtxt"
  # fetch source
  local srcfile
  if ! srcfile="$(fetch_source "$pkg")"; then
    echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pkg\":\"$pkg\",\"job\":\"$jobid\",\"phase\":\"fetch\",\"level\":\"ERROR\",\"msg\":\"fetch failed\"}" >> "$logjson"
    echo "fetch failed" >> "$logtxt"
    return 2
  fi
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pkg\":\"$pkg\",\"job\":\"$jobid\",\"phase\":\"fetch\",\"level\":\"INFO\",\"src\":\"$srcfile\"}" >> "$logjson"
  echo "Fetched $srcfile" >> "$logtxt"

  # extract
  case "$srcfile" in
    *.tar.gz|*.tgz) $TAR_BIN -xzf "$srcfile" -C "$work" ;;
    *.tar.xz) $TAR_BIN -xJf "$srcfile" -C "$work" ;;
    *.tar.bz2) $TAR_BIN -xjf "$srcfile" -C "$work" ;;
    *.zip) unzip -q "$srcfile" -d "$work" ;;
    *) # try tar autodetect
       $TAR_BIN -xf "$srcfile" -C "$work" || { echo "extract failed" >> "$logtxt"; return 3; } ;;
  esac
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pkg\":\"$pkg\",\"job\":\"$jobid\",\"phase\":\"extract\",\"level\":\"INFO\"}" >> "$logjson"
  echo "Extracted to $work" >> "$logtxt"

  # find top-level source dir
  local srcdir
  srcdir="$(find "$work" -maxdepth 2 -mindepth 1 -type d | head -n1 || true)"
  [ -z "$srcdir" ] && srcdir="$work"
  echo "srcdir=$srcdir" >> "$logtxt"

  # apply patches if present
  if [ -d "$PKG_DIR/$pkg/patches" ]; then
    for p in "$PKG_DIR/$pkg/patches/"*; do
      [ -f "$p" ] || continue
      (cd "$srcdir" && patch -p1 < "$p") >> "$logtxt" 2>&1 || { echo "patch failed" >> "$logtxt"; }
    done
  fi

  # choose build system
  local hint="${RECIPE_HINT[$pkg]}"
  local bsys
  if [ -n "$hint" ]; then
    bsys="$hint"
  else
    bsys="$(detect_build_system "$srcdir")"
  fi
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pkg\":\"$pkg\",\"job\":\"$jobid\",\"phase\":\"detect\",\"build_system\":\"$bsys\"}" >> "$logjson"
  echo "Detected build system: $bsys" >> "$logtxt"

  # set up DESTDIR
  local destdir="$work/destdir"
  mkdir -p "$destdir"

  # export minimal env
  export CFLAGS MAKEFLAGS
  export DESTDIR="$destdir"

  # build steps
  local rc=0
  case "$bsys" in
    autotools)
      (cd "$srcdir" && \
        if [ -f autogen.sh ]; then ./autogen.sh >> "$logtxt" 2>&1 || rc=$?; fi; \
        ./configure --prefix=/usr >> "$logtxt" 2>&1 || rc=$?; \
        make $MAKEFLAGS >> "$logtxt" 2>&1 || rc=$?; \
        make DESTDIR="$destdir" install >> "$logtxt" 2>&1 || rc=$?)
      ;;
    cmake)
      (cd "$srcdir" && mkdir -p build && cd build && \
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr >> "$logtxt" 2>&1 || rc=$?; \
        make $MAKEFLAGS >> "$logtxt" 2>&1 || rc=$?; \
        make DESTDIR="$destdir" install >> "$logtxt" 2>&1 || rc=$?)
      ;;
    meson)
      (cd "$srcdir" && meson setup builddir --prefix=/usr >> "$logtxt" 2>&1 || rc=$?; \
        ninja -C builddir >> "$logtxt" 2>&1 || rc=$?; \
        ninja -C builddir install DESTDIR="$destdir" >> "$logtxt" 2>&1 || rc=$?)
      ;;
    makefile)
      (cd "$srcdir" && make $MAKEFLAGS >> "$logtxt" 2>&1 || rc=$?; \
        make DESTDIR="$destdir" install >> "$logtxt" 2>&1 || rc=$?)
      ;;
    *)
      echo "Unknown build system for $pkg" >> "$logtxt"
      rc=4
      ;;
  esac

  if [ $rc -ne 0 ]; then
    echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pkg\":\"$pkg\",\"job\":\"$jobid\",\"phase\":\"build\",\"level\":\"ERROR\",\"rc\":$rc}" >> "$logjson"
    echo "Build failed rc=$rc" >> "$logtxt"
    return $rc
  fi

  # package artifact
  local artifact="${ARTIFACT_DIR}/${pkg}-${RECIPE_VERSION[$pkg]}-${jobid}.tar.zst"
  # Create artifact from destdir contents
  (cd "$destdir" && $TAR_BIN -cf - . ) | $ZSTD_BIN -q -o "$artifact"
  local artsha
  artsha="$(sha256sum "$artifact" | awk '{print $1}')"
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pkg\":\"$pkg\",\"job\":\"$jobid\",\"phase\":\"package\",\"artifact\":\"$artifact\",\"sha256\":\"$artsha\"}" >> "$logjson"
  echo "Packaged artifact $artifact" >> "$logtxt"

  # manifest
  local manifest="${ARTIFACT_DIR}/${pkg}-${RECIPE_VERSION[$pkg]}-${jobid}.manifest.json"
  cat > "$manifest" <<-JSON
{
  "name": "${RECIPE_NAME[$pkg]}",
  "pkg": "$pkg",
  "version": "${RECIPE_VERSION[$pkg]}",
  "jobid": "$jobid",
  "artifact": "$artifact",
  "artifact_sha256": "$artsha",
  "source": "${RECIPE_URL[$pkg]}",
  "source_sha256": "${RECIPE_SHA[$pkg]}",
  "build_system": "$bsys",
  "build_start": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "status": "SUCCESS"
}
JSON

  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pkg\":\"$pkg\",\"job\":\"$jobid\",\"phase\":\"done\",\"artifact\":\"$artifact\"}" >> "$logjson"
  echo "BUILD SUCCESS: $pkg -> $artifact" >> "$logtxt"
  # optionally keep or remove work dir
  if [ "$KEEP_LOGS" = "no" ]; then
    rm -rf "$work"
  fi
  return 0
}

# worker: sequential build from order list (no concurrency internal)
worker_build_list() {
  local listfile="$1"
  while IFS= read -r pkg || [ -n "$pkg" ]; do
    [ -z "$pkg" ] && continue
    echo "=== Worker: building $pkg ==="
    # attempt with retries
    local attempt=1
    local ok=0
    while [ $attempt -le "$RETRY_LIMIT" ]; do
      if build_package "$pkg" "$attempt"; then
        ok=1
        break
      else
        echo "Package $pkg failed on attempt $attempt"
        sleep $(( RETRY_BACKOFF * attempt ))
      fi
      attempt=$((attempt+1))
    done
    if [ $ok -ne 1 ]; then
      echo "Package $pkg permanently failed after $RETRY_LIMIT attempts"
      # continue to next package
    fi
  done < "$listfile"
}

# run pipeline: load config, recipes, compute order, and build using PARALLELISM workers
cmd_run() {
  load_config || exit 1
  ensure_dirs
  load_recipes
  if [ ${#RECIPE_NAME[@]} -eq 0 ]; then
    loge "No packages found in $PKG_DIR"
    exit 1
  fi
  if [ "$CLEAN_ON_START" = "yes" ]; then
    loge "Cleaning work dir (CLEAN_ON_START=yes)"
    rm -rf "$WORK_DIR"/* || true
  fi

  mapfile -t ORDER < <(resolve_deps_order)
  echo "Build order resolved: ${ORDER[*]}"
  # split ORDER into N pieces for parallel workers (simple round-robin)
  local nworkers="${PARALLELISM:-2}"
  local tmpdir
  tmpdir="$(mktemp -d)"
  for ((i=0;i<nworkers;i++)); do
    > "$tmpdir/worker-$i.list"
  done
  local i=0
  for p in "${ORDER[@]}"; do
    echo "$p" >> "$tmpdir/worker-$(( i % nworkers )).list"
    i=$((i+1))
  done
  # launch workers
  for ((w=0; w<nworkers; w++)); do
    worker_build_list "$tmpdir/worker-$w.list" &
    pids[$w]=$!
    echo "Started worker $w pid ${pids[$w]}"
  done
  # wait all
  for pid in "${pids[@]}"; do wait "$pid" || true; done
  echo "All workers finished."
  rm -rf "$tmpdir"
}

# build single package command
cmd_build_one() {
  load_config || exit 1
  ensure_dirs
  load_recipes
  local pkg="$1"
  if [ -z "${RECIPE_NAME[$pkg]:-}" ]; then
    loge "Package $pkg not found in $PKG_DIR"
    exit 1
  fi
  build_package "$pkg"
}

# status: list available packages and brief info
cmd_status() {
  load_config || exit 1
  ensure_dirs
  load_recipes
  echo "Packages known: ${!RECIPE_NAME[@]}"
  echo
  echo "Artifacts present in $ARTIFACT_DIR:"
  ls -1 "$ARTIFACT_DIR" 2>/dev/null || echo "(none)"
  echo
  echo "Recent logs:"
  ls -1t "$LOG_DIR" 2>/dev/null | head -n 10 || echo "(none)"
}

# clean
cmd_clean() {
  load_config || exit 1
  ensure_dirs
  echo "Removing work directory contents..."
  rm -rf "$WORK_DIR"/*
  echo "Done."
}

# help
cmd_help() {
  cat <<EOF
$ME - mini automated builder (single-file)

Usage:
  $ME init                # create skeleton (master.conf and sample package)
  $ME run                 # run full pipeline: resolve order and build in parallel
  $ME build <pkg>         # build single package by name
  $ME status              # show status summary
  $ME clean               # remove work/ temporary build directories
  $ME help
EOF
}

# ------- command dispatch -------
case "${1:-help}" in
  init) cmd_init ;;
  run) cmd_run ;;
  build) shift; cmd_build_one "$1" ;;
  status) cmd_status ;;
  clean) cmd_clean ;;
  help|*) cmd_help ;;
esac
