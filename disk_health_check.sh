#!/bin/bash
#==============================================================================
# Disk Health Check Script v2.6
# Author: For Hung (VPNNGA.COM / Dataz.vn)
# Mục đích: Check toàn diện sức khỏe và thông số disk trên Linux server/VPS
# Hỗ trợ: Debian/Ubuntu, RHEL/CentOS/Rocky, Arch, Alpine
# Hỗ trợ disk: SATA, SAS, NVMe, virtio (KVM), Xen, OpenVZ
# Usage: sudo bash disk_health_check.sh [--full] [--json] [--no-color]
#==============================================================================

set -o pipefail

# ============================================================
# CẤU HÌNH
# ============================================================
WARN_THRESHOLD=80
CRIT_THRESHOLD=90
INODE_WARN=80
TEMP_WARN=50
TEMP_CRIT=60

# Parse arguments
FULL_MODE=0
JSON_MODE=0
NO_COLOR=0
DEBUG_MODE=0
for arg in "$@"; do
    case "$arg" in
        --full)     FULL_MODE=1 ;;
        --json)     JSON_MODE=1 ;;
        --no-color) NO_COLOR=1 ;;
        --debug)    DEBUG_MODE=1 ;;
        -h|--help)
            echo "Usage: $0 [--full] [--debug] [--no-color]"
            echo "  --full     : Quét thêm top thư mục chiếm dung lượng (chậm)"
            echo "  --debug    : Dump raw SMART output (debug parse)"
            echo "  --no-color : Tắt màu (dùng khi pipe ra file)"
            exit 0
            ;;
    esac
done

# Màu sắc
if [ "$NO_COLOR" -eq 1 ] || [ ! -t 1 ]; then
    RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; NC=''
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
fi

# ============================================================
# DETECTION FUNCTIONS
# ============================================================

# Phát hiện OS family để chọn package manager
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_NAME="${PRETTY_NAME:-Unknown Linux}"
        OS_VERSION="${VERSION_ID:-}"
    else
        OS_ID="unknown"
        OS_NAME="$(uname -s)"
        OS_VERSION=""
    fi

    # Map sang family để chọn lệnh cài
    case "$OS_ID" in
        debian|ubuntu|linuxmint|pop|kali|raspbian)
            OS_FAMILY="debian"
            PKG_INSTALL="apt install -y"
            PKG_NAMES="smartmontools sysstat util-linux"
            ;;
        rhel|centos|rocky|almalinux|fedora|ol)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_INSTALL="dnf install -y"
            else
                PKG_INSTALL="yum install -y"
            fi
            PKG_NAMES="smartmontools sysstat util-linux"
            ;;
        arch|manjaro|endeavouros)
            OS_FAMILY="arch"
            PKG_INSTALL="pacman -S --noconfirm"
            PKG_NAMES="smartmontools sysstat util-linux"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_INSTALL="apk add"
            PKG_NAMES="smartmontools sysstat util-linux"
            ;;
        opensuse*|sles)
            OS_FAMILY="suse"
            PKG_INSTALL="zypper install -y"
            PKG_NAMES="smartmontools sysstat util-linux"
            ;;
        *)
            OS_FAMILY="unknown"
            PKG_INSTALL=""
            PKG_NAMES="smartmontools sysstat"
            ;;
    esac
}

# Phát hiện môi trường ảo hoá (ảnh hưởng việc đọc SMART)
detect_virt() {
    VIRT_TYPE="none"
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
    elif [ -r /proc/1/environ ] && grep -q container /proc/1/environ 2>/dev/null; then
        VIRT_TYPE="container"
    elif [ -d /proc/vz ] && [ ! -d /proc/bc ]; then
        VIRT_TYPE="openvz"
    elif [ -r /sys/hypervisor/type ]; then
        VIRT_TYPE=$(cat /sys/hypervisor/type 2>/dev/null)
    elif grep -qi "qemu\|kvm" /proc/cpuinfo 2>/dev/null; then
        VIRT_TYPE="kvm"
    fi
}

