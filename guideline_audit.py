#!/usr/bin/env python3
"""Independent, evidence-oriented audit of IK2215 guideline sections 4 and 5.

The checks are for this AS102 lab design. They do not reproduce the private
grading script or its point allocation. Run through test_routing_score.sh.
"""

from __future__ import annotations

import argparse
import fcntl
import ipaddress
import re
import signal
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ASN = 102
OWN = ipaddress.ip_network("1.102.0.0/20")
OWN_PREFIX = str(OWN)
DOMAIN = "isp102.lab"
ROUTERS = tuple(f"as102r{i}" for i in range(1, 5))
SERVERS = tuple(f"as102s{i}" for i in range(1, 4))
CLIENTS = ("as102c1", "as102c2")
NODES = ROUTERS + SERVERS + CLIENTS
EXTERNAL_HOSTS = {
    "as1h2": 1,
    "as2h2": 2,
    "as3h2": 3,
    "as12h1": 12,
    "as21h1": 21,
    "as22h1": 22,
}
ROUTER_IPS = {
    "1.0.0.5": "R1", "1.102.3.0": "R1", "1.102.3.2": "R1",
    "1.102.3.5": "R1", "1.102.4.1": "R1",
    "2.21.0.1": "R2", "1.102.3.1": "R2", "1.102.3.6": "R2",
    "1.102.4.2": "R2",
    "1.102.1.1": "R3", "1.102.3.3": "R3", "1.102.3.7": "R3",
    "1.102.3.8": "R3", "1.102.4.3": "R3",
    "1.102.2.1": "R4", "1.102.3.4": "R4", "1.102.3.9": "R4",
    "1.102.4.4": "R4",
}
LINKS = (
    ("L12", "as102r1", "eth1"),
    ("L13", "as102r1", "eth2"),
    ("L14", "as102r1", "eth3"),
    ("L23", "as102r2", "eth2"),
    ("L34", "as102r3", "eth3"),
)


