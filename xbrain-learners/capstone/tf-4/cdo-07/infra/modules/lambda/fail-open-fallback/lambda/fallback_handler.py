"""
Fail-Open Fallback Lambda — CDO-07 · Task Force 4
===================================================
Nhiệm vụ: khi Lambda Window Feeder timeout hoặc AI Engine down,
Lambda này kích hoạt để đánh giá metric theo ngưỡng tĩnh (static thresholds),
publish alert lên SNS, push annotation lên Managed Grafana, và ghi audit log S3.

Trigger: SNS topic "window-feeder-failed" hoặc invoked trực tiếp từ EventBridge
         khi Window Feeder publish alert với reason = "window_feeder_failed".

Ngưỡng tĩnh (per ADR-001 + 03_security_design.md):
  - CPU utilization  > 85 %
  - Memory usage     > 90 %
  - ALB connections  > 450
  - SQS queue depth  > 10 000
"""

import datetime as dt
import hashlib
import json
import logging
import os
import urllib.error
import urllib.request
import uuid
from typing import Any

import boto3

# ---------------------------------------------------------------------------
# Cấu hình Logger
# ---------------------------------------------------------------------------
LOGGER = logging.getLogger()
LOGGER.setLevel(os.getenv("LOG_LEVEL", "INFO"))

# ---------------------------------------------------------------------------
# Biến môi trường (bắt buộc truyền qua Terraform)
# ---------------------------------------------------------------------------
REGION = os.getenv("AWS_REGION", "us-east-1")
ALERT_SNS_TOPIC_ARN = os.environ["ALERT_SNS_TOPIC_ARN"]
AUDIT_S3_BUCKET = os.environ["AUDIT_S3_BUCKET"]
AUDIT_S3_PREFIX = os.getenv("AUDIT_S3_PREFIX", "fail-open-fallback/")

# Grafana — optional: nếu không set thì bỏ qua bước push annotation
GRAFANA_HOST = os.getenv("GRAFANA_HOST", "")           # e.g. https://g-xxxx.grafana-workspace.us-east-1.amazonaws.com
GRAFANA_API_KEY_PARAMETER = os.getenv("GRAFANA_API_KEY_PARAMETER", "")  # SSM SecureString path
GRAFANA_DASHBOARD_UID = os.getenv("GRAFANA_DASHBOARD_UID", "")

# Ngưỡng tĩnh (có thể override qua biến môi trường để linh hoạt)
THRESHOLD_CPU_PCT = float(os.getenv("THRESHOLD_CPU_PCT", "85"))
THRESHOLD_MEMORY_PCT = float(os.getenv("THRESHOLD_MEMORY_PCT", "90"))
THRESHOLD_ALB_CONNECTIONS = int(os.getenv("THRESHOLD_ALB_CONNECTIONS", "450"))
THRESHOLD_QUEUE_DEPTH = int(os.getenv("THRESHOLD_QUEUE_DEPTH", "10000"))

# AWS clients
_ssm = boto3.client("ssm", region_name=REGION)
_s3 = boto3.client("s3", region_name=REGION)
_sns = boto3.client("sns", region_name=REGION)
_cloudwatch = boto3.client("cloudwatch", region_name=REGION)


