#!/usr/bin/env bash
# Bagian A: ganti auth_supported pada driver storage RBD libvirt Rocky 9.
set -Eeuo pipefail

# Sesuaikan nilai ini dengan paket dan lokasi Anda. Bisa juga melalui environment.
LIBVIRT_NVR="${LIBVIRT_NVR:-11.10.0-12.7.el9_8}"
RPM_DIST="${RPM_DIST:-.el9_8}"
WORK_DIR="${WORK_DIR:-/root/libvirt-rbd-backport}"
SRPM_URL="${SRPM_URL:-https://dl.rockylinux.org/pub/rocky/9/AppStream/source/tree/Packages/l/libvirt-${LIBVIRT_NVR}.src.rpm}"
ORIGINAL_RPM_URL="${ORIGINAL_RPM_URL:-https://dl.rockylinux.org/pub/rocky/9/AppStream/x86_64/os/Packages/l/libvirt-daemon-driver-storage-rbd-${LIBVIRT_NVR}.x86_64.rpm}"
FIXED_RPM="${FIXED_RPM:-${WORK_DIR}/fixed.rpm}"
MODULE="${MODULE:-/usr/lib64/libvirt/storage-backend/libvirt_storage_backend_rbd.so}"
LIBVIRT_SERVICE="${LIBVIRT_SERVICE:-libvirtd}"
AGENT_SERVICE="${AGENT_SERVICE:-cloudstack-agent}"

die() { echo "ERROR: $*" >&2; exit 1; }
action="${1:-help}"
case "$action" in
    build|install|rollback) ;;
    help|--help|-h)
        echo "Pemakaian: sudo bash $0 {build|install|rollback}"
        echo "build: mesin build Rocky 9; install/rollback: host KVM."
        exit 0 ;;
    *) die "Pilihan tidak dikenal: $action" ;;
esac
[[ $EUID -eq 0 ]] || die "Jalankan sebagai root."
source /etc/os-release
[[ "$ID" == rocky && "$VERSION_ID" == 9* ]] || die "Script ini untuk Rocky Linux 9."
[[ $(uname -m) == x86_64 ]] || die "Default RPM script ini untuk x86_64."
mkdir -p "$WORK_DIR/rollback"

