#!/usr/bin/env bash
# Focused, evidence-oriented checks for the three routing grading categories:
# same_path, IGP_disruption, and BGP_transit.
#
# Kathara 3.7.9 reserves some short CLI flags while parsing `exec`; commands
# below deliberately use compatible spellings (notably vtysh --command,
# ping -w, and traceroute long options).

set -u
set -o pipefail

PASS=0
FAIL=0
CHANGED=()

pass() { printf '  PASS %-28s %s\n' "$1" "$2"; PASS=$((PASS + 1)); }
fail() { printf '  FAIL %-28s %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
section() { printf '\n==== %s ====\n' "$1"; }

kexec() {
    local node="$1"; shift
    kathara exec "$node" -- "$@" 2>/dev/null
}

vty() {
    local node="$1"; shift
    kexec "$node" vtysh --command "$*"
}

link_down() {
    local node="$1" iface="$2"
    if kexec "$node" ip link set dev "$iface" down; then
        CHANGED+=("$node:$iface")
        return 0
    fi
    return 1
}

link_up() {
    local node="$1" iface="$2" item
    kexec "$node" ip link set dev "$iface" up >/dev/null 2>&1 || true
    local kept=()
    for item in "${CHANGED[@]}"; do
        [ "$item" = "$node:$iface" ] || kept+=("$item")
    done
    CHANGED=("${kept[@]}")
}

cleanup() {
    local item node iface
    for item in "${CHANGED[@]}"; do
        node=${item%%:*}; iface=${item#*:}
        kexec "$node" ip link set dev "$iface" up >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT INT TERM HUP

ping_ok() {
    # -w is a deadline: it avoids Kathara's special handling of ping -c.
    kexec "$1" ping -n -w 2 -W 2 "$2" >/dev/null 2>&1
}

wait_ping() {
    local node="$1" dst="$2" limit="$3" i
    for ((i = 0; i < limit; i++)); do
        ping_ok "$node" "$dst" && return 0
        sleep 1
    done
    return 1
}

trace() {
    kexec "$1" traceroute -n --wait=2 --queries=1 --max-hops=16 "$2"
}

router_path() {
    trace "$1" "$2" | awk '
      $1 ~ /^[0-9]+$/ {
        ip=$2; r=""
        if (ip ~ /^(1\.0\.0\.5|1\.102\.3\.(0|2|5)|1\.102\.4\.1)$/) r="R1"
        else if (ip ~ /^(2\.21\.0\.1|1\.102\.3\.(1|6)|1\.102\.4\.2)$/) r="R2"
        else if (ip ~ /^(1\.102\.1\.1|1\.102\.3\.(3|7|8)|1\.102\.4\.3)$/) r="R3"
        else if (ip ~ /^(1\.102\.2\.1|1\.102\.3\.(4|9)|1\.102\.4\.4)$/) r="R4"
        if (r != "" && r != last) { out=(out=="" ? r : out "-" r); last=r }
      }
      END { print out }'
}

assert_path() {
    local id="$1" node="$2" dst="$3" expected="$4" actual source=""
    actual=$(router_path "$node" "$dst")
    case "$node" in
        as102r1) source=R1 ;; as102r2) source=R2 ;;
        as102r3) source=R3 ;; as102r4) source=R4 ;;
    esac
    if [ -n "$source" ] && [[ "$actual" != "$source" && "$actual" != "$source-"* ]]; then
        actual="$source${actual:+-$actual}"
    fi
    [ "$actual" = "$expected" ] && pass "$id" "$actual" || \
        fail "$id" "expected $expected, got ${actual:-<no internal hops>}"
}

ospf_full_total() {
    local node total=0 n
    for node in as102r1 as102r2 as102r3 as102r4; do
        n=$(vty "$node" show ip ospf neighbor | grep -c Full || true)
        total=$((total + n))
    done
    printf '%s\n' "$total"
}

wait_ospf_total() {
    local expected="$1" limit="$2" current
    for ((i = 0; i < limit; i++)); do
        current=$(ospf_full_total)
        [ "$current" = "$expected" ] && return 0
        sleep 1
    done
    return 1
}

single_next_hop() {
    local node="$1" prefix="$2" routes count
    routes=$(vty "$node" show ip route "$prefix")
    count=$(printf '%s\n' "$routes" |
        grep -cE '^[[:space:]]+(\*[[:space:]]+)?[0-9]+(\.[0-9]+){3},[[:space:]]+via[[:space:]]+' || true)
    [ "$count" -eq 1 ]
}

test_same_path() {
    section same_path
    assert_path SP1.r1_to_client as102r1 1.102.2.10 R1-R4
    assert_path SP1.client_to_r1 as102c1 1.102.4.1 R4-R1
    assert_path SP2.r1_to_server as102r1 1.102.1.2 R1-R3
    assert_path SP2.server_to_r1 as102s1 1.102.4.1 R3-R1
    assert_path SP3.r2_to_client as102r2 1.102.2.10 R2-R1-R4
    assert_path SP3.client_to_r2 as102c1 1.102.4.2 R4-R1-R2
    assert_path SP4.r2_to_server as102r2 1.102.1.2 R2-R3
    assert_path SP4.server_to_r2 as102s1 1.102.4.2 R3-R2
    assert_path SP5.client_to_server as102c1 1.102.1.2 R4-R3
    assert_path SP5.server_to_client as102s1 1.102.2.10 R3-R4
}