# ---------------------------------------------------------------------------
# Handler chính
# ---------------------------------------------------------------------------
def handler(event: dict, context: Any) -> dict:
    """Entry point Lambda."""
    run_id = str(uuid.uuid4())
    triggered_at = _utc_now()

    LOGGER.info("Fail-Open Fallback triggered | run_id=%s", run_id)

    audit: dict = {
        "run_id": run_id,
        "triggered_at": triggered_at,
        "trigger_source": _extract_trigger_source(event),
        "mode": "fail_open_static_threshold",
        "status": "started",
    }

    try:
        # 1. Lấy metric thực từ CloudWatch
        cw_metrics = _fetch_cloudwatch_metrics()
        audit["cloudwatch_metrics"] = cw_metrics

        # 2. Đánh giá theo ngưỡng tĩnh
        violations = _evaluate_static_thresholds(cw_metrics)
        drift_detected = len(violations) > 0

        # 3. Tạo recommendation
        recommendation = _build_recommendation(violations)

        audit.update(
            {
                "drift_detected": drift_detected,
                "violations": violations,
                "recommendation": recommendation,
                "thresholds_used": {
                    "cpu_pct": THRESHOLD_CPU_PCT,
                    "memory_pct": THRESHOLD_MEMORY_PCT,
                    "alb_connections": THRESHOLD_ALB_CONNECTIONS,
                    "queue_depth": THRESHOLD_QUEUE_DEPTH,
                },
                "status": "completed",
                "completed_at": _utc_now(),
            }
        )

        # 4. Ghi audit log vào S3
        _write_audit(audit)

        # 5. Publish SNS alert nếu phát hiện drift
        if drift_detected:
            LOGGER.warning(
                "Static threshold violation detected | violations=%s", violations
            )
            _publish_sns_alert(audit)

        # 6. Push annotation lên Grafana (không critical, lỗi thì log tiếp)
        _push_grafana_annotation(audit)

        LOGGER.info(
            "Fail-Open Fallback completed | drift_detected=%s | run_id=%s",
            drift_detected,
            run_id,
        )
        return _response(200, audit)

    except Exception as exc:
        LOGGER.exception("Fail-Open Fallback encountered an error | run_id=%s", run_id)
        audit.update(
            {
                "status": "error",
                "error": str(exc),
                "completed_at": _utc_now(),
            }
        )
        # Vẫn cố ghi audit dù lỗi
        try:
            _write_audit(audit)
        except Exception:
            LOGGER.exception("Failed to write audit log after error")

        return _response(500, audit)


# ---------------------------------------------------------------------------
# Lấy metric từ CloudWatch
# ---------------------------------------------------------------------------
def _fetch_cloudwatch_metrics() -> dict:
    """
    Truy vấn các metric gần nhất từ CloudWatch.
    Trả về dict metric_name → giá trị cuối cùng (None nếu không có dữ liệu).
    """
    now = dt.datetime.now(dt.timezone.utc)
    start = now - dt.timedelta(minutes=10)

    # Định nghĩa metric cần lấy
    metric_queries = [
        {
            "key": "cpu_pct",
            "namespace": "AWS/ECS",
            "metric_name": "CPUUtilization",
            "stat": "Maximum",
            "dimensions": [],  # aggregate toàn cluster
        },
        {
            "key": "memory_pct",
            "namespace": "AWS/ECS",
            "metric_name": "MemoryUtilization",
            "stat": "Maximum",
            "dimensions": [],
        },
        {
            "key": "alb_connections",
            "namespace": "AWS/ApplicationELB",
            "metric_name": "ActiveConnectionCount",
            "stat": "Maximum",
            "dimensions": [],
        },
        {
            "key": "queue_depth",
            "namespace": "AWS/SQS",
            "metric_name": "ApproximateNumberOfMessagesVisible",
            "stat": "Maximum",
            "dimensions": [],
        },
    ]

    results: dict = {}
    for mq in metric_queries:
        try:
            resp = _cloudwatch.get_metric_statistics(
                Namespace=mq["namespace"],
                MetricName=mq["metric_name"],
                Dimensions=mq.get("dimensions", []),
                StartTime=start,
                EndTime=now,
                Period=300,
                Statistics=[mq["stat"]],
            )
            datapoints = resp.get("Datapoints", [])
            if datapoints:
                latest = sorted(datapoints, key=lambda d: d["Timestamp"])[-1]
                results[mq["key"]] = round(latest[mq["stat"]], 4)
            else:
                results[mq["key"]] = None
        except Exception as exc:
            LOGGER.warning("Could not fetch metric %s: %s", mq["metric_name"], exc)
            results[mq["key"]] = None

    LOGGER.info("CloudWatch metrics fetched: %s", results)
    return results


