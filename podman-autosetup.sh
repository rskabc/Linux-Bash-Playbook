#!/usr/bin/env bash
# Setup Podman + tools + configs + Quadlet deployments (anti-gagal) + colored logs
# Includes: Web HaloEats, Web Fornet, Web Halss, Observium, Nginx Proxy Manager, Zabbix Integration

set -euo pipefail
IFS=$'\n\t'

LOG_FILE="/var/log/podman-autosetup.log"
mkdir -p "$(dirname "$LOG_FILE")"

# ---- Color handling (only for TTY) ----
if [[ -t 1 ]]; then
  C_RESET="\033[0m"
  C_DIM="\033[2m"
  C_BOLD="\033[1m"
  C_RED="\033[31m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_BLUE="\033[34m"
else
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

ts() { date +"%Y-%m-%d %H:%M:%S"; }

log() {
  local msg="$*"
  # write plain (no ANSI) to log file
  echo -e "[$(ts)] ${msg}" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >>"$LOG_FILE"
  # print to screen (colored already inside msg)
  echo -e "[$(ts)] ${msg}"
}

info() { log "${C_BLUE}ℹ️  $*${C_RESET}"; }
ok()   { log "${C_GREEN}✅ $*${C_RESET}"; }
warn() { log "${C_YELLOW}⚠️  $*${C_RESET}"; }
err()  { log "${C_RED}❌ $*${C_RESET}"; }

FAILED_STEPS=()
fail_step() { FAILED_STEPS+=("$1"); err "$1"; }

trap 'err "Script error di baris $LINENO (cek log: $LOG_FILE)"; exit 1' ERR

if [[ "${EUID}" -ne 0 ]]; then
  err "Harus dijalankan sebagai root. Jalankan: sudo -i"
  exit 1
fi

PKG_MGR=""
if command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  PKG_MGR="yum"
else
  err "dnf/yum tidak ditemukan."
  exit 1
fi

pkg_update() {
  info "Repo makecache ($PKG_MGR)..."
  if ! $PKG_MGR -y makecache >>"$LOG_FILE" 2>&1; then
    warn "makecache gagal (repo/network). lanjut..."
  else
    ok "Repo metadata siap."
  fi
}

pkg_install() {
  local pkgs=("$@")
  info "Install: ${pkgs[*]}"
  $PKG_MGR -y install "${pkgs[@]}" >>"$LOG_FILE" 2>&1
}

pkg_is_installed() { rpm -q "$1" >/dev/null 2>&1; }

enable_service_now() {
  local svc="$1"
  if systemctl list-unit-files | grep -qE "^${svc}\."; then
    info "Enable & start: $svc"
    if systemctl enable --now "$svc" >>"$LOG_FILE" 2>&1; then
      ok "$svc aktif."
    else
      fail_step "Gagal enable/start service: $svc"
    fi
  else
    warn "Unit $svc tidak ditemukan (skip)."
  fi
}

ensure_epel() {
  if ! pkg_is_installed epel-release; then
    info "Install epel-release (untuk htop, dll)..."
    if pkg_install epel-release; then
      ok "epel-release terpasang."
    else
      warn "epel-release gagal dipasang. lanjut..."
    fi
  else
    ok "epel-release sudah ada."
  fi
}

install_base_packages() {
  log "=============================="
  log "${C_BOLD}📦 Install paket dasar${C_RESET}"
  log "=============================="

  pkg_update
  ensure_epel

  # "yum-utils" di sebagian RHEL/Alma modern bisa tidak ada -> fallback dnf-utils
  local pkgs=(
    curl wget git nano tree
    net-tools bind-utils traceroute
    chrony bash-completion
    cockpit cockpit-ws
    net-snmp net-snmp-utils
    htop
  )

  for p in "${pkgs[@]}"; do
    if pkg_is_installed "$p"; then
      ok "Paket sudah ada: $p"
    else
      if pkg_install "$p"; then
        ok "Terpasang: $p"
      else
        fail_step "Gagal install paket: $p"
      fi
    fi
  done

  # utils tambahan: yum-utils atau dnf-utils
  if pkg_is_installed yum-utils; then
    ok "Paket sudah ada: yum-utils"
  else
    info "(Opsional) Install yum-utils/dnf-utils..."
    if $PKG_MGR -y install yum-utils >>"$LOG_FILE" 2>&1; then
      ok "Terpasang: yum-utils"
    elif $PKG_MGR -y install dnf-utils >>"$LOG_FILE" 2>&1; then
      ok "Terpasang: dnf-utils"
    else
      warn "yum-utils/dnf-utils tidak bisa diinstall (skip)."
    fi
  fi
}

install_podman_stack() {
  log "=============================="
  log "${C_BOLD}🐳 Install Podman stack (tanpa iptables)${C_RESET}"
  log "=============================="

  local pkgs=(
    podman
    slirp4netns
    fuse-overlayfs
    shadow-utils-subid
    policycoreutils-python-utils
  )

  for p in "${pkgs[@]}"; do
    if pkg_is_installed "$p"; then
      ok "Paket sudah ada: $p"
    else
      if pkg_install "$p"; then
        ok "Terpasang: $p"
      else
        fail_step "Gagal install paket Podman stack: $p"
      fi
    fi
  done

  if command -v podman >/dev/null 2>&1; then
    ok "Podman: $(podman --version 2>/dev/null || true)"
  else
    fail_step "Podman tidak ditemukan setelah instalasi."
  fi

  mkdir -p /etc/containers/systemd
  ok "Folder Quadlet siap: /etc/containers/systemd"
}

enable_cockpit() {
  log "=============================="
  log "${C_BOLD}🧩 Enable Cockpit${C_RESET}"
  log "=============================="

  pkg_install cockpit cockpit-ws >/dev/null 2>&1 || true

  if systemctl list-unit-files | grep -q '^cockpit\.socket'; then
    enable_service_now cockpit.socket
  else
    warn "cockpit.socket tidak ditemukan. Cek: systemctl list-unit-files | grep cockpit"
  fi
}

configure_bash_completion() {
  log "=============================="
  log "${C_BOLD}⌨️  Bash completion${C_RESET}"
  log "=============================="

  local line='source /etc/profile.d/bash_completion.sh'
  if [[ -f /etc/profile.d/bash_completion.sh ]]; then
    if ! grep -qF "$line" /root/.bashrc 2>/dev/null; then
      echo "$line" >> /root/.bashrc
      ok "Ditambahkan ke /root/.bashrc: $line"
    else
      ok "Sudah ada di /root/.bashrc"
    fi
  else
    warn "/etc/profile.d/bash_completion.sh tidak ditemukan."
  fi
}

configure_snmp() {
  log "=============================="
  log "${C_BOLD}📡 SNMP v2c${C_RESET}"
  log "=============================="

  mkdir -p /etc/snmp

  cat <<EOF > /etc/snmp/snmpd.conf
com2sec readonly  default         public
group   MyROGroup v2c             readonly
view    all    included  .1                               80
access  MyROGroup ""      v2c    noauth  exact  all    none   none
syslocation Jakarta, Indonesia
syscontact reski.abuchaer@gmail.com
EOF

  enable_service_now snmpd.service || true
  enable_service_now snmpd || true
}

configure_chrony() {
  log "=============================="
  log "${C_BOLD}🕒 Chrony (NTP)${C_RESET}"
  log "=============================="

  if [[ -f /etc/chrony.conf ]]; then
    sed -i 's|^pool.*|server 0.id.pool.ntp.org iburst\nserver 1.id.pool.ntp.org iburst|' /etc/chrony.conf

    if systemctl list-unit-files | grep -q '^chronyd\.service'; then
      enable_service_now chronyd.service
    else
      enable_service_now chronyd
    fi

    info "chronyc sources -v:"
    chronyc sources -v | tee -a "$LOG_FILE" || warn "chronyc gagal (tunggu sync beberapa saat)."
  else
    fail_step "/etc/chrony.conf tidak ditemukan."
  fi
}

configure_ssh_banner() {
  log "=============================="
  log "${C_BOLD}🛡️  SSH Banner${C_RESET}"
  log "=============================="

  cat <<'EOB' > /etc/issue.net
Peringatan: Akses ke sistem ini diawasi. Segala aktivitas Anda dapat dicatat dan diaudit.
Jika Anda tidak berwenang, segera keluar dari sistem ini.
EOB

  if [[ -f /etc/ssh/sshd_config ]]; then
    if grep -qE '^\s*Banner\s+' /etc/ssh/sshd_config; then
      sed -i 's|^\s*Banner\s\+.*|Banner /etc/issue.net|' /etc/ssh/sshd_config
    else
      echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
    fi

    systemctl restart sshd >>"$LOG_FILE" 2>&1 && ok "Banner SSH aktif." || fail_step "Gagal restart sshd."
  else
    fail_step "/etc/ssh/sshd_config tidak ditemukan."
  fi
}

# ---------- Git + Quadlet helpers ----------
git_upsert_repo() {
  local repo_url="$1"
  local dest_dir="$2"

  mkdir -p "$(dirname "$dest_dir")"

  if [[ -d "$dest_dir/.git" ]]; then
    info "git pull: $dest_dir"
    if git -C "$dest_dir" pull --rebase >>"$LOG_FILE" 2>&1; then
      ok "Git pull OK: $dest_dir"
    else
      warn "Git pull gagal: $dest_dir (lanjut pakai file lokal)"
      fail_step "Git pull gagal: $dest_dir"
    fi
  else
    info "git clone: $repo_url -> $dest_dir"
    if git clone "$repo_url" "$dest_dir" >>"$LOG_FILE" 2>&1; then
      ok "Git clone OK: $dest_dir"
    else
      fail_step "Git clone gagal: $dest_dir"
    fi
  fi
}

pull_images_from_quadlet_dir() {
  local quadlet_dir="$1"
  if [[ ! -d "$quadlet_dir" ]]; then
    warn "Folder quadlet tidak ditemukan: $quadlet_dir (skip pull image)"
    return 0
  fi

  info "Pull image dari Image= (*.container) di: $quadlet_dir"

  local images=()
  while IFS= read -r f; do
    local img
    img="$(grep -E '^\s*Image\s*=' "$f" | head -n1 | cut -d'=' -f2- | xargs || true)"
    [[ -n "$img" ]] && images+=("$img")
  done < <(find "$quadlet_dir" -maxdepth 1 -type f -name "*.container" 2>/dev/null)

  if [[ "${#images[@]}" -eq 0 ]]; then
    warn "Tidak ada Image= ditemukan di *.container (skip pull)."
    return 0
  fi

  mapfile -t images < <(printf "%s\n" "${images[@]}" | awk '!seen[$0]++')

  for img in "${images[@]}"; do
    info "podman pull $img"
    if podman pull "$img" >>"$LOG_FILE" 2>&1; then
      ok "Pull OK: $img"
    else
      fail_step "Pull gagal: $img"
    fi
  done
}

systemd_reload() {
  info "systemctl daemon-reload"
  systemctl daemon-reload >>"$LOG_FILE" 2>&1 && ok "daemon-reload OK" || fail_step "daemon-reload gagal"
}

start_service() {
  local svc="$1"
  info "Start: $svc"
  systemctl start "$svc" >>"$LOG_FILE" 2>&1 && ok "Running: $svc" || fail_step "Gagal start: $svc"
}

enable_now_services() {
  # enable + start bareng
  info "Enable --now: $*"
  systemctl enable --now "$@" >>"$LOG_FILE" 2>&1 && ok "Enable --now sukses." || fail_step "Enable --now gagal."
}

# ---------- Deploy web apps ----------
deploy_web_app_quadlet() {
  local app="$1"
  local repo="$2"
  local opt_dir="$3"
  local unit_file="$4"

  log "=============================="
  log "${C_BOLD}🚀 Deploy: $app${C_RESET}"
  log "=============================="

  git_upsert_repo "$repo" "$opt_dir"
  pull_images_from_quadlet_dir "$opt_dir/quadlet"

  ln -sf "$opt_dir/quadlet/$unit_file" "/etc/containers/systemd/$unit_file"
  ok "Symlink: /etc/containers/systemd/$unit_file -> $opt_dir/quadlet/$unit_file"

  systemd_reload
  start_service "${unit_file%.container}.service"
}

deploy_observium_quadlet() {
  local repo="$1"
  local opt_dir="$2"

  log "=============================="
  log "${C_BOLD}🚀 Deploy: Observium${C_RESET}"
  log "=============================="

  git_upsert_repo "$repo" "$opt_dir"
  pull_images_from_quadlet_dir "$opt_dir/quadlet"

  ln -sf "$opt_dir/quadlet/observium.network"        "/etc/containers/systemd/observium.network"
  ln -sf "$opt_dir/quadlet/db_data.volume"           "/etc/containers/systemd/db_data.volume"
  ln -sf "$opt_dir/quadlet/observium_data.volume"    "/etc/containers/systemd/observium_data.volume"
  ln -sf "$opt_dir/quadlet/observium_rrd.volume"     "/etc/containers/systemd/observium_rrd.volume"
  ln -sf "$opt_dir/quadlet/observium_logs.volume"    "/etc/containers/systemd/observium_logs.volume"
  ln -sf "$opt_dir/quadlet/observium-db.container"   "/etc/containers/systemd/observium-db.container"
  ln -sf "$opt_dir/quadlet/observium-app.container"  "/etc/containers/systemd/observium-app.container"

  ok "Symlink Observium Quadlet selesai."
  systemd_reload
  start_service "observium-db.service"
  start_service "observium-app.service"
}

deploy_npm_quadlet() {
  local repo="$1"
  local opt_dir="/opt/NginxProxyManager"
  local unit_file="npm.container"

  log "=============================="
  log "${C_BOLD}🚀 Deploy: Nginx Proxy Manager${C_RESET}"
  log "=============================="

  git_upsert_repo "$repo" "$opt_dir"
  pull_images_from_quadlet_dir "$opt_dir/quadlet"

  ln -sf "$opt_dir/quadlet/$unit_file" "/etc/containers/systemd/$unit_file"
  ok "Symlink: /etc/containers/systemd/$unit_file -> $opt_dir/quadlet/$unit_file"

  systemd_reload
  start_service "npm.service"
}

# ---------- Deploy Zabbix (UPDATED sesuai script kamu) ----------
deploy_zabbix_quadlet() {
  local repo="$1"
  local opt_dir="/opt/zabbix-integration"

  log "=============================="
  log "${C_BOLD}🚀 Deploy: Zabbix Integration${C_RESET}"
  log "=============================="

  git_upsert_repo "$repo" "$opt_dir"
  pull_images_from_quadlet_dir "$opt_dir/quadlet"

  # === SYMLINK PERSIS SESUAI FORMAT YANG KAMU KASIH ===
  ln -sf /opt/zabbix-integration/quadlet/zabbix.network \
         /etc/containers/systemd/zabbix.network

  ln -sf /opt/zabbix-integration/quadlet/zabbix-postgres.volume \
         /etc/containers/systemd/zabbix-postgres.volume

  ln -sf /opt/zabbix-integration/quadlet/zabbix-postgres-backup.volume \
         /etc/containers/systemd/zabbix-postgres-backup.volume

  ln -sf /opt/zabbix-integration/quadlet/zabbix-database-backups.volume \
         /etc/containers/systemd/zabbix-database-backups.volume

  ln -sf /opt/zabbix-integration/quadlet/zabbix-db.container \
         /etc/containers/systemd/zabbix-db.container

  ln -sf /opt/zabbix-integration/quadlet/zabbix-server.container \
         /etc/containers/systemd/zabbix-server.container

  ln -sf /opt/zabbix-integration/quadlet/zabbix-web.container \
         /etc/containers/systemd/zabbix-web.container

  ln -sf /opt/zabbix-integration/quadlet/zabbix-agent.container \
         /etc/containers/systemd/zabbix-agent.container

  ln -sf /opt/zabbix-integration/quadlet/zabbix-backup.container \
         /etc/containers/systemd/zabbix-backup.container

  ln -sf /opt/zabbix-integration/quadlet/zbx-mikrotik-sync.container \
         /etc/containers/systemd/zbx-mikrotik-sync.container

  ok "Symlink Zabbix Quadlet selesai."

  systemd_reload

  # Start bareng (sesuai yang kamu minta)
  info "Start semua service Zabbix (bareng)..."
  systemctl start \
    zabbix-db.service \
    zabbix-server.service \
    zabbix-web.service \
    zabbix-agent.service \
    zabbix-backup.service \
    zbx-mikrotik-sync.service >>"$LOG_FILE" 2>&1 || true

  # Enable --now bareng (ini juga akan memastikan running)
  enable_now_services \
    zabbix-db.service \
    zabbix-server.service \
    zabbix-web.service \
    zabbix-agent.service \
    zabbix-backup.service \
    zbx-mikrotik-sync.service
}

# ---------- MAIN ----------
log "${C_BOLD}🧾 Mulai setup. Log: $LOG_FILE${C_RESET}"

install_base_packages
install_podman_stack
enable_cockpit
configure_bash_completion
configure_snmp
configure_chrony
configure_ssh_banner

# Token env (JANGAN hardcode token di script/README)
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  warn "GITHUB_TOKEN belum diset. Clone repo privat akan gagal."
  warn "Set dulu: export GITHUB_TOKEN='github_pat_xxxxx'"
fi

HALOEATS_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/web-haloeats.git"
FORNET_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/web-fornet.git"
HALSS_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/web-halss.git"
OBSERVIUM_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/Observium-Docker.git"
NPM_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/NginxProxyManager.git"
ZBX_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/zabbix-integration.git"

deploy_web_app_quadlet "Web HaloEats"    "$HALOEATS_REPO" "/opt/web-haloeats" "web-haloeats.container"
deploy_web_app_quadlet "Web Fornet"      "$FORNET_REPO"   "/opt/web-fornet"   "web-fornet.container"
deploy_web_app_quadlet "Web HalssMakeup" "$HALSS_REPO"    "/opt/web-halss"    "web-halss.container"
deploy_observium_quadlet "$OBSERVIUM_REPO" "/opt/Observium-Docker"
deploy_npm_quadlet "$NPM_REPO"

# Zabbix (UPDATED sesuai permintaan kamu)
deploy_zabbix_quadlet "$ZBX_REPO"

log ""
log "=============================="
log "${C_BOLD}☕ SUMMARY (setelah ngopi)${C_RESET}"
log "=============================="
log "Podman     : $(podman --version 2>/dev/null || echo 'N/A')"
log "Cockpit    : $(systemctl is-active cockpit.socket 2>/dev/null || echo 'unknown')"
log "SNMPD      : $(systemctl is-active snmpd 2>/dev/null || echo 'unknown')"
log "Chronyd    : $(systemctl is-active chronyd 2>/dev/null || echo 'unknown')"
log "SSHD       : $(systemctl is-active sshd 2>/dev/null || echo 'unknown')"
log ""

log "Zabbix services:"
for s in zabbix-db.service zabbix-server.service zabbix-web.service zabbix-agent.service zabbix-backup.service zbx-mikrotik-sync.service; do
  log " - $s : $(systemctl is-active "$s" 2>/dev/null || echo 'unknown')"
done

log ""
log "Quadlet dir: /etc/containers/systemd"
ls -lah /etc/containers/systemd | tee -a "$LOG_FILE" || true
log ""

if [[ "${#FAILED_STEPS[@]}" -gt 0 ]]; then
  warn "Ada beberapa langkah gagal:"
  for f in "${FAILED_STEPS[@]}"; do warn " - $f"; done
  warn "Cek log: $LOG_FILE"
  exit 2
else
  ok "Selesai tanpa error fatal. Log: $LOG_FILE"
fi
