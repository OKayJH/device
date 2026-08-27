#!/bin/bash -e
set -o pipefail

MODE="${1:-prepare}"
case "$MODE" in
    prepare)
        BOOT_IMG="${2:-${RK_BOOT_IMG:-$RK_FIRMWARE_DIR/boot.img}}"
        RECOVERY_IMG="${3:-$RK_FIRMWARE_DIR/recovery.img}"
        ;;
    verify-package)
        BOOT_IMG="${2:-${RK_BOOT_IMG:-$RK_FIRMWARE_DIR/boot.img}}"
        RECOVERY_IMG="${3:-$RK_FIRMWARE_DIR/recovery.img}"
        PACKAGE_FILE="${4:-}"
        UPDATE_IMG="${5:-$RK_FIRMWARE_DIR/update.img}"
        ;;
    *)
        # Backward compatibility with the original <boot.img> <recovery.img>
        # invocation used while this helper was developed.
        BOOT_IMG="$1"
        RECOVERY_IMG="${2:-$RK_FIRMWARE_DIR/recovery.img}"
        MODE=prepare
        ;;
esac
PARAMETER="${RK_CHIP_DIR:?}/parameter.txt"
DUMPIMAGE="${DUMPIMAGE:-}"

[ "${RK_KERNEL_DTS_NAME:-}" = "dlcvcam-rk3576" ] || {
    echo "ERROR: recovery golden image is restricted to IMX296 DTS dlcvcam-rk3576 (got ${RK_KERNEL_DTS_NAME:-unset})" >&2
    exit 1
}
[ -n "${RK_USE_FIT_IMG:-}" ] || {
    echo "ERROR: RK_USE_FIT_IMG must be enabled" >&2
    exit 1
}
[ -z "${RK_RECOVERY:-}" ] || {
    echo "ERROR: standard Rockchip RK_RECOVERY must stay disabled" >&2
    exit 1
}
[ "${RK_PARAMETER:-parameter.txt}" = "parameter.txt" ] || {
    echo "ERROR: recovery fallback requires parameter.txt, got ${RK_PARAMETER:-unset}" >&2
    exit 1
}

