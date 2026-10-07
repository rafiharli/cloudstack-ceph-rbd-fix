# Perbaikan kompatibilitas Ceph RBD dan CloudStack pada Rocky 9

Dua script sederhana untuk mengganti opsi `auth_supported` yang ditolak library klien Ceph menjadi `auth_client_required`.

| Script | Tujuan |
| --- | --- |
| `fix-libvirt-rbd.sh` (A) | Memperbaiki driver storage RBD libvirt ketika penambahan primary storage gagal dengan `failed to set RADOS option: auth_supported`. |
| `fix-cloudstack-agent-rbd.sh` (B) | Memperbaiki URI RBD pada plugin KVM agent ketika konversi template/disk gagal dengan `invalid conf option auth_supported`. |

Default mengikuti lab: management dan KVM `192.168.14.8`, monitor Ceph `192.168.14.4`, pool `cloudstack-pool`, pengguna `client.cloudstack`; Rocky 9 x86_64, libvirt `11.10.0-12.7.el9_8`, agent `4.23.0.0`, JDK 17 dengan target bytecode Java 11. Nilai ini contoh, bukan persyaratan alamat jaringan.

Edit variabel di bagian atas masing-masing script jika versi, URL, direktori, atau nama layanan berbeda. Script dijalankan **lokal** pada mesin yang dituju sehingga tidak membutuhkan IP login atau password SSH. Secret Ceph tidak diperlukan untuk patch; pengecekan RBD memakai konfigurasi dan keyring yang sudah tersedia di host. Jangan masukkan keyring atau secret ke repository.

## Sebelum menjalankan

Ceph, pool, akses jaringan, konfigurasi `/etc/ceph/ceph.conf`, keyring pengguna, dan paket klien Ceph/RBD harus sudah tersedia pada host KVM. Script memperbaiki dua komponen kompatibilitas; setup awal Ceph mengikuti panduan instalasi Anda. Cek akses dari host KVM:

```bash
# Sesuaikan nama pengguna (tanpa client.) dan nama pool.
ceph_user='cloudstack'
ceph_pool='cloudstack-pool'
rbd --id "$ceph_user" -p "$ceph_pool" ls
```

Exit code 0 berarti berhasil, termasuk ketika pool masih kosong. Jangan membagikan isi keyring atau log agent mentah karena log dapat memuat key.

Jalankan pemasangan ketika tidak ada deployment/migrasi berlangsung. Bagian A me-restart `libvirtd` dan menghentikan sementara agent yang aktif; Bagian B menghentikan sementara agent yang aktif. Layanan agent yang awalnya tidak aktif tidak dihidupkan otomatis. Default Bagian A memakai daemon monolitik `libvirtd`; sesuaikan `LIBVIRT_SERVICE` jika memakai daemon storage modular.

## Unduh script

```bash
git clone https://github.com/rafiharli/cloudstack-ceph-rbd-fix.git
cd cloudstack-ceph-rbd-fix
```

## A — build dan pasang driver libvirt

Build sebaiknya pada mesin **Rocky dengan rilis, arsitektur, dan repository klien Ceph yang sesuai host KVM**. Build seluruh SRPM bisa lama dan memerlukan RAM/disk; yang dipasang hanya subpaket driver RBD. Script mengaktifkan CRB dan memasang dependensi build melalui DNF, tanpa menonaktifkan tes bawaan.

Pada mesin build:

```bash
sudo bash fix-libvirt-rbd.sh build
```

Hasil default: `/root/libvirt-rbd-backport/fixed.rpm`. Jika build dilakukan langsung pada host KVM, lanjutkan `install`. Jika memakai mesin build terpisah, salin hasilnya terlebih dahulu:

```bash
# Pada mesin build; sesuaikan IP dan pastikan direktori tujuan tersedia.
kvm_ip='192.168.14.8'
ssh "root@$kvm_ip" 'mkdir -p /root/libvirt-rbd-backport'
scp /root/libvirt-rbd-backport/fixed.rpm "root@$kvm_ip:/root/libvirt-rbd-backport/fixed.rpm"
```

Pada host KVM, unduh repository yang sama, lalu:

```bash
sudo bash fix-libvirt-rbd.sh install
```

