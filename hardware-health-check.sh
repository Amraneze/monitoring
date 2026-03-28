#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
#  hardware-health-check.sh
#  Full hardware health report: RAM sticks, CPU cores, HDD/SSD drives
#  Run as root: sudo bash hardware-health-check.sh
# ══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

PASS="${GREEN}✔ PASS${RESET}"
WARN="${YELLOW}⚠ WARN${RESET}"
FAIL="${RED}✖ FAIL${RESET}"
INFO="${CYAN}ℹ INFO${RESET}"

ISSUES=0   # count of FAIL items
WARNINGS=0 # count of WARN items

# ── Helpers ───────────────────────────────────────────────────────────────────
header() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; echo -e "${BOLD}${CYAN}  $1${RESET}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }
subheader() { echo -e "\n${BOLD}  ── $1 ──${RESET}"; }
pass()  { echo -e "  ${PASS}  $1"; }
warn()  { echo -e "  ${WARN}  $1"; WARNINGS=$((WARNINGS+1)); }
fail()  { echo -e "  ${FAIL}  $1"; ISSUES=$((ISSUES+1)); }
info()  { echo -e "  ${INFO}  $1"; }
dim()   { echo -e "  ${DIM}$1${RESET}"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Error: This script must be run as root (sudo bash $0)${RESET}"
        exit 1
    fi
}

