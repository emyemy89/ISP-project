"""Focused regressions for the currently observed AS102 failures.

Called by guideline_audit.py, which owns the lock, signals, and final cleanup.
"""


def run_cases(audit) -> None:
    audit.services()
    audit.igp_baseline()

    audit.section("Focused regression: R1-R2 internal link (L12)")
    try:
        audit.link("as102r1", "eth1", "down")
        converged = audit.wait_ospf(8, 70)
        audit.check("CASE.L12.ospf", converged, "8 Full adjacency entries after L12 down")
        if converged:
            audit.check("CASE.L12.internal", audit.ping("as102c1", "1.102.1.2"),
                        "client still reaches the server network")
            audit.check("CASE.L12.internet", audit.wait_ping("as102c1", "1.0.1.2", 20),
                        "client reaches AS1 after IGP reconvergence")
        else:
            audit.skip("CASE.L12.reachability", "OSPF did not converge")
    finally:
        if ("as102r1", "eth1") in audit.links_down:
            audit.link("as102r1", "eth1", "up")
    audit.check("CASE.L12.restore", audit.wait_ospf(10, 70),
                "all 10 OSPF adjacencies restored")

    audit.section("Focused regression: R2 physically unavailable")
    try:
        for interface in ("eth0", "eth1", "eth2"):
            audit.link("as102r2", interface, "down")
        converged = audit.wait_ospf(6, 70)
        audit.check("CASE.R2.ospf", converged, "6 Full adjacency entries without R2")
        next_hops = audit.active_next_hops("as102r4", "0.0.0.0/0") if converged else []
        if next_hops == ["1.102.3.5"]:
            audit.check("CASE.R2.default", True, f"R4 default via R1: {next_hops}")
        else:
            audit.warn("CASE.R2.default", f"R4 default should reach R1; actual {next_hops}")
        reachable = (audit.wait_ping("as102c1", "2.21.1.1", 240)
                     if next_hops else audit.ping("as102c1", "2.21.1.1"))
        audit.check("CASE.R2.transit", reachable,
                    f"client reaches AS21 via AS1 with R2 down; R4 default {next_hops}")
        if reachable:
            def check_path():
                hops = audit.trace("as102c1", "2.21.1.1")
                return "1.0.0.4" in hops, f"AS1 path to AS21: {hops}"
            audit.probe("CASE.R2.path", check_path)
    finally:
        for interface in ("eth2", "eth1", "eth0"):
            if ("as102r2", interface) in audit.links_down:
                audit.link("as102r2", interface, "up")
    audit.check("CASE.R2.ospf_restore", audit.wait_ospf(10, 70),
                "all 10 OSPF adjacencies restored")
    audit.check("CASE.R2.bgp_restore",
                audit.wait_bgp("as102r2", "2.21.0.0", 120)
                and audit.wait_bgp("as102r1", "1.102.4.2", 120),
                "AS21 eBGP and R1-R2 iBGP restored")
