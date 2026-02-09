# Operations Guide

Quick reference for common operational scenarios.

## Scenario 1: Availability Zone Fails

**Symptoms:**
- CloudWatch alarm fires for AZ-1a
- Internet traffic slow or timing out

**What happens automatically:**
- Route 53 health checks detect failure
- Transit Gateway routes traffic to healthy AZ-1b
- NAT Gateway in AZ-1b picks up load
- **Failover time: 30 seconds**

**What you do:**
1. Check AWS Health Dashboard for AZ status
2. Verify traffic is flowing (test `curl https://google.com` from prod VPC)
3. Monitor NAT Gateway connections in AZ-1b (should stay under 50,000)
4. Wait for AWS to restore AZ (typically 1-4 hours)

**When to escalate:**
- AZ down for >4 hours → Open AWS Support ticket
- Traffic exceeds 40 Gbps → Deploy 3rd NAT Gateway in AZ-1c

---

## Scenario 2: Production Down - Need Emergency Firewall Rule

**Process:**

1. **Confirm it's a firewall block** (check Network Firewall logs in CloudWatch)

2. **Post in Slack #security:**
```
   @security-oncall P1 INCIDENT
   Prod API down - blocked by firewall
   Need: api.newvendor.com allowed
```

3. **Security team adds temporary rule** (valid 2 hours):
```bash
   # They run this, not you
   aws network-firewall update-rule-group ...
```

4. **Verify service restored:**
```bash
   curl -I https://api.newvendor.com
```

5. **Create Jira ticket** for permanent rule within 24 hours

**SLA:** 15 minutes for emergency approval during business hours

---

## Scenario 3: New AWS Account Needs Network Access

**Steps:**

1. Create account in AWS Organizations console
2. Move account to appropriate OU:
   - Production apps → Production OU
   - Dev/staging → Development OU
3. SCPs apply automatically (no manual config needed)
4. Attach account to Transit Gateway
5. Done - takes 5 minutes

**What gets inherited automatically:**
- Security group 0.0.0.0/0 blocking (via SCP)
- Access to Shared Services VPC (DNS, VPC Endpoints)
- Compliance logging requirements

---

## Scenario 4: Developer Complains "AWS Blocked Me"

**What they see:**
```
Error: Access Denied - service control policy
```

**What happened:**
They tried to create a security group rule with 0.0.0.0/0 (blocked by SCP)

**How to help:**

1. **Check if it's legitimate** (e.g., ALB needing public access on 443)

2. **If legitimate:** Security team tags the security group with `approved-exception=true`

3. **If not legitimate:** Show them the secure alternative:
   - Use VPC Endpoint instead of internet access
   - Use bastion host instead of direct SSH
   - Add specific IP ranges instead of 0.0.0.0/0

**Self-service coming soon:** Developers will be able to request exceptions via portal

---

## Monitoring Dashboards

**CloudWatch Dashboard:** `https://console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=NetworkInfra`

**Key metrics to watch:**
- Transit Gateway bytes processed (alert at >40 Gbps)
- Network Firewall drop count (alert at >1000/hour)
- NAT Gateway active connections (alert at >45,000)

**Security Hub:** Check daily for new findings related to network security