# ---------------------------------------------------------------------------
# Đánh giá ngưỡng tĩnh
# ---------------------------------------------------------------------------
def _evaluate_static_thresholds(metrics: dict) -> list:
    """So sánh metric với ngưỡng tĩnh, trả về danh sách vi phạm."""
    violations = []

    checks = [
        (
            "cpu_utilization",
            metrics.get("cpu_pct"),
            THRESHOLD_CPU_PCT,
            f"CPU utilization {metrics.get('cpu_pct')}% > threshold {THRESHOLD_CPU_PCT}%",
            "Xem xét scale-up ECS task CPU hoặc tối ưu hóa xử lý request",
        ),
        (
            "memory_utilization",
            metrics.get("memory_pct"),
            THRESHOLD_MEMORY_PCT,
            f"Memory utilization {metrics.get('memory_pct')}% > threshold {THRESHOLD_MEMORY_PCT}%",
            "Tăng memory limit ECS task hoặc kiểm tra memory leak",
        ),
        (
            "alb_active_connections",
            metrics.get("alb_connections"),
            THRESHOLD_ALB_CONNECTIONS,
            f"ALB active connections {metrics.get('alb_connections')} > threshold {THRESHOLD_ALB_CONNECTIONS}",
            "Kiểm tra connection pool exhaustion và scale ALB target group",
        ),
        (
            "queue_depth",
            metrics.get("queue_depth"),
            THRESHOLD_QUEUE_DEPTH,
            f"Queue depth {metrics.get('queue_depth')} > threshold {THRESHOLD_QUEUE_DEPTH}",
            "Consumer đang bị lag — tăng số lượng consumer hoặc kiểm tra DLQ",
        ),
    ]

    for metric_name, value, threshold, description, action in checks:
        if value is not None and value > threshold:
            violations.append(
                {
                    "metric": metric_name,
                    "current_value": value,
                    "threshold": threshold,
                    "description": description,
                    "recommended_action": action,
                    "severity": "HIGH" if value > threshold * 1.2 else "MEDIUM",
                }
            )

    return violations


# ---------------------------------------------------------------------------
# Xây dựng recommendation
# ---------------------------------------------------------------------------
def _build_recommendation(violations: list) -> dict:
    """Tạo structured recommendation từ danh sách vi phạm."""
    if not violations:
        return {
            "summary": "Không phát hiện vi phạm ngưỡng tĩnh. Hệ thống hoạt động bình thường.",
            "action_required": False,
            "actions": [],
        }

    actions = [v["recommended_action"] for v in violations]
    high_severity = [v for v in violations if v["severity"] == "HIGH"]

    return {
        "summary": (
            f"Phát hiện {len(violations)} vi phạm ngưỡng tĩnh "
            f"({len(high_severity)} nghiêm trọng cao). "
            "AI Engine không khả dụng — đây là kết quả từ Fail-Open Fallback."
        ),
        "action_required": True,
        "severity": "HIGH" if high_severity else "MEDIUM",
        "actions": actions,
        "note": "Kết quả này dựa trên ngưỡng tĩnh, không phải ML prediction. "
                "Hãy kiểm tra trạng thái AI Engine và khởi động lại nếu cần.",
    }


# ---------------------------------------------------------------------------
# Ghi audit log S3
# ---------------------------------------------------------------------------
def _write_audit(audit: dict) -> None:
    key = _build_audit_key(audit["run_id"])
    audit["audit_s3_uri"] = f"s3://{AUDIT_S3_BUCKET}/{key}"
    _s3.put_object(
        Bucket=AUDIT_S3_BUCKET,
        Key=key,
        Body=json.dumps(audit, separators=(",", ":"), default=str).encode("utf-8"),
        ContentType="application/json",
    )
    LOGGER.info("Audit log written to %s", audit["audit_s3_uri"])


def _build_audit_key(run_id: str) -> str:
    prefix = AUDIT_S3_PREFIX.strip("/")
    now = dt.datetime.now(dt.timezone.utc)
    digest = hashlib.sha256(run_id.encode()).hexdigest()[:12]
    return f"{prefix}/{now:%Y/%m/%d}/{run_id}-{digest}.json"