install_if_missing() {
    local cmd=$1 pkg=${2:-$1}
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "  ${DIM}Installing $pkg...${RESET}"
        apt-get install -y -q "$pkg" 2>/dev/null || \
        yum install -y -q "$pkg" 2>/dev/null || \
        true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  0. PREFLIGHT
# ══════════════════════════════════════════════════════════════════════════════
require_root

echo -e "${BOLD}"
echo "  ██╗  ██╗██╗    ██╗    ██╗  ██╗███████╗ █████╗ ██╗  ████████╗██╗  ██╗"
echo "  ██║  ██║██║    ██║    ██║  ██║██╔════╝██╔══██╗██║  ╚══██╔══╝██║  ██║"
echo "  ███████║██║ █╗ ██║    ███████║█████╗  ███████║██║     ██║   ███████║"
echo "  ██╔══██║██║███╗██║    ██╔══██║██╔══╝  ██╔══██║██║     ██║   ██╔══██║"
echo "  ██║  ██║╚███╔███╔╝    ██║  ██║███████╗██║  ██║███████╗██║   ██║  ██║"
echo "  ╚═╝  ╚═╝ ╚══╝╚══╝     ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚═╝   ╚═╝  ╚═╝"
echo -e "${RESET}"
echo -e "  ${DIM}Server Hardware Health Check — $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "  ${DIM}Hostname: $(hostname)  |  Kernel: $(uname -r)${RESET}"

# Install required tools
header "0. INSTALLING REQUIRED TOOLS"
for tool_pkg in "smartctl:smartmontools" "dmidecode:dmidecode" "lscpu:util-linux" "edac-util:edac-utils" "mcelog:mcelog" "sensors:lm-sensors"; do
    cmd="${tool_pkg%%:*}"
    pkg="${tool_pkg##*:}"
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd already available"
    else
        install_if_missing "$cmd" "$pkg"
        if command -v "$cmd" &>/dev/null; then
            pass "$cmd installed"
        else
            warn "$cmd not available (some checks will be skipped)"
        fi
    fi
done

# ══════════════════════════════════════════════════════════════════════════════
#  1. RAM — PER DIMM / STICK
# ══════════════════════════════════════════════════════════════════════════════
header "1. RAM — PER MEMORY STICK (DIMM)"

if command -v dmidecode &>/dev/null; then
    # Parse dmidecode memory devices
    DIMM_COUNT=0
    POPULATED_COUNT=0

    # Use process substitution to parse each memory device block
    while IFS= read -r block; do
        [[ -z "$block" ]] && continue

        locator=$(echo "$block"    | grep -m1 "Locator:"           | grep -v "Bank" | awk -F': ' '{print $2}' | xargs)
        bank=$(echo "$block"       | grep -m1 "Bank Locator:"      | awk -F': ' '{print $2}' | xargs)
        size=$(echo "$block"       | grep -m1 "^\s*Size:"          | awk -F': ' '{print $2}' | xargs)
        speed=$(echo "$block"      | grep -m1 "Speed:"             | awk -F': ' '{print $2}' | xargs)
        configured=$(echo "$block" | grep -m1 "Configured.*Speed:" | awk -F': ' '{print $2}' | xargs)
        mfr=$(echo "$block"        | grep -m1 "Manufacturer:"      | awk -F': ' '{print $2}' | xargs)
        part=$(echo "$block"       | grep -m1 "Part Number:"       | awk -F': ' '{print $2}' | xargs)
        memtype=$(echo "$block"    | grep -m1 "^\s*Type:"          | awk -F': ' '{print $2}' | xargs)
        ecc=$(echo "$block"        | grep -m1 "Error.*Type:"       | awk -F': ' '{print $2}' | xargs)
        voltage=$(echo "$block"    | grep -m1 "Voltage:"           | awk -F': ' '{print $2}' | xargs)

        DIMM_COUNT=$((DIMM_COUNT+1))

        if [[ "$size" == "No Module Installed" ]] || [[ "$size" == "Unknown" ]] || [[ -z "$size" ]]; then
            dim "  Slot $locator ($bank): empty"
            continue
        fi

        POPULATED_COUNT=$((POPULATED_COUNT+1))
        subheader "Slot: $locator  |  Bank: $bank"

        info "Size:        $size"
        info "Type:        $memtype"
        info "Mfr:         $mfr"
        info "Part:        $part"
        [[ -n "$voltage" ]] && info "Voltage:     $voltage"

        # Speed check: configured should match rated speed
        if [[ -n "$speed" && -n "$configured" ]]; then
            speed_mhz=$(echo "$speed" | grep -oP '\d+' | head -1)
            conf_mhz=$(echo "$configured" | grep -oP '\d+' | head -1)
            info "Rated speed: $speed"
            if [[ -n "$speed_mhz" && -n "$conf_mhz" ]]; then
                if [[ "$conf_mhz" -lt "$speed_mhz" ]] 2>/dev/null; then
                    warn "Running at ${conf_mhz}MHz — below rated ${speed_mhz}MHz (possible XMP/slot issue)"
                else
                    pass "Running at rated speed (${conf_mhz}MHz)"
                fi
            fi
        fi

        # ECC support
        if [[ "$ecc" == *"ECC"* ]] || [[ "$memtype" == *"ECC"* ]]; then
            pass "ECC: $ecc"
        else
            info "ECC: $ecc (non-ECC RAM — hardware error detection not available)"
        fi

    done < <(dmidecode -t memory 2>/dev/null | awk '/Memory Device$/{found=1; block=""} found{block=block"\n"$0} /^$/{if(found){print block; found=0; block=""}}' || true)

    echo ""
    info "Total slots: $DIMM_COUNT  |  Populated: $POPULATED_COUNT"

else
    warn "dmidecode not available — cannot read per-DIMM info"
fi

# ── ECC error counts (requires edac kernel module) ────────────────────────────
subheader "ECC Error Counts (requires ECC RAM + edac kernel module)"

ECC_AVAILABLE=false
if [[ -d /sys/devices/system/edac/mc ]]; then
    MC_DIRS=$(ls /sys/devices/system/edac/mc/ 2>/dev/null | grep -E "^mc[0-9]" || true)
    if [[ -n "$MC_DIRS" ]]; then
        ECC_AVAILABLE=true
        for mc in $MC_DIRS; do
            mc_path="/sys/devices/system/edac/mc/$mc"
            ce=$(cat "$mc_path/ce_count"  2>/dev/null || echo "N/A")
            ue=$(cat "$mc_path/ue_count"  2>/dev/null || echo "N/A")
            ce_noinfo=$(cat "$mc_path/ce_noinfo_count" 2>/dev/null || echo "N/A")
            ue_noinfo=$(cat "$mc_path/ue_noinfo_count" 2>/dev/null || echo "N/A")
            mc_name=$(cat "$mc_path/mc_name" 2>/dev/null || echo "unknown")
            info "Controller $mc ($mc_name)"

            if [[ "$ue" != "N/A" && "$ue" -gt 0 ]] 2>/dev/null; then
                fail "Uncorrectable ECC errors: $ue — RAM has FAILED, replace immediately"
            else
                pass "Uncorrectable errors (UE): ${ue}"
            fi

            if [[ "$ce" != "N/A" && "$ce" -gt 100 ]] 2>/dev/null; then
                warn "Correctable ECC errors: $ce — RAM is degrading"
            elif [[ "$ce" != "N/A" && "$ce" -gt 0 ]] 2>/dev/null; then
                warn "Correctable ECC errors: $ce — monitor this (small count is acceptable)"
            else
                pass "Correctable errors (CE): ${ce}"
            fi

            # Per-DIMM ECC if available
            for dimm_path in "$mc_path"/dimm*; do
                [[ -d "$dimm_path" ]] || continue
                dimm_name=$(basename "$dimm_path")
                dimm_ce=$(cat "$dimm_path/dimm_ce_count" 2>/dev/null || echo "N/A")
                dimm_ue=$(cat "$dimm_path/dimm_ue_count" 2>/dev/null || echo "N/A")
                dimm_label=$(cat "$dimm_path/dimm_label" 2>/dev/null || echo "unknown")
                if [[ "$dimm_ue" != "N/A" && "$dimm_ue" -gt 0 ]] 2>/dev/null; then
                    fail "  DIMM $dimm_name ($dimm_label): UE=$dimm_ue FAILED"
                elif [[ "$dimm_ce" != "N/A" && "$dimm_ce" -gt 0 ]] 2>/dev/null; then
                    warn "  DIMM $dimm_name ($dimm_label): CE=$dimm_ce (degrading)"
                else
                    pass "  DIMM $dimm_name ($dimm_label): CE=$dimm_ce UE=$dimm_ue"
                fi
            done
        done
    fi
fi

if [[ "$ECC_AVAILABLE" == "false" ]]; then
    info "No EDAC memory controller found in sysfs"
    info "Either non-ECC RAM is installed, or the edac_core kernel module is not loaded"
    info "To load it: modprobe edac_core && modprobe <your_cpu_edac_module>"
fi

# edac-util summary
if command -v edac-util &>/dev/null; then
    subheader "edac-util summary"
    edac_out=$(edac-util -s 0 2>&1 || true)
    if echo "$edac_out" | grep -qi "error"; then
        fail "edac-util reports errors: $edac_out"
    else
        pass "edac-util: no errors reported"
        dim "    $edac_out"
    fi
fi

# ── RAM utilisation ───────────────────────────────────────────────────────────
subheader "RAM Utilisation"
mem_total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
mem_avail=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
mem_used=$((mem_total - mem_avail))
mem_pct=$((mem_used * 100 / mem_total))
swap_total=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
swap_free=$(grep SwapFree /proc/meminfo | awk '{print $2}')
swap_used=$((swap_total - swap_free))

to_gb() { echo "scale=1; $1/1024/1024" | bc 2>/dev/null || echo "$1 kB"; }

info "Total:     $(to_gb $mem_total) GB"
info "Used:      $(to_gb $mem_used) GB  ($mem_pct%)"
info "Available: $(to_gb $mem_avail) GB"

if [[ $mem_pct -ge 95 ]]; then
    fail "RAM usage critical: ${mem_pct}%"
elif [[ $mem_pct -ge 85 ]]; then
    warn "RAM usage high: ${mem_pct}%"
else
    pass "RAM usage: ${mem_pct}%"
fi

if [[ $swap_total -gt 0 ]]; then
    swap_pct=$((swap_used * 100 / swap_total))
    if [[ $swap_pct -ge 50 ]]; then
        warn "Swap usage: ${swap_pct}% — system may be RAM-starved"
    else
        pass "Swap usage: ${swap_pct}% ($(to_gb $swap_used)/$(to_gb $swap_total) GB)"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  2. CPU — PER CORE & SOCKET
# ══════════════════════════════════════════════════════════════════════════════
header "2. CPU — CORES & HARDWARE HEALTH"

# ── CPU info ──────────────────────────────────────────────────────────────────
subheader "CPU Overview"
if command -v lscpu &>/dev/null; then
    cpu_model=$(lscpu | grep "Model name" | awk -F': ' '{print $2}' | xargs)
    sockets=$(lscpu | grep "^Socket(s)" | awk '{print $2}')
    cores_per=$(lscpu | grep "^Core(s) per socket" | awk '{print $2}')
    threads=$(lscpu | grep "^Thread(s) per core" | awk '{print $2}')
    total_cores=$(lscpu | grep "^CPU(s):" | awk '{print $2}')
    max_mhz=$(lscpu 2>/dev/null | grep "CPU max MHz" | awk -F': ' '{print $2}' | xargs)
    cur_mhz=$(lscpu 2>/dev/null | grep "CPU MHz" | awk -F': ' '{print $2}' | xargs)
    virt=$(lscpu 2>/dev/null | grep "Virtualization" | awk -F': ' '{print $2}' | xargs || echo "N/A")
    arch=$(lscpu | grep "^Architecture" | awk '{print $2}')

    info "Model:    $cpu_model"
    info "Arch:     $arch  |  Sockets: $sockets  |  Cores/socket: $cores_per  |  Threads/core: $threads"
    info "Total CPUs (logical): $total_cores"
    [[ -n "$max_mhz" ]] && info "Max freq: ${max_mhz} MHz  |  Current: ${cur_mhz} MHz"
    [[ -n "$virt" ]] && info "Virtualization: $virt"

    # Frequency sanity check
    if [[ -n "$max_mhz" && -n "$cur_mhz" ]]; then
        max_int=${max_mhz%.*}
        cur_int=${cur_mhz%.*}
        if [[ -n "$max_int" && -n "$cur_int" ]] 2>/dev/null; then
            throttle_pct=$((cur_int * 100 / max_int))
            if [[ $throttle_pct -lt 50 ]]; then
                warn "CPU running at ${throttle_pct}% of max frequency — possible throttling"
            fi
        fi
    fi
fi

# ── Per-core temperature ──────────────────────────────────────────────────────
subheader "CPU Temperatures (per core)"
TEMP_FOUND=false

# Method 1: lm-sensors
if command -v sensors &>/dev/null; then
    TEMP_FOUND=true
    sensors_out=$(sensors 2>/dev/null)
    while IFS= read -r line; do
        label=$(echo "$line" | awk -F':' '{print $1}' | xargs)
        temp_val=$(echo "$line" | grep -oP '[+-]?\d+\.\d+(?=°C)' | head -1)
        high=$(echo "$line" | grep -oP '(?<=high = \+)\d+\.\d+' | head -1 || true)
        crit=$(echo "$line" | grep -oP '(?<=crit = \+)\d+\.\d+' | head -1 || true)

        if [[ -n "$temp_val" ]]; then
            temp_int=${temp_val%.*}
            if [[ $temp_int -ge 90 ]] 2>/dev/null; then
                fail "$label: ${temp_val}°C — CRITICAL (thermal throttling or cooler failure)"
            elif [[ $temp_int -ge 80 ]] 2>/dev/null; then
                warn "$label: ${temp_val}°C — high (check cooling)"
            elif [[ $temp_int -ge 70 ]] 2>/dev/null; then
                warn "$label: ${temp_val}°C — elevated under load"
            else
                pass "$label: ${temp_val}°C"
            fi
        fi
    done < <(echo "$sensors_out" | grep -E "Core [0-9]+|Tctl|Tccd|Package" || true)
fi

# Method 2: /sys/class/thermal (fallback, works without lm-sensors)
if [[ "$TEMP_FOUND" == "false" ]]; then
    for zone in /sys/class/thermal/thermal_zone*; do
        [[ -f "$zone/temp" ]] || continue
        type=$(cat "$zone/type" 2>/dev/null || echo "unknown")
        temp_raw=$(cat "$zone/temp" 2>/dev/null || echo "0")
        temp_c=$((temp_raw / 1000))
        if [[ $temp_c -ge 90 ]]; then
            fail "$type: ${temp_c}°C — CRITICAL"
        elif [[ $temp_c -ge 80 ]]; then
            warn "$type: ${temp_c}°C — high"
        elif [[ $temp_c -gt 0 ]]; then
            pass "$type: ${temp_c}°C"
            TEMP_FOUND=true
        fi
    done
fi

[[ "$TEMP_FOUND" == "false" ]] && warn "No CPU temperature sensors found (hwmon/sensors not available)"

# ── CPU Machine Check Exceptions (hardware faults) ────────────────────────────
subheader "CPU Machine Check Exceptions (MCE)"

# Method 1: rasdaemon
if command -v rasdaemon &>/dev/null; then
    mce_count=$(rasdaemon --error-count 2>/dev/null | grep -oP '\d+' | head -1 || echo "0")
    if [[ "$mce_count" -gt 0 ]] 2>/dev/null; then
        fail "rasdaemon: $mce_count MCE events — possible faulty CPU/RAM/bus"
        rasdaemon --error-count 2>/dev/null | head -20 || true
    else
        pass "rasdaemon: 0 MCE events"
    fi
fi

# Method 2: mcelog
if command -v mcelog &>/dev/null; then
    mce_log=$(mcelog --client 2>/dev/null || mcelog 2>/dev/null || true)
    if [[ -n "$mce_log" ]]; then
        fail "mcelog reports hardware errors:"
        echo "$mce_log" | head -20 | while IFS= read -r l; do dim "    $l"; done
    else
        pass "mcelog: no hardware errors"
    fi
fi

# Method 3: kernel dmesg (always available)
subheader "Kernel hardware error messages (dmesg)"
mce_dmesg=$(dmesg --level=err,crit,alert,emerg 2>/dev/null | \
    grep -iE "mce|machine check|hardware error|edac|ecc|uncorrected|corrected error|cpu.*error|memory.*error" || true)

if [[ -n "$mce_dmesg" ]]; then
    warn "Hardware-related kernel messages found:"
    echo "$mce_dmesg" | tail -20 | while IFS= read -r l; do dim "    $l"; done
else
    pass "dmesg: no hardware error messages"
fi

# ── CPU utilisation per core ──────────────────────────────────────────────────
subheader "CPU Utilisation (current, 1-second sample)"
if command -v mpstat &>/dev/null; then
    mapfile -t mpstat_lines < <(mpstat -P ALL 1 1 2>/dev/null | grep "Average" | grep -v "CPU" || true)
    for line in "${mpstat_lines[@]}"; do
        cpu=$(echo "$line" | awk '{print $2}')
        idle=$(echo "$line" | awk '{print $NF}')
        used=$(echo "100 - $idle" | bc 2>/dev/null || echo "N/A")
        if [[ "$cpu" != "all" && -n "$used" ]]; then
            used_int=${used%.*}
            if [[ "$used_int" -ge 95 ]] 2>/dev/null; then
                warn "Core $cpu: ${used}% busy"
            else
                pass "Core $cpu: ${used}% busy"
            fi
        fi
    done
else
    # Fallback: read /proc/stat
    info "mpstat not available — reading /proc/stat"
    awk '/^cpu[0-9]/{
        total=$2+$3+$4+$5+$6+$7+$8
        idle=$5
        printf "  Core %s: %.1f%% used\n", substr($1,4), (total-idle)/total*100
    }' /proc/stat