# Phân loại disk: physical/virtual, SSD/HDD/NVMe
classify_disk() {
    local disk="$1"
    local disk_path="/sys/block/$disk"

    DISK_TYPE="unknown"
    DISK_IS_VIRTUAL=0

    # Loại bỏ disk không cần check
    case "$disk" in
        loop*|ram*|sr*|fd*|zram*|dm-*|md*)
            DISK_TYPE="skip"
            return
            ;;
    esac

    # NVMe
    if [[ "$disk" =~ ^nvme ]]; then
        DISK_TYPE="nvme"
        return
    fi

    # Virtio (KVM virtual disk)
    if [[ "$disk" =~ ^vd ]]; then
        DISK_TYPE="virtio"
        DISK_IS_VIRTUAL=1
        return
    fi

    # Xen virtual disk
    if [[ "$disk" =~ ^xvd ]]; then
        DISK_TYPE="xen"
        DISK_IS_VIRTUAL=1
        return
    fi

    # SATA/SAS/SCSI - check rotational
    if [ -r "$disk_path/queue/rotational" ]; then
        local rot
        rot=$(cat "$disk_path/queue/rotational" 2>/dev/null)
        if [ "$rot" = "0" ]; then
            DISK_TYPE="ssd"
        elif [ "$rot" = "1" ]; then
            DISK_TYPE="hdd"
        fi
    fi

    # Check xem có phải virtual không qua vendor
    local vendor
    vendor=$(cat "$disk_path/device/vendor" 2>/dev/null | xargs)
    case "$vendor" in
        QEMU|VBOX|VMware|Msft|Xen) DISK_IS_VIRTUAL=1 ;;
    esac
}

# Lấy đúng tham số smartctl cho từng loại disk
get_smartctl_args() {
    local disk="$1"
    case "$disk" in
        nvme*)  echo "-d nvme" ;;
        *)      echo "" ;;
    esac
}

# ============================================================
# UTILITY FUNCTIONS
# ============================================================
print_header() {
    echo ""
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
    echo -e "${BLUE}${BOLD}  $1${NC}"
    echo -e "${BLUE}${BOLD}========================================================================${NC}"
}

print_sub() {
    echo -e "${CYAN}${BOLD}--- $1 ---${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}⚠ Script nên chạy với quyền root (sudo) để xem đầy đủ SMART data${NC}"
        echo ""
    fi
}

check_dependencies() {
    local missing=()
    for cmd in smartctl iostat lsblk df; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        return
    fi

    echo -e "${YELLOW}⚠ Thiếu công cụ: ${missing[*]}${NC}"

    # Cần root để cài
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}  Cần chạy với sudo để tự động cài đặt. Bỏ qua phần SMART/IO.${NC}"
        echo ""
        return
    fi

    if [ -z "$PKG_INSTALL" ]; then
        echo -e "${RED}  Không xác định được package manager (OS: ${OS_FAMILY}). Bỏ qua.${NC}"
        echo ""
        return
    fi

    echo -e "${CYAN}→ Đang tự động cài đặt: $PKG_NAMES${NC}"

    # Update package index trước (Debian/Ubuntu/Alpine)
    case "$OS_FAMILY" in
        debian)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $PKG_NAMES >/dev/null 2>&1
            ;;
        rhel)
            # Thử import GPG key mới nếu là AlmaLinux/Rocky (tránh lỗi GPG check FAILED)
            if [ "$OS_ID" = "almalinux" ]; then
                rpm --import https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux 2>/dev/null
                rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux 2>/dev/null
            elif [ "$OS_ID" = "rocky" ]; then
                rpm --import https://download.rockylinux.org/pub/rocky/RPM-GPG-KEY-rockyofficial 2>/dev/null
            fi
            $PKG_INSTALL $PKG_NAMES >/dev/null 2>&1
            # Nếu vẫn lỗi do GPG, thử bypass
            if ! command -v smartctl &>/dev/null; then
                echo -e "${YELLOW}  Thử lại với --nogpgcheck...${NC}"
                $PKG_INSTALL --nogpgcheck $PKG_NAMES >/dev/null 2>&1
            fi
            ;;
        arch)
            pacman -Sy --noconfirm $PKG_NAMES >/dev/null 2>&1
            ;;
        alpine)
            apk update >/dev/null 2>&1
            apk add $PKG_NAMES >/dev/null 2>&1
            ;;
        suse)
            zypper --non-interactive install $PKG_NAMES >/dev/null 2>&1
            ;;
    esac

    # Verify lại
    local still_missing=()
    for cmd in smartctl iostat; do
        if ! command -v "$cmd" &>/dev/null; then
            still_missing+=("$cmd")
        fi
    done

    if [ ${#still_missing[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ Cài đặt thành công${NC}"
    else
        echo -e "${YELLOW}⚠ Vẫn thiếu: ${still_missing[*]} (sẽ skip các check liên quan)${NC}"
    fi
    echo ""
}

# ============================================================
# 1. SYSTEM INFO
# ============================================================
show_system_info() {
    print_header "1. THÔNG TIN HỆ THỐNG"
    echo -e "Tên máy      : ${GREEN}$(hostname)${NC}"
    echo -e "OS           : ${GREEN}${OS_NAME}${NC}"
    echo -e "OS Family    : ${GREEN}${OS_FAMILY}${NC}"
    echo -e "Kernel       : ${GREEN}$(uname -r)${NC}"
    echo -e "Kiến trúc    : ${GREEN}$(uname -m)${NC}"

    case "$VIRT_TYPE" in
        none|"")
            echo -e "Ảo hoá       : ${GREEN}bare-metal / không phát hiện${NC}"
            ;;
        *)
            echo -e "Ảo hoá       : ${YELLOW}${VIRT_TYPE}${NC}"
            ;;
    esac

    echo -e "Uptime       : ${GREEN}$(uptime -p 2>/dev/null || uptime)${NC}"
    echo -e "Thời gian    : ${GREEN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
}

