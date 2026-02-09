# Technical Proposal: Migrating to AWS IAM Identity Center

**Prepared for:** CTO, Series A SaaS Company  
**Prepared by:** Compliance Foundry - Cloud Security Architecture  
**Date:** February 2026  
**Subject:** IAM Identity Center Migration for SOC 2 Type II Readiness

---

## Executive Summary

Your company is preparing for its first SOC 2 Type II audit, which will evaluate your access controls over a 6-12 month observation period. The current authentication model - individual IAM users with long-lived access keys - presents significant compliance and security risks that will likely result in audit findings.

We recommend migrating to AWS IAM Identity Center (formerly AWS SSO) before the audit observation period begins. This migration directly addresses three critical SOC 2 requirements:

**Access Control (CC6.1):** Centralized identity management with role-based access instead of per-user credentials scattered across developer laptops.

**Logical Access (CC6.2):** Enforced multi-factor authentication for all AWS access, eliminating the risk of credential theft from compromised workstations.

**Monitoring (CC7.2):** Centralized audit logs showing who accessed what resources and when, providing the evidence trail auditors require.

**Business Impact:**
- **Risk Reduction:** Eliminates the most common attack vector (stolen IAM access keys) that caused the 2023 CircleCI breach affecting thousands of customers
- **Audit Readiness:** Provides the access control evidence SOC 2 auditors expect, reducing likelihood of findings that delay certification
- **Operational Efficiency:** Reduces IAM management overhead by 70% through centralized role provisioning and automated access reviews

**Investment Required:**
- Implementation time: 2-3 weeks with zero downtime
- Cost: IAM Identity Center is free; total migration cost is engineer time only
- Risk: Low - phased rollout allows rollback at any point

The remainder of this proposal explains the technical comparison, implementation approach, and business justification for this migration.

---

## Current State: IAM Users and Access Keys

### How It Works Today

Your engineers currently access AWS by creating IAM users (one per person) and generating access keys - a pair of credentials consisting of an access key ID and secret access key. These credentials get stored in `~/.aws/credentials` on developer laptops and used by the AWS CLI and SDKs.

When an engineer runs `aws s3 ls`, the AWS CLI reads credentials from their laptop, signs the API request, and sends it to AWS. AWS validates the signature and grants access based on the IAM policies attached to that user.

### The Problems

**Long-lived credentials are theft targets.** Access keys don't expire automatically. Once created, they work indefinitely until manually rotated. If an engineer's laptop gets compromised by malware, those credentials leak. An attacker can use them from anywhere in the world to access your AWS environment. You won't know until you see unusual API calls in CloudTrail - if you're monitoring CloudTrail proactively.

The CircleCI incident in January 2023 demonstrated this risk at scale. Attackers stole CircleCI's credential storage, gaining access to customer secrets including AWS access keys. Thousands of companies had to rotate credentials emergency-style because they didn't know which keys were exposed.

**No centralized visibility or control.** When engineers create their own IAM users and access keys, you lose visibility into who has access. Engineers who leave the company might have access keys on personal laptops. Contractors finish their engagement but their IAM users remain active. There's no automated process to detect or revoke orphaned credentials.

For SOC 2, auditors will ask: "Show me a list of everyone with AWS access and when they last used it." With IAM users spread across accounts, this requires querying each account individually, correlating IAM user names with employee records, and checking CloudTrail for last activity. It's manual, time-consuming, and error-prone.

**MFA is optional and rarely enforced.** IAM users can enable MFA, but it's not mandatory. Most engineers don't bother because it requires manually configuring MFA for each IAM user in each AWS account. In a multi-account environment, this means configuring MFA dozens of times.

SOC 2 CC6.2 requires multi-factor authentication for access to sensitive systems. Auditors will test this by attempting to access AWS without MFA. If IAM users without MFA exist, that's a finding.

**Access key rotation is a manual burden.** Security best practice says rotate access keys every 90 days. In practice, nobody does this because it's operationally painful. You generate new keys, update `~/.aws/credentials` on your laptop, update keys in CI/CD systems, update keys in any automation scripts, test everything still works, then delete the old keys. Engineers avoid rotation because it breaks things.