fi

# ── CPU flags / feature check ─────────────────────────────────────────────────
subheader "CPU Feature Check"
flags=$(grep -m1 "^flags" /proc/cpuinfo | awk -F': ' '{print $2}')
for feature in "sse4_2" "avx" "avx2" "aes" "rdrand" "vmx vmx" "svm"; do
    feat_clean=${feature%% *}
    if echo "$flags" | grep -qw "$feat_clean"; then
        pass "CPU feature: $feat_clean"
    else
        info "CPU feature absent: $feat_clean (may be expected depending on CPU generation)"
    fi
done

# ── Microcode version ─────────────────────────────────────────────────────────
subheader "CPU Microcode"
microcode=$(grep -m1 "microcode" /proc/cpuinfo | awk -F': ' '{print $2}' | xargs || echo "N/A")
info "Current microcode: $microcode"
if dmesg 2>/dev/null | grep -qi "microcode.*updated\|microcode.*loaded"; then
    pass "Microcode was updated at boot"
elif dmesg 2>/dev/null | grep -qi "microcode.*not updated\|microcode.*up to date"; then
    pass "Microcode is up to date"
else
    warn "Cannot confirm microcode update status — check: apt install intel-microcode / amd64-microcode"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  3. DRIVES — HDD & SSD PER DEVICE
