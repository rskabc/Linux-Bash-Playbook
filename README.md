# 🚀 AlmaLinux Server Setup Script (`setupserver.sh`)

Shell script ini digunakan untuk melakukan instalasi dan konfigurasi awal pada sistem **AlmaLinux**, cocok untuk provisioning server baru sebelum digunakan untuk keperluan produksi atau otomatisasi.

---

## 📁 Nama File

```bash
setupserver.sh
```

---

## 📦 Paket yang Diinstal

| Kategori       | Paket                                                                           |
|----------------|----------------------------------------------------------------------------------|
| Sistem         | `htop`, `nano`, `tree`, `curl`, `wget`, `unzip`, `zip`, `git`, `yum-utils`      |
| Jaringan       | `net-tools`, `bind-utils`, `traceroute`, `snmp`, `chrony`                       |
| Shell/Terminal | `bash-completion`                                                               |

---

## ⚙️ Konfigurasi Otomatis

### 🔐 SNMP v2c
- Community: `public`
- Lokasi: `Jakarta, Indonesia`
- Kontak: `reski.abuchaer@gmail.com`

### ⏰ NTP (Chrony)
- Server lokal Indonesia:
  - `0.id.pool.ntp.org`
  - `1.id.pool.ntp.org`

### 🔐 SSH Banner
Menampilkan pesan peringatan saat login melalui SSH:
```
Peringatan: Akses ke sistem ini diawasi. Segala aktivitas Anda dapat dicatat dan diaudit.
Jika Anda tidak berwenang, segera keluar dari sistem ini.
```

---

## ▶️ Cara Penggunaan

1. **Download & beri izin eksekusi:**

```bash
wget https://path-ke-script/setupserver.sh
chmod +x setupserver.sh
```

2. **Jalankan sebagai root:**

```bash
sudo ./setupserver.sh
```

---

## ✅ Hasil Setelah Eksekusi

- Sistem telah diperbarui
- Paket dasar terinstal
- SNMP & NTP dikonfigurasi dan aktif
- SSH banner keamanan tampil saat login
- bash-completion aktif otomatis

---

## 👨‍💻 Dibuat oleh

Chaerul — [chaer.newbie@gmail.com](mailto:chaer.newbie@gmail.com)# playbook-linux
# Linux-Bash-Playbook
