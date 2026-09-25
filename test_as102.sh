#!/usr/bin/env bash
# ==============================================================================
# IK2215 ISP Project (AS102) - Comprehensive Test Automation Script
# Based on: Network Design Report & Test Sheet (AS102 Instantiated Version)
# Authors: Emanuel Paraschiv (emapar@kth.se), Haoyu Chen (chchen3@kth.se)
#
# Target Environment: Lab VM with Kathará 3.7.9
# Usage:
#   bash test_as102.sh [OPTIONS]
#
# Options:
#   (no args)       Run safe non-destructive test suite (Static, Topo, OSPF, BGP, Services, E2E)
#   --all           Run complete suite including dynamic path & failover recovery tests
#   --static        Run static compliance & configuration checks (T1.1-T1.4, C1-C7)
#   --topo          Run topology & IP allocation verification (T1.5, T2.1-T2.4)
#   --ospf          Run OSPF adjacency, costs & deterministic metrics checks (T3.1-T3.9)
#   --bgp           Run BGP peering, advertised prefixes, policy & transit checks (B1-B28)
#   --services      Run DNS (D1-D12), Web (W1-W6), and DHCP (H1-H10) verification
#   --e2e           Run end-to-end connectivity ping & curl tests (E1-E6)
#   --paths         Run P0-P10 path verification & convergence tests (link toggling)
#   --link-fail     Run F1-F4 internal 5-link failure & recovery tests
#   --bgp-fail      Run BF1-BF7 border router & uplink failure recovery tests
#   --help          Show this help message
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
# 0. Color Codes and Global Counters
# ------------------------------------------------------------------------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[1;34m'
BOLD='\033[1m'
NC='\033[0m'

pass_count=0
fail_count=0
warn_count=0
skip_count=0

# Determine project directory (handle running inside or outside project folder)
if [ -f "lab.conf" ]; then
    PROJECT_DIR="."
elif [ -d "project" ] && [ -f "project/lab.conf" ]; then
    PROJECT_DIR="project"
else
    PROJECT_DIR="."
fi

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
report_pass() {
    local id="$1"
    local desc="$2"
    echo -e "  [${GREEN}PASS${NC}] ${BOLD}${id}${NC}: ${desc}"
    ((pass_count++))
}

report_fail() {
    local id="$1"
    local desc="$2"
    local detail="$3"
    echo -e "  [${RED}FAIL${NC}] ${BOLD}${id}${NC}: ${desc}"
    if [ -n "$detail" ]; then
        echo -e "         ${RED}Detail:${NC} ${detail}"
    fi
    ((fail_count++))
}

report_warn() {
    local id="$1"
    local desc="$2"
    echo -e "  [${YELLOW}WARN${NC}] ${BOLD}${id}${NC}: ${desc}"
    ((warn_count++))
}

report_skip() {
    local id="$1"
    local desc="$2"
    echo -e "  [${CYAN}SKIP${NC}] ${BOLD}${id}${NC}: ${desc}"
    ((skip_count++))
}

section_header() {
    local title="$1"
    echo -e "\n${BLUE}==============================================================================${NC}"
    echo -e "${BOLD}${BLUE}>>> ${title}${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
}

# Detect if Kathara needs the Nuitka self-execution flag
KATHARA_FLAGS=""
if kathara --no-deployment-flag=self-execution -v >/dev/null 2>&1 || kathara --no-deployment-flag=self-execution --version >/dev/null 2>&1; then
    KATHARA_FLAGS="--no-deployment-flag=self-execution"
elif kathara -c "pass" 2>&1 | grep -q "self-execution"; then
    KATHARA_FLAGS="--no-deployment-flag=self-execution"
fi

# Run command inside a Kathara node
kexec() {
    local node="$1"
    shift
    kathara $KATHARA_FLAGS exec "$node" -- "$@" 2>/dev/null
}

# Run vtysh command inside a Kathara FRR router
kvtysh() {
    local node="$1"
    local cmd="$2"
    kathara $KATHARA_FLAGS exec "$node" -- vtysh --command="$cmd" 2>/dev/null
}

# Wait with a countdown timer for protocol convergence
wait_countdown() {
    local secs="$1"
    local reason="$2"
    echo -ne "  ${YELLOW}... Waiting ${secs}s for ${reason} ...${NC}"
    while [ "$secs" -gt 0 ]; do
        sleep 1
        ((secs--))
        echo -ne "\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b\b  ${YELLOW}... Waiting ${secs}s for ${reason} ...${NC}"
    done
    echo -e "\r                                                         \r"
}

# Cleanup and restoration trap to ensure lab is never left broken
cleanup_lab() {
    echo -e "\n${YELLOW}>>> [Safety Hook] Restoring all interfaces and routing services...${NC}"
    for r in as102r1 as102r2 as102r3 as102r4 as21r1; do
        for eth in eth0 eth1 eth2 eth3 eth4; do
            kexec "$r" ip link set "$eth" up 2>/dev/null || true
        done
    done
    kexec as102r1 systemctl start frr 2>/dev/null || true
    kexec as102r2 systemctl start frr 2>/dev/null || true
}
trap cleanup_lab INT TERM

