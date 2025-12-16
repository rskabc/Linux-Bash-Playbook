#!/usr/bin/env bash
set -u
# Tidak pakai set -e agar script tetap lanjut walau ada step gagal

LOG_FILE="/var/log/podman-autosetup.log"
mkdir -p "$(dirname "$LOG_FILE")" || true
touch "$LOG_FILE" 2>/dev/null || true

# =========================
# CONFIG - edit sesuai kebutuhan
# =========================
BASE_DIR="/opt"

# --- Git repos (isi bila mau auto clone; boleh kosong) ---
REPO_WEB_HALSS=""        # contoh: https://github.com/xxx/web-halss.git
REPO_WEB_HALOEATS=""     # contoh: https://github.com/xxx/web-haloeats.git
REPO_WEB_FORNET=""       # contoh: https://github.com/xxx/web-fornet.git
REPO_OBSERVIUM=""        # contoh: https://github.com/xxx/Observium-Docker.git

# --- Deploy paths ---
DIR_WEB_HALSS="${BASE_DIR}/web-halss"
DIR_WEB_HALOEATS="${BASE_DIR}/web-haloeats"
DIR_WEB_FORNET="${BASE_DIR}/web-fornet"
DIR_OBSERVIUM="${BASE_DIR}/Observium-Docker"

# --- Ports (ubah kalau bentrok) ---
PORT_HALSS="8001"
PORT_HALOEATS="8005"
PORT_FORNET="8006"

# =========================
# UI helpers (auto fallback UTF-8)
# =========================
supports_utf8() {
  [[ "${LANG:-}" == *UTF-8* || "${LC_ALL:-}" == *UTF-8* ]]
}

if supports_utf8; then
  ICON_OK="☑"
  ICON_FAIL="☒"
  ICON_WARN="▣"
  ICON_STEP="➤"
else
  ICON_OK="[OK]"
  ICON_FAIL="[FAIL]"
  ICON_WARN="[WARN]"
  ICON_STEP=">>"
fi

ts() { date '+%F %T'; }

# IMPORTANT: tampilkan ke layar + simpan ke log
log() {
  local msg="$*"
  printf "[%s] %s\n" "$(ts)" "$msg" | tee -a "$LOG_FILE"
}

ok()   { log "$ICON_OK  $*"; }
fail() { log "$ICON_FAIL $*"; }
warn() { log "$ICON_WARN $*"; }
step() { log "$ICON_STEP $*"; }

run() {
  local title="$1"; shift
  # jalankan command, tetap log stderr/stdout ke file (dan tidak menenggelamkan output utama)
  "$@" >>"$LOG_FILE" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then ok "$title"; else fail "$title (rc=$rc)"; fi
  return $rc
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# =========================
# Git helpers
# =========================
git_repo_status() {
  local path="$1"
  if [[ -d "$path/.git" ]]; then
    local branch commit remote
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '-')"
    commit="$(git -C "$path" rev-parse --short HEAD 2>/dev/null || echo '-')"
    remote="$(git -C "$path" remote get-url origin 2>/dev/null || echo '-')"
    ok "Git repo: $path (branch=$branch commit=$commit)"
    log "      remote: $remote"
  else
    warn "Git repo: $path (tidak ditemukan .git)"
  fi
}

clone_or_update_repo() {
  local url="$1"
  local path="$2"

  if [[ -z "$url" ]]; then
    warn "Repo URL kosong untuk $path (skip clone/update)"
    return 0
  fi

  if [[ -d "$path/.git" ]]; then
    step "Git pull: $path"
    run "Git pull $path" git -C "$path" pull --rebase
  else
    mkdir -p "$(dirname "$path")"
    step "Git clone: $url -> $path"
    run "Git clone $path" git clone "$url" "$path"
  fi
}

# =========================
# Quadlet helpers
# =========================
ensure_symlink() {
  local src="$1"
  local dst="$2"

  if [[ ! -e "$src" ]]; then
    fail "Source tidak ada: $src"
    return 1
  fi

  # hindari symlink loop
  if [[ -L "$dst" ]]; then
    local resolved
    resolved="$(readlink -f "$dst" 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
      rm -f "$dst" >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  run "Symlink: $dst -> $src" ln -sf "$src" "$dst"
}

svc_exists() { systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

svc_status_line() {
  local unit="$1"
  if svc_exists "$unit"; then
    local st
    st="$(systemctl is-active "$unit" 2>/dev/null || true)"
    case "$st" in
      active) ok   "Service $unit : $st" ;;
      failed) fail "Service $unit : $st" ;;
      *)      warn "Service $unit : $st" ;;
    esac
  else
    warn "Service $unit : not-found"
  fi
}