test_igp_disruption() {
    section IGP_disruption
    local label node iface expected=8 actual item bad spec src dst
    local -a links=(
        'L12:as102r1:eth1' 'L13:as102r1:eth2' 'L14:as102r1:eth3'
        'L23:as102r2:eth2' 'L34:as102r3:eth3'
    )
    local -a probes=(
        'as102r1:1.102.1.2' 'as102r1:1.102.2.10'
        'as102r2:1.102.1.2' 'as102r2:1.102.2.10'
        'as102r3:1.102.2.10' 'as102r4:1.102.1.2'
        'as102c1:1.0.1.2' 'as102c1:2.21.1.1'
    )
    for item in "${links[@]}"; do
        IFS=: read -r label node iface <<< "$item"
        if ! link_down "$node" "$iface"; then
            fail "IGP.$label" "cannot bring $node/$iface down"
            continue
        fi
        bad=0
        if ! wait_ospf_total "$expected" 30; then
            actual=$(ospf_full_total)
            fail "IGP.$label.ospf" "expected $expected Full entries, got $actual"
            bad=1
        fi
        for spec in "${probes[@]}"; do
            IFS=: read -r src dst <<< "$spec"
            if ! ping_ok "$src" "$dst"; then
                fail "IGP.$label.ping" "$src cannot reach $dst"
                bad=1
            fi
        done
        for spec in \
            'as102r1:1.102.1.0/24' 'as102r1:1.102.2.0/24' \
            'as102r2:1.102.1.0/24' 'as102r2:1.102.2.0/24' \
            'as102r3:1.102.2.0/24' 'as102r4:1.102.1.0/24'
        do
            IFS=: read -r src dst <<< "$spec"
            if ! single_next_hop "$src" "$dst"; then
                fail "IGP.$label.ecmp" "$src route $dst is missing or has ECMP"
                bad=1
            fi
        done
        [ "$bad" -eq 0 ] && pass "IGP.$label" 'converged; all probes reachable; no ECMP'
        link_up "$node" "$iface"
        wait_ospf_total 10 30 >/dev/null || fail "IGP.$label.restore" 'OSPF did not restore 10 Full entries'
    done
}

test_bgp_transit() {
    section BGP_transit
    local output bad=0
    output=$(trace as102c1 3.0.1.3)
    if printf '%s\n' "$output" | grep -q '1\.0\.0\.4' &&
       ! printf '%s\n' "$output" | grep -qE '2\.21\.0\.0|1\.102\.3\.1'; then
        pass BGP.normal_primary 'Internet traffic exits via AS1/R1'
    else
        fail BGP.normal_primary "unexpected trace: $(printf '%s' "$output" | tr '\n' ' ')"; bad=1
    fi
    output=$(trace as102c1 2.21.1.1)
    if printf '%s\n' "$output" | grep -qE '1\.102\.3\.1|2\.21\.0\.0'; then
        pass BGP.normal_as21 'AS21 traffic exits through the direct R2 peering'
    else
        fail BGP.normal_as21 "unexpected trace: $(printf '%s' "$output" | tr '\n' ' ')"; bad=1
    fi
    output=$(trace as21h1 1.0.1.2)
    if ! printf '%s\n' "$output" | grep -qE '1\.102\.|2\.21\.0\.1'; then
        pass BGP.no_normal_transit 'AS21 uses AS2, not AS102, in normal operation'
    else
        fail BGP.no_normal_transit "unexpected trace: $(printf '%s' "$output" | tr '\n' ' ')"; bad=1
    fi

    if link_down as102r1 eth0; then
        if wait_ping as102c1 1.0.1.2 90 &&
           trace as102c1 1.0.1.2 | grep -qE '1\.102\.3\.1|2\.21\.0\.0'; then
            pass BGP.r1_uplink_down 'AS102 Internet traffic failed over through AS21'
        else
            fail BGP.r1_uplink_down 'no working AS21 failover path'; bad=1
        fi
        link_up as102r1 eth0
        wait_ping as102c1 1.0.1.2 90 || { fail BGP.r1_restore 'Internet did not recover'; bad=1; }
    else
        fail BGP.r1_uplink_down 'cannot disable as102r1/eth0'; bad=1
    fi

    if link_down as21r1 eth1; then
        if wait_ping as21h1 1.0.1.2 120 &&
           trace as21h1 1.0.1.2 | grep -qE '2\.21\.0\.1|1\.102\.'; then
            pass BGP.as21_uplink_down 'AS21 obtains emergency transit through AS102'
        else
            fail BGP.as21_uplink_down 'no working emergency transit path'; bad=1
        fi
        link_up as21r1 eth1
        if wait_ping as21h1 1.0.1.2 120 &&
           ! trace as21h1 1.0.1.2 | grep -qE '2\.21\.0\.1|1\.102\.'; then
            pass BGP.as21_restore 'AS21 returned to its AS2 primary path'
        else
            fail BGP.as21_restore 'AS21 did not recover its normal path'; bad=1
        fi
    else
        fail BGP.as21_uplink_down 'cannot disable as21r1/eth1'; bad=1
    fi
    return "$bad"
}

preflight() {
    local node
    for node in as102r1 as102r2 as102r3 as102r4 as102s1 as102c1 as21r1 as21h1; do
        kexec "$node" true >/dev/null 2>&1 || { echo "ERROR: $node is not running"; return 1; }
    done
}

main() {
    case "${1:-all}" in
        all) preflight && test_same_path && test_igp_disruption && test_bgp_transit ;;
        same_path) preflight && test_same_path ;;
        igp_disruption) preflight && test_igp_disruption ;;
        bgp_transit) preflight && test_bgp_transit ;;
        *) echo "Usage: $0 [all|same_path|igp_disruption|bgp_transit]"; return 2 ;;
    esac
    printf '\nRESULT: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
}

main "$@"
