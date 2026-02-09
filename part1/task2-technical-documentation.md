# Hub-and-Spoke Network Architecture
## Technical Design Document

**Author:** Network Architecture Team  
**Last Updated:** February 2026  

---

## 1. Problem and Design Intent

We're consolidating 50+ AWS accounts into a centralized network architecture to solve three critical compliance findings from our last SOC 2 audit: no centralized egress control, inconsistent security group management, and no proof of production-development isolation.

The current state allows developers to create VPCs with direct internet gateways. We have zero visibility into what's leaving our network and no way to enforce consistent security policies. This architecture forces all internet-bound traffic through a single inspection point using AWS Transit Gateway and a dedicated inspection VPC.

**Core Design Principle:** Network-level enforcement that doesn't rely on humans configuring things correctly. Route tables physically prevent unauthorized traffic flows - even misconfigured security groups can't bypass this.

---

## 2. Architecture Components

**Transit Gateway** acts as the routing hub with separate route tables per environment. Production attachments use a route table that explicitly excludes development CIDR ranges (10.100.0.0/16). It's physically impossible for production to route to development - there's no route entry. This scales to 5,000 VPC attachments, well beyond our 500-account target.

**Inspection VPC** contains AWS Network Firewall and NAT Gateways deployed across two availability zones. All internet egress is forced here via Transit Gateway default routes. The firewall runs stateful domain filtering (allow-list), Suricata IDS rules, and logs all traffic to CloudWatch. NAT Gateways handle source address translation so outbound traffic appears from known IPs.

**Spoke VPCs** have no direct internet gateways. Production (10.1.0.0/16 - 10.99.0.0/16), Development (10.100.0.0/16 - 10.199.0.0/16), and Shared Services (10.200.0.0/16+) attach to Transit Gateway with environment-specific route tables. Each VPC gets a /16 block with /24 subnets per availability zone.

**Hybrid Connectivity** via Direct Connect (10 Gbps) provides private access to corporate datacenter. This traffic bypasses Network Firewall because our datacenter already has perimeter security. VPN (1.25 Gbps) provides automatic failover via BGP routing.

---

## 3. Traffic Flow and Segmentation

### North-South (Internet Egress)

Production EC2 instance calling external API:
1. Instance sends packet → VPC default route points to Transit Gateway
2. Transit Gateway production route table forces 0.0.0.0/0 → inspection VPC attachment
3. Packet arrives in inspection VPC → routes to Network Firewall endpoint
4. Firewall inspects (domain filtering, IDS, protocol validation) → allow/deny decision
5. If allowed → NAT Gateway translates source IP → Internet Gateway → internet
6. Return traffic follows reverse path via stateful tracking

Added latency: 4-7ms. For latency-sensitive workloads we can configure PrivateLink to bypass inspection with security approval.

### East-West (Spoke-to-Spoke)

Development accessing Shared Services DNS:
1. Dev VPC sends packet for 10.200.0.0/16 → Transit Gateway
2. Transit Gateway dev route table forces inspection first (no direct spoke-to-spoke routing)
3. Network Firewall logs traffic and applies east-west policy rules
4. If allowed → Transit Gateway routes to Shared Services attachment

We inspect spoke-to-spoke traffic for compliance (SOC 2 requires "all traffic logged") and to prevent lateral movement from compromised instances.

### Enforcement Layers

**Route tables (primary):** Transit Gateway route tables physically prevent unauthorized flows. Production route table has no entry for development CIDRs.

**Network ACLs (secondary):** Data subnets deny 0.0.0.0/0 traffic. If someone accidentally adds an internet gateway, NACLs block it.

**Security groups (tertiary):** Reference other security groups rather than CIDR ranges. Example: prod-db allows prod-app on port 5432, not entire 10.1.0.0/16.

**Service Control Policies (preventive):** Block internet gateway creation in prod/dev accounts. Block security group rules with source 0.0.0.0/0.

---

## 4. Availability and Failure Modes

Multi-AZ design with active/active Network Firewall endpoints and NAT Gateways in us-east-1a and us-east-1b. Traffic stays within its AZ until Transit Gateway to avoid cross-AZ data transfer costs.