# ══════════════════════════════════════════════════════════════════════════════
header "3. HARD DRIVES & SSDs — PER DEVICE"

if ! command -v smartctl &>/dev/null; then
    fail "smartctl not found — cannot check drives. Install: apt install smartmontools"
else
    # Auto-discover all block devices
    DRIVES=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}' || \
             ls /dev/sd* /dev/nvme* /dev/hd* 2>/dev/null | grep -E "^/dev/(sd[a-z]|nvme[0-9]n[0-9]|hd[a-z])$" || true)

    if [[ -z "$DRIVES" ]]; then
        warn "No drives found via lsblk"
    fi

    for drive in $DRIVES; do
        [[ -b "$drive" ]] || continue

        subheader "Drive: $drive"

        # ── Basic identity ────────────────────────────────────────────────────
        smart_info=$(smartctl -i "$drive" 2>/dev/null || true)

        model=$(echo "$smart_info"   | grep -E "Device Model|Model Number|Product:" | head -1 | awk -F': ' '{print $2}' | xargs)
        serial=$(echo "$smart_info"  | grep -E "Serial Number" | head -1 | awk -F': ' '{print $2}' | xargs)
        fw=$(echo "$smart_info"      | grep -E "Firmware" | head -1 | awk -F': ' '{print $2}' | xargs)
        capacity=$(echo "$smart_info"| grep -E "User Capacity" | head -1 | awk -F': ' '{print $2}' | xargs)
        type=$(echo "$smart_info"    | grep -E "Rotation Rate|Form Factor" | head -1 | awk -F': ' '{print $2}' | xargs)
        transport=$(echo "$smart_info"| grep -E "Transport protocol|SATA Version" | head -1 | awk -F': ' '{print $2}' | xargs)

        [[ -n "$model" ]]    && info "Model:    $model"
        [[ -n "$serial" ]]   && info "Serial:   $serial"
        [[ -n "$capacity" ]] && info "Capacity: $capacity"
        [[ -n "$type" ]]     && info "Type:     $type"
        [[ -n "$fw" ]]       && info "Firmware: $fw"
        [[ -n "$transport" ]]&& info "Interface:$transport"

        # Detect NVMe vs SATA
        is_nvme=false
        [[ "$drive" == *"nvme"* ]] && is_nvme=true

        # ── Overall SMART health ──────────────────────────────────────────────
        health=$(smartctl -H "$drive" 2>/dev/null | grep -E "SMART overall|test result|health" | tail -1)
        if echo "$health" | grep -qi "PASSED\|OK\|ok"; then
            pass "SMART overall health: PASSED"
        elif echo "$health" | grep -qi "FAILED"; then
            fail "SMART overall health: FAILED — drive is critically damaged"
        else
            warn "SMART health: $health"
        fi

        # ── Full SMART attributes (SATA/SAS) ─────────────────────────────────
        if [[ "$is_nvme" == "false" ]]; then
            smart_attrs=$(smartctl -A "$drive" 2>/dev/null || true)

            check_attr() {
                local attr_name="$1" warn_val="$2" fail_val="$3" description="$4"
                local raw
                raw=$(echo "$smart_attrs" | grep -iE "[[:space:]]${attr_name}[[:space:]]" | awk '{print $NF}' | head -1 | tr -d ' ')
                [[ -z "$raw" ]] && return
                raw_int=$(echo "$raw" | grep -oP '^\d+' || echo "0")
                if [[ -n "$fail_val" && "$raw_int" -ge "$fail_val" ]] 2>/dev/null; then
                    fail "$description: $raw_int $([[ $raw_int -gt 0 ]] && echo '← CRITICAL')"
                elif [[ -n "$warn_val" && "$raw_int" -ge "$warn_val" ]] 2>/dev/null; then
                    warn "$description: $raw_int"
                elif [[ "$raw_int" -gt 0 ]] 2>/dev/null; then
                    warn "$description: $raw_int (non-zero — monitor this)"
                else
                    pass "$description: $raw_int"
                fi
            }

            # Critical reliability indicators
            check_attr "Reallocated_Sector_Ct"     1    10   "Reallocated sectors"
            check_attr "Current_Pending_Sector"    1    1    "Pending (unstable) sectors"
            check_attr "Offline_Uncorrectable"     1    1    "Offline uncorrectable sectors"
            check_attr "Reported_Uncorrect"        1    1    "Reported uncorrectable errors"
            check_attr "Reallocated_Event_Count"   1    10   "Reallocated events"
            check_attr "Command_Timeout"           5    20   "Command timeouts"
            check_attr "UDMA_CRC_Error_Count"      0    10   "UDMA CRC errors (cable/connector)"
            check_attr "Multi_Zone_Error_Rate"     0    5    "Multi-zone errors"
            check_attr "Spin_Retry_Count"          0    3    "Spin retry count"

            # Temperature
            temp_raw=$(echo "$smart_attrs" | grep -iE "Temperature_Celsius|Airflow_Temperature" | head -1 | awk '{print $NF}' | grep -oP '^\d+')
            if [[ -n "$temp_raw" ]]; then
                if [[ $temp_raw -ge 55 ]] 2>/dev/null; then
                    fail "Drive temperature: ${temp_raw}°C — critical (risk of data loss)"
                elif [[ $temp_raw -ge 45 ]] 2>/dev/null; then
                    warn "Drive temperature: ${temp_raw}°C — elevated"
                else
                    pass "Drive temperature: ${temp_raw}°C"
                fi
            fi

            # Power-on hours
            poh=$(echo "$smart_attrs" | grep "Power_On_Hours" | awk '{print $NF}' | grep -oP '^\d+' || true)
            if [[ -n "$poh" ]]; then
                poh_years=$(echo "scale=1; $poh / 8760" | bc 2>/dev/null || echo "?")
                if [[ $poh -ge 50000 ]] 2>/dev/null; then
                    warn "Power-on hours: $poh (~${poh_years} years) — drive is very old"
                elif [[ $poh -ge 30000 ]] 2>/dev/null; then
                    warn "Power-on hours: $poh (~${poh_years} years) — consider proactive replacement"
                else
                    pass "Power-on hours: $poh (~${poh_years} years)"
                fi
            fi

            # SSD-specific: wear level
            wear=$(echo "$smart_attrs" | grep -iE "Wear_Leveling_Count|Media_Wearout_Indicator|SSD_Life_Left|Percent_Lifetime_Remain" | head -1 | awk '{print $4}' || true)
            if [[ -n "$wear" ]]; then
                if [[ $wear -le 10 ]] 2>/dev/null; then
                    fail "SSD wear level value: $wear — drive is nearly worn out"
                elif [[ $wear -le 25 ]] 2>/dev/null; then
                    warn "SSD wear level value: $wear — consider replacement soon"
                else
                    pass "SSD wear level value: $wear"
                fi
            fi

        else
            # ── NVMe specific attributes ──────────────────────────────────────
            nvme_attrs=$(smartctl -A "$drive" 2>/dev/null || true)

            spare=$(echo "$nvme_attrs"       | grep "Available Spare"       | grep -v Threshold | awk '{print $NF}' | tr -d '%' | head -1)
            spare_thresh=$(echo "$nvme_attrs"| grep "Available Spare Thresh" | awk '{print $NF}' | tr -d '%' | head -1)
            wear=$(echo "$nvme_attrs"        | grep "Percentage Used"        | awk '{print $NF}' | tr -d '%' | head -1)
            temp=$(echo "$nvme_attrs"        | grep "Temperature"            | head -1 | grep -oP '\d+(?= Celsius)' | head -1)
            media_err=$(echo "$nvme_attrs"   | grep "Media and Data Integ"   | awk '{print $NF}' | head -1)
            err_entries=$(echo "$nvme_attrs" | grep "Number of Error"        | awk '{print $NF}' | head -1)
            unsafe=$(echo "$nvme_attrs"      | grep "Unsafe Shutdowns"       | awk '{print $NF}' | head -1)

            [[ -n "$temp" ]]       && { [[ $temp -ge 70 ]] && fail "NVMe temp: ${temp}°C" || pass "NVMe temp: ${temp}°C"; }
            [[ -n "$wear" ]]       && { [[ $wear -ge 90 ]] && fail "NVMe wear: ${wear}%" || [[ $wear -ge 75 ]] && warn "NVMe wear: ${wear}%" || pass "NVMe percentage used: ${wear}%"; }
            [[ -n "$spare" ]]      && { [[ $spare -le ${spare_thresh:-10} ]] && fail "NVMe spare below threshold: ${spare}% (thresh: ${spare_thresh}%)" || pass "NVMe available spare: ${spare}% (thresh: ${spare_thresh}%)"; }
            [[ -n "$media_err" ]]  && { [[ $media_err -gt 0 ]] && fail "NVMe media errors: $media_err" || pass "NVMe media errors: $media_err"; }
            [[ -n "$err_entries" ]]&& { [[ $err_entries -gt 0 ]] && warn "NVMe error log entries: $err_entries" || pass "NVMe error log entries: $err_entries"; }
            [[ -n "$unsafe" ]]     && { [[ $unsafe -gt 100 ]] && warn "Unsafe shutdowns: $unsafe" || info "Unsafe shutdowns: $unsafe"; }
        fi

        # ── Self-test log ─────────────────────────────────────────────────────
        subheader "  Self-test history ($drive)"
        selftest=$(smartctl -l selftest "$drive" 2>/dev/null | grep -E "^#" | head -5 || true)
        if [[ -z "$selftest" ]]; then
            info "No self-test history found"
            info "Run a short test: smartctl -t short $drive"
        else
            while IFS= read -r line; do
                if echo "$line" | grep -qi "Completed without error\|Successful"; then
                    pass "  $line"
                elif echo "$line" | grep -qi "Failed\|Error"; then
                    fail "  $line"
                else
                    info "  $line"
                fi
            done < <(echo "$selftest")
        fi

        # ── Error log ─────────────────────────────────────────────────────────
        err_count=$(smartctl -l error "$drive" 2>/dev/null | grep "Error Count:" | awk '{print $NF}' || echo "0")
        if [[ -n "$err_count" && "$err_count" -gt 0 ]] 2>/dev/null; then
            warn "SMART error log count: $err_count"
            smartctl -l error "$drive" 2>/dev/null | grep -A2 "Error [0-9]" | head -20 | while IFS= read -r l; do dim "    $l"; done
        else
            pass "SMART error log: clean (0 errors)"
        fi

        # ── Disk space ────────────────────────────────────────────────────────
        subheader "  Filesystem usage ($drive)"
        while IFS= read -r line; do
            pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
            mp=$(echo "$line" | awk '{print $6}')
            used_h=$(echo "$line" | awk '{print $3}')
            size_h=$(echo "$line" | awk '{print $2}')
            if [[ $pct -ge 90 ]] 2>/dev/null; then
                fail "  $mp: ${pct}% full (${used_h}/${size_h})"
            elif [[ $pct -ge 80 ]] 2>/dev/null; then
                warn "  $mp: ${pct}% full (${used_h}/${size_h})"
            else
                pass "  $mp: ${pct}% full (${used_h}/${size_h})"
            fi
        done < <(df -h 2>/dev/null | grep "^/dev/$(basename $drive)" || true)

    done
