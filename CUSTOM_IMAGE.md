# Centralized Pterodactyl Node.js image

Image ini menyediakan Node.js 22, Python 3, pip, venv, FFmpeg, yt-dlp, dan
cloudflared. Semua komponen berada di layer Docker yang dipakai bersama oleh
server-server Pterodactyl pada node yang sama.

## Menerbitkan image

1. Push `Dockerfile.nodejs-tools` dan `.github/workflows/build-nodejs-tools.yml`
   ke repository GitHub milik `kavionn` pada branch `main`.
2. Buka tab **Actions**, pilih **Build centralized Pterodactyl images**, kemudian
   jalankan **Run workflow**.
3. Setelah build pertama selesai, buka profil GitHub -> **Packages** ->
   `pterodactyl-nodejs` -> **Package settings**, lalu ubah visibility menjadi
   **Public** agar Wings dapat menarik image tanpa kredensial registry.

Workflow menerbitkan dua image multi-architecture:

- `ghcr.io/kavionn/pterodactyl-nodejs:22` untuk menjalankan server.
- `ghcr.io/kavionn/pterodactyl-nodejs:installer-22` untuk installation script.

Build dijalankan kembali setiap Senin agar yt-dlp dan cloudflared ikut diperbarui.
Menjalankan build ulang tidak menghapus data server. Wings akan menggunakan image
baru ketika image ditarik kembali saat server dimulai.

## Yang masih dipasang per server

Hanya dependency project dari `package.json` yang tetap dipasang ke volume tiap
server dengan `npm install`. Dependency project tidak dapat dipusatkan karena
setiap aplikasi dapat memakai versi package yang berbeda.