# ============================================================
# 2. BLOCK DEVICES
# ============================================================
show_block_devices() {
    print_header "2. DANH SÁCH Ổ ĐĨA VÀ PHÂN VÙNG"
    echo -e "${CYAN}Cấu trúc block device:${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null | grep -vE "^loop|^sr"

    echo ""
    print_sub "Chi tiết disk vật lý/ảo (đã lọc loop/ram/cdrom)"

    local disks
    disks=$(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

    for disk in $disks; do
        classify_disk "$disk"
        [ "$DISK_TYPE" = "skip" ] && continue

        echo -e "${YELLOW}● /dev/$disk${NC}"

        local model vendor size
        model=$(cat /sys/block/"$disk"/device/model 2>/dev/null | xargs)
        vendor=$(cat /sys/block/"$disk"/device/vendor 2>/dev/null | xargs)
        size=$(lsblk -d -n -o SIZE /dev/"$disk" 2>/dev/null | xargs)

        [ -n "$vendor" ] && echo "    Vendor   : $vendor"
        [ -n "$model" ]  && echo "    Model    : $model"
        echo "    Size     : $size"

        case "$DISK_TYPE" in
            ssd)    echo -e "    Loại     : ${GREEN}SSD (SATA/SAS)${NC}" ;;
            hdd)    echo -e "    Loại     : ${YELLOW}HDD (đĩa quay)${NC}" ;;
            nvme)   echo -e "    Loại     : ${GREEN}NVMe SSD${NC}" ;;
            virtio) echo -e "    Loại     : ${CYAN}Virtio (KVM virtual disk)${NC}" ;;
            xen)    echo -e "    Loại     : ${CYAN}Xen virtual disk${NC}" ;;
            *)      echo -e "    Loại     : unknown" ;;
        esac
    done
}

# ============================================================
# 3. DISK USAGE
# ============================================================
show_disk_usage() {
    print_header "3. DUNG LƯỢNG DISK"
    df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay -x aufs 2>/dev/null | \
    awk -v warn=$WARN_THRESHOLD -v crit=$CRIT_THRESHOLD '
    NR==1 {printf "%-22s %-8s %-8s %-8s %-8s %-6s %s\n", $1, $2, $3, $4, $5, $6, $7; next}
    {
        usage = $6+0
        color = "\033[0;32m"; status = "OK"
        if (usage >= crit)      { color = "\033[0;31m"; status = "CRITICAL" }
        else if (usage >= warn) { color = "\033[1;33m"; status = "WARNING" }
        printf "%s%-22s %-8s %-8s %-8s %-8s %-6s %s [%s]\033[0m\n", color, $1, $2, $3, $4, $5, $6, $7, status
    }'

    print_sub "Inode Usage"
    df -hi -x tmpfs -x devtmpfs -x squashfs -x overlay -x aufs 2>/dev/null | \
    awk -v warn=$INODE_WARN '
    NR==1 {printf "%-22s %-10s %-10s %-10s %-8s %s\n", $1, $2, $3, $4, $5, $6; next}
    {
        usage = $5+0
        color = "\033[0;32m"
        if (usage >= warn) color = "\033[1;33m"
        printf "%s%-22s %-10s %-10s %-10s %-8s %s\033[0m\n", color, $1, $2, $3, $4, $5, $6
    }'
}