fi

# ══════════════════════════════════════════════════════════════════════════════
#  4. SYSTEM-WIDE HEALTH SIGNALS
# ══════════════════════════════════════════════════════════════════════════════
header "4. SYSTEM-WIDE HEALTH SIGNALS"

subheader "Recent kernel errors (last 500 dmesg lines)"
recent_errors=$(dmesg 2>/dev/null | tail -500 | grep -iE "error|failed|fault|panic|oops|killed|oom|hung|soft lockup|rcu stall" | grep -viE "acpi.*warning|bluetooth|usb.*descriptor|firmware.*optional" || true)
if [[ -n "$recent_errors" ]]; then
    warn "Recent kernel messages of interest:"
    echo "$recent_errors" | tail -15 | while IFS= read -r l; do dim "    $l"; done
else
    pass "No recent kernel errors in dmesg"
fi

subheader "OOM killer activity"
oom=$(dmesg 2>/dev/null | grep -i "oom\|out of memory\|killed process" || true)
if [[ -n "$oom" ]]; then
    fail "OOM killer has been active:"
    echo "$oom" | tail -5 | while IFS= read -r l; do dim "    $l"; done
else
    pass "OOM killer: no activity found"
fi

subheader "System uptime & load"
uptime_out=$(uptime)
info "$uptime_out"
load_15=$(uptime | grep -oP 'load average:.*' | awk -F',' '{print $3}' | xargs)
cpu_count=$(nproc)
load_int=${load_15%.*}
if [[ -n "$load_int" && -n "$cpu_count" && $load_int -gt $cpu_count ]] 2>/dev/null; then
    warn "15-min load average ($load_15) exceeds CPU count ($cpu_count)"
