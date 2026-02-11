"""
Security group drift remediation Lambda.
Triggered by EventBridge on AuthorizeSecurityGroupIngress with 0.0.0.0/0.
Checks whitelist, reverts the change in the target account, logs to audit, stores evidence, notifies.
"""

import json
import os
import boto3
from datetime import datetime
from typing import Any

# Env (set by Terraform)
WHITELIST_TABLE = os.environ["WHITELIST_TABLE"]
AUDIT_TABLE = os.environ["AUDIT_TABLE"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
EVIDENCE_BUCKET = os.environ["EVIDENCE_BUCKET"]
REMEDIATION_ROLE = os.environ["REMEDIATION_ROLE"]

dynamo = boto3.resource("dynamodb")
s3 = boto3.client("s3")


def lambda_handler(event: dict, context: Any) -> dict:
    """
    Process EventBridge event containing CloudTrail AuthorizeSecurityGroupIngress.
    Revert 0.0.0.0/0 rules in target account unless security group is whitelisted.
    """
    try:
        detail = event.get("detail")
        if isinstance(detail, dict):
            _process_record(detail)
    except Exception as e:
        print(f"Remediation failed: {e}")
        raise
    return {"statusCode": 200, "body": "ok"}


def _process_record(detail: dict) -> None:
    """Process one CloudTrail event detail."""
    event_name = detail.get("eventName")
    if event_name not in ("AuthorizeSecurityGroupIngress", "AuthorizeSecurityGroupEgress"):
        return

    request_params = detail.get("requestParameters") or {}
    group_id = request_params.get("groupId")
    if not group_id:
        return

    account_id = detail.get("recipientAccountId") or detail.get("awsRegion", "").split("-")[0]
    region = detail.get("awsRegion", "us-east-1")
    event_id = detail.get("eventID", "")
    event_time = detail.get("eventTime", "")

    # Check whitelist
    if _is_whitelisted(group_id):
        print(f"Security group {group_id} is whitelisted, skipping remediation")
        return

    # Build evidence payload for audit and S3
    evidence = {
        "eventName": event_name,
        "eventId": event_id,
        "eventTime": event_time,
        "accountId": account_id,
        "region": region,
        "groupId": group_id,
        "requestParameters": request_params,
    }

    # Revert in target account
    revoke_success = _revoke_in_account(account_id, region, event_name, request_params)

    # Audit log
    _write_audit(account_id, region, group_id, event_name, evidence, revoke_success)

    # Store evidence in S3
    _store_evidence(event_id, evidence, revoke_success)

    # Notify
    _notify(account_id, group_id, event_name, revoke_success)


def _is_whitelisted(security_group_id: str) -> bool:
    """Check if security group is in the whitelist DynamoDB table."""
    table = dynamo.Table(WHITELIST_TABLE)
    try:
        r = table.get_item(Key={"security_group_id": security_group_id})
        return "Item" in r
    except Exception:
        return False


def _revoke_in_account(
    account_id: str, region: str, event_name: str, request_params: dict
) -> bool:
    """Assume role in target account and revoke the security group rule."""
    sts = boto3.client("sts")
    role_arn = f"arn:aws:iam::{account_id}:role/{REMEDIATION_ROLE}"
    try:
        creds = sts.assume_role(
            RoleArn=role_arn,
            RoleSessionName="SecurityGroupRemediation",
        )["Credentials"]
    except Exception as e:
        print(f"Assume role failed for {account_id}: {e}")
        return False

    ec2 = boto3.client(
        "ec2",
        region_name=region,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
    )

    try:
        if event_name == "AuthorizeSecurityGroupIngress":
            ec2.revoke_security_group_ingress(
                GroupId=request_params.get("groupId"),
                IpPermissions=_normalize_ip_permissions(request_params.get("ipPermissions", {})),
            )
        else:
            ec2.revoke_security_group_egress(
                GroupId=request_params.get("groupId"),
                IpPermissions=_normalize_ip_permissions(request_params.get("ipPermissions", {})),
            )
        return True
    except Exception as e:
        print(f"Revoke failed in {account_id}/{region}: {e}")
        return False


def _normalize_ip_permissions(ip_perms: Any) -> list:
    """Convert requestParams ipPermissions shape to EC2 API list of dicts."""
    if isinstance(ip_perms, list):
        return ip_perms
    items = ip_perms.get("items", []) if isinstance(ip_perms, dict) else []
    out = []
    for item in items:
        perm = {"IpProtocol": item.get("ipProtocol", "-1")}
        if item.get("fromPort") is not None:
            perm["FromPort"] = int(item["fromPort"])
        if item.get("toPort") is not None:
            perm["ToPort"] = int(item["toPort"])
        ip_ranges = []
        for r in (item.get("ipRanges", {}) or {}).get("items", []) or []:
            if isinstance(r, dict) and r.get("cidrIp"):
                ip_ranges.append({"CidrIp": r["cidrIp"]})
        if ip_ranges:
            perm["IpRanges"] = ip_ranges
        ipv6 = (item.get("ipv6Ranges", {}) or {}).get("items", []) or []
        if ipv6:
            perm["Ipv6Ranges"] = [{"CidrIpv6": r.get("cidrIpv6", r)} if isinstance(r, dict) else {"CidrIpv6": r} for r in ipv6]
        out.append(perm)
    return out


def _write_audit(
    account_id: str,
    region: str,
    group_id: str,
    event_name: str,
    evidence: dict,
    success: bool,
) -> None:
    """Write remediation record to audit DynamoDB table."""
    table = dynamo.Table(AUDIT_TABLE)
    ts = datetime.utcnow().isoformat() + "Z"
    # TTL 7 years (compliance)
    from datetime import timedelta
    expiration = int((datetime.utcnow() + timedelta(days=2555)).timestamp())
    table.put_item(
        Item={
            "account_id": account_id,
            "timestamp": ts,
            "region": region,
            "security_group_id": group_id,
            "event_name": event_name,
            "remediation_success": success,
            "evidence_snapshot": json.dumps(evidence),
            "expiration_time": expiration,
        }
    )


def _store_evidence(event_id: str, evidence: dict, success: bool) -> None:
    """Store immutable evidence in S3 (versioning + object lock)."""
    key = f"remediations/{event_id}.json"
    body = json.dumps({**evidence, "remediation_success": success}, indent=2)
    s3.put_object(
        Bucket=EVIDENCE_BUCKET,
        Key=key,
        Body=body,
        ContentType="application/json",
    )


def _notify(account_id: str, group_id: str, event_name: str, success: bool) -> None:
    """Publish to SNS for security team."""
    sns = boto3.client("sns")
    subject = "Security group drift remediated" if success else "Security group drift remediation failed"
    message = (
        f"Account: {account_id}\nSecurity Group: {group_id}\nEvent: {event_name}\n"
        f"Revert success: {success}"
    )
    sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject, Message=message)
