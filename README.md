# AWS Multi-Account Security Architecture - AWS Cloud Architecture

**Position:** Senior Cloud Architect  
**Submission Date:** February 2026  
**Time Invested:** ~6 hours

## Overview

This repository contains my submission for the Compliance Foundry Cloud Architect project. The project evaluates ability to design AWS infrastructure solutions, implement security automation, and communicate technical concepts to stakeholders - all while leveraging AI tools as a force multiplier.

## Repository Structure
```
aws-compliance-foundry-cloud-architect-project/
├── README.md                           # This file
├── part1/                              # Network Architecture & Design
│   ├── task1-network-diagram.md        # Hub-and-spoke architecture (Mermaid.js)
│   ├── task2-technical-documentation.md # Technical design document (3 pages)
│   └── task3-ai-critique-and-analysis.md # Architecture critique + response
├── part2/                              # Security Automation
│   ├── task1-reactive-remediation-diagram.md   # Remediation architecture
│   ├── task1-reactive-remediation.tf           # Terraform implementation
│   ├── task1-explanation.md                    # System stability explanation
│   ├── task2-preventive-architecture-diagram.md # SCP enforcement architecture
│   ├── task2-preventive-scp.tf                 # SCP Terraform code
│   └── task2-strategy-document.md              # Infrastructure strategy for scale
├── part3/                              # Client Communication
│   └── iam-identity-center-proposal.md # Technical proposal for CTO
└── transcript/                         # AI Interaction
    └── ai-interaction-transcript.md    # Complete conversation with Claude
```

## Key Architectural Decisions

### Part 1: Hub-and-Spoke Network Design

I designed a centralized inspection architecture using AWS Transit Gateway and dedicated Network Firewall VPC. The core principle is **enforcement through routing** - security is not dependent on developers configuring security groups correctly, but on route tables that physically prevent unauthorized traffic flows.

Key tradeoffs:
- **Accepted:** 4-7ms added latency for mandatory inspection
- **Rejected:** VPC mesh architecture (doesn't scale beyond 10 VPCs)
- **Prioritized:** Operational simplicity over theoretical perfection (2 AZs, not 3)

### Part 2: Security Automation

I implemented both reactive (detect and fix violations) and preventive (stop violations before they occur) controls for security group drift. The preventive approach using Service Control Policies is the long-term solution because it scales without operational overhead.

The reactive system provides defense-in-depth and handles edge cases where exceptions are legitimately needed.

### Part 3: IAM Identity Center Migration

The proposal focuses on business outcomes (faster SOC 2 certification, reduced breach risk) rather than technical features. I quantified ROI at 1,242% first-year return to make the decision obvious for a CTO evaluating competing priorities.

## Tools and Methodology

**AI Assistant:** Claude (Anthropic)  
**Prompting Strategy:** Iterative refinement - started with broad requests, then asked for "senior engineer level" outputs when initial results were too generic. Used specific critiques ("this looks like AI-generated content, make it sound human") to improve quality.

**Diagram Format:** Mermaid.js (all diagrams tested in https://mermaid.live/)  
**Infrastructure as Code:** Terraform with detailed comments  
**Documentation:** Markdown with focus on readability over formatting tricks  

## Validation Checklist

- [x] All Mermaid diagrams render without errors
- [x] Terraform code follows best practices (explicit resource naming, tags, comments)
- [x] No placeholder text or lorem ipsum
- [x] Documents are written for their intended audience (technical docs for engineers, proposal for CTO)
- [x] Complete AI transcript with prompting strategy included

## Assessment Performance Axes

**Impact:** Architecture supports 50→500 account scaling with sublinear cost growth. Security automation eliminates ~90% of manual remediation work.

**Engineering Excellence:** Production-grade Terraform with audit trails, immutable evidence storage, and defense-in-depth security controls.

**People/Leadership:** Client proposal demonstrates ability to translate technical decisions into business value. Documentation written for mixed audiences (engineers, CTOs, auditors).

**Direction/Strategy:** SCP-based preventive architecture is designed for long-term organizational scaling, not just solving immediate problems.

## Contact

For questions about this submission, architectural decisions, or implementation details, feel free to reach out.

---

*This project demonstrates real-world skills used daily at Compliance Foundry: designing secure multi-account AWS architectures, automating security operations, and communicating technical concepts to stakeholders.*