def compact(value: object, limit: int = 190) -> str:
    text = " ".join(str(value).split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


class Audit:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0
        self.warned = 0
        self.skipped = 0
        self.links_down: list[tuple[str, str]] = []
        self.frr_stopped: list[str] = []
        self.client_ips: dict[str, str] = {}

    def section(self, name: str) -> None:
        print(f"\n==== {name} ====", flush=True)

    def result(self, kind: str, ident: str, detail: object) -> None:
        setattr(self, {"PASS": "passed", "FAIL": "failed", "WARN": "warned", "SKIP": "skipped"}[kind],
                getattr(self, {"PASS": "passed", "FAIL": "failed", "WARN": "warned", "SKIP": "skipped"}[kind]) + 1)
        print(f"  {kind:<4} {ident:<29} {compact(detail)}", flush=True)

    def check(self, ident: str, okay: bool, detail: object) -> bool:
        self.result("PASS" if okay else "FAIL", ident, detail)
        return okay

    def warn(self, ident: str, detail: object) -> None:
        self.result("WARN", ident, detail)

    def skip(self, ident: str, detail: object) -> None:
        self.result("SKIP", ident, detail)

    def probe(self, ident: str, action) -> None:
        try:
            okay, detail = action()
            self.check(ident, bool(okay), detail)
        except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
            self.check(ident, False, f"probe error: {compact(exc)}")

    def command(self, node: str, *argv: str, timeout: int = 45) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["kathara", "exec", node, "--", *argv],
            cwd=ROOT, capture_output=True, text=True, timeout=timeout, check=False,
        )

    def output(self, node: str, *argv: str, timeout: int = 45) -> str:
        result = self.command(node, *argv, timeout=timeout)
        if result.returncode != 0 or result.stdout.startswith(("Error,", "CRITICAL")):
            raise RuntimeError(f"{node} {' '.join(argv)}: {compact(result.stderr or result.stdout)}")
        return result.stdout

    def vty(self, node: str, command: str) -> str:
        result = self.output(node, "vtysh", "--command", command)
        if result.lstrip().startswith("%"):
            raise RuntimeError(f"{node}: {command}: {compact(result)}")
        return result

    def ping(self, node: str, destination: str, seconds: int = 2) -> bool:
        # Kathara 3.7.9 intercepts "-c"; ping -w is a bounded deadline.
        result = self.command(node, "ping", "-n", "-w", str(seconds), "-W", "2", destination)
        return result.returncode == 0 and "bytes from" in result.stdout

    def wait_ping(self, node: str, destination: str, seconds: int) -> bool:
        until = time.monotonic() + seconds
        stable = 0
        while time.monotonic() < until:
            stable = stable + 1 if self.ping(node, destination) else 0
            if stable >= 3:
                return True
            time.sleep(1)
        return False

    def trace(self, node: str, destination: str) -> list[str]:
        output = self.output(
            node, "traceroute", "-n", "--wait=2", "--queries=1", "--max-hops=16",
            destination, timeout=60,
        )
        hops = re.findall(r"(?m)^\s*\d+\s+(\d+(?:\.\d+){3})(?:\s|$)", output)
        if destination not in hops:
            raise RuntimeError(f"{node} -> {destination}: traceroute did not reach target: {compact(output)}")
        return hops

    def logical_path(self, node: str, destination: str, first: str, last: str) -> str:
        path: list[str] = []
        for hop in self.trace(node, destination):
            router = ROUTER_IPS.get(hop)
            if router and (not path or path[-1] != router):
                path.append(router)
        if not path or path[0] != first:
            path.insert(0, first)
        if path[-1] != last:
            path.append(last)
        return "-".join(path)

    def client_ip(self, node: str) -> str:
        output = self.output(node, "ip", "-4", "-o", "addr", "show", "dev", "eth0")
        match = re.search(r"\binet\s+(\d+(?:\.\d+){3})/\d+", output)
        if not match:
            raise RuntimeError(f"{node}: no IPv4 address on eth0")
        return match.group(1)

    def ospf_full(self) -> int:
        return sum(len(re.findall(r"\bFull/", self.vty(node, "show ip ospf neighbor"))) for node in ROUTERS)

    def wait_ospf(self, count: int, seconds: int = 70) -> bool:
        until = time.monotonic() + seconds
        stable = 0
        while time.monotonic() < until:
            stable = stable + 1 if self.ospf_full() == count else 0
            if stable >= 2:
                return True
            time.sleep(1)
        return False

    def wait_bgp(self, node: str, peer: str, seconds: int = 120) -> bool:
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            try:
                if "BGP state = Established" in self.vty(
                    node, f"show bgp neighbors {peer}"
                ):
                    return True
            except RuntimeError:
                pass
            time.sleep(2)
        return False

    def link(self, node: str, interface: str, state: str) -> None:
        self.output(node, "ip", "link", "set", "dev", interface, state)
        item = (node, interface)
        if state == "down" and item not in self.links_down:
            self.links_down.append(item)
        if state == "up" and item in self.links_down:
            self.links_down.remove(item)

    def stop_frr(self, node: str) -> None:
        self.output(node, "systemctl", "stop", "frr")
        if node not in self.frr_stopped:
            self.frr_stopped.append(node)

    def start_frr(self, node: str) -> None:
        self.output(node, "systemctl", "start", "frr")
        if node in self.frr_stopped:
            self.frr_stopped.remove(node)

    def restore(self) -> None:
        for node, interface in list(reversed(self.links_down)):
            try:
                self.link(node, interface, "up")
            except Exception as exc:
                self.check("RESTORE.link", False, f"{node}/{interface}: {compact(exc)}")
        for node in list(reversed(self.frr_stopped)):
            try:
                self.start_frr(node)
            except Exception as exc:
                self.check("RESTORE.frr", False, f"{node}: {compact(exc)}")

    def preflight(self) -> bool:
        self.section("Kathara preflight")
        if not (ROOT / "lab.conf").is_file():
            self.check("ENV.lab", False, "lab.conf missing")
            return False
        missing = []
        for node in NODES + ("as1r1", "as2r1", "as3r1", "as12r1", "as21r1", "as22r1",
                             "as1h1", "as2h2", "as3h2", "as12h1", "as21h1", "as22h1"):
            result = self.command(node, "true", timeout=30)
            if result.returncode != 0:
                missing.append(node)
        return self.check("ENV.devices", not missing,
                          "all required containers running" if not missing else f"not running: {', '.join(missing)}")

    def static_checks(self) -> None:
        self.section("4.2 topology and 5.3 configuration constraints")
        missing = [node for node in NODES if not (ROOT / node).is_dir()
                   or not (ROOT / f"{node}.startup").is_file()]
        self.check("STATIC.nodes", not missing, "all 9 AS102 device folders/startup files" if not missing else missing)
        text = (ROOT / "lab.conf").read_text()
        entries = {}
        for node, index, domain in re.findall(r'(?m)^(as102(?:r[1-4]|s[1-3]|c[1-2]))\[(\d+)\]="([^"]+)"', text):
            entries[(node, int(index))] = domain
        expected_indices = {**{node: set(range(n)) for node, n in zip(ROUTERS, (4, 3, 4, 3))},
                            **{node: {0} for node in SERVERS + CLIENTS}}
        wrong_ports = {node: sorted(i for name, i in entries if name == node)
                       for node, indices in expected_indices.items()
                       if {i for name, i in entries if name == node} != indices}
        self.check("STATIC.interfaces", not wrong_ports,
                   "no template interfaces added/removed" if not wrong_ports else wrong_ports)
        fixed = {("as102r1", 0): "A4", ("as102r2", 0): "H0",
                 ("as102r3", 0): "S1", ("as102r4", 0): "C1"}
        fixed.update({(node, 0): "S1" for node in SERVERS})
        fixed.update({(node, 0): "C1" for node in CLIENTS})
        bad_fixed = [f"{n}[{i}]={entries.get((n, i))}, expected {d}"
                     for (n, i), d in fixed.items() if entries.get((n, i)) != d]
        self.check("STATIC.preassigned", not bad_fixed,
                   "preassigned external/server/client networks retained" if not bad_fixed else bad_fixed)
        domains: dict[str, list[str]] = defaultdict(list)
        for (node, index), domain in entries.items():
            if node in ROUTERS and index > 0:
                domains[domain].append(node)
        bad_links = {domain: peers for domain, peers in domains.items()
                     if len(peers) != 2 or len(set(peers)) != 2}
        self.check("STATIC.point_to_point", bool(domains) and not bad_links,
                   f"{len(domains)} internal router links, all point-to-point" if not bad_links else bad_links)
        bridges = []
        for removed in domains:
            graph: dict[str, set[str]] = {node: set() for node in ROUTERS}
            for domain, peers in domains.items():
                if domain != removed and len(peers) == 2:
                    graph[peers[0]].add(peers[1])
                    graph[peers[1]].add(peers[0])
            seen = {ROUTERS[0]}
            todo = [ROUTERS[0]]
            while todo:
                for peer in graph[todo.pop()] - seen:
                    seen.add(peer)
                    todo.append(peer)
            if len(seen) != len(ROUTERS):
                bridges.append(removed)
        self.check("STATIC.redundancy", bool(domains) and not bridges,
                   "router graph remains connected after any single internal link fails"
                   if not bridges else f"single points of failure: {bridges}")

        router_cfg = {node: (ROOT / node / "etc/frr/frr.conf").read_text() for node in ROUTERS}
        configured: dict[tuple[str, str], ipaddress.IPv4Interface] = {}
        errors = []
        for node, conf in router_cfg.items():
            interface = None
            for line in conf.splitlines():
                if line.startswith("interface "):
                    interface = line.split()[1]
                elif line.strip() == "exit":
                    interface = None
                elif line.strip().startswith("ip address ") and interface:
                    try:
                        configured[(node, interface)] = ipaddress.ip_interface(line.strip().split()[2])
                    except ValueError:
                        errors.append(f"{node}/{interface}: invalid IPv4 CIDR")
            startup = (ROOT / f"{node}.startup").read_text()
            if re.search(r"(?m)^\s*(?:ip\s+addr(?:ess)?\s+add|ifconfig\b|route\s+add\b|ip\s+route\s+add)", startup):
                errors.append(f"{node}: startup configures an address/static route outside FRR")
            if re.search(r"(?m)^\s*(?:ip|ipv6)\s+route\s+", conf):
                errors.append(f"{node}: static route in FRR")
            if node in ROUTERS[2:] and re.search(r"(?m)^\s*router bgp\b", conf):
                errors.append(f"{node}: BGP on r3/r4")
            if node in ROUTERS[:2] and re.search(r"(?m)^\s*network (?:1\.0\.0\.4/31|2\.21\.0\.0/31) area\b", conf):
                errors.append(f"{node}: OSPF enabled on external eth0")
            if re.search(r"(?m)^\s*set weight\b", conf):
                errors.append(f"{node}: forbidden BGP weight")
            for line in conf.splitlines():
                if line.strip().startswith("set community "):
                    if len(re.findall(r"\b\d+:\d+\b", line)) > 1:
                        errors.append(f"{node}: more than one community on a prefix")
        self.check("STATIC.router_rules", not errors,
                   "router IPs via FRR; no static routes, external OSPF, r3/r4 BGP, weight or multi-community"
                   if not errors else errors[:8])

        ip_errors = []
        segments: dict[str, ipaddress.IPv4Network] = {}
        addresses: dict[str, set[ipaddress.IPv4Address]] = defaultdict(set)
        for (node, index), domain in entries.items():
            interface = f"eth{index}"
            cidr = configured.get((node, interface)) if node in ROUTERS else None
            if node in SERVERS:
                startup = (ROOT / f"{node}.startup").read_text()
                match = re.search(r"\bip\s+addr\s+add\s+(\d+(?:\.\d+){3}/\d+)\b", startup)
                if match:
                    cidr = ipaddress.ip_interface(match.group(1))
                else:
                    ip_errors.append(f"{node}: missing ip addr add")
                gateway = re.search(r"\bip\s+route\s+add\s+default\s+via\s+(\d+(?:\.\d+){3})", startup)
                if not gateway:
                    ip_errors.append(f"{node}: missing ip route add default via")
            if node in ROUTERS and cidr is None:
                ip_errors.append(f"{node}/{interface}: no FRR IP address")
            if cidr is None:
                continue
            if (node, index) not in (("as102r1", 0), ("as102r2", 0)) and cidr.ip not in OWN:
                ip_errors.append(f"{node}/{interface}: {cidr.ip} outside {OWN}")
            if domain in segments and segments[domain] != cidr.network:
                ip_errors.append(f"{domain}: inconsistent masks/subnets")
            segments[domain] = cidr.network
            if cidr.ip in addresses[domain]:
                ip_errors.append(f"{domain}: duplicate address {cidr.ip}")
            addresses[domain].add(cidr.ip)
        if configured.get(("as102r1", "eth0")) != ipaddress.ip_interface("1.0.0.5/31"):
            ip_errors.append("r1/eth0 must be 1.0.0.5/31")
        if configured.get(("as102r2", "eth0")) != ipaddress.ip_interface("2.21.0.1/31"):
            ip_errors.append("r2/eth0 must be 2.21.0.1/31")
        if segments.get("S1") is None or ipaddress.ip_address("1.102.1.2") not in addresses["S1"]:
            ip_errors.append("s1 must own 1.102.1.2")
        for (node, interface), cidr in configured.items():
            if interface == "dummy0" and cidr.ip not in OWN:
                ip_errors.append(f"{node}/dummy0 outside {OWN}")
        for domain, network in segments.items():
            for other, other_net in segments.items():
                if domain < other and network.overlaps(other_net):
                    ip_errors.append(f"{domain} {network} overlaps {other} {other_net}")
        self.check("STATIC.address_plan", not ip_errors,
                   f"interface subnets valid, disjoint; all internal/dummy IPs in {OWN}"
                   if not ip_errors else ip_errors[:8])

        client_errors = []
        for node in CLIENTS:
            commands = [line.strip() for line in (ROOT / f"{node}.startup").read_text().splitlines()
                        if line.strip() and not line.lstrip().startswith("#")]
            if commands != ["/sbin/dhclient eth0"]:
                client_errors.append(f"{node}: {commands}")
        self.check("STATIC.client_startup", not client_errors,
                   "each client startup has only /sbin/dhclient eth0" if not client_errors else client_errors)
        service_startups = {node: (ROOT / f"{node}.startup").read_text() for node in SERVERS}
        service_errors = []
        if "systemctl start named" not in service_startups["as102s1"]:
            service_errors.append("s1 must start named via systemctl")
        if re.search(r"\b(?:apache2|isc-dhcp-server)\b", service_startups["as102s1"]):
            service_errors.append("s1 must not run web/DHCP")
        if not any("systemctl start apache2" in service_startups[node] for node in SERVERS[1:]):
            service_errors.append("s2/s3 must run Apache")
        if not any("systemctl start isc-dhcp-server" in service_startups[node] for node in SERVERS[1:]):
            service_errors.append("s2/s3 must run DHCP")
        if "systemctl start isc-dhcp-relay" not in (ROOT / "as102r4.startup").read_text():
            service_errors.append("r4 must start DHCP relay")
        self.check("STATIC.service_placement", not service_errors,
                   "DNS only on s1; Apache/DHCP on s2 or s3; relay on r4"
                   if not service_errors else service_errors)

        redistribution = [(node, line.strip()) for node, conf in router_cfg.items()
                          for line in conf.splitlines() if line.strip().startswith("redistribute bgp")]
        if redistribution:
            safe = False
            if len(redistribution) == 1 and redistribution[0][0] == "as102r2":
                declaration = re.search(r"(?:^|\s)route-map\s+(\S+)$", redistribution[0][1])
                if declaration:
                    conf = router_cfg["as102r2"]
                    map_name = re.escape(declaration.group(1))
                    permit_blocks = re.findall(
                        rf"(?m)^route-map {map_name} permit \d+\n((?:[ \t]+[^\n]*\n)*)", conf)
                    prefix_lists = []
                    for block in permit_blocks:
                        matches = re.findall(r"(?m)^\s+match\s+(.+)$", block)
                        if len(matches) != 1:
                            break
                        match = re.fullmatch(r"ip address prefix-list (\S+)", matches[0])
                        if not match:
                            break
                        prefix_lists.append(match.group(1))
                    else:
                        safe = bool(permit_blocks)
                        for name in prefix_lists:
                            entries = re.findall(
                                rf"(?m)^ip prefix-list {re.escape(name)}(?: seq \d+)? permit (\S+).*$", conf)
                            if not entries or any(prefix != "2.21.0.0/20" for prefix in entries):
                                safe = False
                                break
            self.check("STATIC.bgp_into_igp", safe,
                       "only AS21 aggregate selected for redistribution" if safe else redistribution)
        else:
            self.check("STATIC.bgp_into_igp", True, "no BGP redistribution into IGP")

    def service_active(self, node: str, service: str) -> bool:
        # Kathara's PID 1 is bash; systemctl can say inactive for live daemons.
        process = {
            "named": "named",
            "apache2": "apache2",
            "isc-dhcp-server": "dhcpd",
            "isc-dhcp-relay": "dhcrelay",
        }[service]
        result = self.command(node, "pgrep", "-x", process)
        return result.returncode == 0 and bool(result.stdout.strip())

    def dig(self, node: str, name: str, record: str = "A", server: str | None = None) -> list[str]:
        args = ["dig"]
        if server:
            args.append("@" + server)
        args.extend(["+short", "+time=2", "+tries=1", name, record])
        text = self.output(node, *args)
        return [line.strip().rstrip(".") for line in text.splitlines() if line.strip()]

    def dns_a(self, node: str, name: str, address: str, server: str | None = None) -> bool:
        return address in self.dig(node, name, "A", server)

    def reverse_name(self, address: str) -> str:
        return ".".join(reversed(address.split("."))) + ".in-addr.arpa"

    def services(self) -> None:
        self.section("5.2 DNS, Web, DHCP")
        zones = self.command("as102s1", "named-checkconf", "-z", "/etc/bind/named.conf")
        zone_errors = [line for line in (zones.stdout + zones.stderr).splitlines()
                       if "error" in line.lower() or "failed" in line.lower()
                       or "invalid" in line.lower()]
        zone_valid = self.check("DNS.zone_syntax", zones.returncode == 0,
                   "all BIND zones load successfully" if zones.returncode == 0
                   else zone_errors[:5] or compact(zones.stdout + zones.stderr))
        states = {node: self.service_active(node, "named") for node in SERVERS}
        self.check("DNS.single_server", states == {"as102s1": True, "as102s2": False, "as102s3": False},
                   f"named active states: {states}")
        own_ready = zone_valid and states["as102s1"]
        if not own_ready:
            self.skip("DNS.own_forward", "blocked by invalid zone or missing named process")
        own_names = (("ns", "1.102.1.2"), ("www", "1.102.1.3"), ("dhcpd", "1.102.1.4"))
        for label, address in own_names if own_ready else ():
            self.probe(f"DNS.local.{label}", lambda label=label, address=address:
                       (self.dns_a("as102c1", f"{label}.{DOMAIN}", address),
                        f"{label}.{DOMAIN} -> {address} from c1"))
            for source in EXTERNAL_HOSTS:
                self.probe(f"DNS.external.{source}.{label}",
                           lambda source=source, label=label, address=address:
                           (self.dns_a(source, f"{label}.{DOMAIN}", address),
                            f"{label}.{DOMAIN} -> {address} from {source}"))

        external_names = []
        for host, number in EXTERNAL_HOSTS.items():
            startup = (ROOT / f"{host}.startup").read_text()
            match = re.search(r"\bip\s+addr\s+add\s+(\d+(?:\.\d+){3})/\d+", startup)
            if match:
                external_names.append((number, match.group(1)))
        for number, address in external_names:
            self.probe(f"DNS.forward.AS{number}", lambda number=number, address=address:
                       (self.dns_a("as102c1", f"www.isp{number}.lab", address)
                        and self.dns_a("as102s2", f"www.isp{number}.lab", address),
                        f"client and server resolve www.isp{number}.lab -> {address}"))
            self.probe(f"DNS.reverse.AS{number}", lambda number=number, address=address:
                       (any(name.endswith(".lab") for name in
                            self.dig("as102c1", self.reverse_name(address), "PTR"))
                        and any(name.endswith(".lab") for name in
                                self.dig("as102s2", self.reverse_name(address), "PTR")),
                        f"client and server resolve PTR {address}"))
        if own_ready:
            try:
                answers = self.dig("as102c1", self.reverse_name("1.102.1.2"), "PTR")
                if "ns.isp102.lab" in answers:
                    self.check("DNS.own_reverse_bonus", True, "1.102.1.2 PTR resolves")
                else:
                    self.warn("DNS.own_reverse_bonus", f"optional reverse DNS missing: {answers}")
            except Exception as exc:
                self.warn("DNS.own_reverse_bonus", f"optional reverse DNS probe failed: {compact(exc)}")
        else:
            self.skip("DNS.own_reverse_bonus", "blocked by invalid zone or missing named process")

        names: list[tuple[str, str]] = []
        for index, node in enumerate(ROUTERS, 1):
            output = self.output(node, "ip", "-4", "-o", "addr", "show")
            for interface, address in re.findall(r"\d+:\s+(\S+)\s+inet\s+(\d+(?:\.\d+){3})/\d+", output):
                if interface == "lo":
                    continue
                label = f"r{index}-lo" if interface == "dummy0" else f"r{index}-{interface}"
                names.append((label, address))
        names.extend((label, address) for label, address in
                     (("ns", "1.102.1.2"), ("www", "1.102.1.3"), ("dhcpd", "1.102.1.4")))
        for index, node in enumerate(CLIENTS, 1):
            names.append((f"c{index}", self.client_ip(node)))
        missing_names = []
        for label, address in names if own_ready else ():
            try:
                if not self.dns_a("as102c1", f"{label}.{DOMAIN}", address, "1.102.1.2"):
                    missing_names.append(f"{label} -> {address}")
            except Exception as exc:
                missing_names.append(f"{label}: {compact(exc)}")
        if own_ready:
            self.check("DNS.all_active_ips", not missing_names,
                       f"{len(names)} active router/host IPs have matching A records"
                       if not missing_names else missing_names[:10])
        else:
            self.skip("DNS.all_active_ips", "blocked by invalid zone or missing named process")

        apache = {node: self.service_active(node, "apache2") for node in SERVERS}
        self.check("WEB.placement", not apache["as102s1"] and any(apache[n] for n in SERVERS[1:]),
                   f"Apache active states: {apache}")
        for source in ("as102c1", "as2h2"):
            def web_probe(source=source, pinned=False):
                args = ["curl", "--silent", "--show-error", "--fail", "--max-time", "8"]
                if pinned:
                    args.extend(["--resolve", f"www.{DOMAIN}:80:1.102.1.3"])
                args.append(f"http://www.{DOMAIN}/")
                page = self.output(source, *args)
                fields = ("ASN:", "NETWORK:", "NAME1:", "EMAIL1:", "NAME2:", "EMAIL2:")
                okay = all(field in page for field in fields) and "102" in page and OWN_PREFIX in page
                return okay, f"{source} retrieves page with ASN, network, name and email fields"
            self.probe(f"WEB.direct_{source}", lambda source=source: web_probe(source, True))
            if own_ready:
                try:
                    dns_ok = self.dns_a(source, f"www.{DOMAIN}", "1.102.1.3")
                except (RuntimeError, subprocess.TimeoutExpired):
                    dns_ok = False
                self.check(f"DNS.www_from_{source}", dns_ok, f"www.{DOMAIN} resolves from {source}")
                if dns_ok:
                    self.probe(f"WEB.name_{source}", lambda source=source: web_probe(source, False))
                else:
                    self.skip(f"WEB.name_{source}", "blocked by unresolved web name")
            else:
                self.skip(f"WEB.name_{source}", "blocked by invalid zone or missing named process")

        dhcp = {node: self.service_active(node, "isc-dhcp-server") for node in SERVERS}
        relay = self.service_active("as102r4", "isc-dhcp-relay")
        self.check("DHCP.placement", not dhcp["as102s1"] and any(dhcp[n] for n in SERVERS[1:]) and relay,
                   f"DHCP server states: {dhcp}; r4 relay: {relay}")
        for node in CLIENTS:
            def client_probe(node=node):
                output = self.output(node, "ip", "-4", "-o", "addr", "show", "dev", "eth0")
                ip = self.client_ip(node)
                default = self.output(node, "ip", "-4", "route", "show", "default")
                resolver = self.output(node, "head", "-n", "10", "/etc/resolv.conf")
                okay = (ipaddress.ip_address(ip) in ipaddress.ip_network("1.102.2.0/24")
                        and "dynamic" in output and "via 1.102.2.1" in default
                        and "nameserver 1.102.1.2" in resolver)
                self.client_ips[node] = ip
                return okay, f"{node}: DHCP={ip}, gateway={compact(default)}, DNS={compact(resolver)}"
            self.probe(f"DHCP.{node}", client_probe)
        if len(set(self.client_ips.values())) != len(self.client_ips):
            self.check("DHCP.unique_leases", False, self.client_ips)
        else:
            self.check("DHCP.unique_leases", len(self.client_ips) == 2, self.client_ips)

    def active_next_hops(self, node: str, destination: str) -> list[str]:
        try:
            output = self.vty(node, f"show ip route {destination}")
        except RuntimeError as exc:
            if "Network not in table" in str(exc):
                return []
            raise
        return re.findall(r"(?m)^\s*\*\s+(\d+(?:\.\d+){3}),\s+via\s+\S+", output)

    def ospf_ecmp_summary(self, node: str) -> tuple[bool, str]:
        table = self.vty(node, "show ip route ospf")
        counts: dict[str, int] = {}
        current = None
        for line in table.splitlines():
            route = re.match(r"^O(\S*)\s+(\d+(?:\.\d+){3}/\d+)", line)
            if route:
                current = route.group(2)
                counts[current] = counts.get(current, 0) + ("*" in route.group(1))
            elif current and re.match(r"^\s+\*\s+\d", line):
                counts[current] += 1
            elif not line.strip():
                current = None
        multiple = {prefix: count for prefix, count in counts.items() if count > 1}
        selected = sum(count > 0 for count in counts.values())
        return bool(selected) and not multiple, (
            f"{node}: {selected} selected OSPF prefixes, ECMP={multiple}"
        )

    def igp_baseline(self) -> None:
        self.section("5.1.1 IGP baseline and default route")
        self.probe("IGP.neighbors", lambda: (self.ospf_full() == 10,
                   f"Full adjacency entries: {self.ospf_full()}/10"))
        lsa = self.vty("as102r3", "show ip ospf database external")
        pairs = re.findall(
            r"Link State ID:\s+(\d+(?:\.\d+){3}).*?Advertising Router:\s+(\d+(?:\.\d+){3})",
            lsa, flags=re.S,
        )
        defaults = {router for network, router in pairs if network == "0.0.0.0"}
        self.check("IGP.default_present", bool(defaults),
                   f"IGP default origin(s): {sorted(defaults)}")
        if "1.0.0.5" in defaults:
            self.check("IGP.R1_default_origin", True, "R1 originates a default LSA")
        else:
            self.warn("IGP.R1_default_origin", "R1 does not originate default; test R2 outage for impact")
        self.check("IGP.backup_default", "2.21.0.1" in defaults,
                   f"R2 backup default origin; actual ASBRs: {sorted(defaults)}")
        forbidden = sorted({network for network, _ in pairs if network not in ("0.0.0.0", "2.21.0.0")})
        self.check("IGP.no_bgp_leak", not forbidden,
                   "only default and AS21 aggregate are external LSAs" if not forbidden else forbidden)
        for node, expected in (("as102r3", "1.102.3.2"), ("as102r4", "1.102.3.5")):
            hops = self.active_next_hops(node, "0.0.0.0/0")
            if hops == [expected]:
                self.check(f"IGP.default_{node}", True, f"direct next hop to R1: {hops}")
            else:
                self.warn(f"IGP.default_{node}",
                          f"next hop {hops}, not direct R1 {expected}; dataplane decides policy")
        for node in ROUTERS:
            self.probe(f"IGP.no_ecmp.{node}",
                       lambda node=node: self.ospf_ecmp_summary(node))

    def primary_paths(self) -> None:
        self.section("5.1.1 deterministic primary paths, both directions")
        client = self.client_ip("as102c1")
        cases = (
            ("r1_client", "as102r1", client, "R1", "R4", "R1-R4"),
            ("client_r1", "as102c1", "1.102.4.1", "R4", "R1", "R4-R1"),
            ("r1_server", "as102r1", "1.102.1.2", "R1", "R3", "R1-R3"),
            ("server_r1", "as102s1", "1.102.4.1", "R3", "R1", "R3-R1"),
            ("r2_client", "as102r2", client, "R2", "R4", "R2-R1-R4"),
            ("client_r2", "as102c1", "1.102.4.2", "R4", "R2", "R4-R1-R2"),
            ("r2_server", "as102r2", "1.102.1.2", "R2", "R3", "R2-R3"),
            ("server_r2", "as102s1", "1.102.4.2", "R3", "R2", "R3-R2"),
            ("client_server", "as102c1", "1.102.1.2", "R4", "R3", "R4-R3"),
            ("server_client", "as102s1", client, "R3", "R4", "R3-R4"),
        )
        for label, node, destination, first, last, expected in cases:
            self.probe(f"PATH.{label}", lambda node=node, destination=destination,
                       first=first, last=last, expected=expected:
                       (self.logical_path(node, destination, first, last) == expected,
                        f"{node} -> {destination}: expected {expected}"))

    def igp_disruptions(self) -> None:
        self.section("5.1.1 each internal link failure and secondary paths")
        client = self.client_ip("as102c1")
        alternatives = {
            "L12": (("as102r2", client, "R2", "R4", "R2-R3-R4"),
                    ("as102c1", "1.102.4.2", "R4", "R2", "R4-R3-R2")),
            "L13": (("as102r1", "1.102.1.2", "R1", "R3", "R1-R2-R3"),
                    ("as102s1", "1.102.4.1", "R3", "R1", "R3-R2-R1")),
            "L14": (("as102r1", client, "R1", "R4", "R1-R3-R4"),
                    ("as102c1", "1.102.4.1", "R4", "R1", "R4-R3-R1")),
            "L23": (("as102r2", "1.102.1.2", "R2", "R3", "R2-R1-R3"),
                    ("as102s1", "1.102.4.2", "R3", "R2", "R3-R1-R2")),
            "L34": (("as102c1", "1.102.1.2", "R4", "R3", "R4-R1-R3"),
                    ("as102s1", client, "R3", "R4", "R3-R1-R4")),
        }
        probes = (
            ("as102r1", "1.102.1.2"), ("as102r1", client),
            ("as102r2", "1.102.1.2"), ("as102r2", client),
            ("as102c1", "1.102.1.2"), ("as102c2", "1.102.1.2"),
            ("as102s1", client), ("as102c1", "1.0.1.2"),
            ("as102c1", "2.21.1.1"),
        )
        for label, node, interface in LINKS:
            self.section(f"IGP {label}: {node}/{interface} down")
            try:
                self.link(node, interface, "down")
                self.check(f"IGP.{label}.adjacency", self.wait_ospf(8, 70),
                           f"expected 8 Full entries; observed {self.ospf_full()}")
                for source, destination in probes:
                    self.check(f"IGP.{label}.reach", self.ping(source, destination),
                               f"{source} -> {destination}")
                for router in ROUTERS:
                    self.probe(f"IGP.{label}.ecmp.{router}",
                               lambda router=router: self.ospf_ecmp_summary(router))
                for source, destination, first, last, expected in alternatives[label]:
                    self.probe(f"IGP.{label}.alternate",
                               lambda source=source, destination=destination,
                               first=first, last=last, expected=expected:
                               (self.logical_path(source, destination, first, last) == expected,
                                f"{source} -> {destination}: expected {expected}"))
            except (RuntimeError, subprocess.TimeoutExpired) as exc:
                self.check(f"IGP.{label}.execution", False, compact(exc))
            finally:
                if (node, interface) in self.links_down:
                    self.link(node, interface, "up")
                self.check(f"IGP.{label}.restore", self.wait_ospf(10, 70),
                           f"OSPF restored to {self.ospf_full()}/10 Full entries")

    def best_bgp_path(self, node: str, prefix: str) -> tuple[str, str]:
        output = self.vty(node, f"show bgp ipv4 unicast {prefix}")
        path = ""
        for line in output.splitlines():
            match = re.match(r"^\s+((?:\d+\s+)*\d+),", line)
            if match:
                path = " ".join(match.group(1).split())
            if "valid" in line and "best" in line:
                if not path:
                    raise RuntimeError(f"cannot parse best AS path: {compact(output)}")
                return path, line.strip()
        raise RuntimeError(f"{node}: no best BGP path to {prefix}: {compact(output)}")

    def advertised(self, node: str, peer: str) -> set[str]:
        output = self.vty(node, f"show bgp ipv4 unicast neighbors {peer} advertised-routes")
        prefixes = set()
        for line in output.splitlines():
            fields = line.split()
            if len(fields) > 1 and re.fullmatch(r"\d+(?:\.\d+){3}/\d+", fields[1]):
                prefixes.add(fields[1])
        if not prefixes:
            raise RuntimeError(f"{node}: no advertised routes to {peer}: {compact(output)}")
        return prefixes

    def bgp_policy(self) -> None:
        self.section("5.1.2 BGP sessions, exports, inbound and outbound policy")
        for node, peer in (
            ("as102r1", "1.0.0.4"), ("as102r2", "2.21.0.0"),
            ("as102r1", "1.102.4.2"), ("as102r2", "1.102.4.1"),
        ):
            self.probe(f"BGP.session.{node}.{peer}", lambda node=node, peer=peer:
                       ("BGP state = Established" in self.vty(node, f"show bgp neighbors {peer}"),
                        f"{node} <-> {peer} Established"))
        for node, peer in (("as102r1", "1.0.0.4"), ("as102r2", "2.21.0.0")):
            def export_probe(node=node, peer=peer):
                advertised = self.advertised(node, peer)
                own = {prefix for prefix in advertised if ipaddress.ip_network(prefix).subnet_of(OWN)}
                return own == {OWN_PREFIX}, f"{node} -> {peer}: own prefixes {sorted(own)}"
            self.probe(f"BGP.aggregate.{node}", export_probe)
        self.probe("BGP.no_other_transit_to_AS1", lambda:
                   (self.advertised("as102r1", "1.0.0.4") <= {OWN_PREFIX, "2.21.0.0/20"},
                    f"AS102 -> AS1 exports {sorted(self.advertised('as102r1', '1.0.0.4'))}"))
        expected_own_paths = {
            "as1r1": "102", "as2r1": "1 102", "as3r1": "1 102",
            "as12r1": "1 102", "as22r1": "2 1 102", "as21r1": "102 102",
        }
        for node, expected in expected_own_paths.items():
            self.probe(f"BGP.inbound.{node}", lambda node=node, expected=expected:
                       (self.best_bgp_path(node, OWN_PREFIX)[0] == expected,
                        f"{node} best AS path to {OWN_PREFIX}: expected {expected}, "
                        f"got {self.best_bgp_path(node, OWN_PREFIX)[0]}"))
        self.probe("BGP.AS1_community", lambda:
                   ("localpref 200" in self.best_bgp_path("as1r1", OWN_PREFIX)[1],
                    "AS1 best route to AS102 has local preference 200"))
        for node, prefix, expected in (
            ("as1r1", "2.21.0.0/20", "2 21"),
            ("as21r1", "1.0.0.0/20", "2 1"),
        ):
            self.probe(f"BGP.no_normal_transit.{node}", lambda node=node, prefix=prefix,
                       expected=expected: (self.best_bgp_path(node, prefix)[0] == expected,
                       f"{node} best path to {prefix}: expected {expected}, "
                       f"got {self.best_bgp_path(node, prefix)[0]}"))
        for node, destination, forbidden in (
            ("as102c1", "1.0.1.2", ("2.21.0.0",)),
            ("as102s1", "1.0.1.2", ("2.21.0.0",)),
            ("as102c1", "3.0.1.3", ("2.21.0.0",)),
            ("as102c1", "2.21.1.1", ("1.0.0.4",)),
            ("as21h1", "1.0.1.2", ("1.102.3.1", "2.21.0.1")),
            ("as1h1", "2.21.1.1", ("1.0.0.5",)),
        ):
            self.probe(f"BGP.data_plane.{node}.{destination}",
                       lambda node=node, destination=destination, forbidden=forbidden:
                       (all(hop not in self.trace(node, destination) for hop in forbidden),
                        f"{node} -> {destination} avoids {forbidden}"))

    def bgp_failovers(self) -> None:
        self.section("5.1.2 AS102 and AS21 uplink failures")
        try:
            self.link("as102r1", "eth0", "down")
            internet = self.wait_ping("as102c1", "1.0.1.2", 240)
            self.check("BGP.AS102_backup_reach", internet,
                       "client reaches AS1 through AS21 when R1 uplink is down")
            if internet:
                self.probe("BGP.AS102_backup_path", lambda:
                           (("2.21.0.0" in self.trace("as102c1", "1.0.1.2")),
                            "client trace to AS1 enters AS21"))
        finally:
            if ("as102r1", "eth0") in self.links_down:
                self.link("as102r1", "eth0", "up")
        self.check("BGP.AS102_uplink_restore", self.wait_ping("as102c1", "1.0.1.2", 100),
                   "client Internet connectivity recovered")
        try:
            self.link("as21r1", "eth1", "down")
            internet = self.wait_ping("as21h1", "1.0.1.2", 240)
            self.check("BGP.AS21_backup_reach", internet,
                       "AS21 reaches AS1 through AS102 when AS2 uplink is down")
            if internet:
                self.probe("BGP.AS21_backup_path", lambda:
                           (("2.21.0.1" in self.trace("as21h1", "1.0.1.2")),
                            "AS21 trace to AS1 enters AS102"))
        finally:
            if ("as21r1", "eth1") in self.links_down:
                self.link("as21r1", "eth1", "up")
        self.check("BGP.AS21_uplink_restore", self.wait_ping("as21h1", "1.0.1.2", 130),
                   "AS21 primary connectivity recovered")
        self.probe("BGP.AS21_primary_return", lambda:
                   ("2.21.0.1" not in self.trace("as21h1", "1.0.1.2"),
                    "AS21 stops using AS102 after AS2 uplink restoration"))

    def router_failovers(self) -> None:
        self.section("5.1.2 either border router unavailable; iBGP redundancy")
        try:
            for interface in ("eth0", "eth1", "eth2", "eth3"):
                self.link("as102r1", interface, "down")
            converged = False
            for _ in range(35):
                if self.active_next_hops("as102r4", "0.0.0.0/0") == ["1.102.3.8"]:
                    converged = True
                    break
                time.sleep(2)
            self.check("BGP.R1_igp_converged", converged,
                       "R4 default route moves from R1 to R3")
            recovered = self.wait_ping("as102c1", "1.0.1.2", 240)
            self.check("BGP.R1_offline", recovered,
                       "client Internet connectivity survives all R1 physical links down")
            if recovered:
                def r1_backup_path():
                    hops = self.trace("as102c1", "1.0.1.2")
                    next_hops = self.active_next_hops("as102r2", "1.0.0.0/20")
                    return next_hops == ["2.21.0.0"], (
                        f"R2 routes AS1 via AS21 {next_hops}; trace {hops}")
                self.probe("BGP.R1_offline_path", r1_backup_path)
        finally:
            for interface in ("eth3", "eth2", "eth1", "eth0"):
                if ("as102r1", interface) in self.links_down:
                    self.link("as102r1", interface, "up")
        self.check("BGP.R1_restore", self.wait_ping("as102c1", "1.0.1.2", 100),
                   "client Internet connectivity after R1 interfaces restore")
        self.check("BGP.R1_control_restore", self.wait_ospf(10, 70) and
                   self.wait_bgp("as102r1", "1.0.0.4"), "OSPF and AS1 BGP recovered")
        try:
            for interface in ("eth0", "eth1", "eth2"):
                self.link("as102r2", interface, "down")
            converged = self.wait_ospf(6, 70)
            default_hops = self.active_next_hops("as102r4", "0.0.0.0/0") if converged else []
            if default_hops == ["1.102.3.5"]:
                self.check("BGP.R2_igp_default", True, f"R4 default via R1 {default_hops}")
            else:
                self.warn("BGP.R2_igp_default", f"R4 default should reach R1; actual {default_hops}")
            recovered = (self.wait_ping("as102c1", "2.21.1.1", 240)
                         if default_hops else self.ping("as102c1", "2.21.1.1"))
            self.check("BGP.R2_offline", recovered,
                       "client reaches AS21 via AS1 when R2 routing is offline")
            if recovered:
                self.probe("BGP.R2_offline_path", lambda:
                           ("1.0.0.4" in self.trace("as102c1", "2.21.1.1"),
                            "client reaches AS21 through AS1 while R2 is offline"))
        finally:
            for interface in ("eth2", "eth1", "eth0"):
                if ("as102r2", interface) in self.links_down:
                    self.link("as102r2", interface, "up")
        self.check("BGP.R2_restore", self.wait_ping("as102c1", "2.21.1.1", 100),
                   "client reaches AS21 after R2 interfaces restore")
        self.check("BGP.R2_control_restore", self.wait_ospf(10, 70) and
                   self.wait_bgp("as102r2", "2.21.0.0"), "OSPF and AS21 BGP recovered")
        self.check("BGP.iBGP_before_link", self.wait_bgp("as102r1", "1.102.4.2"),
                   "iBGP re-established after router interfaces restore")
        try:
            self.link("as102r1", "eth1", "down")
            self.check("BGP.iBGP_alt", self.wait_ospf(8, 70) and
                       self.wait_bgp("as102r1", "1.102.4.2"),
                       "iBGP survives R1-R2 direct link failure over R3")
        finally:
            if ("as102r1", "eth1") in self.links_down:
                self.link("as102r1", "eth1", "up")
        self.check("BGP.iBGP_restore", self.wait_ospf(10, 70),
                   "all OSPF adjacencies restored")

    def finish(self) -> int:
        print(f"\nRESULT: PASS={self.passed} FAIL={self.failed} "
              f"WARN={self.warned} SKIP={self.skipped}", flush=True)
        print("Report length, peer review and the live presentation require manual review.")
        return 1 if self.failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", nargs="?", default="all",
                        choices=("all", "quick", "static", "services", "same_path",
                                 "igp_disruption", "bgp_policy", "bgp_transit",
                                 "router_disruption", "problem_cases"))
    args = parser.parse_args()
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    if (ROOT / "ASN").read_text().strip() != str(ASN):
        print(f"ERROR: this audit models AS{ASN}; ASN file differs", file=sys.stderr)
        return 2
    audit = Audit()
    lock = Path("/tmp/ik2215-as102-audit.lock").open("w")
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("ERROR: another routing audit is running", file=sys.stderr)
            return 2
        if args.mode in ("all", "quick", "static"):
            audit.static_checks()
        if args.mode != "static" and audit.preflight():
            if args.mode in ("all", "quick", "same_path", "igp_disruption"):
                audit.igp_baseline()
            if args.mode in ("all", "quick", "same_path"):
                audit.primary_paths()
            if args.mode in ("all", "igp_disruption"):
                audit.igp_disruptions()
            if args.mode in ("all", "quick", "bgp_policy", "bgp_transit"):
                audit.bgp_policy()
            if args.mode in ("all", "bgp_transit"):
                audit.bgp_failovers()
            if args.mode == "problem_cases":
                from problem_cases_audit import run_cases
                run_cases(audit)
            if args.mode in ("all", "router_disruption"):
                audit.router_failovers()
            if args.mode in ("all", "quick", "services"):
                audit.services()
        elif args.mode != "static":
            audit.result("SKIP", "RUNTIME", "start scenario with kathara lstart --noterminals")
    except KeyboardInterrupt:
        audit.warn("INTERRUPTED", "restoring changed links and FRR services")
    except Exception as exc:
        audit.check("AUDIT.unexpected", False, repr(exc))
    finally:
        audit.restore()
        lock.close()
    return audit.finish()


if __name__ == "__main__":
    sys.exit(main())
