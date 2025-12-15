#!/usr/bin/env bash
# Setup Podman + tools + configs + Quadlet deployments
# Target: AlmaLinux/RHEL/CentOS (dnf/yum)

set -u
IFS=$'\n\t'

LOG_FILE="/var/log/setup_podman_quadlet_stack.log"
mkdir -p "$(dirname "$LOG_FILE")"

# --------- Pretty logging ----------
ts() { date +"%Y-%m-%d %H:%M:%S"; }
log() { echo -e "[$(ts)] $*" | tee -a "$LOG_FILE"; }
ok() { log "✅ $*"; }
warn() { log "⚠️  $*"; }
err() { log "❌ $*"; }

FAILED_STEPS=()
fail_step() { FAILED_STEPS+=("$1"); err "$1"; }

# --------- Safety checks ----------
if [[ "${EUID}" -ne 0 ]]; then
  err "Harus dijalankan sebagai root. Coba: sudo -i"
  exit 1
fi

# --------- Detect package manager ----------
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
  log "🔄 Update metadata repo ($PKG_MGR makecache)..."
  if ! $PKG_MGR -y makecache >>"$LOG_FILE" 2>&1; then
    warn "makecache gagal, lanjut (repo mungkin sedang bermasalah)."
  else
    ok "Metadata repo siap."
  fi
}

pkg_install() {
  local pkgs=("$@")
  log "📦 Install paket: ${pkgs[*]}"
  if ! $PKG_MGR -y install "${pkgs[@]}" >>"$LOG_FILE" 2>&1; then
    return 1
  fi
  return 0
}

pkg_is_installed() {
  rpm -q "$1" >/dev/null 2>&1
}

enable_service_now() {
  local svc="$1"
  if systemctl list-unit-files | grep -qE "^${svc}\."; then
    log "🔧 Enable & start: $svc"
    if systemctl enable --now "$svc" >>"$LOG_FILE" 2>&1; then
      ok "$svc aktif."
    else
      fail_step "Gagal enable/start service: $svc"
    fi
  else
    warn "Unit $svc tidak ditemukan (skip)."
  fi
}

# --------- EPEL for htop (umumnya) ----------
ensure_epel() {
  # Aman: coba install epel-release; jika sudah ada ya sudah
  if ! pkg_is_installed epel-release; then
    log "📦 Mencoba install epel-release (dibutuhkan untuk htop pada banyak sistem)..."
    if pkg_install epel-release; then
      ok "epel-release terpasang."
    else
      warn "epel-release gagal dipasang. Jika htop gagal, periksa repo EPEL."
    fi
  else
    ok "epel-release sudah ada."
  fi
}

# --------- Packages selection (RHEL-ish) ----------
install_base_packages() {
  # yum-utils kadang bernama dnf-utils (RHEL8/9)
  local yum_utils_pkg="yum-utils"
  if ! repoquery -q dnf-utils >/dev/null 2>&1; then
    yum_utils_pkg="yum-utils"
  else
    yum_utils_pkg="dnf-utils"
  fi

  local pkgs=(
    curl wget git nano tree
    net-tools bind-utils traceroute
    chrony bash-completion
    "$yum_utils_pkg"
    cockpit
    net-snmp net-snmp-utils
    htop
  )

  pkg_update
  ensure_epel

  # Install satu per satu agar “anti gagal” (tetap lanjut walau 1 paket bermasalah)
  for p in "${pkgs[@]}"; do
    if pkg_is_installed "$p"; then
      ok "Paket sudah ada: $p"
    else
      log "➡️  Install: $p"
      if pkg_install "$p"; then
        ok "Terpasang: $p"
      else
        fail_step "Gagal install paket: $p"
      fi
    fi
  done
}

