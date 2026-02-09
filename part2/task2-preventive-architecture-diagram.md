# Part 2, Task 2.2: Preventive Architecture Using Service Control Policies

## SCP-Based Prevention System

This architecture uses AWS Service Control Policies (SCPs) to prevent security group violations from happening in the first place, rather than detecting and fixing them after the fact.

### Architecture Diagram
```mermaid
graph TB
    subgraph ORG_ROOT["AWS Organization Root"]
        MGMT[Management Account<br/>org-master-000]
        
        subgraph SCP_LAYER["Service Control Policy Layer"]
            SCP_DENY_PUBLIC_SG[SCP: DenyPublicSecurityGroups<br/>Blocks: 0.0.0.0/0 and ::/0<br/>Applied to: Workload OUs]
            
            SCP_REQUIRE_APPROVAL[SCP: RequireApprovalWorkflow<br/>Enforces: break-glass tags<br/>Applied to: Production OU]
            
            SCP_PREVENT_GUARDRAIL[SCP: PreventGuardrailBypass<br/>Blocks: SCP detachment<br/>Blocks: OU movement<br/>Applied to: All OUs]
        end
        
        subgraph ORG_STRUCTURE["Organizational Structure"]
            
            subgraph WORKLOAD_OU["Workload OU"]
                PROD_OU[Production OU<br/>───────<br/>Inherits: DenyPublicSG<br/>+ RequireApprovalWorkflow]
                
                DEV_OU[Development OU<br/>───────<br/>Inherits: DenyPublicSG<br/>Relaxed: approval not required]
                
                subgraph PROD_ACCOUNTS["Production Accounts"]
                    PROD_1[prod-app-001<br/>IAM restricted by SCP]
                    PROD_2[prod-app-002<br/>IAM restricted by SCP]
                    PROD_3[prod-db-001<br/>IAM restricted by SCP]
                end
                
                subgraph DEV_ACCOUNTS["Development Accounts"]
                    DEV_1[dev-app-001<br/>IAM restricted by SCP]
                    DEV_2[dev-test-002<br/>IAM restricted by SCP]
                end
            end
            
            subgraph SECURITY_OU["Security OU<br/>───────<br/>Exempt from deny SCPs"]
                SEC_ACCT[security-ops-999<br/>Break-glass access allowed]
            end
            
            subgraph INFRA_OU["Infrastructure OU<br/>───────<br/>Controlled exceptions"]
                NETWORK_ACCT[network-prod-100<br/>IGW creation allowed<br/>For NAT/Inspection VPC]
            end
        end
        
        subgraph APPROVAL_WORKFLOW["Approved Exception Workflow"]
            
            TICKET[Jira Ticket<br/>Developer requests<br/>public SG exception]
            
            SECURITY_REVIEW[Security Team Review<br/>───────<br/>Validates: business need<br/>Approves: time-bound exception]
            
            BREAK_GLASS[Break-Glass Execution<br/>───────<br/>1. Assume SecurityBreakGlassRole<br/>2. Tag resource: approved-exception=true<br/>3. SCP allows tagged resources]
            
            AUTO_EXPIRE[Auto-Expiration<br/>───────<br/>Lambda removes tag after TTL<br/>Security group reverts to denied]
        end
    end
    
    subgraph ENFORCEMENT_POINTS["How SCPs Enforce Policy"]
        
        subgraph BLOCK_EXAMPLE["❌ Blocked Action Example"]
            DEV_ATTEMPT[Developer in prod-app-001<br/>Attempts: AuthorizeSecurityGroupIngress<br/>CidrIp: 0.0.0.0/0]
            
            IAM_CHECK[IAM evaluates permissions:<br/>1. User policy: ALLOW<br/>2. SCP: DENY<br/>───────<br/>Result: DENY wins]
            
            API_REJECT[AWS API rejects request<br/>Error: Access Denied]
        end
        
        subgraph ALLOW_EXAMPLE["✅ Allowed Action Example"]
            SEC_TEAM[Security team in security-ops-999<br/>Attempts: Same action<br/>Has tag: approved-exception=true]
            
            IAM_CHECK_ALLOW[IAM evaluates permissions:<br/>1. User policy: ALLOW<br/>2. SCP: ALLOW (exempt OU)<br/>───────<br/>Result: ALLOW]
            
            API_SUCCESS[AWS API accepts request<br/>Security group modified]
        end
    end
    
    subgraph MONITORING["Continuous Monitoring"]
        CONFIG[AWS Config Rule<br/>───────<br/>Detects: Untagged public SGs<br/>Alerts: Security Hub]
        
        CLOUDWATCH[CloudWatch Metric<br/>───────<br/>Tracks: SCP deny events<br/>Dashboard: Real-time violations]
        
        EVENTBRIDGE_MONITOR[EventBridge Rule<br/>───────<br/>Pattern: AccessDenied errors<br/>Action: Log to S3 + SNS alert]
    end

    %% Flows
    MGMT --> SCP_LAYER
    SCP_DENY_PUBLIC_SG -.->|Enforces on| PROD_OU
    SCP_DENY_PUBLIC_SG -.->|Enforces on| DEV_OU
    SCP_REQUIRE_APPROVAL -.->|Enforces on| PROD_OU
    SCP_PREVENT_GUARDRAIL -.->|Enforces on| WORKLOAD_OU
    
    PROD_OU --> PROD_ACCOUNTS
    DEV_OU --> DEV_ACCOUNTS
    
    %% Approval workflow
    TICKET --> SECURITY_REVIEW
    SECURITY_REVIEW -->|Approved| BREAK_GLASS
    BREAK_GLASS --> SEC_ACCT
    BREAK_GLASS -.->|Tags resource| PROD_1
    AUTO_EXPIRE -.->|Removes tag after 24h| PROD_1
    
    %% Enforcement examples
    PROD_1 -->|Attempts modification| DEV_ATTEMPT
    DEV_ATTEMPT --> IAM_CHECK
    IAM_CHECK --> API_REJECT
    
    SEC_ACCT -->|Approved exception| SEC_TEAM
    SEC_TEAM --> IAM_CHECK_ALLOW
    IAM_CHECK_ALLOW --> API_SUCCESS
    
    %% Monitoring
    API_REJECT -.->|Logs deny| EVENTBRIDGE_MONITOR
    EVENTBRIDGE_MONITOR --> CLOUDWATCH
    PROD_1 -.->|Config evaluates| CONFIG
    
    %% Styling
    style SCP_DENY_PUBLIC_SG fill:#ff6b6b,stroke:#c92a2a,stroke-width:4px,color:#fff
    style SCP_REQUIRE_APPROVAL fill:#ff8787,stroke:#e03131,stroke-width:3px
    style SCP_PREVENT_GUARDRAIL fill:#fa5252,stroke:#c92a2a,stroke-width:3px
    style IAM_CHECK fill:#ffd43b,stroke:#f08c00,stroke-width:3px
    style API_REJECT fill:#ff6b6b,stroke:#c92a2a,stroke-width:3px
    style API_SUCCESS fill:#51cf66,stroke:#2f9e44,stroke-width:3px
    style SECURITY_REVIEW fill:#74c0fc,stroke:#1971c2,stroke-width:2px
    style BREAK_GLASS fill:#ffd43b,stroke:#f59f00,stroke-width:2px
```

