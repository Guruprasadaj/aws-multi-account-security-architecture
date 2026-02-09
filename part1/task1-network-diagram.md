graph TB
    subgraph LEGEND["📋 Design Principles"]
        direction LR
        L1["🔴 Untrusted Zone"]
        L2["🟡 Inspection Zone"]
        L3["🟢 Trusted Zone"]
        L4["⚡ Active/Active"]
        L5["🔒 Enforcement Point"]
    end

    INTERNET((("🌐<br/>Internet<br/>Untrusted")))

    subgraph EDGE["Edge Security Layer (Inspection VPC)"]
        direction TB
        
        IGW["Internet Gateway<br/>───────────<br/>Single Point of Entry/Exit"]
        
        subgraph AZ_1A["Availability Zone 1a ⚡"]
            NAT_1A["NAT Gateway<br/>5 Gbps Burst<br/>$0.045/GB processed"]
            NFW_1A["🔒 Network Firewall<br/>Stateful + IDS/IPS<br/>Auto-scales to 100 Gbps"]
        end
        
        subgraph AZ_1B["Availability Zone 1b ⚡"]
            NAT_1B["NAT Gateway<br/>5 Gbps Burst<br/>$0.045/GB processed"]
            NFW_1B["🔒 Network Firewall<br/>Stateful + IDS/IPS<br/>Auto-scales to 100 Gbps"]
        end
        
        INSPECT_NOTE["⚠️ ENFORCEMENT:<br/>All RFC1918 ↔ Internet<br/>must traverse firewall<br/>───────────<br/>Prevents shadow IT egress"]
    end

    subgraph CORE["Transit Gateway (Routing Fabric)"]
        direction TB
        
        TGW{{"Transit Gateway<br/>───────────<br/>50 Gbps/attachment<br/>5000 routes max<br/>───────────<br/>🔒 Route Table Isolation<br/>enforces segmentation"}}
        
        subgraph ROUTING["Routing Policy Enforcement"]
            RT_PROD["Production RT<br/>───────────<br/>0.0.0.0/0 → Inspection<br/>10.3.0.0/16 → Shared<br/>───────────<br/>NO Dev access"]
            
            RT_DEV["Development RT<br/>───────────<br/>0.0.0.0/0 → Inspection<br/>10.3.0.0/16 → Shared<br/>───────────<br/>NO Prod access"]
            
            RT_SHARED["Shared Services RT<br/>───────────<br/>Receives from ALL<br/>───────────<br/>Hub for DNS/Logs"]
        end
    end

    subgraph WORKLOADS["Application Workload Zone"]
        direction LR
        
        subgraph PROD_VPC["Production VPC<br/>───────────<br/>Account: prod-123456<br/>───────────<br/>🔒 SCPs Prevent<br/>Security Group 0.0.0.0/0"]
            PROD_APP["App Tier<br/>Multi-AZ<br/>───────────<br/>Auto Scaling:<br/>2 → 50 instances"]
            PROD_DB["Data Tier<br/>Multi-AZ<br/>───────────<br/>RDS Aurora<br/>Failover: 30s"]
            
            PROD_APP -.->|"Private only<br/>No internet route"| PROD_DB
        end
        
        subgraph DEV_VPC["Development VPC<br/>───────────<br/>Account: dev-789012<br/>───────────<br/>Cost Controls:<br/>Auto-shutdown 6pm"]
            DEV_WORK["Workloads<br/>Multi-AZ<br/>───────────<br/>Ephemeral:<br/>Nightly rebuild"]
        end
        
        subgraph SHARED_VPC["Shared Services VPC<br/>───────────<br/>Account: platform-345678<br/>───────────<br/>99.99% SLA target"]
            DNS["Route 53<br/>Resolver<br/>───────────<br/>Hybrid DNS"]
            VPC_EP["VPC Endpoints<br/>───────────<br/>S3, DynamoDB<br/>Secrets Manager<br/>───────────<br/>Saves: $2.5k/mo<br/>vs NAT Gateway"]
            LOG_HUB["Log Aggregation<br/>───────────<br/>OpenSearch<br/>400-day retention"]
        end
    end

    subgraph HYBRID["Hybrid Connectivity"]
        DX["Direct Connect<br/>───────────<br/>10 Gbps Dedicated<br/>SLA: 99.99%<br/>───────────<br/>Failover: VPN<br/>1.25 Gbps IPSec"]
        CORP["Corporate DC<br/>192.168.0.0/16<br/>───────────<br/>BGP ASN: 65000"]
    end

    subgraph OBSERVE["Security & Observability"]
        direction TB
        
        FLOW["VPC Flow Logs<br/>───────────<br/>All VPCs → S3<br/>Athena Queries<br/>───────────<br/>Storage: $50/TB/mo"]
        
        ALERTS["Security Hub<br/>───────────<br/>CIS Benchmarks<br/>PCI-DSS Controls<br/>───────────<br/>Auto-remediation<br/>via EventBridge"]
        
        METRICS["CloudWatch<br/>───────────<br/>TGW Packet Loss<br/>NFW Drop Count<br/>NAT Connection Ct<br/>───────────<br/>Alarms: PagerDuty"]
    end

    %% TRAFFIC FLOW 1: Production → Internet (Critical Path)
    PROD_APP ==>|"①<br/>Default Route"| TGW
    TGW ==>|"②<br/>RT forces<br/>inspection"| NFW_1A
    NFW_1A ==>|"③<br/>Stateful<br/>allow/deny"| NAT_1A
    NAT_1A ==>|"④<br/>SNAT to<br/>public IP"| IGW
    IGW ==>|"⑤"| INTERNET

    %% TRAFFIC FLOW 2: Development → Shared (East-West)
    DEV_WORK ==>|"⑥<br/>10.3.0.0/16"| TGW
    TGW ==>|"⑦<br/>Policy:<br/>inspect first"| NFW_1B
    NFW_1B ==>|"⑧<br/>Allow rule"| TGW
    TGW ==>|"⑨<br/>Route to<br/>Shared RT"| DNS

    %% TRAFFIC FLOW 3: On-Prem → Production (Hybrid)
    CORP -->|"⑩<br/>BGP<br/>advertise"| DX
    DX -->|"⑪<br/>Private VIF"| TGW
    TGW -->|"⑫<br/>Prod RT<br/>allows Corp"| PROD_APP

    %% FAILURE MODE: AZ-1a Failure
    NFW_1A -.->|"⚠️ AZ Failure<br/>Traffic fails to<br/>NFW_1B in AZ-1b<br/>───────────<br/>RTO: 30 seconds"| NFW_1B

    %% OBSERVABILITY FLOWS
    PROD_VPC -.->|"Stream"| FLOW
    DEV_VPC -.->|"Stream"| FLOW
    EDGE -.->|"Stream"| FLOW
    NFW_1A -.->|"Alert on<br/>deny rules"| ALERTS
    TGW -.->|"Bytes<br/>processed"| METRICS
    FLOW -.->|"Aggregate"| LOG_HUB

    %% ROUTE TABLE ASSOCIATIONS
    TGW -.->|"Enforces"| RT_PROD
    TGW -.->|"Enforces"| RT_DEV
    TGW -.->|"Enforces"| RT_SHARED

    %% COST OPTIMIZATION
    VPC_EP -.->|"Saves NAT<br/>charges"| PROD_APP
    VPC_EP -.->|"Saves NAT<br/>charges"| DEV_WORK

    %% SECURITY ENFORCEMENT
    RT_PROD -.->|"Prevents<br/>Dev access"| PROD_VPC
    RT_DEV -.->|"Prevents<br/>Prod access"| DEV_VPC
    INSPECT_NOTE -.->|"Mandatory<br/>for all"| NFW_1A

    %% STYLING - Zones
    style LEGEND fill:#f5f5f5,stroke:#9e9e9e,stroke-width:2px
    style INTERNET fill:#ffcdd2,stroke:#c62828,stroke-width:4px
    style EDGE fill:#fff9c4,stroke:#f57f17,stroke-width:3px
    style CORE fill:#e1bee7,stroke:#6a1b9a,stroke-width:3px
    style WORKLOADS fill:#c8e6c9,stroke:#2e7d32,stroke-width:3px
    style HYBRID fill:#bbdefb,stroke:#1565c0,stroke-width:3px
    style OBSERVE fill:#f8bbd0,stroke:#880e4f,stroke-width:3px

    %% STYLING - Critical Components
    style TGW fill:#7b1fa2,stroke:#4a148c,stroke-width:4px,color:#fff,font-weight:bold
    style NFW_1A fill:#388e3c,stroke:#1b5e20,stroke-width:3px,color:#fff,font-weight:bold
    style NFW_1B fill:#388e3c,stroke:#1b5e20,stroke-width:3px,color:#fff,font-weight:bold
    style IGW fill:#1976d2,stroke:#0d47a1,stroke-width:3px,color:#fff
    style PROD_VPC fill:#fbc02d,stroke:#f57f17,stroke-width:2px
    style DEV_VPC fill:#29b6f6,stroke:#01579b,stroke-width:2px
    style SHARED_VPC fill:#ab47bc,stroke:#4a148c,stroke-width:2px
    style INSPECT_NOTE fill:#ffab91,stroke:#d84315,stroke-width:2px

    %% STYLING - Traffic Flows
    linkStyle 0,1,2,3,4 stroke:#d32f2f,stroke-width:4px
    linkStyle 5,6,7,8 stroke:#f57c00,stroke-width:4px
    linkStyle 9,10,11 stroke:#1976d2,stroke-width:4px
```
