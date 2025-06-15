#!/bin/bash

set -e

echo "🔧 Memperbarui sistem..."
dnf update -y

echo "📦 Menginstal paket utilitas..."
dnf install -y \
  htop \
  nano \
  tree \
  curl \
  wget \
  net-tools \
  bind-utils \
  traceroute \
  yum-utils \
  unzip \
  zip \
  git \
  snmp \
  chrony \
  bash-completion

echo "✅ Mengaktifkan bash-completion..."
echo "source /etc/profile.d/bash_completion.sh" >> ~/.bashrc
source ~/.bashrc

echo "📡 Mengkonfigurasi SNMP v2c..."
cat <<EOF > /etc/snmp/snmpd.conf
com2sec readonly  default         public
group   MyROGroup v2c             readonly
view    all    included  .1                               80
access  MyROGroup ""      v2c    noauth  exact  all    none   none
syslocation Jakarta, Indonesia
syscontact reski.abuchaer@gmail.com
EOF

echo "✔️ Mengaktifkan dan memulai SNMP..."
systemctl enable snmpd --now

echo "⏰ Mengkonfigurasi NTP (Chrony)..."
sed -i 's|^pool.*|server 0.id.pool.ntp.org iburst\nserver 1.id.pool.ntp.org iburst|' /etc/chrony.conf
systemctl enable chronyd --now
chronyc sources -v

echo "🔐 Menambahkan banner SSH..."
cat <<'EOB' > /etc/issue.net
Peringatan: Akses ke sistem ini diawasi. Segala aktivitas Anda dapat dicatat dan diaudit.
Jika Anda tidak berwenang, segera keluar dari sistem ini.
EOB

sed -i 's|^#Banner none|Banner /etc/issue.net|' /etc/ssh/sshd_config
systemctl restart sshd

echo "✅ Setup selesai. Server AlmaLinux Anda telah dikonfigurasi dengan baik."