## How It Works

### Policy Enforcement at AWS API Level

Service Control Policies operate at the AWS Organizations level and are evaluated for every API call made within member accounts. When a developer attempts to create a security group rule allowing 0.0.0.0/0, the request flow is:

1. **Developer makes API call:** `aws ec2 authorize-security-group-ingress --cidr 0.0.0.0/0`
2. **IAM evaluates permissions:** Checks user's IAM policies (typically ALLOW)
3. **SCP evaluation:** Checks applicable SCPs from organization hierarchy
4. **Deny wins:** If any SCP denies the action, request is blocked regardless of IAM permissions
5. **API returns error:** `AccessDenied: You are not authorized to perform this operation`

This happens before any AWS resources are modified. The security group rule is never created, preventing the violation rather than detecting and fixing it.

### Organizational Unit (OU) Hierarchy

The OU structure enables policy inheritance:

- **Workload OU:** Parent for all application workloads
  - **Production OU:** Strictest controls (DenyPublicSG + RequireApprovalWorkflow)
  - **Development OU:** Moderate controls (DenyPublicSG only)
- **Security OU:** Exempt from deny policies (break-glass capability)
- **Infrastructure OU:** Controlled exceptions (NAT Gateways legitimately need IGWs)

When a new AWS account is created and placed in the Production OU, it automatically inherits all SCPs attached to Production OU and its parent Workload OU. No per-account configuration required.

### Exception Workflow

For legitimate use cases requiring public security groups (e.g., Application Load Balancers):

1. **Developer submits Jira ticket** explaining business need
2. **Security team reviews** and approves with time-bound exception (24 hours)
3. **Security team assumes break-glass role** in Security OU account
4. **Tags the security group** with `approved-exception=true` and `exception-expires=<timestamp>`
5. **SCP allows modification** because of conditional exception in policy
6. **Lambda function auto-expires tag** after 24 hours, returning to denied state

This provides escape hatch for emergencies while maintaining audit trail and automatic cleanup.

### Monitoring and Alerting

Three layers of monitoring ensure policy effectiveness:

**AWS Config Rules:** Continuously evaluate security groups for compliance, flag any with 0.0.0.0/0 that lack approval tags

**CloudWatch Metrics:** Track SCP denial events via CloudTrail logs, alert when denial rate spikes (potential attack or misconfiguration)

**EventBridge Rules:** Pattern-match AccessDenied errors caused by SCPs, log to S3 for audit trail and send SNS alerts

Unlike reactive remediation which reports "we fixed a problem," preventive monitoring reports "we blocked an attempted violation." This shifts the security narrative from incident response to threat prevention.

## Key Design Decisions

**Why SCPs over reactive remediation alone?**

SCPs prevent violations at API level before they can occur. Reactive remediation still allows a 30-60 second window where the violation exists. For publicly accessible security groups, that window is exploitable.

**Why OU-based instead of account-based policy attachment?**

Scales to 500+ accounts. New account placed in appropriate OU inherits all policies automatically. No per-account SCP management.

**Why break-glass role in separate Security OU?**

Separation of duties. Even if attacker compromises a production account with admin permissions, they cannot modify SCPs or move the account out of the protected OU. Only the Security OU (different IAM boundary, different MFA requirements) can perform break-glass actions.

**Why time-bound exceptions with auto-expiration?**

Prevents "temporary" exceptions from becoming permanent. Forces periodic re-validation of business need. Exceptions expire automatically even if humans forget to remove them.

## Validation

✅ **Diagram renders in Mermaid Live Editor**  
✅ **Shows complete SCP enforcement flow**  
✅ **Includes OU hierarchy and policy inheritance**  
✅ **Exception workflow clearly documented**  
✅ **Monitoring and alerting architecture visible**