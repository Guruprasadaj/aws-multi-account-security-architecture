# terraform/preventive-scp/main.tf
# Service Control Policies for preventive security controls

# ============================================================================
# SCP: Deny Public Security Group Rules
# ============================================================================

resource "aws_organizations_policy" "deny_public_sg" {
  name        = "DenyPublicSecurityGroups"
  description = "Prevents creation of security group rules allowing 0.0.0.0/0 or ::/0"
  type        = "SERVICE_CONTROL_POLICY"
  
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyPublicIngressIPv4"
        Effect = "Deny"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress"
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          # Block if any IP permission contains 0.0.0.0/0
          "ForAnyValue:StringEquals" = {
            "ec2:IpPermissions.Cidr" = ["0.0.0.0/0"]
          }
        }
      },
      {
        Sid    = "DenyPublicIngressIPv6"
        Effect = "Deny"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress"
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          # Block IPv6 equivalent ::/0
          "ForAnyValue:StringEquals" = {
            "ec2:IpPermissions.Cidr" = ["::/0"]
          }
        }
      },
      {
        Sid    = "AllowIfApprovedBySecurityTeam"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress"
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          # Exception: Allow if security group has approved tag
          StringEquals = {
            "aws:ResourceTag/security-exception" = "approved"
          }
          # Exception: Only valid for 24 hours from tag creation
          DateLessThan = {
            "aws:CurrentTime" = "$${aws:PrincipalTag/exception-expires}"
          }
        }
      }
    ]
  })
}

# ============================================================================
# SCP: Prevent Guardrail Bypass
# ============================================================================

resource "aws_organizations_policy" "prevent_bypass" {
  name        = "PreventGuardrailBypass"
  description = "Prevents removal of SCPs or movement of accounts out of protected OUs"
  type        = "SERVICE_CONTROL_POLICY"
  
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "PreventSCPDetachment"
        Effect = "Deny"
        Action = [
          "organizations:DetachPolicy",
          "organizations:DeletePolicy"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:PrincipalOrgID" = data.aws_organizations_organization.current.id
          }
          # Only organization management account can modify SCPs
          ArnNotEquals = {
            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
          }
        }
      },
      {
        Sid    = "PreventOUMovement"
        Effect = "Deny"
        Action = [
          "organizations:MoveAccount"
        ]
        Resource = "*"
        Condition = {
          # Prevent moving accounts out of Workload OU
          StringEquals = {
            "organizations:SourceOrganizationalUnitId" = [
              aws_organizations_organizational_unit.production.id,
              aws_organizations_organizational_unit.development.id
            ]
          }
        }
      },
      {
        Sid    = "PreventIAMRoleEscalation"
        Effect = "Deny"
        Action = [
          "iam:CreateRole",
          "iam:PutRolePolicy",
          "iam:AttachRolePolicy"
        ]
        Resource = "*"
        Condition = {
          # Prevent creating roles that bypass SCP via trust policies
          StringEquals = {
            "iam:PassedToService" = "organizations.amazonaws.com"
          }
        }
      }
    ]
  })
}

# ============================================================================
# SCP: Require Approval Workflow for Production
# ============================================================================

resource "aws_organizations_policy" "require_approval" {
  name        = "RequireApprovalWorkflow"
  description = "Production changes require break-glass role with time-bound exceptions"
  type        = "SERVICE_CONTROL_POLICY"
  
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RequireBreakGlassRole"
        Effect = "Deny"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:CreateSecurityGroup",
          "ec2:DeleteSecurityGroup"
        ]
        Resource = "*"
        Condition = {
          # Block unless using approved break-glass role
          StringNotEquals = {
            "aws:PrincipalArn" = [
              "arn:aws:iam::*:role/SecurityBreakGlassRole",
              "arn:aws:iam::*:role/AutomationServiceRole"
            ]
          }
          # Exception: Allow if MFA is present (emergency access)
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
        }
      },
      {
        Sid    = "RequireChangeTicket"
        Effect = "Deny"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress"
        ]
        Resource = "*"
        Condition = {
          # Require ticket number in request tag
          StringNotLike = {
            "aws:RequestTag/change-ticket" = "JIRA-*"
          }
        }
      }
    ]
  })
}

# ============================================================================
# Organizational Units Structure
# ============================================================================

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = data.aws_organizations_organization.current.roots[0].id
}

resource "aws_organizations_organizational_unit" "production" {
  name      = "Production"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "development" {
  name      = "Development"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = data.aws_organizations_organization.current.roots[0].id
}

resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = data.aws_organizations_organization.current.roots[0].id
}