install_podman_stack() {
  # Dependensi umum podman + networking
  local pkgs=(
    podman
    podman-plugins
    containernetworking-plugins
    slirp4netns
    fuse-overlayfs
    uidmap
    iptables
    policycoreutils-python-utils
  )

  log "🐳 Memastikan Podman + dependensi pendukung..."
  for p in "${pkgs[@]}"; do
    if pkg_is_installed "$p"; then
      ok "Paket sudah ada: $p"
    else
      log "➡️  Install: $p"
      if pkg_install "$p"; then
        ok "Terpasang: $p"
      else
        fail_step "Gagal install paket Podman stack: $p"
      fi
    fi
  done

  if command -v podman >/dev/null 2>&1; then
    ok "Podman versi: $(podman --version 2>/dev/null || true)"
  else
    fail_step "Podman tidak ditemukan setelah instalasi."
  fi

  # Pastikan folder quadlet systemd
  mkdir -p /etc/containers/systemd
  ok "Folder Quadlet: /etc/containers/systemd siap."
}

# --------- Requested configs ----------
configure_bash_completion() {
  log "❓ Mengaktifkan bash-completion..."
  # Pastikan file profile ada
  if [[ -f /etc/profile.d/bash_completion.sh ]]; then
    # Hindari duplikat baris di .bashrc
    local line='source /etc/profile.d/bash_completion.sh'
    if ! grep -qF "$line" /root/.bashrc 2>/dev/null; then
      echo "$line" >> /root/.bashrc
      ok "Ditambahkan ke /root/.bashrc"
    else
      ok "Baris bash-completion sudah ada di /root/.bashrc"
    fi
    # shellcheck disable=SC1090
    source /root/.bashrc || true
    ok "bash-completion aktif (untuk root shell)."
  else
    warn "/etc/profile.d/bash_completion.sh tidak ditemukan (paket bash-completion mungkin bermasalah)."
  fi
}

configure_snmp() {
  log "❓❓ Mengkonfigurasi SNMP v2c..."
  cat <<EOF > /etc/snmp/snmpd.conf
com2sec readonly  default         public
group   MyROGroup v2c             readonly
view    all    included  .1                               80
access  MyROGroup ""      v2c    noauth  exact  all    none   none
syslocation Jakarta, Indonesia
syscontact reski.abuchaer@gmail.com
EOF

  log "❓❓ Mengaktifkan dan memulai SNMP..."
  enable_service_now snmpd
}

configure_chrony() {
  log "❓ Mengkonfigurasi NTP (Chrony)..."
  if [[ -f /etc/chrony.conf ]]; then
    # Ganti baris pool* menjadi 2 server ID (lebih deterministic)
    sed -i 's|^pool.*|server 0.id.pool.ntp.org iburst\nserver 1.id.pool.ntp.org iburst|' /etc/chrony.conf
    enable_service_now chronyd
    log "🕒 Cek source NTP:"
    chronyc sources -v | tee -a "$LOG_FILE" || warn "chronyc gagal (mungkin chronyd belum stabil)."
  else
    fail_step "/etc/chrony.conf tidak ditemukan."
  fi
}

configure_ssh_banner() {
  log "❓❓ Menambahkan banner SSH..."
  cat <<'EOB' > /etc/issue.net
Peringatan: Akses ke sistem ini diawasi. Segala aktivitas Anda dapat dicatat dan diaudit.
Jika Anda tidak berwenang, segera keluar dari sistem ini.
EOB

  if [[ -f /etc/ssh/sshd_config ]]; then
    # Pastikan Banner diarahkan ke /etc/issue.net
    if grep -qE '^\s*Banner\s+' /etc/ssh/sshd_config; then
      sed -i 's|^\s*Banner\s\+.*|Banner /etc/issue.net|' /etc/ssh/sshd_config
    else
      echo "Banner /etc/issue.net" >> /etc/ssh/sshd_config
    fi

    # Restart sshd
    if systemctl restart sshd >>"$LOG_FILE" 2>&1; then
      ok "sshd direstart dengan banner aktif."
    else
      fail_step "Gagal restart sshd."
    fi
  else
    fail_step "/etc/ssh/sshd_config tidak ditemukan."
  fi
}

enable_cockpit() {
  # Cockpit biasanya via socket
  log "🧩 Mengaktifkan Cockpit..."
  enable_service_now cockpit.socket
}