# ============================================================
# 4. SMART HEALTH
# ============================================================
# Detect RAID controller (Dell PERC, LSI MegaRAID, HP SmartArray, Fujitsu PRAID, Adaptec...)
detect_raid_controller() {
    RAID_TYPE=""
    RAID_DEVICE=""

    # Pattern các loại RAID controller phổ biến:
    # - megaraid: LSI/Broadcom MegaRAID, Dell PERC, Fujitsu PRAID, IBM ServeRAID, Lenovo
    # - cciss: HP Smart Array (cũ)
    # - aacraid: Adaptec
    # - 3ware: 3ware/LSI 3ware
    local megaraid_pattern="megaraid|perc|praid|servraid|serveraid|lsi|symbios|broadcom"
    local hp_pattern="smart array|hpsa|hpe"
    local adaptec_pattern="adaptec|aacraid"
    local areca_pattern="areca"

    # Check qua lspci
    if command -v lspci &>/dev/null; then
        local pci_info
        pci_info=$(lspci 2>/dev/null | grep -iE "raid|storage|scsi")
        if echo "$pci_info" | grep -qiE "$megaraid_pattern"; then
            RAID_TYPE="megaraid"
        elif echo "$pci_info" | grep -qiE "$hp_pattern"; then
            RAID_TYPE="cciss"
        elif echo "$pci_info" | grep -qiE "$adaptec_pattern"; then
            RAID_TYPE="aacraid"
        elif echo "$pci_info" | grep -qiE "$areca_pattern"; then
            RAID_TYPE="areca"
        fi
    fi

    # Backup: detect qua model name của disk
    if [ -z "$RAID_TYPE" ]; then
        for disk in $(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}'); do
            local model vendor
            model=$(cat /sys/block/"$disk"/device/model 2>/dev/null | xargs)
            vendor=$(cat /sys/block/"$disk"/device/vendor 2>/dev/null | xargs)
            local check_str="${vendor} ${model}"
            if echo "$check_str" | grep -qiE "$megaraid_pattern"; then
                RAID_TYPE="megaraid"
                break
            elif echo "$check_str" | grep -qiE "$hp_pattern|smart\s+array"; then
                RAID_TYPE="cciss"
                break
            elif echo "$check_str" | grep -qiE "$adaptec_pattern"; then
                RAID_TYPE="aacraid"
                break
            fi
        done
    fi

    # Backup 2: smartctl --scan thường list ra các disk phía sau RAID
    if [ -z "$RAID_TYPE" ] && command -v smartctl &>/dev/null; then
        local scan_out
        scan_out=$(smartctl --scan 2>/dev/null)
        if echo "$scan_out" | grep -q "megaraid"; then
            RAID_TYPE="megaraid"
        elif echo "$scan_out" | grep -q "cciss"; then
            RAID_TYPE="cciss"
        elif echo "$scan_out" | grep -q "aacraid"; then
            RAID_TYPE="aacraid"
        fi
    fi
}

