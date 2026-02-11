# terraform/security-group-remediation/main.tf
# This implements the reactive remediation system for security group drift

# ============================================================================
# EventBridge Rule - Detects unauthorized security group modifications
# ============================================================================

resource "aws_cloudwatch_event_rule" "security_group_drift" {
  name        = "detect-security-group-drift"
  description = "Detects when security groups are opened to 0.0.0.0/0"
  
  # Event pattern matches AuthorizeSecurityGroupIngress API calls
  # where the CIDR is 0.0.0.0/0 (internet-wide access)
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventName = ["AuthorizeSecurityGroupIngress"]
      requestParameters = {
        ipPermissions = {
          items = {
            ipRanges = {
              items = {
                cidrIp = ["0.0.0.0/0"]
              }
            }
          }
        }
      }
    }
  })
  
  tags = {
    Purpose    = "SecurityAutomation"
    Compliance = "SOC2-CC6.1"
  }
}

# ============================================================================
# Lambda - Build zip from source
# ============================================================================

data "archive_file" "remediation_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/remediation"
  output_path = "${path.module}/build/remediation_function.zip"
}

# ============================================================================
# Lambda Function - Performs automated remediation
# ============================================================================

resource "aws_lambda_function" "remediation" {
  filename         = data.archive_file.remediation_zip.output_path
  source_code_hash = data.archive_file.remediation_zip.output_base64sha256
  function_name    = "security-group-remediator"
  role             = aws_iam_role.lambda_remediation.arn
  handler          = "remediation.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  
  environment {
    variables = {
      WHITELIST_TABLE     = aws_dynamodb_table.whitelist.name
      AUDIT_TABLE         = aws_dynamodb_table.audit_log.name
      SNS_TOPIC_ARN       = aws_sns_topic.violations.arn
      EVIDENCE_BUCKET     = aws_s3_bucket.evidence.id
      REMEDIATION_ROLE    = "SecurityRemediationRole"  # Exists in each account
    }
  }
  
  # Enable X-Ray tracing for observability
  tracing_config {
    mode = "Active"
  }
  
  tags = {
    Purpose = "SecurityRemediation"
  }
}

# EventBridge triggers Lambda when rule matches
resource "aws_cloudwatch_event_target" "lambda" {
  rule      = aws_cloudwatch_event_rule.security_group_drift.name
  target_id = "RemediationLambda"
  arn       = aws_lambda_function.remediation.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.security_group_drift.arn
}

# ============================================================================
# DynamoDB Tables - Whitelist and Audit Log
# ============================================================================

# Whitelist table stores security groups that are exempt from remediation
# (e.g., load balancers that legitimately need 0.0.0.0/0 access)
resource "aws_dynamodb_table" "whitelist" {
  name           = "security-group-whitelist"
  billing_mode   = "PAY_PER_REQUEST"  # Serverless, scales automatically
  hash_key       = "security_group_id"
  
  attribute {
    name = "security_group_id"
    type = "S"
  }
  
  # Enable point-in-time recovery for compliance
  point_in_time_recovery {
    enabled = true
  }
  
  tags = {
    Purpose = "SecurityWhitelist"
  }
}

# Audit log stores all remediation actions for compliance
resource "aws_dynamodb_table" "audit_log" {
  name           = "security-remediation-audit"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "account_id"
  range_key      = "timestamp"
  
  attribute {
    name = "account_id"
    type = "S"
  }
  
  attribute {
    name = "timestamp"
    type = "S"
  }
  
  # TTL to auto-delete old records after 7 years (compliance retention)
  ttl {
    attribute_name = "expiration_time"
    enabled        = true
  }
  
  point_in_time_recovery {
    enabled = true
  }
  
  tags = {
    Purpose    = "AuditLog"
    Retention  = "7years"
  }
}

# ============================================================================
# S3 Bucket - Evidence Storage with Object Lock
# ============================================================================

resource "aws_s3_bucket" "evidence" {
  bucket = "security-remediation-evidence-${data.aws_caller_identity.current.account_id}"
  
  tags = {
    Purpose    = "ComplianceEvidence"
    Retention  = "7years"
  }
}

# Enable versioning (required for Object Lock)
resource "aws_s3_bucket_versioning" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# Object Lock prevents deletion/modification of evidence
resource "aws_s3_bucket_object_lock_configuration" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  
  rule {
    default_retention {
      mode = "COMPLIANCE"  # Cannot be overridden, even by root
      years = 7
    }
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "evidence" {
  bucket = aws_s3_bucket.evidence.id
  
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================================
# SNS Topic - Security Violation Notifications
# ============================================================================

resource "aws_sns_topic" "violations" {
  name = "security-group-violations"
  
  tags = {
    Purpose = "SecurityAlerts"
  }
}

# Subscribe security team email
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.violations.arn
  protocol  = "email"
  endpoint  = "security-team@company.com"
}

# ============================================================================
# IAM Role - Lambda Execution Role
# ============================================================================

resource "aws_iam_role" "lambda_remediation" {
  name = "SecurityGroupRemediationLambda"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# Policy allowing Lambda to assume cross-account remediation role
resource "aws_iam_role_policy" "cross_account_assume" {
  name = "AssumeRemediationRole"
  role = aws_iam_role.lambda_remediation.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Resource = "arn:aws:iam::*:role/SecurityRemediationRole"
    }]
  })
}

# Policy for DynamoDB access
resource "aws_iam_role_policy" "dynamodb_access" {
  name = "DynamoDBAccess"
  role = aws_iam_role.lambda_remediation.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Query"
      ]
      Resource = [
        aws_dynamodb_table.whitelist.arn,
        aws_dynamodb_table.audit_log.arn
      ]
    }]
  })
}

# Policy for S3 evidence storage
resource "aws_iam_role_policy" "s3_evidence" {
  name = "S3EvidenceAccess"
  role = aws_iam_role.lambda_remediation.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:PutObjectLegalHold"
      ]
      Resource = "${aws_s3_bucket.evidence.arn}/*"
    }]
  })
}

# Policy for SNS notifications
resource "aws_iam_role_policy" "sns_publish" {
  name = "SNSPublish"
  role = aws_iam_role.lambda_remediation.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "sns:Publish"
      Resource = aws_sns_topic.violations.arn
    }]
  })
}

# Attach AWS managed policy for basic Lambda execution
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_remediation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Data source for current AWS account ID
data "aws_caller_identity" "current" {}