# --------- Git + Quadlet helpers ----------
git_upsert_repo() {
  # Usage: git_upsert_repo <repo_url> <dest_dir>
  local repo_url="$1"
  local dest_dir="$2"

  mkdir -p "$(dirname "$dest_dir")"

  if [[ -d "$dest_dir/.git" ]]; then
    log "🔁 Repo sudah ada, git pull: $dest_dir"
    if git -C "$dest_dir" pull --rebase >>"$LOG_FILE" 2>&1; then
      ok "Git pull sukses: $dest_dir"
    else
      fail_step "Git pull gagal: $dest_dir"
    fi
  else
    log "📥 Git clone: $repo_url -> $dest_dir"
    if git clone "$repo_url" "$dest_dir" >>"$LOG_FILE" 2>&1; then
      ok "Clone sukses: $dest_dir"
    else
      fail_step "Git clone gagal: $dest_dir"
    fi
  fi
}

pull_images_from_quadlet_dir() {
  # Usage: pull_images_from_quadlet_dir <quadlet_dir>
  local quadlet_dir="$1"
  if [[ ! -d "$quadlet_dir" ]]; then
    fail_step "Folder quadlet tidak ditemukan: $quadlet_dir"
    return 0
  fi

  log "📦 Pull image dari Quadlet folder: $quadlet_dir"
  local images=()
  while IFS= read -r f; do
    # Ambil Image= dari file .container
    local img
    img="$(grep -E '^\s*Image\s*=' "$f" | head -n1 | cut -d'=' -f2- | xargs || true)"
    if [[ -n "$img" ]]; then
      images+=("$img")
    fi
  done < <(find "$quadlet_dir" -maxdepth 1 -type f -name "*.container" 2>/dev/null)

  if [[ "${#images[@]}" -eq 0 ]]; then
    warn "Tidak ada Image= ditemukan di *.container dalam $quadlet_dir (skip pull)."
    return 0
  fi

  # Deduplicate
  mapfile -t images < <(printf "%s\n" "${images[@]}" | awk '!seen[$0]++')

  for img in "${images[@]}"; do
    log "⬇️  podman pull $img"
    if podman pull "$img" >>"$LOG_FILE" 2>&1; then
      ok "Pull sukses: $img"
    else
      fail_step "Pull gagal: $img"
    fi
  done
}

link_quadlet_unit() {
  # Usage: link_quadlet_unit <source_file> <dest_file>
  local src="$1"
  local dst="$2"

  if [[ ! -f "$src" ]]; then
    fail_step "File quadlet tidak ditemukan: $src"
    return 0
  fi

  mkdir -p "$(dirname "$dst")"
  ln -sf "$src" "$dst"
  ok "Symlink: $dst -> $src"
}

systemd_reload() {
  log "🔄 systemctl daemon-reload"
  if systemctl daemon-reload >>"$LOG_FILE" 2>&1; then
    ok "daemon-reload OK"
  else
    fail_step "daemon-reload gagal"
  fi
}

start_service() {
  local svc="$1"
  log "▶️  Start service: $svc"
  if systemctl start "$svc" >>"$LOG_FILE" 2>&1; then
    ok "Service jalan: $svc"
  else
    fail_step "Gagal start service: $svc"
  fi
}

deploy_web_app_quadlet() {
  # Usage: deploy_web_app_quadlet <app_name> <repo_url> <opt_dir> <container_unit_filename>
  local app="$1"
  local repo="$2"
  local opt_dir="$3"
  local unit_file="$4"

  log "=============================="
  log "🚀 Deploy: $app"
  log "=============================="

  git_upsert_repo "$repo" "$opt_dir"
  pull_images_from_quadlet_dir "$opt_dir/quadlet"

  link_quadlet_unit "$opt_dir/quadlet/$unit_file" "/etc/containers/systemd/$unit_file"
  systemd_reload

  # unit .container biasanya menghasilkan service nama sama: <name>.service
  local svc="${unit_file%.container}.service"
  start_service "$svc"
}