# Đọc SMART qua RAID controller
show_smart_raid() {
    local dev="$1"
    echo -e "${CYAN}→ Phát hiện RAID controller (${RAID_TYPE}). Quét disk vật lý phía sau...${NC}"
    echo ""

    local found=0
    # Thử các disk ID từ 0 đến 23 (đủ cho hầu hết server)
    for i in $(seq 0 23); do
        local out
        out=$(smartctl -d "${RAID_TYPE},$i" -i "$dev" 2>/dev/null)
        if echo "$out" | grep -qiE "Device Model|Product:|Model Number"; then
            found=1
            local model serial size rotation
            model=$(echo "$out" | grep -iE "Device Model|Product:|Model Number" | head -1 | awk -F: '{print $2}' | xargs)
            serial=$(echo "$out" | grep -iE "Serial [Nn]umber" | head -1 | awk -F: '{print $2}' | xargs)
            size=$(echo "$out" | grep -iE "User Capacity" | head -1 | sed -E 's/.*\[([^]]+)\].*/\1/')
            rotation=$(echo "$out" | grep -iE "Rotation Rate" | head -1 | awk -F: '{print $2}' | xargs)

            echo -e "${YELLOW}● ${dev} -d ${RAID_TYPE},${i}${NC}"
            if [ "$DEBUG_MODE" -eq 1 ]; then
                echo -e "${CYAN}    [DEBUG] Raw SMART -A output:${NC}"
                echo "$attrs" | sed 's/^/    | /'
                echo ""
            fi
            [ -n "$model" ]  && echo "    Model        : $model"
            [ -n "$serial" ] && echo "    Serial       : $serial"
            [ -n "$size" ]   && echo "    Size         : $size"
            [ -n "$rotation" ] && echo "    Rotation     : $rotation"

            # Health
            local health
            health=$(smartctl -d "${RAID_TYPE},$i" -H "$dev" 2>/dev/null | grep -iE "SMART overall|SMART Health Status" | awk -F: '{print $2}' | xargs)
            if [[ "$health" =~ ^(PASSED|OK)$ ]]; then
                echo -e "    SMART Status : ${GREEN}$health ✓${NC}"
            elif [ -n "$health" ]; then
                echo -e "    SMART Status : ${RED}$health ✗${NC}"
            fi

            # Attributes
            local attrs poh temp realloc
            attrs=$(smartctl -d "${RAID_TYPE},$i" -A "$dev" 2>/dev/null)
            poh=$(echo "$attrs" | grep -iE "Power_On_Hours|Power On Hours" | awk '{print $NF}' | head -1 | tr -d ',')
            [ -n "$poh" ] && [[ "$poh" =~ ^[0-9]+$ ]] && echo "    Power On     : $poh giờ (~$((poh/24)) ngày)"

            # Parse nhiệt độ THẬT (RAW_VALUE) từ SMART output
            # Format ATA: "194 Temperature_Celsius 0x0022 070 046 000 Old_age Always - 30 (Min/Max 22/54)"
            # Cột RAW_VALUE nằm SAU dấu "-", không phải cột thứ 10 (cột 10 là VALUE normalized)
            temp=""

            # Format 1: SCSI/SAS "Current Drive Temperature: 45 C"
            temp=$(echo "$attrs" | grep -iE "Current Drive Temperature|Drive Temperature" | grep -oE "[0-9]+ C" | head -1 | awk '{print $1}')

            # Format 2: NVMe "Temperature: 45 Celsius"
            if [ -z "$temp" ]; then
                temp=$(echo "$attrs" | grep -iE "^Temperature:" | grep -oE "[0-9]+" | head -1)
            fi

            # Format 3: ATA attr 194 Temperature_Celsius - lấy số ĐẦU TIÊN sau dấu "-"
            if [ -z "$temp" ]; then
                temp=$(echo "$attrs" | grep -iE "^[[:space:]]*194[[:space:]].*Temperature" | \
                       sed -E 's/.*[[:space:]]-[[:space:]]+([0-9]+).*/\1/' | head -1)
            fi

            # Format 4: ATA attr 190 Airflow_Temperature_Cel
            if [ -z "$temp" ]; then
                temp=$(echo "$attrs" | grep -iE "^[[:space:]]*190[[:space:]].*Airflow_Temperature" | \
                       sed -E 's/.*[[:space:]]-[[:space:]]+([0-9]+).*/\1/' | head -1)
            fi

            # Validate phải là số
            if ! [[ "$temp" =~ ^[0-9]+$ ]]; then
                temp=""
            fi

            if [ -n "$temp" ]; then
                # Thêm Min/Max nếu có
                local minmax
                minmax=$(echo "$attrs" | grep -iE "Temperature_Celsius|Airflow_Temperature" | grep -oE "Min/Max [0-9]+/[0-9]+" | head -1)
                local mm_suffix=""
                [ -n "$minmax" ] && mm_suffix=" (${minmax})"

                if [ "$temp" -ge "$TEMP_CRIT" ]; then
                    echo -e "    Temperature  : ${RED}${temp}°C ⚠ QUÁ NÓNG${mm_suffix}${NC}"
                elif [ "$temp" -ge "$TEMP_WARN" ]; then
                    echo -e "    Temperature  : ${YELLOW}${temp}°C cao${mm_suffix}${NC}"
                else
                    echo -e "    Temperature  : ${GREEN}${temp}°C ✓${mm_suffix}${NC}"
                fi
            fi

            realloc=$(echo "$attrs" | grep -i "Reallocated_Sector" | awk '{print $NF}' | head -1)
            if [ -n "$realloc" ] && [ "$realloc" != "0" ]; then
                echo -e "    Bad Sectors  : ${RED}$realloc (đã có sector lỗi!)${NC}"
            elif [ -n "$realloc" ]; then
                echo -e "    Bad Sectors  : ${GREEN}0 ✓${NC}"
            fi

            echo ""
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo -e "${YELLOW}⚠ Không tìm thấy disk nào phía sau RAID controller${NC}"
        echo -e "${YELLOW}  Thử thủ công: smartctl --scan${NC}"
    fi
}

