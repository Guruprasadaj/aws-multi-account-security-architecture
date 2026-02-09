# Architecture Decisions

This document explains the key architectural choices made in this project and why alternatives were rejected.

## Decision 1: Hub-and-Spoke with Transit Gateway

**What we chose:** Transit Gateway with centralized inspection

**Why not VPC Peering?** 
Doesn't scale. At 50 VPCs you need 1,225 peering connections. No way to do centralized inspection.

**Why not Shared VPC?**
Single failure domain. One VPC outage takes down everything. Doesn't support account isolation for compliance.

**Tradeoff accepted:** 
4-7ms added latency for inspection. Worth it for mandatory security enforcement and compliance.

---

## Decision 2: AWS Network Firewall (Not Palo Alto)

**What we chose:** AWS Network Firewall

**Why not Palo Alto on Gateway Load Balancer?**
- Costs $8,500/month vs $2,800/month for AWS NFW
- We'd have to manage patching, scaling, HA
- Team of 2 network engineers can't support self-managed firewalls at scale

**Tradeoff accepted:**
Less advanced features (no malware sandbox). But we get auto-scaling to 100 Gbps and zero operational overhead.

---

## Decision 3: Two Availability Zones (Not Three)

**What we chose:** Active/Active across 2 AZs

**Why not 3 AZs?**
- Costs 50% more ($965/month vs $643/month)
- Only gains 0.02% availability improvement
- Our customer SLA is 99.9%, which 2 AZs easily meets

**Tradeoff accepted:**
Single AZ failure = 50% capacity reduction temporarily. Acceptable for our traffic levels (8 Gbps baseline, 50 Gbps capacity).

---

## Decision 4: Preventive SCPs Over Reactive-Only

**What we chose:** Service Control Policies + reactive remediation

**Why not just Lambda auto-fix?**
Reactive still has 30-60 second exposure window. SCPs prevent the violation from ever occurring.

**Why not just SCPs?**
Need reactive as backup for edge cases and monitoring. Defense in depth.

**Cost impact:**
SCPs are free. Reactive costs $10K/month in engineer time at scale. SCPs reduce violations by 90%, saving $9K/month.
