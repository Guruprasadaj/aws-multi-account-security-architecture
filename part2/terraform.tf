# Terraform and backend configuration for Part 2 (remediation + SCP)
# Create the S3 bucket and DynamoDB table before first run (see part2/README.md).

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }

  backend "s3" {
    # Override with -backend-config or use backend config file.
    # Example: terraform init -backend-config="bucket=YOUR_UNIQUE_BUCKET"
    bucket         = "aws-multi-account-security-tfstate"
    key            = "part2/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