else
    pass "Load average within normal range"
fi

subheader "Failed systemd services"
if command -v systemctl &>/dev/null; then
    failed=$(systemctl --failed --no-legend 2>/dev/null | grep -v "^$" || true)
    if [[ -n "$failed" ]]; then
        warn "Failed systemd services:"
        echo "$failed" | while IFS= read -r l; do dim "    $l"; done
    else
        pass "No failed systemd services"
    fi
else
    info "systemctl not available"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  5. SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
header "5. SUMMARY"

echo ""
echo -e "  Total ${RED}FAILURES${RESET}: ${BOLD}$ISSUES${RESET}"
echo -e "  Total ${YELLOW}WARNINGS${RESET}: ${BOLD}$WARNINGS${RESET}"
echo ""

if [[ $ISSUES -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}⚠  HARDWARE ISSUES DETECTED — review FAIL items above immediately${RESET}"
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}△  WARNINGS present — review above, monitor closely${RESET}"
else
    echo -e "  ${GREEN}${BOLD}✔  ALL CHECKS PASSED — hardware appears healthy${RESET}"
fi

echo ""
echo -e "  ${DIM}Report generated: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "  ${DIM}To run a full SMART self-test on a drive:${RESET}"
echo -e "  ${DIM}  smartctl -t long /dev/sda   (takes 1–4 hours, non-destructive)${RESET}"
echo -e "  ${DIM}  smartctl -l selftest /dev/sda  (check results after)${RESET}"
echo ""

exit $([[ $ISSUES -gt 0 ]] && echo 1 || echo 0)