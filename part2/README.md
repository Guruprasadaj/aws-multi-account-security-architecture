# Part 2: Security Automation (Terraform)

Reactive remediation (EventBridge + Lambda) and preventive SCPs. All Terraform in this directory is one configuration.

## Prerequisites

- Terraform >= 1.5.0
- AWS credentials with permissions to create the resources (and Organizations for SCPs)

## Backend setup (first time)

State is stored in S3 with a DynamoDB lock. Create these once:

1. **S3 bucket** (name must be globally unique):
   ```bash
   aws s3api create-bucket --bucket aws-multi-account-security-tfstate --region us-east-1
   aws s3api put-bucket-versioning --bucket aws-multi-account-security-tfstate \
     --versioning-configuration Status=Enabled
   ```

2. **DynamoDB table** for state locking:
   ```bash
   aws dynamodb create-table --table-name terraform-state-lock \
     --attribute-definitions AttributeName=LockID,AttributeType=S \
     --key-schema AttributeName=LockID,KeyType=HASH \
     --billing-mode PAY_PER_REQUEST --region us-east-1
   ```

3. **Init:**
   ```bash
   cd part2
   terraform init
   ```

To use a different bucket or table, create them and run:

```bash
terraform init -backend-config="bucket=YOUR_BUCKET" -backend-config="dynamodb_table=YOUR_TABLE"
```

## Commands

```bash
cd part2
terraform init
terraform validate
terraform plan
terraform apply
```

Lambda zip is built from `lambda/remediation/` automatically during `plan`/`apply` (no manual zip step).
