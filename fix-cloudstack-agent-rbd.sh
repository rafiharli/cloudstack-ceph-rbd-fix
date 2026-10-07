#!/usr/bin/env bash
# Bagian B: patch satu class plugin KVM agent, tanpa build seluruh CloudStack.
set -Eeuo pipefail

# Sesuaikan dengan versi agent, lokasi instalasi, dan JDK Anda.
CS_VERSION="${CS_VERSION:-4.23.0.0}"
WORK_DIR="${WORK_DIR:-/root/cloudstack-agent-rbd-fix}"
AGENT_LIB="${AGENT_LIB:-/usr/share/cloudstack-agent/lib}"
PLUGIN="${PLUGIN:-${AGENT_LIB}/cloud-plugin-hypervisor-kvm-${CS_VERSION}.jar}"
SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/apache/cloudstack/${CS_VERSION}/plugins/hypervisors/kvm/src/main/java/com/cloud/hypervisor/kvm/storage/KVMPhysicalDisk.java}"
JDK_PACKAGE="${JDK_PACKAGE:-java-17-openjdk-devel}"
JDK_BIN="${JDK_BIN:-/usr/lib/jvm/java-17-openjdk/bin}"
JAVA_TARGET="${JAVA_TARGET:-11}"
AGENT_SERVICE="${AGENT_SERVICE:-cloudstack-agent}"

die() { echo "ERROR: $*" >&2; exit 1; }
action="${1:-help}"
case "$action" in
    apply|rollback) ;;
    help|--help|-h)
        echo "Pemakaian pada host KVM: sudo bash $0 {apply|rollback}"
        exit 0 ;;
    *) die "Pilihan tidak dikenal: $action" ;;
esac
[[ $EUID -eq 0 ]] || die "Jalankan sebagai root."
source /etc/os-release
[[ "$ID" == rocky && "$VERSION_ID" == 9* ]] || die "Script ini untuk Rocky Linux 9."
[[ $(rpm -q --qf '%{VERSION}' cloudstack-agent) == "$CS_VERSION" ]] \
    || die "Versi agent berbeda. Sesuaikan CS_VERSION dan SOURCE_URL."
[[ -f "$PLUGIN" ]] || die "Plugin tidak ditemukan: $PLUGIN"
command -v python3 >/dev/null || die "Install python3 terlebih dahulu."
target='com/cloud/hypervisor/kvm/storage/KVMPhysicalDisk.class'
backup="$WORK_DIR/rollback/original.jar"

if [[ "$action" == apply ]]; then
    # Exit 0 hanya jika kedua mode autentikasi sudah menggunakan opsi baru.
    if python3 - "$PLUGIN" "$target" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as jar:
    data = jar.read(sys.argv[2])
sys.exit(0 if b'auth_supported' not in data and
         b'auth_client_required=cephx' in data and
         b'auth_client_required=none' in data else 1)
PY
    then
        echo "OK: plugin sudah memakai auth_client_required; tidak ada perubahan."
        exit 0
    fi
    dnf install -y "$JDK_PACKAGE" curl python3
    for tool in javac jar javap; do
        [[ -x "$JDK_BIN/$tool" ]] || die "$JDK_BIN/$tool tidak tersedia."
    done
    mkdir -p "$WORK_DIR"/{rollback,src,classes}
    # Backup lama tidak ditimpa, tetapi harus sesuai plugin yang sedang aktif.
    [[ -f "$backup" ]] || cp -a "$PLUGIN" "$backup"
    cmp -s "$backup" "$PLUGIN" || die "Backup berbeda dari plugin aktif. Periksa backup sebelum melanjutkan."
    curl -fL "$SOURCE_URL" -o "$WORK_DIR/src/KVMPhysicalDisk.java"
    python3 - "$WORK_DIR/src/KVMPhysicalDisk.java" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
if s.count(':auth_supported=') != 2:
    sys.exit('Source tidak memuat tepat dua opsi lama; periksa versi source.')