show_smart_info() {
    print_header "4. SMART HEALTH CHECK"

    if ! command -v smartctl &>/dev/null; then
        echo -e "${YELLOW}⚠ smartctl chưa cài. Cài bằng: sudo $PKG_INSTALL smartmontools${NC}"
        return
    fi

    # Detect RAID controller
    detect_raid_controller

    # Cảnh báo trên môi trường ảo
    case "$VIRT_TYPE" in
        kvm|xen|qemu|vmware|virtualbox|microsoft|openvz|lxc|docker|container)
            echo -e "${YELLOW}⚠ Đang chạy trên môi trường ảo (${VIRT_TYPE}).${NC}"
            echo -e "${YELLOW}  SMART data từ guest thường không khả dụng. Hãy check trên host.${NC}"
            echo ""
            ;;
    esac

    local disks
    disks=$(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')

    for disk in $disks; do
        classify_disk "$disk"
        [ "$DISK_TYPE" = "skip" ] && continue

        # Skip virtual disk vì không có SMART thật
        if [ "$DISK_IS_VIRTUAL" -eq 1 ] || [ "$DISK_TYPE" = "virtio" ] || [ "$DISK_TYPE" = "xen" ]; then
            echo -e "${YELLOW}● /dev/$disk - skip (virtual disk, không có SMART)${NC}"
            continue
        fi

        # Check RAID controller - đọc qua megaraid/cciss/aacraid
        local model_check vendor_check
        model_check=$(cat /sys/block/"$disk"/device/model 2>/dev/null | xargs)
        vendor_check=$(cat /sys/block/"$disk"/device/vendor 2>/dev/null | xargs)
        local raid_str="${vendor_check} ${model_check}"
        if echo "$raid_str" | grep -qiE "PERC|MegaRAID|PRAID|ServeRAID|LOGICAL|SmartArray|Smart Array|HPSA|Adaptec|LSI|Areca|FTS"; then
            # Nếu chưa set RAID_TYPE từ detect_raid_controller thì set fallback
            [ -z "$RAID_TYPE" ] && RAID_TYPE="megaraid"
            show_smart_raid "/dev/$disk"
            continue
        fi

        echo -e "${YELLOW}● /dev/$disk (${DISK_TYPE})${NC}"

        local args
        args=$(get_smartctl_args "$disk")

        local health
        health=$(smartctl $args -H /dev/"$disk" 2>/dev/null | grep -iE "SMART overall|SMART Health Status" | awk -F: '{print $2}' | xargs)

        if [ -z "$health" ]; then
            echo -e "    SMART        : ${YELLOW}Không đọc được trực tiếp, đang thử qua RAID controller...${NC}"
            # Fallback cuối: thử quét megaraid dù chưa detect được
            local scan_devs
            scan_devs=$(smartctl --scan 2>/dev/null | grep -oE "\-d [a-z]+" | sort -u | head -1 | awk '{print $2}')
            if [ -n "$scan_devs" ]; then
                RAID_TYPE="$scan_devs"
                show_smart_raid "/dev/$disk"
            else
                echo -e "    ${YELLOW}Gợi ý: chạy \`smartctl --scan\` để xem các loại quét khả dụng${NC}"
            fi
            continue
        fi

        if [[ "$health" =~ ^(PASSED|OK)$ ]]; then
            echo -e "    SMART Status : ${GREEN}$health ✓${NC}"
        else
            echo -e "    SMART Status : ${RED}$health ✗${NC}"
        fi

        # Thông số chi tiết
        local smart_output
        smart_output=$(smartctl $args -A /dev/"$disk" 2>/dev/null)

        # Power-on hours
        local poh
        poh=$(echo "$smart_output" | grep -iE "Power_On_Hours|Power On Hours" | awk '{print $NF}' | head -1 | tr -d ',')
        if [ -n "$poh" ] && [[ "$poh" =~ ^[0-9]+$ ]]; then
            echo "    Power On     : $poh giờ (~$((poh/24)) ngày, ~$((poh/8760)) năm)"
        fi

        # Temperature
        local temp
        if [ "$DISK_TYPE" = "nvme" ]; then
            temp=$(echo "$smart_output" | grep -i "Temperature:" | awk '{print $2}' | head -1)
        else
            temp=$(echo "$smart_output" | grep -iE "Temperature_Celsius|Current Drive Temperature" | awk '{for(i=1;i<=NF;i++) if($i~/^[0-9]+$/ && $i+0<100 && $i+0>10){print $i; exit}}' | head -1)
        fi

        if [ -n "$temp" ] && [[ "$temp" =~ ^[0-9]+$ ]]; then
            if [ "$temp" -ge "$TEMP_CRIT" ]; then
                echo -e "    Temperature  : ${RED}${temp}°C ⚠ QUÁ NÓNG${NC}"
            elif [ "$temp" -ge "$TEMP_WARN" ]; then
                echo -e "    Temperature  : ${YELLOW}${temp}°C ⚠ Cao${NC}"
            else
                echo -e "    Temperature  : ${GREEN}${temp}°C ✓${NC}"
            fi
        fi

        # Bad sectors (HDD/SATA-SSD)
        if [ "$DISK_TYPE" != "nvme" ]; then
            local realloc
            realloc=$(echo "$smart_output" | grep -i "Reallocated_Sector" | awk '{print $NF}' | head -1)
            if [ -n "$realloc" ] && [ "$realloc" != "0" ]; then
                echo -e "    Bad Sectors  : ${RED}$realloc (đã có sector lỗi!)${NC}"
            elif [ -n "$realloc" ]; then
                echo -e "    Bad Sectors  : ${GREEN}0 ✓${NC}"
            fi

            local pending
            pending=$(echo "$smart_output" | grep -i "Current_Pending_Sector" | awk '{print $NF}' | head -1)
            if [ -n "$pending" ] && [ "$pending" != "0" ]; then
                echo -e "    Pending      : ${RED}$pending sectors pending${NC}"
            fi
        fi

        # NVMe wear / SSD wear
        if [ "$DISK_TYPE" = "nvme" ]; then
            local pct_used
            pct_used=$(echo "$smart_output" | grep -i "Percentage Used" | awk '{print $NF}' | tr -d '%' | head -1)
            [ -n "$pct_used" ] && echo "    Wear Used    : ${pct_used}%"

            local spare
            spare=$(echo "$smart_output" | grep -i "Available Spare:" | awk '{print $NF}' | tr -d '%' | head -1)
            [ -n "$spare" ] && echo "    Available Spare: ${spare}%"
        else
            local wear
            wear=$(echo "$smart_output" | grep -iE "Wear_Leveling_Count|Media_Wearout_Indicator" | awk '{print $4}' | head -1)
            [ -n "$wear" ] && echo "    SSD Health   : $wear"
        fi

        # Data written - parse khác cho NVMe vs SATA
        local written
        if [ "$DISK_TYPE" = "nvme" ]; then
            # NVMe format: "Data Units Written:                 1,234,567 [632 TB]"
            written=$(echo "$smart_output" | grep -i "Data Units Written" | sed -E 's/.*\[([^]]+)\].*/\1/' | head -1)
            if [ -z "$written" ]; then
                # Fallback nếu không có giá trị trong [ ]
                written=$(echo "$smart_output" | grep -i "Data Units Written" | awk -F: '{print $2}' | xargs | head -1)
            fi
        else
            # SATA SSD/HDD format: "Total_LBAs_Written ... 123456789"
            local lbas
            lbas=$(echo "$smart_output" | grep -i "Total_LBAs_Written" | awk '{print $NF}' | head -1)
            if [ -n "$lbas" ] && [[ "$lbas" =~ ^[0-9]+$ ]]; then
                # LBA * 512 bytes / 1024^4 = TB
                written=$(awk -v l="$lbas" 'BEGIN{printf "%.2f TB", l*512/1099511627776}')
            fi
        fi
        [ -n "$written" ] && echo "    Đã ghi       : $written"

        echo ""
    done
}

