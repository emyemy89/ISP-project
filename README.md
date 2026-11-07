# ISP Network Implementation (AS102)

This project was developed as part of the course **IK2215 Advanced Internetworking** at **KTH Royal Institute of Technology**.

### Overview & How It Works
- **What it is**: A fully functional virtual Internet Service Provider (ISP 102) integrated into an emulated multi-AS Internet topology with client and server infrastructures.
- **Routing**: 
  - **Internal (IGP)**: OSPF with tuned link costs to enforce deterministic, redundant failover paths without ECMP.
  - **External (BGP)**: eBGP connecting to an upstream Tier-1 provider (AS1) and private peer (AS21), paired with internal iBGP, route maps, community tags, and `/20` prefix aggregation.
- **Network Services**: Hosted authoritative DNS (BIND 9), an HTTP Web server (Apache2), and dynamic host configuration via an ISC DHCP server and relay.

### Tools & Technologies
- **Emulation**: [Kathará](https://www.kathara.net/) (container-based network emulation)
- **Routing Engine**: FRRouting (FRR)
- **Services**: BIND 9, Apache HTTP Server, ISC DHCP Suite

