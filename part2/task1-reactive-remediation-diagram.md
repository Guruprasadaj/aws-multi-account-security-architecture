graph TB
    subgraph AWS_ACCOUNTS["AWS Organization (50+ Accounts)"]
        subgraph WORKLOAD_ACCT["Workload Account (prod-app-123)"]
            EC2[EC2 Instance]
            SG[Security Group<br/>sg-0abc123]
            CLOUDTRAIL_LOCAL[CloudTrail<br/>Local Trail]
        end
        
        subgraph WORKLOAD_ACCT2["Workload Account (dev-app-456)"]
            EC2_2[EC2 Instance]
            SG_2[Security Group<br/>sg-0def456]
            CLOUDTRAIL_LOCAL2[CloudTrail<br/>Local Trail]
        end
    end
    
    subgraph SECURITY_ACCOUNT["Security Account (security-ops-999)"]
        
        subgraph DETECTION["Detection Layer"]
            CLOUDTRAIL_ORG[CloudTrail<br/>Organization Trail<br/>Logs to S3]
            EVENTBRIDGE[EventBridge Rule<br/>Pattern: AuthorizeSecurityGroupIngress<br/>Filter: CidrIp = 0.0.0.0/0]
        end
        
        subgraph REMEDIATION["Remediation Layer"]
            LAMBDA[Lambda Function<br/>security-group-remediator<br/>Runtime: Python 3.12<br/>Timeout: 60s]
            
            subgraph LAMBDA_LOGIC["Remediation Logic"]
                VALIDATE[1. Validate Event<br/>Extract: account, region, sg-id, rule]
                CHECK_WHITELIST[2. Check Whitelist<br/>DynamoDB lookup:<br/>Is this SG exempt?]
                ASSUME_ROLE[3. Assume Cross-Account Role<br/>sts:AssumeRole<br/>SecurityRemediationRole]
                REVOKE_RULE[4. Revoke Rule<br/>ec2:RevokeSecurityGroupIngress<br/>Remove 0.0.0.0/0 rule]
                TAG_SG[5. Tag Security Group<br/>remediation-timestamp<br/>original-rule-details]
            end
        end
        
        subgraph NOTIFICATION["Notification Layer"]
            SNS[SNS Topic<br/>security-violations]
            SLACK[Slack Webhook<br/>#security-alerts]
            SECURITYHUB[Security Hub<br/>Custom Finding]
        end
        
        subgraph AUDIT["Audit Layer"]
            DYNAMODB[DynamoDB Table<br/>remediation-log<br/>Partition Key: account-id<br/>Sort Key: timestamp]
            S3_EVIDENCE[S3 Bucket<br/>remediation-evidence<br/>Object Lock: Enabled<br/>Retention: 7 years]
        end
    end
    
    subgraph IAM_ROLES["Cross-Account IAM"]
        LAMBDA_ROLE[Lambda Execution Role<br/>Can assume roles in all accounts]
        REMEDIATION_ROLE[SecurityRemediationRole<br/>Exists in each workload account<br/>Trusts Security Account]
    end

    %% Flow: Security Group Modified
    EC2 -.->|Developer modifies| SG
    SG -->|AuthorizeSecurityGroupIngress<br/>CidrIp: 0.0.0.0/0| CLOUDTRAIL_LOCAL
    CLOUDTRAIL_LOCAL -->|API Event| CLOUDTRAIL_ORG
    
    %% Flow: Detection
    CLOUDTRAIL_ORG -->|S3 Event Notification| EVENTBRIDGE
    EVENTBRIDGE -->|Event Pattern Match| LAMBDA
    
    %% Flow: Remediation
    LAMBDA --> VALIDATE
    VALIDATE --> CHECK_WHITELIST
    CHECK_WHITELIST -->|Not Whitelisted| ASSUME_ROLE
    ASSUME_ROLE -->|Cross-Account Access| REMEDIATION_ROLE
    REMEDIATION_ROLE --> REVOKE_RULE
    REVOKE_RULE --> TAG_SG
    TAG_SG --> SG
    
    %% Flow: Notification
    LAMBDA --> SNS
    SNS --> SLACK
    SNS --> SECURITYHUB
    
    %% Flow: Audit Trail
    LAMBDA --> DYNAMODB
    LAMBDA --> S3_EVIDENCE
    
    %% Styling
    style EVENTBRIDGE fill:#ff6b6b,stroke:#c92a2a,stroke-width:3px
    style LAMBDA fill:#51cf66,stroke:#2f9e44,stroke-width:3px
    style REVOKE_RULE fill:#ffd43b,stroke:#f08c00,stroke-width:3px
    style DYNAMODB fill:#74c0fc,stroke:#1971c2,stroke-width:2px
    style SNS fill:#ff8787,stroke:#fa5252,stroke-width:2px