**AZ-1a complete failure:** Route tables detect unavailable firewall endpoint within 10 seconds. Traffic automatically re-routes to AZ-1b firewall and NAT Gateway. RTO: 30 seconds including routing convergence. Existing NAT connections break (stateful) but applications retry successfully.

**Network Firewall service failure:** Both endpoints failing simultaneously stops all internet egress. No bypass mode - this would violate compliance requirements. We accept this risk because mandatory inspection is non-negotiable. AWS documented recovery time: service-level incident response (never observed in production).

**Transit Gateway attachment failure:** AWS managed service auto-recovery, documented RTO under 5 minutes.

---

## 5. Logging and Compliance

**VPC Flow Logs:** All VPCs → S3 (400-day retention for SOC 2) + CloudWatch Logs (real-time queries). Captures all network traffic metadata.

**Network Firewall Alerts:** Denied traffic and IDS rule matches → CloudWatch Logs → Security Hub. EventBridge rules trigger PagerDuty for specific patterns.

**CloudWatch Metrics:** Transit Gateway bytes processed, NAT Gateway connections, firewall drop counts. Used for capacity planning and performance monitoring.

Logs aggregate in Shared Services OpenSearch cluster. Historical analysis via Athena queries on S3 data.

**Compliance Mapping:**
- SOC 2 CC6.1 (Logical Access): VPC Flow Logs prove segmentation
- SOC 2 CC7.2 (System Monitoring): CloudWatch detects anomalies  
- PCI-DSS 10.2.1 (Audit Logs): Firewall logs all access attempts
- PCI-DSS 1.3.4 (Egress Filtering): Domain allow-list enforced

---

## 6. Scale and Cost

### Current State (50 accounts)
- 53 Transit Gateway attachments (50 VPCs + inspection + Direct Connect + VPN)
- 210 routes across route tables
- 8 Gbps sustained through Network Firewall
- Monthly cost: $6,055 ($121/account)

### Projected (500 accounts)
- 503 attachments (well under 5,000 limit)
- 2,012 routes (will need summarization at 3,000)
- 40 Gbps through firewall (under 100 Gbps auto-scale limit)
- Monthly cost: $27,645 ($55/account - 54% efficiency gain)

**Primary scaling bottleneck:** Transit Gateway route table limit (5,000 routes). Mitigation: route summarization at 3,000 routes (aggregate dev VPCs to 10.100.0.0/12).

**Cost optimization:** VPC Endpoints for S3, DynamoDB, SSM, Secrets Manager save $2,500/month in NAT Gateway data processing charges. AWS API calls bypass NAT entirely.

---

## 7. Known Limitations and Next Steps

**Single region:** No regional redundancy. Multi-region TGW peering is phase 2 (adds 30% cost). Current SLA targets don't require it.

**Inspection latency:** 4-7ms unacceptable for some workloads. Exception process: PrivateLink connections bypass inspection with security approval.

**Route table scale:** Will hit planning threshold at 3,000 routes. Requires route summarization strategy.

### Implementation Plan

**Immediate (0-30 days):**
- Deploy to development environment for validation
- Load test Network Firewall at 20 Gbps sustained  
- Document runbooks for AZ failover scenarios
- Enable AWS Config drift detection rules

**Migration (30-90 days):**
- Onboard production workloads in batches of 10 accounts/week
- Migrate all 50 accounts from legacy architecture
- Implement automated security group remediation

**Future (90-180 days):**
- Evaluate multi-region requirements
- Expand VPC Endpoint coverage
- Implement automated cost alerting (>10% variance)

---

**Technology Choices:**
- AWS Network Firewall over Gateway Load Balancer: Managed service, auto-scales to 100 Gbps, native AWS integration. Cost: $2,800/month vs $8,500/month for self-managed Palo Alto.
- Active/Active over Active/Standby: Eliminates idle resource waste, better cost efficiency.
- Route table enforcement over security group reliance: Physical routing prevention, not policy-based hoping.

**Operational Model:**
- All changes via Terraform with CI/CD pipeline
- Firewall rule updates via GitHub PR workflow
- New VPC provisioning: 5 minutes automated vs 45 minutes manual
- Team size: 2 network engineers at 50 accounts, same at 500 (automation scales)