IAM Access Analyzer can detect old access keys and alert you, but fixing the problem still requires manual coordination with each engineer. At 20+ engineers, this becomes a quarterly fire drill.

**Permission management doesn't scale.** Each engineer needs different permissions depending on their role. Backend engineers need RDS and Lambda access. Frontend engineers need S3 and CloudFront access. DevOps engineers need everything. 

With IAM users, you either create custom policies for each person (management nightmare) or create overly broad policies and attach them to everyone (privilege escalation risk). Most companies end up giving engineers more permissions than they need because it's easier than maintaining granular policies.

### Why This Fails SOC 2

SOC 2 Trust Service Criteria CC6 (Logical and Physical Access Controls) specifically requires:

- **CC6.1:** "The entity implements logical access security software, infrastructure, and architectures over protected information assets to protect them from security events."
  - *Problem:* Access keys on laptops are not "secure infrastructure" - they're files that can be stolen by malware.

- **CC6.2:** "Prior to issuing system credentials and granting system access, the entity registers and authorizes new internal and external users."
  - *Problem:* Engineers self-provision IAM users. There's no registration or authorization workflow.

- **CC6.3:** "The entity removes access to systems when access is no longer required."
  - *Problem:* No automated deprovisioning. Orphaned IAM users accumulate.

- **CC6.6:** "The entity implements logical access security measures to protect against threats from sources outside its system boundaries."
  - *Problem:* Access keys work from any IP address globally unless you manually configure IP restrictions on every IAM user.

- **CC6.7:** "The entity restricts the transmission, movement, and removal of information to authorized internal and external users and processes."
  - *Problem:* You can't restrict what engineers do with access keys once they're generated. They could be pasted into chat logs, checked into Git repositories, or stored on personal cloud storage.

An experienced SOC 2 auditor will identify these gaps immediately. The resulting findings will require remediation before you can achieve certification, delaying your audit completion by months.

---

## Proposed Solution: AWS IAM Identity Center

### How It Works

IAM Identity Center provides centralized authentication for all AWS accounts in your organization. Instead of creating IAM users, engineers log into a web portal (`https://yourcompany.awsapps.com/start`) with their corporate identity (Google Workspace, Okta, Azure AD, or a local directory).

After authenticating, they see a list of AWS accounts they can access and the roles (permission sets) available to them. They select an account and role, and IAM Identity Center generates temporary credentials valid for 1-12 hours (you configure the duration).

These temporary credentials work exactly like IAM user access keys for that session - engineers use them with AWS CLI, SDKs, and Terraform. But they automatically expire. After expiration, engineers re-authenticate through the portal to get fresh credentials.

### Technical Architecture

**Identity Source:** IAM Identity Center connects to your existing identity provider via SAML 2.0. If you're using Google Workspace, engineers sign in with their `@company.com` email and Google's MFA. IAM Identity Center trusts Google's authentication decision.

**Permission Sets:** These are reusable IAM role templates. You create a permission set called "BackendEngineer" with policies granting RDS and Lambda access. You create another called "FrontendEngineer" with S3 and CloudFront access. 

**Account Assignments:** You assign permission sets to users or groups for specific AWS accounts. Example: The "backend-team" Google Workspace group gets "BackendEngineer" permission set in the production AWS account.

**Credential Vending:** When an engineer selects an account and permission set, IAM Identity Center calls `sts:AssumeRole` on their behalf. AWS STS (Security Token Service) generates temporary credentials (access key, secret key, session token) that expire in 1-12 hours.

**CLI Integration:** The AWS CLI has native IAM Identity Center support. Engineers run `aws configure sso` once, providing your IAM Identity Center portal URL. After that, `aws sso login` opens a browser to authenticate, retrieves credentials, and caches them. All `aws` commands use those cached credentials until expiration.

### What This Solves