parameter_part_size_kb()
{
    python3 - "$PARAMETER" "$1" <<'PY'
import re
import sys

parameter, wanted = sys.argv[1:]
text = open(parameter, encoding="utf-8").read()
match = re.search(r"^CMDLINE:\s*mtdparts=:(.*)$", text, re.MULTILINE)
if not match:
    raise SystemExit(2)
for size, name in re.findall(r"(?:^|,)(0x[0-9a-fA-F]+|-)@0x[0-9a-fA-F]+\(([^:)]+)(?::[^)]*)?\)", match.group(1)):
    if name == wanted:
        print(0 if size == "-" else int(size, 16) // 2)
        break
else:
    print(0)
PY
}

for part in misc boot recovery; do
    parameter_part_size_kb "$part" | grep -qv '^0$' || {
        echo "ERROR: $part partition is missing from $PARAMETER" >&2
        exit 1
    }
done

[ -r "$BOOT_IMG" ] || {
    echo "ERROR: stable boot FIT is missing: $BOOT_IMG" >&2
    exit 1
}

if [ -z "$DUMPIMAGE" ]; then
    for candidate in \
        "$RK_SDK_DIR/u-boot/tools/dumpimage" \
        "$RK_SDK_DIR/tools/linux/Linux_Pack_Firmware/rockdev/dumpimage"; do
        if [ -x "$candidate" ]; then
            DUMPIMAGE="$candidate"
            break
        fi
    done
fi
if [ -z "$DUMPIMAGE" ]; then
    DUMPIMAGE="$(command -v dumpimage || true)"
fi
[ -x "$DUMPIMAGE" ] || {
    echo "ERROR: dumpimage is required to validate $BOOT_IMG" >&2
    exit 1
}

FIT_INFO="$(mktemp)"
trap 'rm -f "$FIT_INFO" "$RECOVERY_IMG.tmp"' EXIT
"$DUMPIMAGE" -l "$BOOT_IMG" >"$FIT_INFO"
grep -q 'Type:.*Kernel Image' "$FIT_INFO" && grep -q 'Architecture: AArch64' "$FIT_INFO" || {
    echo "ERROR: boot FIT has no AArch64 Linux kernel" >&2
    exit 1
}
grep -q 'Type:.*Flat Device Tree' "$FIT_INFO" && grep -q 'Architecture: AArch64' "$FIT_INFO" || {
    echo "ERROR: boot FIT has no AArch64 device tree" >&2
    exit 1
}

# The Rockchip FIT listing does not carry the DTB filename. Verify the source
# DTS selected for this build and require its IMX296 include/compatible chain.
DTS="$RK_SDK_DIR/kernel/arch/arm64/boot/dts/rockchip/dlcvcam-rk3576.dts"
CSI_DTSI="$RK_SDK_DIR/kernel/arch/arm64/boot/dts/rockchip/dlcvcam-rk3576-csi0.dtsi"
grep -q 'dlcvcam-rk3576-csi0.dtsi' "$DTS" || {
    echo "ERROR: dlcvcam-rk3576.dts does not include the IMX296 CSI definition" >&2
    exit 1
}
grep -q 'compatible = "sony,imx296lq"' "$CSI_DTSI" || {
    echo "ERROR: IMX296 compatible is missing from $CSI_DTSI" >&2
    exit 1
}

BOOT_BYTES="$(stat -Lc %s "$BOOT_IMG")"
for part in boot recovery; do
    PART_BYTES="$(( $(parameter_part_size_kb "$part") * 1024 ))"
    [ "$BOOT_BYTES" -le "$PART_BYTES" ] || {
        echo "ERROR: $BOOT_IMG ($BOOT_BYTES bytes) exceeds $part ($PART_BYTES bytes)" >&2
        exit 1
    }
done

if [ "$MODE" = verify-package ]; then
    [ -r "$RECOVERY_IMG" ] || {
        echo "ERROR: recovery golden FIT is missing: $RECOVERY_IMG" >&2
        exit 1
    }
    [ -r "$PACKAGE_FILE" ] || {
        echo "ERROR: update package-file is missing: ${PACKAGE_FILE:-unset}" >&2
        exit 1
    }
    [ -r "$UPDATE_IMG" ] || {
        echo "ERROR: packed update image is missing: $UPDATE_IMG" >&2
        exit 1
    }
    grep -Eq '^recovery[[:space:]]+recovery\.img$' "$PACKAGE_FILE" || {
        echo "ERROR: recovery.img is absent from $PACKAGE_FILE" >&2
        exit 1
    }
    "$DUMPIMAGE" -l "$RECOVERY_IMG" >/dev/null
    [ "$(sha256sum "$BOOT_IMG" | cut -d' ' -f1)" = \
      "$(sha256sum "$RECOVERY_IMG" | cut -d' ' -f1)" ] || {
        echo "ERROR: packaged recovery golden image differs from boot.img" >&2
        exit 1
    }
    echo "Verified recovery in update image: $UPDATE_IMG"
    sha256sum "$BOOT_IMG" "$RECOVERY_IMG" "$UPDATE_IMG"
    exit 0
fi

mkdir -p "$(dirname "$RECOVERY_IMG")"
cp --reflink=auto "$BOOT_IMG" "$RECOVERY_IMG.tmp"
sync "$RECOVERY_IMG.tmp"
[ "$(sha256sum "$BOOT_IMG" | cut -d' ' -f1)" = "$(sha256sum "$RECOVERY_IMG.tmp" | cut -d' ' -f1)" ] || {
    echo "ERROR: recovery golden image SHA256 mismatch" >&2
    exit 1
}
mv -f "$RECOVERY_IMG.tmp" "$RECOVERY_IMG"
"$DUMPIMAGE" -l "$RECOVERY_IMG" >/dev/null

echo "Prepared recovery golden FIT: $RECOVERY_IMG"
sha256sum "$BOOT_IMG" "$RECOVERY_IMG"