p.write_text(s.replace(':auth_supported=', ':auth_client_required='))
PY
    agent_cp=$(printf '%s:' "$AGENT_LIB"/*.jar)
    "$JDK_BIN/javac" -J-Xmx256m --release "$JAVA_TARGET" -proc:none \
        -cp "${agent_cp%:}" -d "$WORK_DIR/classes" "$WORK_DIR/src/KVMPhysicalDisk.java"
    cp -a "$backup" "$WORK_DIR/fixed.jar"
    "$JDK_BIN/jar" uf "$WORK_DIR/fixed.jar" -C "$WORK_DIR/classes" "$target"
    class_name='com.cloud.hypervisor.kvm.storage.KVMPhysicalDisk'
    "$JDK_BIN/javap" -public -classpath "$backup" "$class_name" > "$WORK_DIR/api-original.txt"
    "$JDK_BIN/javap" -public -classpath "$WORK_DIR/fixed.jar" "$class_name" > "$WORK_DIR/api-fixed.txt"
    diff -u "$WORK_DIR/api-original.txt" "$WORK_DIR/api-fixed.txt"
    python3 - "$backup" "$WORK_DIR/fixed.jar" "$target" <<'PY'
import struct, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as old, zipfile.ZipFile(sys.argv[2]) as new:
    target = sys.argv[3]
    names = new.namelist()
    if any(n.upper().startswith('META-INF/') and
           n.upper().endswith(('.SF', '.RSA', '.DSA', '.EC')) for n in old.namelist()):
        sys.exit('JAR bertanda tangan; gunakan rebuild paket, jangan patch langsung.')
    if len(names) != len(set(names)) or set(names) != set(old.namelist()):
        sys.exit('Daftar isi JAR berubah atau memiliki entry duplikat.')
    changed = [n for n in old.namelist() if old.read(n) != new.read(n)]
    if changed != [target]:
        sys.exit('Perubahan JAR tidak terbatas pada KVMPhysicalDisk.class.')
    data = new.read(target)
    if struct.unpack('>H', data[6:8])[0] != struct.unpack('>H', old.read(target)[6:8])[0]:
        sys.exit('Target bytecode berbeda dari class asli; sesuaikan JAVA_TARGET.')
    if b'auth_supported' in data or not all(b'auth_client_required=' + mode in data
                                         for mode in (b'cephx', b'none')):
        sys.exit('Verifikasi opsi autentikasi gagal.')
print('OK: satu class berubah, API dan target bytecode tetap sesuai.')
PY
    replacement="$WORK_DIR/fixed.jar"
else
    [[ -f "$backup" ]] || die "Backup belum tersedia: $backup"
    replacement="$backup"
fi

# Siapkan file sebelum menghentikan agent; backup tetap di luar direktori lib.
install -m 0644 "$replacement" "$PLUGIN.new"
agent_stopped=0
cleanup() {
    local status=$?
    trap - EXIT
    rm -f "$PLUGIN.new"
    if (( agent_stopped )); then systemctl start "$AGENT_SERVICE" || true; fi
    if (( status != 0 )); then echo "Gagal. Periksa agent; rollback: bash $0 rollback" >&2; fi
    exit "$status"
}
trap cleanup EXIT
if systemctl is-active --quiet "$AGENT_SERVICE"; then
    agent_stopped=1
    systemctl stop "$AGENT_SERVICE"
fi
mv -f "$PLUGIN.new" "$PLUGIN"
if command -v restorecon >/dev/null; then restorecon "$PLUGIN"; fi
if (( agent_stopped )); then
    systemctl start "$AGENT_SERVICE"
    systemctl is-active --quiet "$AGENT_SERVICE"
    agent_stopped=0
fi
cmp "$replacement" "$PLUGIN"
echo "OK: $action plugin selesai. Tunggu host Up, lalu coba deployment instance."