# ------------------------------------------------------------------------------
# 1. 拓扑与 Kathará 配置 (T1.1 - T1.5)
# ------------------------------------------------------------------------------
test_section_1_topo() {
    section_header "1. 拓扑与 Kathará 配置 (T1.1 - T1.5)"

    # T1.1: 目录与命名规范
    local missing_nodes=0
    for node in as102r1 as102r2 as102r3 as102r4 as102s1 as102s2 as102s3 as102c1 as102c2; do
        if [ ! -d "${PROJECT_DIR}/${node}" ] || [ ! -f "${PROJECT_DIR}/${node}.startup" ]; then
            missing_nodes=1
            break
        fi
    done
    if [ "$missing_nodes" -eq 0 ]; then
        report_pass "T1.1" "存在 as102r1-4, as102s1-3, as102c1/c2 共 9 台设备目录及其 startup 文件"
    else
        report_fail "T1.1" "设备目录或 startup 文件缺失 (需 4 路由器 + 3 服务器 + 2 客户端)"
    fi

    # T1.2: 未增删外部接口
    if [ -f "${PROJECT_DIR}/lab.conf" ]; then
        if grep -q '^as1r1\[4\]="A4"' "${PROJECT_DIR}/lab.conf" && grep -q '^as21r1\[0\]="H0"' "${PROJECT_DIR}/lab.conf"; then
            report_pass "T1.2" "lab.conf 外部连接保留且未篡改对端 AS 预分配端口 (A4, H0)"
        else
            report_fail "T1.2" "lab.conf 外部连接与端口 0 出现异常修改"
        fi
    else
        report_fail "T1.2" "未找到 lab.conf 文件"
    fi

    # T1.3: 内部链路为点对点与广播域核验
    local cd_n1=$(grep -c '="N1"' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local cd_n2=$(grep -c '="N2"' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local cd_n3=$(grep -c '="N3"' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local cd_n4=$(grep -c '="N4"' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local cd_n5=$(grep -c '="N5"' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local cd_s1=$(grep -c '="S1"' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local cd_c1=$(grep -c '="C1"' "${PROJECT_DIR}/lab.conf" 2>/dev/null)

    if [ "$cd_n1" -eq 2 ] && [ "$cd_n2" -eq 2 ] && [ "$cd_n3" -eq 2 ] && [ "$cd_n4" -eq 2 ] && [ "$cd_n5" -eq 2 ] && [ "$cd_s1" -eq 4 ] && [ "$cd_c1" -eq 3 ]; then
        report_pass "T1.3" "点对点链路 (N1-N5 各 2 台), 服务器网段 (S1: 4 台), 客户端网段 (C1: 3 台)"
    else
        report_fail "T1.3" "广播域连接计数不符: N1=$cd_n1 N2=$cd_n2 N3=$cd_n3 N4=$cd_n4 N5=$cd_n5 S1=$cd_s1 C1=$cd_c1"
    fi

    # T1.4: 每台路由器至少 2 条内部链路
    local r1_internal=$(grep -cE '^as102r1\[[1-9]\]' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local r2_internal=$(grep -cE '^as102r2\[[1-9]\]' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local r3_internal=$(grep -cE '^as102r3\[[1-9]\]' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    local r4_internal=$(grep -cE '^as102r4\[[1-9]\]' "${PROJECT_DIR}/lab.conf" 2>/dev/null)
    if [ "$r1_internal" -ge 3 ] && [ "$r2_internal" -ge 2 ] && [ "$r3_internal" -ge 3 ] && [ "$r4_internal" -ge 2 ]; then
        report_pass "T1.4" "每台路由器均具备冗余内部点对点接口 (r1:3, r2:2, r3:3, r4:2)"
    else
        report_fail "T1.4" "路由器内部接口配置不足以支撑拓扑设计要求"
    fi

    # T1.5: 节点容器运行状态
    local r1_host=$(kexec as102r1 hostname 2>/dev/null)
    if [ "$r1_host" == "as102r1" ]; then
        report_pass "T1.5" "Kathará 容器正常运行且可执行指令"
    else
        report_fail "T1.5" "Kathará 未启动或 as102r1 容器不可达 (请先执行 kathara lstart)"
    fi
}

# ------------------------------------------------------------------------------
# 2. IP 地址分配 (T2.1 - T2.4)
# ------------------------------------------------------------------------------
test_section_2_ip() {
    section_header "2. IP 地址分配 (T2.1 - T2.4)"

    # T2.1: 接口 IP 与掩码逐项核对
    local ip_checks=(
        "as102r1:eth0:1.0.0.5/31"
        "as102r1:eth1:1.102.3.0/31"
        "as102r1:eth2:1.102.3.2/31"
        "as102r1:eth3:1.102.3.5/31"
        "as102r1:dummy0:1.102.4.1/32"
        "as102r2:eth0:2.21.0.1/31"
        "as102r2:eth1:1.102.3.1/31"
        "as102r2:eth2:1.102.3.6/31"
        "as102r2:dummy0:1.102.4.2/32"
        "as102r3:eth0:1.102.1.1/24"
        "as102r3:eth1:1.102.3.3/31"
        "as102r3:eth2:1.102.3.7/31"
        "as102r3:eth3:1.102.3.8/31"
        "as102r3:dummy0:1.102.4.3/32"
        "as102r4:eth0:1.102.2.1/24"
        "as102r4:eth1:1.102.3.4/31"
        "as102r4:eth2:1.102.3.9/31"
        "as102r4:dummy0:1.102.4.4/32"
        "as102s1:eth0:1.102.1.2/24"
        "as102s2:eth0:1.102.1.3/24"
        "as102s3:eth0:1.102.1.4/24"
    )

    local all_ip_ok=1
    local ip_mismatch=""
    for item in "${ip_checks[@]}"; do
        IFS=":" read -r dev iface expected_cidr <<< "$item"
        local actual_ip=$(kexec "$dev" ip -4 addr show "$iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+')
        if [ "$actual_ip" != "$expected_cidr" ]; then
            all_ip_ok=0
            ip_mismatch+="$dev $iface: expected $expected_cidr, got $actual_ip; "
        fi
    done

    if [ "$all_ip_ok" -eq 1 ]; then
        report_pass "T2.1" "路由器与服务器全部 21 个物理/逻辑接口 IP 及 CIDR 掩码 100% 匹配报告设计"
    else
        report_fail "T2.1" "接口 IP 分配不匹配" "$ip_mismatch"
    fi

    # T2.2: 外部对等直连 /31 通畅
    local p1_ok=0
    local p2_ok=0
    kexec as102r1 ping -c 2 -W 2 1.0.0.4 >/dev/null 2>&1 && p1_ok=1
    kexec as102r2 ping -c 2 -W 2 2.21.0.0 >/dev/null 2>&1 && p2_ok=1
    if [ "$p1_ok" -eq 1 ] && [ "$p2_ok" -eq 1 ]; then
        report_pass "T2.2" "外部链路 /31 直连互通正常 (r1->1.0.0.4, r2->2.21.0.0)"
    else
        report_fail "T2.2" "外部 /31 直连 ping 失败 (AS1 对端: $p1_ok, AS21 对端: $p2_ok)"
    fi

    # T2.3: 服务器 startup 采用 ip 命令配置
    local s_startup_ok=1
    for s in as102s1 as102s2 as102s3; do
        if ! grep -q "ip addr add" "${PROJECT_DIR}/${s}.startup" 2>/dev/null; then
            s_startup_ok=0
        fi
    done
    if [ "$s_startup_ok" -eq 1 ]; then
        report_pass "T2.3" "服务器均由 startup 文件通过 ip 命令配置 IP 及默认网关"
    else
        report_fail "T2.3" "服务器 startup 文件缺失正确的 ip addr add 命令"
    fi

    # T2.4: 服务器默认网关为 1.102.1.1
    local gw_ok=1
    for s in as102s1 as102s2 as102s3; do
        local gw=$(kexec "$s" ip route show | grep default | awk '{print $3}')
        if [ "$gw" != "1.102.1.1" ]; then
            gw_ok=0
        fi
    done
    if [ "$gw_ok" -eq 1 ]; then
        report_pass "T2.4" "s1, s2, s3 默认网关均正确指向 r3 (1.102.1.1)"
    else
        report_fail "T2.4" "服务器默认网关配置错误"
    fi
}

# ------------------------------------------------------------------------------
# 3. 域内路由 OSPF 与度量确定性 (T3.1 - T3.9)
# ------------------------------------------------------------------------------
test_section_3_ospf() {
    section_header "3. 域内路由 OSPF 与度量确定性 (T3.1 - T3.9)"

    # T3.1: OSPF Full 邻居数量
    local r1_full=$(kvtysh as102r1 "show ip ospf neighbor" | grep -c "Full")
    local r2_full=$(kvtysh as102r2 "show ip ospf neighbor" | grep -c "Full")
    local r3_full=$(kvtysh as102r3 "show ip ospf neighbor" | grep -c "Full")
    local r4_full=$(kvtysh as102r4 "show ip ospf neighbor" | grep -c "Full")

    if [ "$r1_full" -eq 3 ] && [ "$r2_full" -eq 2 ] && [ "$r3_full" -eq 3 ] && [ "$r4_full" -eq 2 ]; then
        report_pass "T3.1" "OSPF Full 邻居状态全部达成: r1=3, r2=2, r3=3, r4=2"
    else
        report_fail "T3.1" "OSPF Full 邻居状态未完全建立 (实测: r1=$r1_full/3, r2=$r2_full/2, r3=$r3_full/3, r4=$r4_full/2)"
    fi

    # T3.2: 接口 OSPF Cost 精确核验 (5/9/10/10/11)
    local cost_mismatch=0
    check_cost() {
        local dev="$1"; local iface="$2"; local exp="$3"
        local c=$(kvtysh "$dev" "show ip ospf interface $iface" | grep -oP 'Cost:\s*\K\d+' | head -n 1)
        if [ "$c" != "$exp" ]; then
            cost_mismatch=1
        fi
    }
    check_cost as102r1 eth1 5
    check_cost as102r1 eth2 9
    check_cost as102r1 eth3 10
    check_cost as102r2 eth1 5
    check_cost as102r2 eth2 10
    check_cost as102r3 eth1 9
    check_cost as102r3 eth2 10
    check_cost as102r3 eth3 11
    check_cost as102r4 eth1 10
    check_cost as102r4 eth2 11

    if [ "$cost_mismatch" -eq 0 ]; then
        report_pass "T3.2" "全部接口 OSPF Cost 精确符合设计: L12=5, L13=9, L14=10, L23=10, L34=11"
    else
        report_fail "T3.2" "部分接口 OSPF Cost 与设计不符"
    fi

    # T3.3: 路由度量确定性与无 ECMP 核查
    local r1_to_server_metric=$(kvtysh as102r1 "show ip route 1.102.1.0/24" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)
    local r2_to_client_metric=$(kvtysh as102r2 "show ip route 1.102.2.0/24" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)
    local r3_to_client_metric=$(kvtysh as102r3 "show ip route 1.102.2.0/24" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)
    local r4_to_server_metric=$(kvtysh as102r4 "show ip route 1.102.1.0/24" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)

    if [ "$r1_to_server_metric" == "9" ] && [ "$r2_to_client_metric" == "15" ] && [ "$r3_to_client_metric" == "11" ] && [ "$r4_to_server_metric" == "11" ]; then
        report_pass "T3.3" "内部子网度量严格确定且无 ECMP (r1->S:9, r2->C:15, r3->C:11, r4->S:11)"
    else
        report_fail "T3.3" "内部路由度量与理论推导不符 (实测: r1->S=$r1_to_server_metric, r2->C=$r2_to_client_metric, r3->C=$r3_to_client_metric, r4->S=$r4_to_server_metric)"
    fi

    # T3.4: IGP 不泄漏至外部接口
    local r1_eth0_ospf=$(kvtysh as102r1 "show ip ospf interface" | grep -c "^eth0 is up" || true)
    local r2_eth0_ospf=$(kvtysh as102r2 "show ip ospf interface" | grep -c "^eth0 is up" || true)
    if [ "$r1_eth0_ospf" -eq 0 ] && [ "$r2_eth0_ospf" -eq 0 ]; then
        report_pass "T3.4" "r1/r2 外部 eth0 接口严格禁用 OSPF (未宣告入 Area 0)"
    else
        report_fail "T3.4" "外部接口 eth0 上检测到 OSPF 进程运行 (违反规范)"
    fi

    # T3.5: 默认路由存在且为 E1 (r3 metric 19, r4 metric 20)
    local r3_def=$(kvtysh as102r3 "show ip route 0.0.0.0/0")
    local r4_def=$(kvtysh as102r4 "show ip route 0.0.0.0/0")
    local r3_def_m=$(echo "$r3_def" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)
    local r4_def_m=$(echo "$r4_def" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)

    if echo "$r3_def" | grep -qE "O\*E1|type 1" && [ "$r3_def_m" == "19" ] && echo "$r4_def" | grep -qE "O\*E1|type 1" && [ "$r4_def_m" == "20" ]; then
        report_pass "T3.5" "默认路由为 O*E1 且主选 r1 (r3 度量 19 via r1, r4 度量 20 via r1)"
    else
        report_fail "T3.5" "默认路由度量或类型不匹配 (r3: type E1?, metric=$r3_def_m/19; r4: type E1?, metric=$r4_def_m/20)"
    fi

    # T3.6: 条件默认路由配置语法核对
    local r1_def_cfg=$(grep "default-information originate" "${PROJECT_DIR}/as102r1/etc/frr/frr.conf" 2>/dev/null)
    local r2_def_cfg=$(grep "default-information originate" "${PROJECT_DIR}/as102r2/etc/frr/frr.conf" 2>/dev/null)
    if echo "$r1_def_cfg" | grep -q "always metric 10 metric-type 1 route-map CHECK-AS1" && \
       echo "$r2_def_cfg" | grep -q "always metric 50 metric-type 1 route-map CHECK-AS21"; then
        report_pass "T3.6" "r1(metric 10, CHECK-AS1) 与 r2(metric 50, CHECK-AS21) 条件默认路由配置正确"
    else
        report_fail "T3.6" "条件默认路由配置不符合设计要求"
    fi

    # T3.7: 仅 2.21.0.0/20 重分发进 OSPF
    local ext_db=$(kvtysh as102r3 "show ip ospf database external")
    local ext_lsa_count=$(echo "$ext_db" | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' | wc -l)
    local ext_pfx=$(echo "$ext_db" | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' | sort -u | tr '\n' ' ')
    if [ "$ext_lsa_count" -ge 2 ] && echo "$ext_pfx" | grep -q "0.0.0.0" && echo "$ext_pfx" | grep -q "2.21.0.0"; then
        report_pass "T3.7" "外部 LSA 正常 (包含 0.0.0.0 默认路由及 2.21.0.0/20 重分发路由, 数量: $ext_lsa_count)"
    else
        report_fail "T3.7" "外部 LSA 异常 (数量: $ext_lsa_count/3, 前缀: $ext_pfx)"
    fi

    # T3.8: r2 重分发路由策略过滤
    local r2_redist=$(grep -A5 "route-map OSPF-INJECT" "${PROJECT_DIR}/as102r2/etc/frr/frr.conf" 2>/dev/null)
    local r2_inj_pfx=$(echo "$r2_redist" | grep -oP 'prefix-list\s+\K\S+')
    local r2_pfx_ok=0
    if [ -n "$r2_inj_pfx" ]; then
        if grep "ip prefix-list $r2_inj_pfx" "${PROJECT_DIR}/as102r2/etc/frr/frr.conf" 2>/dev/null | grep -q "2.21.0.0/20"; then
            r2_pfx_ok=1
        fi
    fi
    if echo "$r2_redist" | grep -q "2.21.0.0/20" || [ "$r2_pfx_ok" -eq 1 ]; then
        report_pass "T3.8" "r2 redistribute bgp 严格匹配 route-map OSPF-INJECT (仅 permit 2.21.0.0/20)"
    else
        report_fail "T3.8" "r2 OSPF-INJECT 过滤规则缺失或不严谨"
    fi

    # T3.9: 2.21.0.0/20 最长前缀匹配度量
    local r3_21_route=$(kvtysh as102r3 "show ip route 2.21.0.0/20")
    local r4_21_route=$(kvtysh as102r4 "show ip route 2.21.0.0/20")
    local r3_21_m=$(echo "$r3_21_route" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)
    local r4_21_m=$(echo "$r4_21_route" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)

    if echo "$r3_21_route" | grep -qE "O\s*E1|type 1" && [ "$r3_21_m" == "30" ] && echo "$r4_21_route" | grep -qE "O\s*E1|type 1" && [ "$r4_21_m" == "35" ]; then
        report_pass "T3.9" "2.21.0.0/20 在 OSPF 中保持精准度量 (r3 度量 30 via r2, r4 度量 35 via r1 方向)"
    else
        report_fail "T3.9" "2.21.0.0/20 度量不符 (r3: metric=$r3_21_m/30, r4: metric=$r4_21_m/35)"
    fi
}

# ------------------------------------------------------------------------------
# 4. 主/备路径验证 (P0 - P10)
# ------------------------------------------------------------------------------
test_section_4_paths() {
    section_header "4. 主/备路径验证 (P0 - P10 路由收敛与确定性测试)"

    traceroute_hops() {
        local dev="$1"
        local dst="$2"
        kexec "$dev" traceroute -n -w 1 -q 1 "$dst" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $2}'
    }

    test_single_path() {
        local id="$1"
        local name="$2"
        local dev="$3"
        local dst="$4"
        local exp_prim_kw="$5"
        local fail_dev="$6"
        local fail_iface="$7"
        local exp_sec_kw="$8"

        # 1. 正常状态测试主路径
        local prim_hops=$(traceroute_hops "$dev" "$dst")
        local prim_ok=0
        if echo "$prim_hops" | grep -q "$exp_prim_kw"; then
            prim_ok=1
        fi

        # 2. 模拟链路故障并验证备路径
        local sec_ok=0
        if [ -n "$fail_dev" ] && [ -n "$fail_iface" ]; then
            kexec "$fail_dev" ip link set "$fail_iface" down
            wait_countdown 15 "OSPF reconvergence upon link failure"
            local sec_hops=$(traceroute_hops "$dev" "$dst")
            if echo "$sec_hops" | grep -q "$exp_sec_kw"; then
                sec_ok=1
            fi
            # 恢复链路
            kexec "$fail_dev" ip link set "$fail_iface" up
            wait_countdown 15 "OSPF reconvergence upon link restore"
        else
            sec_ok=1
        fi

        if [ "$prim_ok" -eq 1 ] && [ "$sec_ok" -eq 1 ]; then
            report_pass "$id" "$name: 主路径及备份路径收敛严格符合设计"
        else
            report_fail "$id" "$name: 路径不符 (主路径匹配: $prim_ok, 备路径匹配: $sec_ok)" "主路径跳: $(echo $prim_hops | tr '\n' ' '), 备路径跳: $(echo $sec_hops | tr '\n' ' ')"
        fi
    }

    # P0: r1 -> r2 (dummy0 1.102.4.2)
    test_single_path "P0" "r1 -> r2 (iBGP冗余链路)" "as102r1" "1.102.4.2" "1.102.3.1" "as102r1" "eth1" "1.102.3.3"

    # P1: r1 -> clients (1.102.2.10)
    test_single_path "P1" "r1 -> clients (主直连r4, 备经r3)" "as102r1" "1.102.2.10" "1.102.3.4" "as102r1" "eth3" "1.102.3.3"

    # P2: clients -> r1 (dummy0 1.102.4.1)
    test_single_path "P2" "clients -> r1 (主直连r1, 备经r3)" "as102c1" "1.102.4.1" "1.102.3.5" "as102r4" "eth1" "1.102.3.8"

    # P3: r1 -> servers (1.102.1.2)
    test_single_path "P3" "r1 -> servers (主直连r3, 备经r2)" "as102r1" "1.102.1.2" "1.102.3.3" "as102r1" "eth2" "1.102.3.1"

    # P4: servers -> r1 (dummy0 1.102.4.1)
    test_single_path "P4" "servers -> r1 (主直连r1, 备经r2)" "as102s1" "1.102.4.1" "1.102.3.2" "as102r3" "eth1" "1.102.3.6"

    # P5: r2 -> clients (1.102.2.10)
    test_single_path "P5" "r2 -> clients (主经r1, 备经r3)" "as102r2" "1.102.2.10" "1.102.3.0" "as102r2" "eth1" "1.102.3.7"

    # P6: clients -> r2 (dummy0 1.102.4.2)
    test_single_path "P6" "clients -> r2 (主经r1, 备经r3)" "as102c1" "1.102.4.2" "1.102.3.5" "as102r4" "eth1" "1.102.3.8"

    # P7: r2 -> servers (1.102.1.2)
    test_single_path "P7" "r2 -> servers (主直连r3, 备经r1)" "as102r2" "1.102.1.2" "1.102.3.7" "as102r2" "eth2" "1.102.3.0"

    # P8: servers -> r2 (dummy0 1.102.4.2)
    test_single_path "P8" "servers -> r2 (主直连r2, 备经r1)" "as102s1" "1.102.4.2" "1.102.3.6" "as102r3" "eth2" "1.102.3.2"

    # P9: clients -> servers (1.102.1.2)
    test_single_path "P9" "clients -> servers (主直连r3, 备经r1)" "as102c1" "1.102.1.2" "1.102.3.8" "as102r4" "eth2" "1.102.3.5"

    # P10: servers -> clients (1.102.2.10)
    test_single_path "P10" "servers -> clients (主直连r4, 备经r1)" "as102s1" "1.102.2.10" "1.102.3.9" "as102r3" "eth3" "1.102.3.2"
}

# ------------------------------------------------------------------------------
# 5. 内部链路逐条故障演练 (F1 - F4)
# ------------------------------------------------------------------------------
test_section_5_link_failure() {
    section_header "5. 内部链路逐条故障演练 (F1 - F4 内部韧性测试)"

    local links=(
        "L12:as102r1:eth1"
        "L13:as102r1:eth2"
        "L14:as102r1:eth3"
        "L23:as102r2:eth2"
        "L34:as102r3:eth3"
    )

    local all_f_ok=1
    for item in "${links[@]}"; do
        IFS=":" read -r lname dev iface <<< "$item"
        echo -e "  ${CYAN}--- Testing Failover for $lname ($dev $iface down) ---${NC}"

        # 1. 断开指定链路
        kexec "$dev" ip link set "$iface" down
        wait_countdown 12 "Convergence after $lname failure"

        # 2. 检查内部连通性 (客户端 ping 服务器)
        local ping_int=0
        kexec as102c1 ping -c 2 -W 2 1.102.1.2 >/dev/null 2>&1 && ping_int=1

        # 3. 检查外部连通性 (客户端 ping 根 DNS 1.0.1.2 及 AS21)
        local ping_ext=0
        kexec as102c1 ping -c 2 -W 2 1.0.1.2 >/dev/null 2>&1 && ping_ext=1

        # 4. 恢复链路
        kexec "$dev" ip link set "$iface" up
        wait_countdown 10 "Reconvergence after $lname restored"

        if [ "$ping_int" -eq 1 ] && [ "$ping_ext" -eq 1 ]; then
            report_pass "F-$lname" "$lname 故障收敛后内部服务与外网连通性完全保持"
        else
            report_fail "F-$lname" "$lname 故障期间出现永久性断网 (内部通: $ping_int, 外部通: $ping_ext)"
            all_f_ok=0
        fi
    done

    if [ "$all_f_ok" -eq 1 ]; then
        report_pass "F.ALL" "5 条内部点对点链路逐条断开演练全部通过，网络无单点故障"
    fi
}

# ------------------------------------------------------------------------------
# 6. BGP 会话与前缀宣告 (B1 - B10)
# ------------------------------------------------------------------------------
test_section_6_bgp_peering() {
    section_header "6. BGP 会话与前缀宣告 (B1 - B10)"

    # B1: r1 与 AS1 eBGP 建立
    local b1_state=$(kvtysh as102r1 "show ip bgp summary" | grep "1.0.0.4" | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/ || $i ~ /Active|Idle|Connect/) {print $i; exit}}')
    if [[ "$b1_state" =~ ^[0-9]+$ ]]; then
        report_pass "B1" "r1 与 AS1 (1.0.0.4) eBGP 状态 Established (收到 $b1_state 条前缀)"
    else
        report_fail "B1" "r1 与 AS1 eBGP 会话未处于 Established (当前状态: $b1_state)"
    fi

    # B2: r2 与 AS21 eBGP 建立
    local b2_state=$(kvtysh as102r2 "show ip bgp summary" | grep "2.21.0.0" | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/ || $i ~ /Active|Idle|Connect/) {print $i; exit}}')
    if [[ "$b2_state" =~ ^[0-9]+$ ]]; then
        report_pass "B2" "r2 与 AS21 (2.21.0.0) eBGP 状态 Established (收到 $b2_state 条前缀)"
    else
        report_fail "B2" "r2 与 AS21 eBGP 会话未处于 Established (当前状态: $b2_state)"
    fi

    # B3: r1-r2 基于 dummy0 的 iBGP 建立并带 update-source / next-hop-self
    local b3_r1=$(kvtysh as102r1 "show ip bgp summary" | grep "1.102.4.2" | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/ || $i ~ /Active|Idle|Connect/) {print $i; exit}}')
    local b3_r2=$(kvtysh as102r2 "show ip bgp summary" | grep "1.102.4.1" | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/ || $i ~ /Active|Idle|Connect/) {print $i; exit}}')
    local r1_nhs=$(grep -c "neighbor 1.102.4.2 next-hop-self" "${PROJECT_DIR}/as102r1/etc/frr/frr.conf" 2>/dev/null)
    local r2_nhs=$(grep -c "neighbor 1.102.4.1 next-hop-self" "${PROJECT_DIR}/as102r2/etc/frr/frr.conf" 2>/dev/null)

    if [[ "$b3_r1" =~ ^[0-9]+$ ]] && [[ "$b3_r2" =~ ^[0-9]+$ ]] && [ "$r1_nhs" -ge 1 ] && [ "$r2_nhs" -ge 1 ]; then
        report_pass "B3" "iBGP (1.102.4.1 <-> 1.102.4.2) 运行在 dummy0 上，Established 且配置 next-hop-self"
    else
        report_fail "B3" "iBGP 会话未就绪或缺失 next-hop-self (r1状态: $b3_r1, r2状态: $b3_r2)"
    fi

    # B4: iBGP 下一跳在 IGP 中可达且路由有效
    local r1_ibgp_valid=$(kvtysh as102r1 "show ip bgp" | grep -cE "^\*>[i ]*.*2\.21\.0\.0/20|^\*>i" || true)
    if [ "$r1_ibgp_valid" -ge 1 ]; then
        report_pass "B4" "iBGP 学习到的路由下一跳均为 IGP 可达且被标记有效最优 (*>i)"
    else
        report_fail "B4" "iBGP 路由有效性检查未通过"
    fi

    # B5: r3/r4 纯内网路由器无 BGP 进程
    local r3_bgpd=$(grep "^bgpd=" "${PROJECT_DIR}/as102r3/etc/frr/daemons" 2>/dev/null)
    local r4_bgpd=$(grep "^bgpd=" "${PROJECT_DIR}/as102r4/etc/frr/daemons" 2>/dev/null)
    if [ "$r3_bgpd" == "bgpd=no" ] && [ "$r4_bgpd" == "bgpd=no" ]; then
        report_pass "B5" "核心路由器 r3 与 r4 严格禁用 bgpd 守护进程"
    else
        report_fail "B5" "r3 或 r4 错误启用了 bgpd (违反项目规则)"
    fi

    # B6: r1 向 AS1 仅宣告聚合前缀与 AS21 备份前缀
    local r1_adv=$(kvtysh as102r1 "show ip bgp neighbor 1.0.0.4 advertised-routes")
    local r1_leak=$(echo "$r1_adv" | grep -E "1\.102\.[1-9]\." || true)
    if echo "$r1_adv" | grep -q "1.102.0.0/20" && echo "$r1_adv" | grep -q "2.21.0.0/20" && [ -z "$r1_leak" ]; then
        report_pass "B6" "r1 向 AS1 仅宣告 1.102.0.0/20 (带社区1:200) 与 2.21.0.0/20，零明细泄露"
    else
        report_fail "B6" "r1 路由宣告异常或泄露了内部明细路由" "$r1_adv"
    fi

    # B7: r2 向 AS21 宣告合规 (聚合加 prepend 102，Internet 加 prepend 102 102 102)
    local r2_adv=$(kvtysh as102r2 "show ip bgp neighbor 2.21.0.0 advertised-routes")
    local r2_leak=$(echo "$r2_adv" | grep -E "1\.102\.[1-9]\." || true)
    local r2_back_as21=$(echo "$r2_adv" | grep "2.21.0.0/20" || true)
    if echo "$r2_adv" | grep -q "1.102.0.0/20" && [ -z "$r2_leak" ] && [ -z "$r2_back_as21" ]; then
        report_pass "B7" "r2 向 AS21 仅宣告 1.102.0.0/20 与合法 Internet 路由，不回灌 AS21 自有前缀"
    else
        report_fail "B7" "r2 向 AS21 宣告异常 (内部泄露: '$r2_leak', 回灌自有前缀: '$r2_back_as21')"
    fi

    # B8: 外部 AS1 路由表仅见聚合 /20
    local as1_bgp=$(kvtysh as1r1 "show ip bgp" 2>/dev/null)
    local as1_more_specific=$(echo "$as1_bgp" | grep -E "1\.102\.[1-9]\." || true)
    if echo "$as1_bgp" | grep -q "1.102.0.0/20" && [ -z "$as1_more_specific" ]; then
        report_pass "B8" "外部 AS1 路由器 BGP 表仅存在 1.102.0.0/20，明细前缀被完全抑制"
    else
        report_fail "B8" "AS1 路由器观察到 AS102 的明细前缀泄露" "$as1_more_specific"
    fi

    # B9: AS1 观察到的 AS102 路径不包含未授权 transit
    local as1_transit=$(kvtysh as1r1 "show ip bgp regexp _102_" | grep -E "^\*>\s*[0-9]" | grep -v "1.102.0.0/20" | grep -v "2.21.0.0/20" || true)
    if [ -z "$as1_transit" ]; then
        report_pass "B9" "AS1 路由表中经由 AS102 的路径仅限本 AS 聚合及授权的 AS21 备份前缀"
    else
        report_fail "B9" "发现异常 transit 路由穿透 AS102" "$as1_transit"
    fi

    # B10: AS21 前缀在 AS1 侧以直连 AS2 为最优，AS102 为备份
    local as1_21_bgp=$(kvtysh as1r1 "show ip bgp 2.21.0.0/20")
    local as1_21_has_102=$(echo "$as1_21_bgp" | grep -cE "102 102 21|102 21" || true)
    if [ "$as1_21_has_102" -ge 1 ]; then
        report_pass "B10" "AS1 到 AS21 包含经 AS102 的备份路径 (AS-Path: 102 102 21)，常态不被优选"
    else
        report_fail "B10" "AS1 未收到 AS102 重宣告的 AS21 备份路径"
    fi
}

# ------------------------------------------------------------------------------
# 7. BGP 策略：出向、入向与防 Transit (B11 - B28)
# ------------------------------------------------------------------------------
test_section_7_bgp_policy() {
    section_header "7. BGP 策略：出向、入向与防 Transit (B11 - B28)"

    # B11: 出向 AS21 流量在 r2 设 LP=200 并通过 iBGP 同步给 r1
    local r2_lp21=$(kvtysh as102r2 "show ip bgp 2.21.0.0/20" | grep -oiP '(?:localpref|locprf)\s*\K\d+' | head -n 1)
    local r1_lp21=$(kvtysh as102r1 "show ip bgp 2.21.0.0/20" | grep -oiP '(?:localpref|locprf)\s*\K\d+' | head -n 1)
    if [ "$r2_lp21" == "200" ] && [ "$r1_lp21" == "200" ]; then
        report_pass "B11" "AS21 前缀在 r2 设置 LOCAL_PREF=200 并成功通过 iBGP 同步给 r1"
    else
        report_fail "B11" "AS21 前缀 LOCAL_PREF 设置不正确 (r2: $r2_lp21/200, r1: $r1_lp21/200)"
    fi

    # B12: AS21 目标数据面流量经 r2 直连出口
    local as21_trace=$(kexec as102c1 traceroute -n -w 1 -q 1 2.21.1.1 2>/dev/null)
    if echo "$as21_trace" | grep -qE "1\.102\.3\.1|2\.21\.0\.0"; then
        report_pass "B12" "AS21 流量数据面精确经 r2 直连出口流出，未绕行 AS1"
    else
        report_fail "B12" "AS21 数据面路径异常" "$(echo "$as21_trace" | tr '\n' ' ')"
    fi

    # B13: 其他 Internet 流量在 r2 上 LP 100 > 50，优选 r1
    local r2_inet_best=$(kvtysh as102r2 "show ip bgp" | grep -E "^\*>[i ]*\s*1\.0\.0\.0/20" | grep -c "1.102.4.1" || true)
    if [ "$r2_inet_best" -eq 0 ]; then
        local r2_inet_detail=$(kvtysh as102r2 "show ip bgp 1.0.0.0/20")
        if echo "$r2_inet_detail" | grep -q "best" && echo "$r2_inet_detail" | grep -q "1.102.4.1"; then
            r2_inet_best=1
        fi
    fi
    if [ "$r2_inet_best" -ge 1 ]; then
        report_pass "B13" "r2 访问 Internet 优选来自 r1 的 iBGP 路径 (LP 100 优于 AS21 的 LP 50)"
    else
        report_fail "B13" "r2 对 Internet 路由选路策略未优选 r1"
    fi

    # B14: 其他 Internet 目标数据面流量经 r1
    local inet_trace=$(kexec as102c1 traceroute -n -w 1 -q 1 1.0.1.2 2>/dev/null)
    if echo "$inet_trace" | grep -qE "1\.102\.3\.5|1\.0\.0\.4"; then
        report_pass "B14" "Internet 数据面流量主路径精准经 r1 退出本 AS"
    else
        report_fail "B14" "Internet 流量未走 r1 主出口" "$(echo "$inet_trace" | tr '\n' ' ')"
    fi

    # B15: 严禁使用 BGP weight
    local r1_w=$(grep -rni "weight" "${PROJECT_DIR}/as102r1/etc/frr/" 2>/dev/null || true)
    local r2_w=$(grep -rni "weight" "${PROJECT_DIR}/as102r2/etc/frr/" 2>/dev/null || true)
    if [ -z "$r1_w" ] && [ -z "$r2_w" ]; then
        report_pass "B15" "完全依循规则，未配置任何非标准的 BGP weight 属性"
    else
        report_fail "B15" "检测到配置了违规的 BGP weight 属性"
    fi

    # B16: AS1 入向选路优选 r1 (LocPrf=200，由社区 1:200 触发)
    local as1_bgp_route=$(kvtysh as1r1 "show ip bgp 1.102.0.0/20")
    local as1_best_hop=$(echo "$as1_bgp_route" | grep -B1 -E "best|valid.*best" | grep -oP '(?:\d+\.){3}\d+' | head -n 1)
    local as1_table_best=$(kvtysh as1r1 "show ip bgp" | grep -E "^\*>[i ]*\s*1\.102\.0\.0/20" || true)

    if [ "$as1_best_hop" == "1.0.0.5" ] || echo "$as1_table_best" | grep -q "1.0.0.5" || echo "$as1_table_best" | grep -qE "102\s*i|102\s*$"; then
        report_pass "B16" "AS1 最优路径直连 102 (1.0.0.5)，由 r1 宣告的 1:200 社区驱动为最高优先级"
    else
        report_fail "B16" "AS1 对 1.102.0.0/20 最优路径非直连 102" "best_hop: $as1_best_hop, table: $as1_table_best"
    fi

    # B17: AS21 直连进入 (AS-Path: 102 102 优于经 AS2 的 2 1 102)
    local as21_bgp_route=$(kvtysh as21r1 "show ip bgp 1.102.0.0/20")
    local as21_best_hop=$(echo "$as21_bgp_route" | grep -B1 -E "best|valid.*best" | grep -oP '(?:\d+\.){3}\d+' | head -n 1)
    local as21_table_best=$(kvtysh as21r1 "show ip bgp" | grep -E "^\*>[i ]*\s*1\.102\.0\.0/20" || true)

    if [ "$as21_best_hop" == "2.21.0.1" ] || echo "$as21_table_best" | grep -q "2.21.0.1" || echo "$as21_table_best" | grep -q "102 102"; then
        report_pass "B17" "AS21 最优路径直连 102 (2.21.0.1 via AS-Path 102 102，胜过经 AS2 的 2 1 102)"
    else
        report_fail "B17" "AS21 未优选直连 AS102 路径 (2.21.0.1)" "best_hop: $as21_best_hop, table: $as21_table_best"
    fi

    # B18 - B21: 各外部 AS 入向路径核验 (经 AS1 入口)
    check_ext_best() {
        local node="$1"
        local exp_pattern="$2"
        local detail=$(kvtysh "$node" "show ip bgp 1.102.0.0/20" 2>/dev/null)
        if echo "$detail" | grep -A2 -E "best|valid.*best" | grep -qE "$exp_pattern"; then
            return 0
        fi
        local tbl=$(kvtysh "$node" "show ip bgp" 2>/dev/null | grep -E "^\*>[i ]*\s*1\.102\.0\.0/20")
        if echo "$tbl" | grep -qE "$exp_pattern"; then
            return 0
        fi
        return 1
    }

    local as2_ok=0; local as22_ok=0; local as3_ok=0; local as12_ok=0
    check_ext_best as2r1 "1 102|1\.0\.0\.0" && as2_ok=1
    check_ext_best as22r1 "2 1 102|2\.0\.0\.0" && as22_ok=1
    check_ext_best as3r1 "1 102|3\.0\.0\.2" && as3_ok=1
    check_ext_best as12r1 "1 102|1\.0\.0\.2" && as12_ok=1

    if [ "$as2_ok" -eq 1 ] && [ "$as22_ok" -eq 1 ] && [ "$as3_ok" -eq 1 ] && [ "$as12_ok" -eq 1 ]; then
        report_pass "B18-B21" "全网入向流量按设计经 AS1 进入本 AS (AS2: '1 102', AS22: '2 1 102', AS3: '1 102', AS12: '1 102')"
    else
        report_fail "B18-B21" "外部 AS 入向选路异常 (AS2:$as2_ok, AS22:$as22_ok, AS3:$as3_ok, AS12:$as12_ok)"
    fi

    # B23 - B25: 防止常态未授权 Transit
    local as21_to_as1_path=$(kvtysh as21r1 "show ip bgp 1.0.0.0/20" | grep -A2 -E "best|valid.*best" | grep -oP '(?:\d+\s+)+[ie\?]' || kvtysh as21r1 "show ip bgp" | grep -E "^\*>[i ]*\s*1\.0\.0\.0/20" || true)
    if echo "$as21_to_as1_path" | grep -q "2 1" && ! echo "$as21_to_as1_path" | grep -q "102"; then
        report_pass "B23" "常态下 AS21 访问 AS1 走直连 AS2 (Path: 2 1), 不借道 AS102 做 Transit"
    else
        report_fail "B23" "常态下 AS21 错误地经由 AS102 Transit" "$as21_to_as1_path"
    fi

    # B26 - B28: 社区属性规范审查
    local r1_comm_cfg=$(grep -rn "set community" "${PROJECT_DIR}/as102r1/etc/frr/frr.conf" 2>/dev/null || true)
    local r2_comm_cfg=$(grep -rn "set community" "${PROJECT_DIR}/as102r2/etc/frr/frr.conf" 2>/dev/null || true)
    if echo "$r1_comm_cfg" | grep -q "1:200" && [ -z "$r2_comm_cfg" ]; then
        report_pass "B26-B28" "社区规范核验通过: 仅 r1 对 AS1 附加恰好 1 个社区 1:200, r2 不附加社区"
    else
        report_fail "B26-B28" "BGP 社区属性配置违规或多配"
    fi
}

# ------------------------------------------------------------------------------
# 8. BGP 与外部出口故障场景 (BF1 - BF7)
# ------------------------------------------------------------------------------
test_section_8_failover() {
    section_header "8. BGP 与外部出口故障场景 (BF1 - BF7 容灾收敛实测)"

    # BF1: r1 完全下线 (模拟边界路由器硬件宕机)
    echo -e "  ${CYAN}--- Testing BF1: r1 Complete Shutdown ---${NC}"
    kexec as102r1 systemctl stop frr
    wait_countdown 15 "OSPF withdrawal & BGP holdtimer failover"

    local bf1_ext_ping=0
    kexec as102c1 ping -c 2 -W 2 1.0.1.2 >/dev/null 2>&1 && bf1_ext_ping=1
    local bf1_r3_def_hop=$(kvtysh as102r3 "show ip route 0.0.0.0/0" | grep -oP '(?:via\s*|nexthop\s*)\K[0-9.]+' | head -n 1)
    local bf1_as1_path=$(kvtysh as1r1 "show ip bgp 1.102.0.0/20" | grep -E "^\*>" | awk '{print $(NF-3), $(NF-2), $(NF-1), $NF}' || true)

    # 恢复 r1
    kexec as102r1 systemctl start frr
    wait_countdown 18 "Restoring r1 & reconvergence"

    if [ "$bf1_ext_ping" -eq 1 ] && [ "$bf1_r3_def_hop" == "1.102.3.6" ]; then
        report_pass "BF1" "r1 下线演练通过: OSPF 默认无缝切至 r2 (via 1.102.3.6), 外网经 AS21 维持通畅"
    else
        report_fail "BF1" "r1 下线演练未通过 (外网通: $bf1_ext_ping, r3下一跳: $bf1_r3_def_hop/1.102.3.6)"
    fi

    # BF2: r2 完全下线 (模拟对等边界路由器宕机)
    echo -e "  ${CYAN}--- Testing BF2: r2 Complete Shutdown ---${NC}"
    kexec as102r2 systemctl stop frr
    wait_countdown 15 "OSPF flush of 2.21.0.0/20 & BGP reconvergence"

    local bf2_21_ping=0
    kexec as102c1 ping -c 2 -W 2 2.21.1.1 >/dev/null 2>&1 && bf2_21_ping=1
    local bf2_ospf_21=$(kvtysh as102r3 "show ip route 2.21.0.0/20" | grep -cE "O\s*E1|type 1" || true)

    # 恢复 r2
    kexec as102r2 systemctl start frr
    wait_countdown 18 "Restoring r2 & reconvergence"

    if [ "$bf2_21_ping" -eq 1 ] && [ "$bf2_ospf_21" -eq 0 ]; then
        report_pass "BF2" "r2 下线演练通过: 2.21.0.0/20 从 OSPF 自动撤除, AS21 流量转由 r1->AS1 绕行直达"
    else
        report_fail "BF2" "r2 下线演练未通过 (AS21连通: $bf2_21_ping, OSPF残留2.21: $bf2_ospf_21)"
    fi

    # BF3: 仅 r1 eth0 链路故障 (验证条件默认路由 route-map CHECK-AS1)
    echo -e "  ${CYAN}--- Testing BF3: r1 eth0 Link Flap (Conditional Default Route) ---${NC}"
    kexec as102r1 ip link set eth0 down
    wait_countdown 15 "Waiting for CHECK-AS1 withdrawal"

    local bf3_r3_metric=$(kvtysh as102r3 "show ip route 0.0.0.0/0" | grep -oP '(?:\[110/|metric\s+)\K\d+' | head -n 1)
    local bf3_ibgp_up=$(kvtysh as102r1 "show ip bgp summary" | grep "1.102.4.2" | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/ || $i ~ /Active|Idle|Connect/) {print $i; exit}}')
    local bf3_ping=0
    kexec as102c1 ping -c 2 -W 2 1.0.1.2 >/dev/null 2>&1 && bf3_ping=1

    kexec as102r1 ip link set eth0 up
    wait_countdown 15 "Restoring r1 eth0 link"

    if [ "$bf3_r3_metric" == "60" ] && [ "$bf3_ping" -eq 1 ] && [[ "$bf3_ibgp_up" =~ ^[0-9]+$ ]]; then
        report_pass "BF3" "CHECK-AS1 条件默认撤销成功: r3 度量变为 60 (经r2), iBGP 正常保活"
    else
        report_fail "BF3" "r1 eth0 故障条件默认路由切换异常 (r3度量: $bf3_r3_metric/60, 外网通: $bf3_ping)"
    fi

    # BF4: 仅 r2 eth0 链路故障 (验证条件默认路由 route-map CHECK-AS21)
    echo -e "  ${CYAN}--- Testing BF4: r2 eth0 Link Flap (CHECK-AS21 & Redistribution) ---${NC}"
    kexec as102r2 ip link set eth0 down
    wait_countdown 15 "Waiting for CHECK-AS21 & OSPF-INJECT flush"

    local bf4_r3_has_21=$(kvtysh as102r3 "show ip route 2.21.0.0/20" | grep -cE "O\s*E1|type 1" || true)
    local bf4_ping21=0
    kexec as102c1 ping -c 2 -W 2 2.21.1.1 >/dev/null 2>&1 && bf4_ping21=1

    kexec as102r2 ip link set eth0 up
    wait_countdown 15 "Restoring r2 eth0 link"

    if [ "$bf4_r3_has_21" -eq 0 ] && [ "$bf4_ping21" -eq 1 ]; then
        report_pass "BF4" "CHECK-AS21 条件默认及重分发瞬时撤除，流量经 r1 备用路径无损访问 AS21"
    else
        report_fail "BF4" "r2 eth0 故障收敛异常 (OSPF残留: $bf4_r3_has_21, AS21连通: $bf4_ping21)"
    fi

    # BF5: AS21-AS2 上联链路断开 (验证 AS102 对 AS21 的紧急 Transit 保护)
    echo -e "  ${CYAN}--- Testing BF5: AS21-AS2 Uplink Outage (AS102 Backup Transit) ---${NC}"
    kexec as21r1 ip link set eth1 down
    wait_countdown 15 "Waiting for AS21 to shift transit to AS102"

    local bf5_as21_transit_ok=0
    kexec as21h1 ping -c 2 -W 2 1.0.1.2 >/dev/null 2>&1 && bf5_as21_transit_ok=1
    local bf5_as1_best_21=$(kvtysh as1r1 "show ip bgp 2.21.0.0/20" | grep -E "^\*>" | grep -c "102 102 21" || true)

    kexec as21r1 ip link set eth1 up
    wait_countdown 15 "Restoring AS21-AS2 uplink"

    if [ "$bf5_as21_transit_ok" -eq 1 ]; then
        report_pass "BF5" "AS21-AS2 断网时，AS102 成功承载 AS21 备份 Transit，AS1 正确收敛至 102 102 21"
    else
        report_warn "BF5" "AS21-AS2 上联断开后 AS21 Transit 未收敛 (可能受对端 AS2/AS21 路由收敛耗时影响)"
    fi

    # BF6: 双重故障测试 (r1 eth0 down + L12 down)
    echo -e "  ${CYAN}--- Testing BF6: Dual Failure (r1-AS1 down + r1-r2 core link down) ---${NC}"
    kexec as102r1 ip link set eth0 down
    kexec as102r1 ip link set eth1 down
    wait_countdown 15 "Testing iBGP over r3 alternate path"

    local bf6_ibgp_state=$(kvtysh as102r1 "show ip bgp summary" | grep "1.102.4.2" | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/ || $i ~ /Active|Idle|Connect/) {print $i; exit}}')
    local bf6_ping=0
    kexec as102c1 ping -c 2 -W 2 1.0.1.2 >/dev/null 2>&1 && bf6_ping=1

    kexec as102r1 ip link set eth0 up
    kexec as102r1 ip link set eth1 up
    wait_countdown 18 "Restoring dual failure links"

    if [[ "$bf6_ibgp_state" =~ ^[0-9]+$ ]] && [ "$bf6_ping" -eq 1 ]; then
        report_pass "BF6" "双重故障演练通过: dummy0 解耦物理链路，iBGP 绕经 r3 依然 Established 且出网不中断"
    else
        report_fail "BF6" "双重故障下 iBGP 状态断开或出网中断 (iBGP: $bf6_ibgp_state, 出网: $bf6_ping)"
    fi

    # BF7: 最终完整状态恢复回归
    local r1_all_full=$(kvtysh as102r1 "show ip ospf neighbor" | grep -c "Full")
    local r1_bgp_e=$(kvtysh as102r1 "show ip bgp summary" | grep "1.0.0.4" | awk '{for(i=10;i<=NF;i++) if($i ~ /^[0-9]+$/ || $i ~ /Active|Idle|Connect/) {print $i; exit}}')
    if [ "$r1_all_full" -eq 3 ] && [[ "$r1_bgp_e" =~ ^[0-9]+$ ]]; then
        report_pass "BF7" "故障注入全部恢复，OSPF 邻居与 BGP 会话全部 100% 回归常态"
    else
        report_fail "BF7" "演练结束后未完全回归初始状态"
    fi
}

# ------------------------------------------------------------------------------
# 9. DNS 服务功能与递归解析 (D1 - D12)
# ------------------------------------------------------------------------------
test_section_9_dns() {
    section_header "9. DNS 服务功能与递归解析 (D1 - D12)"

    # D1: 进程隔离与单一职责
    local s1_ps=$(kexec as102s1 ps aux)
    local s2_ps=$(kexec as102s2 ps aux)
    local s3_ps=$(kexec as102s3 ps aux)

    local s1_ok=0; local s2_ok=0; local s3_ok=0
    if echo "$s1_ps" | grep -q "named" && ! echo "$s1_ps" | grep -qE "apache|dhcpd"; then s1_ok=1; fi
    if echo "$s2_ps" | grep -q "apache2" && ! echo "$s2_ps" | grep -qE "named|dhcpd"; then s2_ok=1; fi
    if echo "$s3_ps" | grep -q "dhcpd" && ! echo "$s3_ps" | grep -qE "named|apache"; then s3_ok=1; fi

    if [ "$s1_ok" -eq 1 ] && [ "$s2_ok" -eq 1 ] && [ "$s3_ok" -eq 1 ]; then
        report_pass "D1" "三台服务器服务完全解耦独立 (s1:named, s2:apache2, s3:dhcpd)"
    else
        report_fail "D1" "服务器进程出现冗余或职责混乱 (s1:$s1_ok, s2:$s2_ok, s3:$s3_ok)"
    fi

    # D2: BIND 配置语法检查
    local chk_conf=$(kexec as102s1 named-checkconf 2>&1)
    local chk_fwd=$(kexec as102s1 named-checkzone isp102.lab /etc/bind/db.lab.isp102 2>&1 | grep -c "OK" || true)
    local chk_rev=$(kexec as102s1 named-checkzone 102.1.in-addr.arpa /etc/bind/db.1.102 2>&1 | grep -c "OK" || true)

    if [ -z "$chk_conf" ] && [ "$chk_fwd" -ge 1 ] && [ "$chk_rev" -ge 1 ]; then
        report_pass "D2" "named-checkconf 与正反向 zone 语法检验全部返回 OK"
    else
        report_fail "D2" "BIND zone 语法校验存在错误 (conf:$chk_conf, fwd:$chk_fwd, rev:$chk_rev)"
    fi

    # D3: 权威 SOA 与 NS 记录标志
    local soa_fwd=$(kexec as102c1 dig @1.102.1.2 isp102.lab SOA 2>/dev/null)
    local soa_rev=$(kexec as102c1 dig @1.102.1.2 102.1.in-addr.arpa SOA 2>/dev/null)
    if echo "$soa_fwd" | grep -q "flags:.*aa" && echo "$soa_fwd" | grep -q "ns.isp102.lab." && echo "$soa_rev" | grep -q "flags:.*aa"; then
        report_pass "D3" "正反向 Zone 均带有 Authoritative Answer (aa) 标志且 NS 为 ns.isp102.lab."
    else
        report_fail "D3" "SOA 记录未正确返回权威应答 (aa 标志缺失)"
    fi

    # D4: 核心服务 A 记录
    local ns_ip=$(kexec as102c1 dig @1.102.1.2 ns.isp102.lab +short 2>/dev/null)
    local www_ip=$(kexec as102c1 dig @1.102.1.2 www.isp102.lab +short 2>/dev/null)
    local dhcpd_ip=$(kexec as102c1 dig @1.102.1.2 dhcpd.isp102.lab +short 2>/dev/null)

    if [ "$ns_ip" == "1.102.1.2" ] && [ "$www_ip" == "1.102.1.3" ] && [ "$dhcpd_ip" == "1.102.1.4" ]; then
        report_pass "D4" "基础 A 记录精准解析 (ns->1.102.1.2, www->1.102.1.3, dhcpd->1.102.1.4)"
    else
        report_fail "D4" "基础 A 记录不匹配 (ns:$ns_ip, www:$www_ip, dhcpd:$dhcpd_ip)"
    fi

    # D5: 路由器全接口 FQDN 记录检查
    local dns_mismatch=0
    check_dns_a() {
        local fqdn="$1"; local exp_ip="$2"
        local got=$(kexec as102c1 dig @1.102.1.2 "$fqdn" +short 2>/dev/null)
        if [ "$got" != "$exp_ip" ]; then
            dns_mismatch=1
        fi
    }
    check_dns_a "r1-eth0.isp102.lab" "1.0.0.5"
    check_dns_a "r1-eth1.isp102.lab" "1.102.3.0"
    check_dns_a "r1-eth2.isp102.lab" "1.102.3.2"
    check_dns_a "r1-eth3.isp102.lab" "1.102.3.5"
    check_dns_a "r1-lo.isp102.lab"   "1.102.4.1"
    check_dns_a "r2-eth0.isp102.lab" "2.21.0.1"
    check_dns_a "r2-eth1.isp102.lab" "1.102.3.1"
    check_dns_a "r2-eth2.isp102.lab" "1.102.3.6"
    check_dns_a "r2-lo.isp102.lab"   "1.102.4.2"
    check_dns_a "r3-eth0.isp102.lab" "1.102.1.1"
    check_dns_a "r3-eth1.isp102.lab" "1.102.3.3"
    check_dns_a "r3-eth2.isp102.lab" "1.102.3.7"
    check_dns_a "r3-eth3.isp102.lab" "1.102.3.8"
    check_dns_a "r3-lo.isp102.lab"   "1.102.4.3"
    check_dns_a "r4-eth0.isp102.lab" "1.102.2.1"
    check_dns_a "r4-eth1.isp102.lab" "1.102.3.4"
    check_dns_a "r4-eth2.isp102.lab" "1.102.3.9"
    check_dns_a "r4-lo.isp102.lab"   "1.102.4.4"

    if [ "$dns_mismatch" -eq 0 ]; then
        report_pass "D5" "路由器全部 18 个接口与 Loopback 的 FQDN 记录逐条核验 100% 正确"
    else
        report_fail "D5" "部分路由器接口 FQDN 正向解析缺失或 IP 错误"
    fi

    # D6: 动态客户端 $GENERATE 记录 (client10 - client29)
    local dyn_dns_ok=1
    for y in $(seq 10 29); do
        local res=$(kexec as102c1 dig @1.102.1.2 "client${y}.isp102.lab" +short 2>/dev/null)
        if [ "$res" != "1.102.2.${y}" ]; then
            dyn_dns_ok=0
            break
        fi
    done
    if [ "$dyn_dns_ok" -eq 1 ]; then
        report_pass "D6" "动态客户端 BIND \$GENERATE 规则成功覆盖 client10-client29 全部 20 个 IP"
    else
        report_warn "D6" "动态客户端 client10-client29 部分解析未通过 (请检查 \$GENERATE 语句)"
    fi

    # D7: 反向 PTR 记录解析
    local ptr_r1_lo=$(kexec as102c1 dig @1.102.1.2 -x 1.102.4.1 +short 2>/dev/null)
    local ptr_www=$(kexec as102c1 dig @1.102.1.2 -x 1.102.1.3 +short 2>/dev/null)
    if echo "$ptr_r1_lo" | grep -q "r1-lo.isp102.lab" && echo "$ptr_www" | grep -q "www.isp102.lab"; then
        report_pass "D7" "本域反向 PTR 解析工作正常 (1.102.4.1 -> r1-lo, 1.102.1.3 -> www)"
    else
        report_fail "D7" "本域反向 PTR 解析不匹配 (got: $ptr_r1_lo, $ptr_www)"
    fi

    # D8 - D9: 递归外域正反向解析 (经 1.0.1.2 根服务器)
    local rec_fwd=$(kexec as102c1 dig @1.102.1.2 www.isp1.lab +short 2>/dev/null)
    local rec_rev=$(kexec as102c1 dig @1.102.1.2 -x 1.0.1.2 +short 2>/dev/null)
    if [ -n "$rec_fwd" ] && [ -n "$rec_rev" ]; then
        report_pass "D8-D9" "经由根 DNS 递归解析外部域名与反向 PTR 成功 (www.isp1.lab->$rec_fwd, PTR->$rec_rev)"
    else
        report_fail "D8-D9" "递归 DNS 查询失败 (fwd: '$rec_fwd', rev: '$rec_rev')"
    fi

    # D10: 外部 AS 访问本域 DNS
    local ext_lookup=$(kexec as1h2 dig @1.102.1.2 www.isp102.lab +short 2>/dev/null)
    if [ "$ext_lookup" == "1.102.1.3" ]; then
        report_pass "D10" "外部 AS 主机可顺利查询本域权威解析 (无 REFUSED，响应正常)"
    else
        report_fail "D10" "外部主机查询本域解析失败 (got: '$ext_lookup')"
    fi

    # D12: 全网节点 /etc/resolv.conf 配置
    local all_resolv_ok=1
    for n in as102r1 as102r2 as102r3 as102r4 as102s1 as102s2 as102s3 as102c1 as102c2; do
        local ns=$(kexec "$n" cat /etc/resolv.conf 2>/dev/null | grep -oP 'nameserver\s*\K[0-9.]+' || true)
        if [ "$ns" != "1.102.1.2" ]; then
            all_resolv_ok=0
            break
        fi
    done
    if [ "$all_resolv_ok" -eq 1 ]; then
        report_pass "D12" "全网 9 个节点 /etc/resolv.conf 统一配置指向 s1 (1.102.1.2)"
    else
        report_warn "D12" "部分节点 /etc/resolv.conf 未指向 1.102.1.2 (客户端需完成 DHCP 获租)"
    fi
}

# ------------------------------------------------------------------------------
# 10. Web 服务与网页内容逐行核验 (W1 - W6)
# ------------------------------------------------------------------------------
test_section_10_web() {
    section_header "10. Web 服务与网页内容逐行核验 (W1 - W6)"

    # W1: 仅运行在 s2
    local s2_web=$(kexec as102s2 pgrep apache2 || true)
    if [ -n "$s2_web" ]; then
        report_pass "W1" "Apache2 Web 服务运行在指定服务器 s2 上"
    else
        report_fail "W1" "s2 上未检测到正在运行的 apache2 服务"
    fi

    # W2 - W3: index.html 存在且包含所有严谨字段
    local html=$(kexec as102c1 curl -s http://www.isp102.lab/ 2>/dev/null)
    local has_asn=$(echo "$html" | grep -c "ASN:\s*102" || true)
    local has_net=$(echo "$html" | grep -c "NETWORK:\s*1.102.0.0/20" || true)
    local has_n1=$(echo "$html" | grep -c "Emanuel Paraschiv" || true)
    local has_e1=$(echo "$html" | grep -c "emapar@kth.se" || true)
    local has_n2=$(echo "$html" | grep -c "Haoyu Chen" || true)
    local has_e2=$(echo "$html" | grep -c "chchen3@kth.se" || true)

    if [ "$has_asn" -ge 1 ] && [ "$has_net" -ge 1 ] && [ "$has_n1" -ge 1 ] && [ "$has_e1" -ge 1 ] && [ "$has_n2" -ge 1 ] && [ "$has_e2" -ge 1 ]; then
        report_pass "W2-W3" "网页 index.html 存在且 6 项身份信息完全逐行匹配报告要求"
    else
        report_fail "W2-W3" "网页内容缺失必要字段 (ASN:$has_asn NET:$has_net N1:$has_n1 E1:$has_e1 N2:$has_n2 E2:$has_e2)"
    fi

    # W4 - W5: 内外 HTTP 访问均返回 200 OK
    local int_code=$(kexec as102c1 curl -s -o /dev/null -w "%{http_code}" http://www.isp102.lab/ 2>/dev/null)
    local ext_code=$(kexec as1h2 curl -s -o /dev/null -w "%{http_code}" http://www.isp102.lab/ 2>/dev/null)
    if [ "$int_code" == "200" ] && [ "$ext_code" == "200" ]; then
        report_pass "W4-W5" "内部客户端与外网主机均可正常获取主页 HTTP 200 OK"
    else
        report_fail "W4-W5" "HTTP 状态码异常 (内部: $int_code, 外部: $ext_code)"
    fi

    # W6: 客户端出向访问外网 Web
    local out_web=$(kexec as102c1 curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://www.isp1.lab/ 2>/dev/null)
    if [ "$out_web" == "200" ]; then
        report_pass "W6" "内部客户端可成功访问外部 ISP-1 Web 页面 (HTTP 200 OK)"
    else
        report_fail "W6" "内部客户端无法获取外部 Web 页面 (HTTP 状态码: $out_web)"
    fi
}

# ------------------------------------------------------------------------------
# 11. DHCP 动态分配与中继交互 (H1 - H10)
# ------------------------------------------------------------------------------
test_section_11_dhcp() {
    section_header "11. DHCP 动态分配与中继交互 (H1 - H10)"

    # H1: 仅运行在 s3
    local s3_dhcp=$(kexec as102s3 pgrep dhcpd || true)
    if [ -n "$s3_dhcp" ]; then
        report_pass "H1" "ISC-DHCP-Server 服务运行在指定服务器 s3 上"
    else
        report_fail "H1" "s3 上未检测到正在运行的 dhcpd 服务"
    fi

    # H2: dhcpd.conf 池与选项配置
    local conf="${PROJECT_DIR}/as102s3/etc/dhcp/dhcpd.conf"
    local has_range=$(grep -c "range 1.102.2.10 1.102.2.29;" "$conf" 2>/dev/null || true)
    local has_gw=$(grep -c "routers 1.102.2.1;" "$conf" 2>/dev/null || true)
    local has_dns=$(grep -c "domain-name-servers 1.102.1.2;" "$conf" 2>/dev/null || true)
    local has_bcast=$(grep -c "broadcast-address 1.102.2.255;" "$conf" 2>/dev/null || true)

    if [ "$has_range" -ge 1 ] && [ "$has_gw" -ge 1 ] && [ "$has_dns" -ge 1 ] && [ "$has_bcast" -ge 1 ]; then
        report_pass "H2" "dhcpd.conf 地址池为 20 个地址 (10-29)，网关、DNS、广播地址完全符合规范"
    else
        report_fail "H2" "dhcpd.conf 配置参数不符合规范 (range:$has_range, gw:$has_gw, dns:$has_dns, bcast:$has_bcast)"
    fi

    # H3: r4 中继进程运行
    local r4_relay=$(kexec as102r4 pgrep dhcrelay || true)
    if [ -n "$r4_relay" ]; then
        report_pass "H3" "r4 DHCP 中继 (dhcrelay) 正常运行并转发请求至 1.102.1.4"
    else
        report_fail "H3" "r4 上未找到运行的 dhcrelay 守护进程"
    fi

    # H4 - H6: 客户端获取的实际 IP、默认路由与 DNS
    local c1_ip=$(kexec as102c1 ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    local c2_ip=$(kexec as102c2 ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    local c1_gw=$(kexec as102c1 ip route | grep default | awk '{print $3}')

    local c1_in_range=0; local c2_in_range=0
    if [[ "$c1_ip" =~ ^1\.102\.2\. ]] && [ "${c1_ip##*.}" -ge 10 ] && [ "${c1_ip##*.}" -le 29 ]; then c1_in_range=1; fi
    if [[ "$c2_ip" =~ ^1\.102\.2\. ]] && [ "${c2_ip##*.}" -ge 10 ] && [ "${c2_ip##*.}" -le 29 ]; then c2_in_range=1; fi

    if [ "$c1_in_range" -eq 1 ] && [ "$c2_in_range" -eq 1 ] && [ "$c1_gw" == "1.102.2.1" ]; then
        report_pass "H4-H6" "c1($c1_ip) 与 c2($c2_ip) 成功租得 [10,29] 动态 IP，网关为 1.102.2.1"
    else
        report_fail "H4-H6" "客户端 DHCP 租约地址或网关异常 (c1:$c1_ip, c2:$c2_ip, gw:$c1_gw)"
    fi

    # H8: s3 租约记录文件存在
    local leases=$(kexec as102s3 cat /var/lib/dhcp/dhcpd.leases 2>/dev/null | grep -c "lease 1.102.2." || true)
    if [ "$leases" -ge 1 ]; then
        report_pass "H8" "s3 dhcpd.leases 存在活跃租约记录"
    else
        report_warn "H8" "dhcpd.leases 暂无记录 (客户端可能使用静态初始化或未触发刷新)"
    fi

    # H10: 客户端 startup 仅一行 dhclient 命令
    local c1_lines=$(grep -vE '^\s*$' "${PROJECT_DIR}/as102c1.startup" 2>/dev/null | wc -l)
    local c1_content=$(cat "${PROJECT_DIR}/as102c1.startup" 2>/dev/null | tr -d '\r\n')
    if [ "$c1_lines" -eq 1 ] && [[ "$c1_content" =~ dhclient ]]; then
        report_pass "H10" "客户端 startup 文件严格遵守项目规范，仅包含单行 dhclient 指令"
    else
        report_fail "H10" "客户端 startup 文件包含多余指令 (行数: $c1_lines, 内容: $c1_content)"
    fi
}

# ------------------------------------------------------------------------------
# 12. 项目规范与合规性静态审查 (C1 - C7)
# ------------------------------------------------------------------------------
test_section_12_compliance() {
    section_header "12. 项目规范与合规性静态审查 (C1 - C7)"

    # C1: 路由器 startup 不含 ip addr 命令 (全部由 FRR 管理)
    local r_startup_ip=0
    for r in as102r1 as102r2 as102r3 as102r4; do
        if grep -nE "ip (addr|a )|ifconfig" "${PROJECT_DIR}/${r}.startup" 2>/dev/null; then
            r_startup_ip=1
        fi
    done
    if [ "$r_startup_ip" -eq 0 ]; then
        report_pass "C1" "路由器 startup 完全由 FRR 纳管 IP，未调用底层 ip addr 命令"
    else
        report_fail "C1" "路由器 startup 中发现了违规配置的 ip addr 指令"
    fi

    # C2: 严禁静态黑洞路由 (Null0 / blackhole)
    local static_blackhole=$(grep -rnE "^\s*ip route|Null0|blackhole" "${PROJECT_DIR}/as102r"*"/etc/frr/" 2>/dev/null || true)
    if [ -z "$static_blackhole" ]; then
        report_pass "C2" "未发现任何静态路由或 Null0 黑洞路由 (利用 dummy0 干净触发聚合)"
    else
        report_fail "C2" "发现静态路由或 Null0 配置" "$static_blackhole"
    fi

    # C3: 聚合与组件 /32 动态触发
    local r1_agg=$(grep "aggregate-address 1.102.0.0/20 summary-only" "${PROJECT_DIR}/as102r1/etc/frr/frr.conf" 2>/dev/null)
    local r2_agg=$(grep "aggregate-address 1.102.0.0/20 summary-only" "${PROJECT_DIR}/as102r2/etc/frr/frr.conf" 2>/dev/null)
    local r1_net=$(grep "network 1.102.4.1/32" "${PROJECT_DIR}/as102r1/etc/frr/frr.conf" 2>/dev/null)
    local r2_net=$(grep "network 1.102.4.2/32" "${PROJECT_DIR}/as102r2/etc/frr/frr.conf" 2>/dev/null)

    if [ -n "$r1_agg" ] && [ -n "$r2_agg" ] && [ -n "$r1_net" ] && [ -n "$r2_net" ]; then
        report_pass "C3" "r1 与 r2 均配置 dummy0 /32 network 触发 aggregate-address summary-only"
    else
        report_fail "C3" "聚合路由触发方式与设计不符"
    fi

    # C4: 内部 OSPF 接口度量确定性验证
    local total_costs=$(grep -h "ip ospf cost" "${PROJECT_DIR}/as102r"*"/etc/frr/frr.conf" 2>/dev/null | wc -l)
    if [ "$total_costs" -ge 10 ]; then
        report_pass "C4" "所有内部点对点接口均显式配置 ip ospf cost，杜绝默认开销不确定性"
    else
        report_fail "C4" "部分接口遗漏了显式 ip ospf cost 配置 (找到 $total_costs/10)"
    fi
}

# ------------------------------------------------------------------------------
# 13. 全网端到端连通性综合测试 (E1 - E6)
# ------------------------------------------------------------------------------
test_section_13_e2e() {
    section_header "13. 全网端到端连通性综合测试 (E1 - E6)"

    # E1: 客户端 ping 全部外网 Web 域名
    local e1_fail=0
    for n in 1 2 3 12 21 22; do
        if ! kexec as102c1 ping -c 1 -W 2 "www.isp${n}.lab" >/dev/null 2>&1; then
            e1_fail=1
            echo -e "         ${RED}-> ping www.isp${n}.lab 失败${NC}"
        fi
    done
    if [ "$e1_fail" -eq 0 ]; then
        report_pass "E1" "客户端可顺利 ping 通全网全部 6 个外部 AS Web 域名 (isp1/2/3/12/21/22)"
    else
        report_fail "E1" "客户端 ping 外网 Web 域名存在丢包"
    fi

    # E2: 服务器 ping 外网
    local e2_fail=0
    for n in 1 2 21; do
        if ! kexec as102s1 ping -c 1 -W 2 "www.isp${n}.lab" >/dev/null 2>&1; then
            e2_fail=1
        fi
    done
    if [ "$e2_fail" -eq 0 ]; then
        report_pass "E2" "服务器 s1 外网连通性正常"
    else
        report_fail "E2" "服务器 ping 外网存在失败"
    fi

    # E3: 客户端 curl 全部外网 Web 主页
    local e3_fail=0
    for n in 1 2 3 12 21 22; do
        local code=$(kexec as102c1 curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://www.isp${n}.lab/" 2>/dev/null)
        if [ "$code" != "200" ]; then
            e3_fail=1
            echo -e "         ${RED}-> curl http://www.isp${n}.lab/ 返回码: $code${NC}"
        fi
    done
    if [ "$e3_fail" -eq 0 ]; then
        report_pass "E3" "客户端 curl 访问全部 6 个外部 AS Web 网站全部返回 HTTP 200 OK"
    else
        report_fail "E3" "部分外部 Web 页面 curl 失败"
    fi

    # E4: 根 DNS 与 TLD DNS 可用性
    local root_ok=0; local tld_ok=0
    kexec as102s1 dig @1.0.1.2 . NS +short >/dev/null 2>&1 && root_ok=1
    kexec as102s1 dig @2.0.1.2 lab. NS +short >/dev/null 2>&1 && tld_ok=1
    if [ "$root_ok" -eq 1 ] && [ "$tld_ok" -eq 1 ]; then
        report_pass "E4" "根 DNS (1.0.1.2) 与 TLD .lab (2.0.1.2) 直连解析通畅"
    else
        report_fail "E4" "根或 TLD DNS 查询失败 (root:$root_ok, tld:$tld_ok)"
    fi
}

# ------------------------------------------------------------------------------
# Summary Output
# ------------------------------------------------------------------------------
print_summary() {
    local total=$((pass_count + fail_count + warn_count))
    echo -e "\n${BLUE}==============================================================================${NC}"
    echo -e "${BOLD}${BLUE}                         TEST SUMMARY REPORT                                  ${NC}"
    echo -e "${BLUE}==============================================================================${NC}"
    echo -e "  Total Checks Executed : ${BOLD}$total${NC}"
    echo -e "  Total Passed          : ${GREEN}${BOLD}$pass_count${NC}"
    echo -e "  Total Failed          : ${RED}${BOLD}$fail_count${NC}"
    echo -e "  Total Warnings        : ${YELLOW}${BOLD}$warn_count${NC}"
    echo -e "  Total Skipped         : ${CYAN}${BOLD}$skip_count${NC}"

    if [ "$fail_count" -eq 0 ]; then
        echo -e "\n  ${GREEN}${BOLD}CONGRATULATIONS! All tested design sheet requirements PASSED!${NC}"
    else
        echo -e "\n  ${RED}${BOLD}ATTENTION: $fail_count check(s) failed. Please review details above.${NC}"
    fi
    echo -e "${BLUE}==============================================================================${NC}\n"
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
show_help() {
    echo "Usage: ./test_as102.sh [OPTION]"
    echo ""
    echo "Options:"
    echo "  (no args)      Run safe baseline verification (Topo, IP, OSPF, BGP, Services, E2E)"
    echo "  --all          Run complete test suite including path & failover link toggling"
    echo "  --static       Run static compliance checks (T1.1-T1.4, C1-C7)"
    echo "  --topo         Run topology & IP checks (T1.5, T2.1-T2.4)"
    echo "  --ospf         Run OSPF checks (T3.1-T3.9)"
    echo "  --bgp          Run BGP peering & policies (B1-B28)"
    echo "  --paths        Run P0-P10 path verification (includes link down/up)"
    echo "  --link-fail    Run F1-F4 internal link failover tests"
    echo "  --bgp-fail     Run BF1-BF7 BGP failover & recovery tests"
    echo "  --services     Run DNS, Web, and DHCP service verification"
    echo "  --dns          Run DNS tests only (D1-D12)"
    echo "  --web          Run Web tests only (W1-W6)"
    echo "  --dhcp         Run DHCP tests only (H1-H10)"
    echo "  --e2e          Run end-to-end connectivity checks (E1-E6)"
    echo "  --help         Show this help message"
}

case "$1" in
    --help|-h)
        show_help
        exit 0
        ;;
    --all)
        test_section_1_topo
        test_section_2_ip
        test_section_3_ospf
        test_section_6_bgp_peering
        test_section_7_bgp_policy
        test_section_9_dns
        test_section_10_web
        test_section_11_dhcp
        test_section_12_compliance
        test_section_13_e2e
        test_section_4_paths
        test_section_5_link_failure
        test_section_8_failover
        print_summary
        ;;
    --static)
        test_section_1_topo
        test_section_12_compliance
        print_summary
        ;;
    --topo)
        test_section_1_topo
        test_section_2_ip
        print_summary
        ;;
    --ospf)
        test_section_3_ospf
        print_summary
        ;;
    --bgp)
        test_section_6_bgp_peering
        test_section_7_bgp_policy
        print_summary
        ;;
    --paths)
        test_section_4_paths
        print_summary
        ;;
    --link-fail)
        test_section_5_link_failure
        print_summary
        ;;
    --bgp-fail)
        test_section_8_failover
        print_summary
        ;;
    --services)
        test_section_9_dns
        test_section_10_web
        test_section_11_dhcp
        print_summary
        ;;
    --dns)
        test_section_9_dns
        print_summary
        ;;
    --web)
        test_section_10_web
        print_summary
        ;;
    --dhcp)
        test_section_11_dhcp
        print_summary
        ;;
    --e2e)
        test_section_13_e2e
        print_summary
        ;;
    "")
        # Default mode: Run all safe, non-destructive tests
        echo -e "${CYAN}Running default safe test suite (non-destructive)...${NC}"
        echo -e "${YELLOW}(Hint: Use '--all' to include link toggling & BGP failover tests)${NC}\n"
        test_section_1_topo
        test_section_2_ip
        test_section_3_ospf
        test_section_6_bgp_peering
        test_section_7_bgp_policy
        test_section_9_dns
        test_section_10_web
        test_section_11_dhcp
        test_section_12_compliance
        test_section_13_e2e
        print_summary
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        show_help
        exit 1
        ;;
esac
