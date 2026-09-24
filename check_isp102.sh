#!/usr/bin/env bash
# ==============================================================================
# IK2215 ISP-project (AS102) Automated Verification Script
# Run this script on your Lab VM inside the ISP-project directory:
#   bash check_isp102.sh
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

pass_count=0
fail_count=0

report_pass() {
    echo -e "  [${GREEN}PASS${NC}] $1"
    ((pass_count++))
}

report_fail() {
    echo -e "  [${RED}FAIL${NC}] $1"
    ((fail_count++))
}

echo -e "\n${CYAN}================================================================${NC}"
echo -e "${CYAN}        IK2215 ISP-102 Automated Health & Compliance Check      ${NC}"
echo -e "${CYAN}================================================================${NC}\n"

# ------------------------------------------------------------------------------
# 1. Check Dummy0 Interfaces
# ------------------------------------------------------------------------------
echo -e "${YELLOW}>>> 1. Checking dummy0 Logical Interfaces on Routers...${NC}"
for r in as102r1 as102r2 as102r3 as102r4; do
    ip_out=$(kathara exec "$r" -- ip addr show dummy0 2>/dev/null)
    if echo "$ip_out" | grep -q "1.102.4."; then
        report_pass "$r: dummy0 exists and has IP assigned"
    else
        report_fail "$r: dummy0 is MISSING or does NOT have IP"
    fi
done

# ------------------------------------------------------------------------------
# 2. Check OSPF Adjacency and Routes
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> 2. Checking OSPF Neighbors and Default Route...${NC}"
r1_ospf_neighbors=$(kathara exec as102r1 -- vtysh -c "show ip ospf neighbor" 2>/dev/null)
for peer in "1.102.3.1" "1.102.3.3" "1.102.3.4"; do
    if echo "$r1_ospf_neighbors" | grep -q "$peer.*Full"; then
        report_pass "as102r1 OSPF adjacency with $peer is Full"
    else
        report_fail "as102r1 OSPF adjacency with $peer is NOT Full"
    fi
done

# Check default route in r3 and r4 pointing to R1 (primary)
r3_route=$(kathara exec as102r3 -- vtysh -c "show ip route 0.0.0.0/0" 2>/dev/null)
if echo "$r3_route" | grep -q "1.102.3.2"; then
    report_pass "as102r3 default route correctly points to as102r1 (Primary via 1.102.3.2)"
else
    report_fail "as102r3 default route does NOT point to as102r1"
fi

# Check AS21 redistributed route in r3/r4
if echo "$r3_route_as21" | grep -q "1.102.3.6" || kathara exec as102r3 -- vtysh -c "show ip route 2.21.0.0/20" 2>/dev/null | grep -q "via 1.102.3.6"; then
    report_pass "as102r3 has direct route to AS21 (2.21.0.0/20) via as102r2"
else
    report_fail "as102r3 MISSING route to AS21 (2.21.0.0/20)"
fi

# ------------------------------------------------------------------------------
# 3. Check BGP Sessions (eBGP and iBGP)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> 3. Checking BGP Peering Sessions...${NC}"
r1_bgp=$(kathara exec as102r1 -- vtysh -c "show ip bgp summary" 2>/dev/null)
if echo "$r1_bgp" | grep "1.0.0.4" | grep -qE "([0-9]+)$"; then
    report_pass "as102r1 eBGP with AS1 (1.0.0.4) is Established"
else
    report_fail "as102r1 eBGP with AS1 (1.0.0.4) is NOT Established"
fi

if echo "$r1_bgp" | grep "1.102.4.2" | grep -qE "([0-9]+)$"; then
    report_pass "as102r1 iBGP with as102r2 (1.102.4.2) is Established"
else
    report_fail "as102r1 iBGP with as102r2 (1.102.4.2) is NOT Established"
fi

r2_bgp=$(kathara exec as102r2 -- vtysh -c "show ip bgp summary" 2>/dev/null)
if echo "$r2_bgp" | grep "2.21.0.0" | grep -qE "([0-9]+)$"; then
    report_pass "as102r2 eBGP with AS21 (2.21.0.0) is Established"
else
    report_fail "as102r2 eBGP with AS21 (2.21.0.0) is NOT Established"
fi

# Check that ONLY aggregated prefix 1.102.0.0/20 is advertised to AS1
r1_advertised=$(kathara exec as102r1 -- vtysh -c "show ip bgp neighbor 1.0.0.4 advertised-routes" 2>/dev/null)
if echo "$r1_advertised" | grep -q "1.102.0.0/20" && ! echo "$r1_advertised" | grep -qE "1.102.[1-4]."; then
    report_pass "as102r1 advertises ONLY aggregated prefix 1.102.0.0/20 to AS1"
else
    report_fail "as102r1 leaked more-specific prefixes to AS1"
fi

