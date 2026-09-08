# Centralized Pterodactyl Node.js image

Image runtime menyediakan Node.js 18 sampai 26 beserta tool dari image `r4`,
sedangkan image installer menyediakan Node.js 22, Python 3, pip, venv, FFmpeg,
yt-dlp, dan cloudflared. Semua komponen berada di layer Docker yang dipakai
bersama oleh server-server Pterodactyl pada node yang sama.

## Menerbitkan image

1. Push `Dockerfile.nodejs-tools`, `Dockerfile.nodejs-runtime`,
   `nodejs-egg.json`, dan `.github/workflows/build-nodejs-tools.yml` ke
   repository GitHub milik `kavionn` pada branch `main`.
2. Buka tab **Actions**, pilih **Build centralized Pterodactyl images**, kemudian
   jalankan **Run workflow**.
3. Setelah build pertama selesai, buka profil GitHub -> **Packages** ->
   `pterodactyl-nodejs` -> **Package settings**, lalu ubah visibility menjadi
   **Public** agar Wings dapat menarik image tanpa kredensial registry.

Workflow menerbitkan image multi-architecture berikut:

- `ghcr.io/kavionn/pterodactyl-nodejs:node_<versi>-ytdlp-2026.08.19-r5`
  untuk runtime Node.js 18 sampai 26. Image `r5` mempertahankan seluruh tool
  dari image `r4`, tetapi banner startup tidak lagi menjalankan `whoami`, sehingga
  aman ketika Wings memakai UID numerik yang tidak tercantum di `/etc/passwd`.
- `ghcr.io/kavionn/pterodactyl-nodejs:installer-22` untuk installation script.

Build dijalankan kembali setiap Senin. Image installer mengambil ulang yt-dlp dan
cloudflared, sedangkan runtime `r5` sengaja tetap berbasis tag `r4` yang dipatok
agar tool di dalamnya tidak berubah tanpa bump versi. Menjalankan build ulang
tidak menghapus data server. Wings akan menggunakan image baru ketika image
ditarik kembali saat server dimulai.

## Yang masih dipasang per server

Hanya dependency project dari `package.json` yang tetap dipasang ke volume tiap
server dengan `npm install`. Dependency project tidak dapat dipusatkan karena
setiap aplikasi dapat memakai versi package yang berbeda.