# ---------------------------------------------------------------------------
# Publish SNS alert
# ---------------------------------------------------------------------------
def _publish_sns_alert(audit: dict) -> None:
    violations_summary = ", ".join(
        f"{v['metric']}={v['current_value']}" for v in audit.get("violations", [])
    )
    subject = f"[FAIL-OPEN] Drift alert từ Static Threshold | {violations_summary}"[:100]

    message = {
        "source": "fail_open_fallback",
        "run_id": audit["run_id"],
        "triggered_at": audit["triggered_at"],
        "trigger_source": audit.get("trigger_source"),
        "drift_detected": audit["drift_detected"],
        "violations": audit.get("violations", []),
        "recommendation": audit.get("recommendation", {}),
        "audit_s3_uri": audit.get("audit_s3_uri"),
        "note": "AI Engine không khả dụng khi alert này được sinh ra.",
    }

    _sns.publish(
        TopicArn=ALERT_SNS_TOPIC_ARN,
        Subject=subject,
        Message=json.dumps(message, indent=2, default=str),
    )
    LOGGER.info("SNS alert published | topic=%s", ALERT_SNS_TOPIC_ARN)


# ---------------------------------------------------------------------------
# Push annotation lên Managed Grafana
# ---------------------------------------------------------------------------
def _push_grafana_annotation(audit: dict) -> None:
    """
    Ghi annotation lên Managed Grafana qua HTTP API.
    Không raise exception — lỗi chỉ được log, không ảnh hưởng luồng chính.
    """
    if not GRAFANA_HOST or not GRAFANA_API_KEY_PARAMETER:
        LOGGER.info("Grafana annotation skipped — GRAFANA_HOST or GRAFANA_API_KEY_PARAMETER not set")
        return

    try:
        api_key = _get_grafana_api_key()
        now_ms = int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000)

        violations_text = "; ".join(
            f"{v['metric']}={v['current_value']}" for v in audit.get("violations", [])
        )
        text = (
            f"[FAIL-OPEN] Static threshold triggered | "
            f"drift={audit.get('drift_detected')} | "
            f"{violations_text or 'No violations'}"
        )

        payload: dict = {
            "time": now_ms,
            "isRegion": False,
            "text": text,
            "tags": ["fail-open", "static-threshold", "cdo-07"],
        }
        if GRAFANA_DASHBOARD_UID:
            payload["dashboardUID"] = GRAFANA_DASHBOARD_UID

        url = f"{GRAFANA_HOST.rstrip('/')}/api/annotations"
        body = json.dumps(payload).encode("utf-8")

        req = urllib.request.Request(
            url,
            data=body,
            method="POST",
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {api_key}",
            },
        )

        with urllib.request.urlopen(req, timeout=10) as resp:
            resp_body = resp.read().decode("utf-8")
            LOGGER.info("Grafana annotation pushed | response=%s", resp_body)

    except urllib.error.HTTPError as exc:
        LOGGER.warning(
            "Grafana annotation failed (HTTP %s): %s", exc.code, exc.read().decode()
        )
    except Exception as exc:
        LOGGER.warning("Grafana annotation failed: %s", exc)


def _get_grafana_api_key() -> str:
    """Lấy Grafana API key từ SSM Parameter Store (SecureString)."""
    resp = _ssm.get_parameter(
        Name=GRAFANA_API_KEY_PARAMETER,
        WithDecryption=True,
    )
    return resp["Parameter"]["Value"]


# ---------------------------------------------------------------------------
# Helper: extract trigger source từ SNS event
# ---------------------------------------------------------------------------
def _extract_trigger_source(event: dict) -> str:
    """Trích xuất thông tin trigger — SNS record hoặc direct invocation."""
    records = event.get("Records", [])
    if records:
        sns_record = records[0].get("Sns", {})
        return f"sns:{sns_record.get('TopicArn', 'unknown')}:{sns_record.get('Subject', '')}"
    return "direct_invocation"


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "body": json.dumps(body, default=str),
    }