# ============================================================
# 5. I/O PERFORMANCE
# ============================================================
show_io_stats() {
    print_header "5. I/O PERFORMANCE"

    if command -v iostat &>/dev/null; then
        print_sub "Disk I/O Statistics (mẫu 2 giây, đã lọc loop/ram)"
        # Lọc bằng grep -v, match cả loop0, loop10, ram1, sr0...
        iostat -xh 2 2 2>/dev/null | tail -n +4 | grep -vE '[[:space:]](loop|ram|sr)[0-9]+$'
    else
        echo -e "${YELLOW}⚠ iostat chưa cài. Cài bằng: sudo $PKG_INSTALL sysstat${NC}"
    fi

    print_sub "Top Process tiêu thụ I/O"
    if command -v iotop &>/dev/null; then
        iotop -b -n 1 -o 2>/dev/null | head -n 12
    else
        echo -e "${YELLOW}⚠ iotop chưa cài (tuỳ chọn). Hiển thị top CPU thay thế:${NC}"
        ps -eo pid,user,comm,%cpu,%mem --sort=-%cpu | head -n 6
    fi
}

# ============================================================
# 6. MOUNT INFO
# ============================================================
show_mount_info() {
    print_header "6. MOUNT OPTIONS VÀ FILESYSTEM"
    print_sub "Filesystem đang mount"
    mount | grep -E "^/dev" | awk '{printf "  %-22s -> %-22s (%s) %s\n", $1, $3, $5, $6}'

    print_sub "Filesystem check status (ext2/3/4)"
    local has_ext=0
    for dev in $(mount | grep -E "^/dev" | awk '{print $1}'); do
        local fstype
        fstype=$(blkid -o value -s TYPE "$dev" 2>/dev/null)
        if [[ "$fstype" =~ ext[234] ]]; then
            has_ext=1
            local mc max lc
            mc=$(tune2fs -l "$dev" 2>/dev/null | grep "Mount count:" | awk '{print $NF}')
            max=$(tune2fs -l "$dev" 2>/dev/null | grep "Maximum mount count:" | awk '{print $NF}')
            lc=$(tune2fs -l "$dev" 2>/dev/null | grep "Last checked:" | cut -d: -f2- | xargs)
            echo "  $dev ($fstype): mount=$mc/$max, last fsck=$lc"
        fi
    done
    [ "$has_ext" -eq 0 ] && echo "  (không có filesystem ext2/3/4)"
}