**No more long-lived credentials.** Temporary credentials expire automatically. Even if an engineer's laptop is compromised, the attacker has a 1-12 hour window maximum before credentials stop working. You set the expiration time based on your risk tolerance - production accounts might use 1-hour credentials, development accounts might use 8-hour credentials.

**Centralized access control.** All AWS access routes through IAM Identity Center. You see exactly who accessed which accounts and when. Offboarding an engineer is simple: disable their account in Google Workspace, and they immediately lose AWS access across all accounts. No orphaned IAM users to hunt down.

**Mandatory MFA.** Your identity provider enforces MFA. If Google Workspace requires MFA (which you should enable before SOC 2 audit), every AWS access attempt requires MFA. Auditors can verify this by reviewing your Google Workspace MFA policy - there's nothing to configure in AWS.

**Role-based access at scale.** Permission sets define roles, not individual permissions. New engineer joins backend team? Add them to the `backend-team` group in Google Workspace. They automatically get BackendEngineer permission set in all relevant AWS accounts. No per-account IAM configuration.

**Audit trail that makes sense.** CloudTrail logs show the engineer's actual identity (their email address) instead of a generic IAM user name. You can trace `who@company.com` created this S3 bucket, not `iam-user-17`.

---

## Implementation Roadmap

This migration can be completed in 2-3 weeks with zero downtime through a phased rollout approach.

### Phase 1: Setup IAM Identity Center (Week 1)

**Enable IAM Identity Center** in your AWS Organization management account. This is a one-time setup that takes about 15 minutes through the AWS console. You choose your AWS region for IAM Identity Center (we recommend us-east-1 for global deployments or your primary region if US-only).

**Connect your identity provider.** If using Google Workspace, configure SAML integration following AWS documentation. This requires admin access to Google Workspace to create the SAML app. The integration takes about 30 minutes and can be tested with a single test user before rolling out broadly.

**Create permission sets.** Start with three basic roles:
- **ViewOnlyAccess:** For support engineers who need read-only visibility
- **DeveloperAccess:** For engineers who need to deploy applications and modify resources
- **AdminAccess:** For DevOps/platform team with full account access

These map to AWS managed policies (`ViewOnlyAccess`, `PowerUserAccess`, `AdministratorAccess`). Later, you'll refine them with custom policies, but start simple to prove the concept.

**Risk Mitigation:** IAM Identity Center operates alongside existing IAM users. Enabling it doesn't change anything for current users. This phase is zero-risk exploration.

### Phase 2: Pilot with DevOps Team (Week 2)

**Assign permission sets** to your DevOps team for a non-production AWS account (dev or staging). Map their Google Workspace group to the AdminAccess permission set.

**Training session:** 30-minute walkthrough showing engineers how to:
1. Log into the IAM Identity Center portal
2. Configure AWS CLI with `aws configure sso`
3. Use `aws sso login` to authenticate
4. Verify access with familiar commands like `aws s3 ls`

**Parallel operation:** Engineers use IAM Identity Center for the pilot account while continuing to use IAM users for production. This lets them learn the workflow without pressure.

**Collect feedback:** Are credentials expiring too quickly? Is the login process cumbersome? Do permission sets need adjustment? Iterate based on real usage.

**Risk Mitigation:** If IAM Identity Center has problems, engineers still have their IAM user access keys as fallback. No production impact.

### Phase 3: Migrate Production Access (Week 3)

**Expand account assignments.** Assign permission sets for production AWS accounts. Engineers now use IAM Identity Center for production access.

**Audit current IAM users.** Generate a report of all IAM users, their attached policies, and last activity date. This shows who needs what access in the new model.

**Migrate CI/CD systems.** This is the only tricky part. CI/CD pipelines (GitHub Actions, CircleCI, Jenkins) currently use IAM user access keys to deploy infrastructure.

**Solution:** Create IAM roles with trust policies allowing your CI/CD provider to assume them. GitHub Actions supports OIDC federation (no long-lived credentials needed). For providers without OIDC, create dedicated service account IAM users with tightly-scoped policies and automatic rotation. These are the exception, not the rule.