deploy_observium_quadlet() {
  # Observium-Docker: banyak unit (network, volume, container)
  local repo="$1"
  local opt_dir="$2"

  log "=============================="
  log "🚀 Deploy: Observium"
  log "=============================="

  git_upsert_repo "$repo" "$opt_dir"
  pull_images_from_quadlet_dir "$opt_dir/quadlet"

  # Link unit-unitnya (sesuai yang kamu tulis)
  link_quadlet_unit "$opt_dir/quadlet/observium.network"        "/etc/containers/systemd/observium.network"
  link_quadlet_unit "$opt_dir/quadlet/db_data.volume"           "/etc/containers/systemd/db_data.volume"
  link_quadlet_unit "$opt_dir/quadlet/observium_data.volume"    "/etc/containers/systemd/observium_data.volume"
  link_quadlet_unit "$opt_dir/quadlet/observium_rrd.volume"     "/etc/containers/systemd/observium_rrd.volume"
  link_quadlet_unit "$opt_dir/quadlet/observium_logs.volume"    "/etc/containers/systemd/observium_logs.volume"
  link_quadlet_unit "$opt_dir/quadlet/observium-db.container"   "/etc/containers/systemd/observium-db.container"
  link_quadlet_unit "$opt_dir/quadlet/observium-app.container"  "/etc/containers/systemd/observium-app.container"

  systemd_reload
  start_service "observium-db.service"
  start_service "observium-app.service"
}

# --------- Main ----------
log "🧾 Mulai setup. Log: $LOG_FILE"

install_base_packages
install_podman_stack

enable_cockpit
configure_bash_completion
configure_snmp
configure_chrony
configure_ssh_banner

# --- GitHub Token handling (lebih aman daripada hardcode) ---
# Export dulu sebelum run script:
# export GITHUB_TOKEN='ghp_xxx...'
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  warn "GITHUB_TOKEN belum diset. Deploy repo privat via token URL akan gagal."
  warn "Set dulu: export GITHUB_TOKEN='...token...'"
else
  ok "GITHUB_TOKEN terdeteksi (tidak ditampilkan)."
fi

# Repo URLs (gunakan token env)
HALOEATS_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/web-haloeats.git"
FORNET_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/web-fornet.git"
HALSS_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/web-halss.git"
OBSERVIUM_REPO="https://${GITHUB_TOKEN:-TOKEN_KOSONG}@github.com/rskabc/Observium-Docker.git"

# Deploy apps to /opt
deploy_web_app_quadlet "Web HaloEats"    "$HALOEATS_REPO" "/opt/web-haloeats" "web-haloeats.container"
deploy_web_app_quadlet "Web Fornet"      "$FORNET_REPO"   "/opt/web-fornet"   "web-fornet.container"
deploy_web_app_quadlet "Web HalssMakeup" "$HALSS_REPO"    "/opt/web-halss"    "web-halss.container"
deploy_observium_quadlet "$OBSERVIUM_REPO" "/opt/Observium-Docker"

# --------- Summary ----------
log ""
log "=============================="
log "☕ SUMMARY (biar enak dilihat setelah ngopi)"
log "=============================="

log "🔧 Paket penting:"
log " - Podman: $(command -v podman >/dev/null 2>&1 && podman --version || echo 'TIDAK ADA')"
log " - Cockpit: $(systemctl is-enabled cockpit.socket 2>/dev/null || echo 'unknown') / $(systemctl is-active cockpit.socket 2>/dev/null || echo 'unknown')"
log " - SNMPD: $(systemctl is-enabled snmpd 2>/dev/null || echo 'unknown') / $(systemctl is-active snmpd 2>/dev/null || echo 'unknown')"
log " - Chronyd: $(systemctl is-enabled chronyd 2>/dev/null || echo 'unknown') / $(systemctl is-active chronyd 2>/dev/null || echo 'unknown')"
log " - SSHD: $(systemctl is-active sshd 2>/dev/null || echo 'unknown')"

log ""
log "🚀 Services (Quadlet):"
for s in web-haloeats.service web-fornet.service web-halss.service observium-db.service observium-app.service; do
  log " - $s : $(systemctl is-active "$s" 2>/dev/null || echo 'unknown')"
done

log ""
log "📁 Symlink Quadlet:"
ls -lah /etc/containers/systemd | tee -a "$LOG_FILE" || true

log ""
if [[ "${#FAILED_STEPS[@]}" -gt 0 ]]; then
  warn "Ada beberapa item yang gagal (cek log untuk detail):"
  for f in "${FAILED_STEPS[@]}"; do
    warn " - $f"
  done
  warn "Log lengkap: $LOG_FILE"
  exit 2
else
  ok "Semua langkah selesai tanpa error fatal. Log: $LOG_FILE"
fi