check_signature() {
    local result
    result=$(rpm -K "$1")
    echo "$result"
    case "$result" in *NOKEY*|*'NOT OK'*) die "Signature RPM belum terverifikasi." ;; esac
}
check_rpm() {
    local expected="libvirt-daemon-driver-storage-rbd-${LIBVIRT_NVR}.x86_64"
    [[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$1") == "$expected" ]] \
        || die "RPM tidak sesuai $expected."
}
patched_module() {
    local content
    content=$(strings "$1")
    grep -qx 'auth_client_required' <<< "$content" && ! grep -qx 'auth_supported' <<< "$content"
}
verify_fixed() {
    check_rpm "$FIXED_RPM"
    local inspect_dir
    inspect_dir=$(mktemp -d "$WORK_DIR/inspect.XXXXXX")
    (cd "$inspect_dir"; rpm2cpio "$FIXED_RPM" | cpio -idm --quiet)
    if ! patched_module "$inspect_dir${MODULE}"; then
        rm -rf "$inspect_dir"
        die "RPM belum memuat patch auth_client_required."
    fi
    rm -rf "$inspect_dir"
}

if [[ "$action" == build ]]; then
    dnf install -y rpm-build dnf-plugins-core redhat-rpm-config git curl python3 cpio binutils
    dnf config-manager --set-enabled crb
    mkdir -p "$WORK_DIR/rpmbuild"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    curl -fL "$SRPM_URL" -o "$WORK_DIR/libvirt.src.rpm"
    check_signature "$WORK_DIR/libvirt.src.rpm"
    [[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$WORK_DIR/libvirt.src.rpm") == "libvirt-${LIBVIRT_NVR}" ]] \
        || die "SRPM berbeda dari LIBVIRT_NVR."
    rpm -ivh --define "_topdir $WORK_DIR/rpmbuild" "$WORK_DIR/libvirt.src.rpm"
    spec="$WORK_DIR/rpmbuild/SPECS/libvirt.spec"
    dnf builddep -y "$spec"
    cp -a "$spec" "$spec.original"
    python3 - "$spec" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text()
marker = '\n%build\n'
if text.count(marker) != 1:
    sys.exit('Struktur spec berbeda; periksa manual.')
patch = '''
# Local Ceph compatibility patch, applied after distribution patches
test "$(grep -c '\"auth_supported\"' src/storage/storage_backend_rbd.c)" -eq 2
sed -i 's/"auth_supported"/"auth_client_required"/g' src/storage/storage_backend_rbd.c
%build
'''
p.write_text(text.replace(marker, '\n' + patch, 1))
PY
    echo "Build berjalan; log: $WORK_DIR/build.log (dapat memakan waktu lama)."
    if ! rpmbuild -bb --define "_topdir $WORK_DIR/rpmbuild" \
        --define "dist $RPM_DIST" --define '_smp_mflags -j1' "$spec" > "$WORK_DIR/build.log" 2>&1; then
        tail -n 40 "$WORK_DIR/build.log"
        die "Build gagal. Periksa dependensi/repository; jangan lewati tes bawaan."
    fi
    built="$WORK_DIR/rpmbuild/RPMS/x86_64/libvirt-daemon-driver-storage-rbd-${LIBVIRT_NVR}.x86_64.rpm"
    cp -f "$built" "$FIXED_RPM"
    verify_fixed
    echo "OK: hasil build $FIXED_RPM. Salin ke host KVM, lalu jalankan install."
    exit 0
fi

# Hentikan jika versi host berbeda; jangan memaksa dependensi RPM.
for package in libvirt-daemon-driver-storage-rbd libvirt-libs libvirt-daemon-driver-storage-core; do
    [[ $(rpm -q --qf '%{VERSION}-%{RELEASE}' "$package") == "$LIBVIRT_NVR" ]] \
        || die "Versi $package berbeda. Sesuaikan variabel dan build ulang."
done
[[ -f "$MODULE" ]] || die "Modul tidak ditemukan: $MODULE"
command -v strings >/dev/null || die "Install binutils terlebih dahulu."
if [[ "$action" == install ]] && patched_module "$MODULE"; then
    echo "OK: driver sudah memakai auth_client_required; tidak ada perubahan."
    exit 0
fi

if [[ "$action" == install ]]; then
    [[ -f "$FIXED_RPM" ]] || die "RPM hasil build belum tersedia: $FIXED_RPM"
    dnf install -y curl cpio binutils
    verify_fixed
    [[ -f "$WORK_DIR/rollback/original.rpm" ]] || \
        curl -fL "$ORIGINAL_RPM_URL" -o "$WORK_DIR/rollback/original.rpm"
    check_signature "$WORK_DIR/rollback/original.rpm"
    check_rpm "$WORK_DIR/rollback/original.rpm"
    [[ -f "$WORK_DIR/rollback/libvirt_storage_backend_rbd.so" ]] || \
        cp -a "$MODULE" "$WORK_DIR/rollback/libvirt_storage_backend_rbd.so"
    package_file="$FIXED_RPM"
else
    package_file="$WORK_DIR/rollback/original.rpm"
    [[ -f "$package_file" ]] || die "Backup RPM belum tersedia."
    check_signature "$package_file"
    check_rpm "$package_file"
fi
rpm -Uvh --test --replacepkgs "$package_file"

# Hidupkan kembali layanan yang dihentikan jika pemasangan mengalami error.
agent_stopped=0
reload_libvirt=0
cleanup() {
    local status=$?
    trap - EXIT
    if (( reload_libvirt )); then systemctl restart "$LIBVIRT_SERVICE" || true; fi
    if (( agent_stopped )); then systemctl start "$AGENT_SERVICE" || true; fi
    if (( status != 0 )); then echo "Gagal. Periksa layanan; rollback: bash $0 rollback" >&2; fi
    exit "$status"
}
trap cleanup EXIT
if systemctl is-active --quiet "$AGENT_SERVICE"; then
    agent_stopped=1
    systemctl stop "$AGENT_SERVICE"
fi
reload_libvirt=1
rpm -Uvh --replacepkgs "$package_file"
systemctl restart "$LIBVIRT_SERVICE"
reload_libvirt=0
if (( agent_stopped )); then
    systemctl start "$AGENT_SERVICE"
    systemctl is-active --quiet "$AGENT_SERVICE"
    agent_stopped=0
fi
systemctl is-active --quiet "$LIBVIRT_SERVICE"
if [[ "$action" == install ]]; then patched_module "$MODULE" || die "Verifikasi modul gagal."; fi
echo "OK: $action driver RBD selesai. Periksa host dan ceph-primary di UI CloudStack."