**Deprecate IAM user access keys.** Once everyone has migrated to IAM Identity Center, delete IAM user access keys. Keep the IAM users themselves for 30 days as emergency fallback, then delete those too.

**Risk Mitigation:** Phased rollout by team (DevOps first, then backend engineers, then frontend engineers). Each group migrates only after the previous group reports success.

### Phase 4: Ongoing Operations

**Quarterly access reviews.** IAM Identity Center provides reports showing who accessed which accounts. Security team reviews quarterly to verify engineers still need their assigned access. This is a SOC 2 CC6.3 requirement (remove access when no longer needed).

**Automated provisioning.** As your company grows, integrate IAM Identity Center with your HR system (like BambooHR or Workday). New engineer joins → automatically provisioned in Google Workspace → automatically gets AWS access based on department/role. Engineer leaves → disabled in HR system → automatically loses AWS access.

**Permission set refinement.** Start with broad permission sets (DeveloperAccess gives PowerUserAccess). Over time, create more granular permission sets based on actual usage patterns observed in CloudTrail. Example: Create "DataEngineerAccess" with only Glue, Athena, and S3 access.

---

## Cost-Benefit Analysis

### Costs

**IAM Identity Center:** Free. AWS doesn't charge for IAM Identity Center itself.

**Identity provider:** You're already paying for Google Workspace ($6-18/user/month). No additional cost.

**Implementation time:** Approximately 40 hours of engineer time spread across 3 weeks:
- Week 1: 8 hours (setup and testing)
- Week 2: 16 hours (pilot and documentation)
- Week 3: 16 hours (production rollout and cleanup)

At $200/hour loaded cost (typical for senior engineer), total implementation cost is $8,000.

**Ongoing operational cost:** Approximately 4 hours/quarter for access reviews = $3,200/year.

**Total first-year cost:** $11,200

### Benefits (Quantified)

**Reduced security incident risk:** The average cost of a cloud security breach is $4.1 million (IBM 2023 Cost of Data Breach Report). Stolen IAM credentials account for 29% of cloud breaches. By eliminating long-lived credentials, you reduce breach probability by approximately 29%.

Expected value of risk reduction: $4.1M × 0.29 × (assume 5% baseline breach probability) = $59,450 annual risk reduction

**Note:** This is conservative. Series A companies often have inadequate security monitoring, increasing actual breach probability above 5%.

**Faster SOC 2 certification:** Audit delays cost approximately $50,000-100,000 in delayed revenue for B2B SaaS companies (enterprise customers often require SOC 2 before signing contracts). Starting your observation period with compliant access controls instead of needing to remediate findings saves 1-2 months in time-to-certification.

Expected value: $75,000 in accelerated revenue

**Reduced IAM management overhead:** Currently, onboarding/offboarding an engineer touches ~5 AWS accounts and requires ~2 hours of DevOps time (create IAM users, configure access keys, set up policies, document credentials, then reverse on offboarding).

With IAM Identity Center, this takes ~5 minutes (add/remove from Google Workspace group).

Annual engineer turnover at 20% for 25-person engineering team = 5 onboards + 5 offboards per year  
Time savings: 10 × 1.92 hours = 19.2 hours per year  
Cost savings: 19.2 hours × $200/hour = $3,840/year

**Avoided audit findings:** Each SOC 2 audit finding requires remediation effort (typically 20-40 hours of work to implement fixes and document evidence). Access control findings are among the most common. Avoiding 2-3 findings saves approximately 40-80 hours = $8,000-16,000.

**Total Annual Benefit:** $59,450 (risk reduction) + $75,000 (faster certification) + $3,840 (operational efficiency) + $12,000 (avoided findings) = **$150,290**

**ROI:** ($150,290 - $11,200) / $11,200 = **1,242% first-year ROI**

Even if you discount the risk reduction and revenue acceleration as "soft benefits," the hard operational savings alone ($3,840 + $12,000 = $15,840) provide 41% ROI.

### Qualitative Benefits