# ------------------------------------------------------------------------------
# 4. Check DHCP Client IP Allocation
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> 4. Checking DHCP Client Allocation (c1 & c2)...${NC}"
c1_ip=$(kathara exec as102c1 -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [[ "$c1_ip" =~ ^1\.102\.2\. ]]; then
    report_pass "as102c1 obtained DHCP lease: $c1_ip"
else
    report_fail "as102c1 failed to obtain DHCP lease on eth0"
fi

c2_ip=$(kathara exec as102c2 -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
if [[ "$c2_ip" =~ ^1\.102\.2\. ]]; then
    report_pass "as102c2 obtained DHCP lease: $c2_ip"
else
    report_fail "as102c2 failed to obtain DHCP lease on eth0"
fi

# ------------------------------------------------------------------------------
# 5. Check DNS (Forward and Reverse)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> 5. Checking DNS Server (s1) Resolution...${NC}"
# Internal forward
dns_int_fwd=$(kathara exec as102c1 -- dig +short @1.102.1.2 www.isp102.lab 2>/dev/null)
if [[ "$dns_int_fwd" == "1.102.1.3" ]]; then
    report_pass "DNS internal forward lookup (www.isp102.lab -> 1.102.1.3)"
else
    report_fail "DNS internal forward lookup failed (got: '$dns_int_fwd')"
fi

# Internal reverse
dns_int_rev=$(kathara exec as102c1 -- dig +short @1.102.1.2 -x 1.102.1.3 2>/dev/null)
if echo "$dns_int_rev" | grep -q "www.isp102.lab"; then
    report_pass "DNS internal reverse lookup (1.102.1.3 -> www.isp102.lab)"
else
    report_fail "DNS internal reverse lookup failed (got: '$dns_int_rev')"
fi

# External domain forward lookup (recursive via root DNS)
dns_ext_fwd=$(kathara exec as102c1 -- dig +short @1.102.1.2 www.isp1.lab 2>/dev/null)
if [[ "$dns_ext_fwd" =~ ^1\.0\. ]]; then
    report_pass "DNS recursive external forward lookup (www.isp1.lab -> $dns_ext_fwd)"
else
    report_fail "DNS recursive external forward lookup failed (got: '$dns_ext_fwd')"
fi

# External domain reverse lookup
dns_ext_rev=$(kathara exec as102c1 -- dig +short @1.102.1.2 -x 1.0.1.2 2>/dev/null)
if echo "$dns_ext_rev" | grep -q "root"; then
    report_pass "DNS recursive external reverse lookup (1.0.1.2 -> $dns_ext_rev)"
else
    report_fail "DNS recursive external reverse lookup failed (got: '$dns_ext_rev')"
fi

# ------------------------------------------------------------------------------
# 6. Check Web Server (s2)
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> 6. Checking Apache Web Server (s2)...${NC}"
web_content=$(kathara exec as102c1 -- curl -s http://www.isp102.lab/ 2>/dev/null)
if echo "$web_content" | grep -q "ASN: 102" && echo "$web_content" | grep -q "NETWORK: 1.102.0.0/20"; then
    report_pass "Web server (www.isp102.lab) returned correct ASN and NETWORK"
else
    report_fail "Web server response missing required fields or curl failed"
fi

# ------------------------------------------------------------------------------
# 7. Check End-to-End Connectivity
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}>>> 7. Checking End-to-End Internet Connectivity...${NC}"
# Ping Root DNS (in AS1)
if kathara exec as102c1 -- ping -c 2 -W 2 1.0.1.2 >/dev/null 2>&1; then
    report_pass "Client c1 can ping Root DNS (1.0.1.2) via AS1"
else
    report_fail "Client c1 CANNOT ping Root DNS (1.0.1.2)"
fi

# Ping AS21 server (via direct backup peering link)
if kathara exec as102c1 -- ping -c 2 -W 2 2.21.1.1 >/dev/null 2>&1; then
    report_pass "Client c1 can ping AS21 server (2.21.1.1) directly"
else
    report_fail "Client c1 CANNOT ping AS21 server (2.21.1.1)"
fi

# Ping TLD DNS (in AS2)
if kathara exec as102c1 -- ping -c 2 -W 2 2.0.1.2 >/dev/null 2>&1; then
    report_pass "Client c1 can ping TLD DNS (2.0.1.2) in AS2"
else
    report_fail "Client c1 CANNOT ping TLD DNS (2.0.1.2)"
fi

# Curl external web server
if kathara exec as102c1 -- curl -s --max-time 3 http://www.isp1.lab/ >/dev/null 2>&1; then
    report_pass "Client c1 can access external web http://www.isp1.lab/"
else
    report_fail "Client c1 CANNOT access external web http://www.isp1.lab/"
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo -e "\n${CYAN}================================================================${NC}"
echo -e "Total Passed: ${GREEN}$pass_count${NC} | Total Failed: ${RED}$fail_count${NC}"
echo -e "${CYAN}================================================================${NC}\n"