# ============================================================================
# SCP Attachments to OUs
# ============================================================================

# Attach deny public SG policy to production OU
resource "aws_organizations_policy_attachment" "prod_deny_public_sg" {
  policy_id = aws_organizations_policy.deny_public_sg.id
  target_id = aws_organizations_organizational_unit.production.id
}

# Attach deny public SG policy to development OU
resource "aws_organizations_policy_attachment" "dev_deny_public_sg" {
  policy_id = aws_organizations_policy.deny_public_sg.id
  target_id = aws_organizations_organizational_unit.development.id
}

# Attach approval workflow to production OU only
resource "aws_organizations_policy_attachment" "prod_require_approval" {
  policy_id = aws_organizations_policy.require_approval.id
  target_id = aws_organizations_organizational_unit.production.id
}

# Attach bypass prevention to workloads OU (cascades to children)
resource "aws_organizations_policy_attachment" "prevent_bypass" {
  policy_id = aws_organizations_policy.prevent_bypass.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

# ============================================================================
# Break-Glass IAM Role (Deployed to each production account)
# ============================================================================

resource "aws_iam_role" "break_glass" {
  name        = "SecurityBreakGlassRole"
  description = "Emergency access role for approved security group exceptions"
  
  # Trust policy: Only security account can assume
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${var.security_account_id}:root"
      }
      Action = "sts:AssumeRole"
      Condition = {
        # Require MFA for assume role
        Bool = {
          "aws:MultiFactorAuthPresent" = "true"
        }
        # Require specific source IP (security team VPN)
        IpAddress = {
          "aws:SourceIp" = var.security_team_cidr
        }
      }
    }]
  })
  
  # Session tags allow time-bound exceptions
  tags = {
    Purpose = "BreakGlassAccess"
  }
}

# Policy allowing security group modification with restrictions
resource "aws_iam_role_policy" "break_glass_sg_access" {
  name = "SecurityGroupEmergencyAccess"
  role = aws_iam_role.break_glass.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:CreateTags"
        ]
        Resource = "arn:aws:ec2:*:*:security-group/*"
        Condition = {
          # Can only modify security groups with emergency tag
          StringEquals = {
            "aws:ResourceTag/emergency-access" = "approved"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSecurityGroupRules"
        ]
        Resource = "*"
      }
    ]
  })
}

# ============================================================================
# Monitoring and Alerting
# ============================================================================

# CloudWatch metric filter for SCP denials
resource "aws_cloudwatch_log_metric_filter" "scp_denials" {
  name           = "SCPDenialCount"
  log_group_name = "/aws/cloudtrail/organization-trail"
  
  pattern = "{ $.errorCode = \"AccessDenied\" && $.errorMessage = \"*service control policy*\" }"
  
  metric_transformation {
    name      = "SCPDenials"
    namespace = "Security/Compliance"
    value     = "1"
  }
}

# Alarm when SCP denials spike (potential attack or misconfiguration)
resource "aws_cloudwatch_metric_alarm" "scp_denial_spike" {
  alarm_name          = "HighSCPDenialRate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "SCPDenials"
  namespace           = "Security/Compliance"
  period              = 300  # 5 minutes
  statistic           = "Sum"
  threshold           = 10   # More than 10 denials in 5 minutes
  alarm_description   = "SCP denial rate indicates potential attack or misconfiguration"
  
  alarm_actions = [aws_sns_topic.security_alerts.arn]
}

resource "aws_sns_topic" "security_alerts" {
  name = "scp-security-alerts"
}

# ============================================================================
# AWS Config Rule - Detect Untagged Public Security Groups
# ============================================================================

resource "aws_config_config_rule" "public_sg_without_approval" {
  name        = "detect-public-sg-without-approval-tag"
  description = "Detects security groups with 0.0.0.0/0 that lack approval tags"
  
  source {
    owner             = "AWS"
    source_identifier = "VPC_SG_OPEN_ONLY_TO_AUTHORIZED_PORTS"
  }
  
  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }
  
  # Parameters to check for 0.0.0.0/0
  input_parameters = jsonencode({
    authorizedTcpPorts = "443,80"  # Only these ports allowed public
  })
}

# ============================================================================
# Data Sources
# ============================================================================

data "aws_organizations_organization" "current" {}
data "aws_caller_identity" "current" {}

# ============================================================================
# Variables
# ============================================================================

variable "security_account_id" {
  description = "AWS account ID for centralized security operations"
  type        = string
}

variable "security_team_cidr" {
  description = "CIDR range for security team VPN (required for break-glass access)"
  type        = string
  default     = "10.50.0.0/24"
}