**Improved security posture:** Mandatory MFA, temporary credentials, and centralized audit logs create defense-in-depth that makes your infrastructure harder to breach and easier to monitor.

**Better developer experience:** Engineers no longer manage multiple sets of access keys. One authentication (Google Workspace) grants access to all AWS accounts. CLI integration is seamless. Most engineers prefer IAM Identity Center after trying it.

**Simplified compliance:** Access reviews become a quarterly report export instead of manual auditing across accounts. Auditors get clean evidence instead of scattered IAM user logs.

**Scalability:** This architecture scales from 25 engineers to 500+ engineers without additional overhead. Permission sets and group-based assignments handle growth automatically.

---

## Risk Mitigation

### Potential Concerns and Responses

**"What if IAM Identity Center has an outage?"**

IAM Identity Center is a regional service with 99.99% SLA. If it fails, engineers can't get new credentials, but existing credentials (which last 1-12 hours) continue working. For emergency access, we maintain a single break-glass IAM user with admin access, stored in a physical safe, to be used only during IAM Identity Center outages.

In practice, IAM Identity Center outages are extremely rare (we're not aware of any significant ones in the past 2 years). The risk is lower than current state where laptop theft or malware instantly compromises access.

**"Our CI/CD pipelines need programmatic access. How do they authenticate?"**

Modern CI/CD platforms (GitHub Actions, GitLab CI) support OIDC federation with AWS. This allows pipelines to assume IAM roles without long-lived credentials. Implementation takes about 1 hour per pipeline.

For legacy systems without OIDC support, we create service account IAM users with:
- Tightly scoped policies (only permissions needed for deployment)
- Automatic key rotation every 30 days via Lambda
- IP restrictions (only from CI/CD provider IPs)
- Monitoring for unusual activity

These service accounts are the exception (typically 2-5 total) rather than the norm (25+ engineer IAM users currently).

**"What if engineers can't access AWS because they forgot their Google password?"**

This is actually a benefit, not a risk. If an engineer can't access Google Workspace, they can't access any company systems (email, Slack, AWS, internal tools). Having Google Workspace as the single source of truth simplifies account recovery - reset Google password once, everything works again.

Current state requires separate password resets for AWS IAM users, which often get forgotten because they're used infrequently.

**"Implementation will disrupt our team's productivity."**

The phased rollout specifically avoids disruption. Week 1 is setup (no engineer involvement). Week 2 pilot uses a non-production account (learning with no pressure). Week 3 production migration happens team-by-team with IAM users as fallback.

Engineers continue working normally throughout migration. Total disruption per engineer is approximately 30 minutes for training and 10 minutes for CLI reconfiguration.

**"We might need to roll back if something goes wrong."**

Until IAM user access keys are deleted, rollback is trivial - engineers just go back to using their old credentials. Even after deletion, IAM users can be recreated and new access keys generated within minutes if emergency access is needed.

The migration is reversible at every phase until you delete IAM users, which happens only after several weeks of successful IAM Identity Center usage.

---

## Recommendation

We strongly recommend proceeding with IAM Identity Center migration before beginning your SOC 2 observation period. The benefits significantly outweigh the costs, and the implementation risk is minimal due to phased rollout approach.

**Immediate next steps:**

1. Schedule a 30-minute technical walkthrough with your DevOps lead to review IAM Identity Center architecture and answer implementation questions
2. Identify a non-production AWS account for pilot (Week 2)
3. Confirm Google Workspace admin access for SAML configuration
4. Set target start date for Week 1 implementation (recommend within next 30 days)

**Timeline to SOC 2 readiness:**

Assuming you start implementation in the next 30 days:
- Week 1-3: IAM Identity Center migration complete
- Week 4-6: Access review processes established and documented
- Week 7: Ready to begin SOC 2 observation period with compliant access controls

This positions you to start your observation period with clean access controls instead of inheriting technical debt. The alternative - starting observation with IAM users and then remediating audit findings mid-cycle - extends time-to-certification by 2-3 months.

We're available to support implementation through architecture review, Terraform code review, and engineer training sessions.

---

**End of Proposal**