# ============================================================
# 7. KERNEL ERRORS
# ============================================================
show_kernel_errors() {
    print_header "7. LỖI DISK TRONG KERNEL LOG"
    local errors
    # Lọc keyword lỗi liên quan disk, loại false positive (kernel write-protect, boot msg, etc.)
    errors=$(dmesg 2>/dev/null | \
        grep -iE "i/o error|bad sector|EXT[234]-fs error|XFS.*error|remount.*read-only|medium error|hardware error|sense key|aborted command|smart.*fail" | \
        grep -ivE "Write protecting|read-only data|page_owner|memory init" | \
        tail -n 10)
    if [ -z "$errors" ]; then
        echo -e "${GREEN}✓ Không phát hiện lỗi disk nghiêm trọng trong kernel log${NC}"
    else
        echo -e "${RED}⚠ Cảnh báo (10 dòng gần nhất):${NC}"
        echo "$errors"
    fi
}

# ============================================================
# 8. RAID STATUS
# ============================================================
show_raid_status() {
    if [ -f /proc/mdstat ]; then
        local raid_info
        raid_info=$(cat /proc/mdstat 2>/dev/null)
        if echo "$raid_info" | grep -qE "^md[0-9]"; then
            print_header "8. RAID STATUS (mdadm)"
            echo "$raid_info"
        fi
    fi

    # ZFS pool
    if command -v zpool &>/dev/null; then
        local zpools
        zpools=$(zpool list 2>/dev/null)
        if [ -n "$zpools" ] && ! echo "$zpools" | grep -qi "no pools"; then
            print_header "8b. ZFS POOLS"
            zpool status
        fi
    fi
}

# ============================================================
# 9. TOP DIRECTORIES (chỉ --full)
# ============================================================
show_top_directories() {
    print_header "9. TOP 10 THƯ MỤC LỚN NHẤT (depth 2)"
    echo -e "${CYAN}Đang quét... (có thể mất 30s-vài phút)${NC}"
    du -h --max-depth=2 / 2>/dev/null | sort -rh | head -n 10
}

# ============================================================
# 10. SUMMARY
# ============================================================
show_summary() {
    print_header "TÓM TẮT & KHUYẾN NGHỊ"

    local critical_count warning_count
    critical_count=$(df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | \
                     awk -v t=$CRIT_THRESHOLD 'NR>1 && $5+0>=t' | wc -l)
    warning_count=$(df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | \
                    awk -v w=$WARN_THRESHOLD -v c=$CRIT_THRESHOLD 'NR>1 && $5+0>=w && $5+0<c' | wc -l)

    echo -e "Partition critical (>=${CRIT_THRESHOLD}%): ${RED}$critical_count${NC}"
    echo -e "Partition warning  (>=${WARN_THRESHOLD}%): ${YELLOW}$warning_count${NC}"

    if [ "$critical_count" -gt 0 ]; then
        echo ""
        echo -e "${RED}${BOLD}⚠ Có partition gần đầy - xử lý ngay!${NC}"
        echo "Gợi ý dọn dẹp:"
        case "$OS_FAMILY" in
            debian)
                echo "  - journalctl --vacuum-time=7d"
                echo "  - apt clean && apt autoremove --purge"
                ;;
            rhel)
                echo "  - journalctl --vacuum-time=7d"
                echo "  - dnf clean all  (hoặc yum clean all)"
                ;;
            arch)
                echo "  - journalctl --vacuum-time=7d"
                echo "  - pacman -Sc"
                ;;
            alpine)
                echo "  - apk cache clean"
                ;;
        esac
        echo "  - Tìm file lớn: find / -type f -size +100M 2>/dev/null"
        echo "  - Docker:      docker system prune -a --volumes"
    fi

    echo ""
    echo -e "${GREEN}✓ Hoàn thành lúc $(date '+%H:%M:%S')${NC}"
}

# ============================================================
# MAIN
# ============================================================
main() {
    echo -e "${BOLD}${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║       DISK HEALTH CHECK v2.6 - Linux Server/VPS Monitor           ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    detect_os
    detect_virt
    check_root
    check_dependencies

    show_system_info
    show_block_devices
    show_disk_usage
    show_smart_info
    show_io_stats
    show_mount_info
    show_kernel_errors
    show_raid_status

    if [ "$FULL_MODE" -eq 1 ]; then
        show_top_directories
    else
        echo ""
        echo -e "${CYAN}💡 Thêm flag --full để quét top thư mục lớn (chậm hơn)${NC}"
    fi

    show_summary
}

main "$@"