Script memeriksa versi tiga paket libvirt, isi RPM hasil build, signature RPM rollback, dan transaksi `rpm --test`. Version–Release dipertahankan untuk dependensi libvirt yang mengharuskan versi tepat. Backup tersimpan di `/root/libvirt-rbd-backport/rollback/`. Jika driver sudah memakai opsi baru, pemasangan dilewati.

## B — patch plugin agent

Pada **host KVM**:

```bash
sudo bash fix-cloudstack-agent-rbd.sh apply
```

Script memasang JDK, mengambil source sesuai versi, mengganti dua opsi autentikasi, lalu compile satu class dengan library agent yang sudah terpasang. Sebelum pemasangan, script memastikan API publik dan target bytecode tetap sama serta hanya satu entry JAR yang berubah. Plugin yang sudah diperbaiki dilewati. Backup ada di `/root/cloudstack-agent-rbd-fix/rollback/original.jar`, di luar direktori library agent.

## Setelah patch

Tunggu host KVM `Up` dan `ceph-primary` `Up` di UI CloudStack, lalu buat instance dengan template `Ready` dan offering/storage tag yang sesuai. Pastikan ROOT volume menggunakan primary storage Ceph dan instance `Running`. Pemeriksaan file patch saja belum membuktikan deployment berhasil.

Untuk memeriksa volume di Ceph, ambil **path/UUID volume** dari CloudStack, lalu pada host yang memiliki akses pool:

```bash
ceph_user='cloudstack'
ceph_pool='cloudstack-pool'
image='ISI_PATH_VOLUME_DARI_CLOUDSTACK'
rbd --id "$ceph_user" -p "$ceph_pool" info "$image"
rbd --id "$ceph_user" -p "$ceph_pool" status "$image"
```

Image harus ada; disk yang sedang digunakan VM biasanya mempunyai watcher dari host KVM.

## Rollback

Pada host KVM, gunakan direktori kerja yang sama dengan saat pemasangan:

```bash
sudo bash fix-cloudstack-agent-rbd.sh rollback
sudo bash fix-libvirt-rbd.sh rollback
```

Rollback mengembalikan file/paket asli dan dapat mengembalikan error kompatibilitas. Jika script gagal setelah menghentikan layanan, script mencoba menghidupkannya kembali; periksa `systemctl status` dan jalankan rollback bila diperlukan. Backup tidak ditimpa otomatis. Jika versi paket berubah, periksa backup dan gunakan direktori kerja baru.

Update paket libvirt atau CloudStack dapat menimpa patch lokal ini. Periksa kembali setelah update; gunakan paket resmi yang sudah memuat perbaikan jika tersedia.

## Pengecekan script

Pemeriksaan lokal mencakup `bash -n`, ShellCheck, dan 13 skenario dengan operasi paket/layanan disimulasikan. Hook patch juga diperiksa terhadap spec SRPM Rocky yang sesuai. Class Java hasil compile lokal diverifikasi untuk mode `cephx` dan `none`, menggunakan target bytecode 55. Mesin uji memakai compiler Java 21 dengan `-source 11 -target 11`; script produksi memakai JDK 17 dengan `--release 11`.

Build RPM penuh dan pemasangan script pada host KVM belum dijalankan dalam pengujian ini. Setelah menjalankan script, tetap periksa hasil deployment melalui CloudStack.

## Referensi dan validasi

- [Source KVMPhysicalDisk CloudStack 4.23.0.0](https://github.com/apache/cloudstack/blob/4.23.0.0/plugins/hypervisors/kvm/src/main/java/com/cloud/hypervisor/kvm/storage/KVMPhysicalDisk.java).
- [Perbaikan upstream CloudStack PR #13991](https://github.com/apache/cloudstack/pull/13991/files).
- [Repositori SRPM Rocky 9 AppStream](https://dl.rockylinux.org/pub/rocky/9/AppStream/source/tree/Packages/l/).

Bagian A adalah patch kompatibilitas lokal yang mengganti literal opsi pada source distribusi, bukan salinan persis patch upstream libvirt. URL default mengikuti paket lab; jika URL tidak tersedia atau versi berbeda, sesuaikan sumber paket terlebih dahulu.