# =========================
# Writers for web containers (nginx static)
# =========================
write_nginx_quadlet() {
  local name="$1"
  local port="$2"
  local rootdir="$3"
  local quadlet_dir="$4"

  mkdir -p "$quadlet_dir" "$rootdir"

  if [[ ! -f "${rootdir}/index.html" ]]; then
    echo "<h1>${name} - fresh install</h1>" > "${rootdir}/index.html"
  fi

  cat > "${quadlet_dir}/${name}.container" <<EOF
[Container]
ContainerName=${name}
Image=docker.io/library/nginx:alpine
PublishPort=${port}:80
Volume=${rootdir}:/usr/share/nginx/html:ro,Z
LogDriver=journald

[Install]
WantedBy=multi-user.target
EOF

  ok "Write quadlet: ${quadlet_dir}/${name}.container"
}

# =========================
# MAIN
# =========================
step "Mulai podman autosetup (log: $LOG_FILE)"

if [[ $EUID -ne 0 ]]; then
  fail "Jalankan sebagai root."
  exit 1
fi

if ! have_cmd podman; then
  fail "podman tidak ditemukan. Install dulu: dnf install -y podman"
  exit 1
fi

# Git sync
step "Git sync repos (opsional)"
if have_cmd git; then
  clone_or_update_repo "$REPO_WEB_HALSS" "$DIR_WEB_HALSS"
  clone_or_update_repo "$REPO_WEB_HALOEATS" "$DIR_WEB_HALOEATS"
  clone_or_update_repo "$REPO_WEB_FORNET" "$DIR_WEB_FORNET"
  clone_or_update_repo "$REPO_OBSERVIUM" "$DIR_OBSERVIUM"
else
  warn "git tidak ada (skip clone/update)"
fi

# Generate Quadlet web apps
step "Generate Quadlet untuk web-halss/web-haloeats/web-fornet (nginx static)"
write_nginx_quadlet "web-halss"    "$PORT_HALSS"    "${DIR_WEB_HALSS}/web"    "${DIR_WEB_HALSS}/quadlet"
write_nginx_quadlet "web-haloeats" "$PORT_HALOEATS" "${DIR_WEB_HALOEATS}/web" "${DIR_WEB_HALOEATS}/quadlet"
write_nginx_quadlet "web-fornet"   "$PORT_FORNET"   "${DIR_WEB_FORNET}/web"   "${DIR_WEB_FORNET}/quadlet"

# Symlink
step "Symlink Quadlet ke /etc/containers/systemd"
mkdir -p /etc/containers/systemd

ensure_symlink "${DIR_WEB_HALSS}/quadlet/web-halss.container"       "/etc/containers/systemd/web-halss.container"
ensure_symlink "${DIR_WEB_HALOEATS}/quadlet/web-haloeats.container" "/etc/containers/systemd/web-haloeats.container"
ensure_symlink "${DIR_WEB_FORNET}/quadlet/web-fornet.container"     "/etc/containers/systemd/web-fornet.container"

# Observium: symlink jika file ada
step "Symlink Observium Quadlet (jika ada)"
for f in observium.network db_data.volume observium_data.volume observium_rrd.volume observium_logs.volume observium-db.container observium-app.container; do
  if [[ -e "${DIR_OBSERVIUM}/quadlet/${f}" ]]; then
    ensure_symlink "${DIR_OBSERVIUM}/quadlet/${f}" "/etc/containers/systemd/${f}"
  else
    warn "Observium quadlet tidak ada: ${DIR_OBSERVIUM}/quadlet/${f} (skip)"
  fi
done

# Reload
step "systemctl daemon-reload"
run "daemon-reload" systemctl daemon-reload

step "Cek quadlet-generator (tail)"
run "journal quadlet-generator tail" bash -lc 'journalctl -b -t quadlet-generator --no-pager | tail -n 40'

# Start services (tidak fatal jika gagal)
step "Start web services"
run "Start web-halss.service" systemctl start web-halss.service || true
run "Start web-haloeats.service" systemctl start web-haloeats.service || true
run "Start web-fornet.service" systemctl start web-fornet.service || true

step "Start Observium services (kalau ada)"
run "Start observium-db.service" systemctl start observium-db.service || true
run "Start observium-app.service" systemctl start observium-app.service || true

# =========================
# SUMMARY
# =========================
echo "============================="
echo "SUMMARY (setelah ngopi)"
echo "============================="

echo
step "Core services"
svc_status_line podman.service
svc_status_line sshd.service
svc_status_line snmpd.service
svc_status_line cockpit.socket
svc_status_line cockpit.service

echo
step "Quadlet services"
svc_status_line web-halss.service
svc_status_line web-haloeats.service
svc_status_line web-fornet.service
svc_status_line observium-db.service
svc_status_line observium-app.service

echo
step "Podman containers (running)"
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Networks}}" | tee -a "$LOG_FILE" || true

echo
step "Git repo status"
if have_cmd git; then
  git_repo_status "$DIR_WEB_HALSS"
  git_repo_status "$DIR_WEB_HALOEATS"
  git_repo_status "$DIR_WEB_FORNET"
  git_repo_status "$DIR_OBSERVIUM"
else
  warn "git tidak ada (skip)"
fi

echo
step "Quadlet Units (/etc/containers/systemd)"
ls -la /etc/containers/systemd | tee -a "$LOG_FILE" || true

echo
ok "Selesai. Jika ada FAIL, cek log: $LOG_FILE"
exit 0
