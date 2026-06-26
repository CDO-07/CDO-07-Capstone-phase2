import datetime as dt
import hashlib
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

import boto3
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest


LOGGER = logging.getLogger()
LOGGER.setLevel(os.getenv("LOG_LEVEL", "INFO"))

REGION = os.getenv("AWS_REGION", "us-east-1")
AMP_WORKSPACE_ID = os.environ["AMP_WORKSPACE_ID"]
AMP_QUERY_WINDOW = os.getenv("AMP_QUERY_WINDOW", "2h")
AI_ENGINE_PREDICT_URL = os.environ["AI_ENGINE_PREDICT_URL"]
AI_ENGINE_TIMEOUT_SECONDS = float(os.getenv("AI_ENGINE_TIMEOUT_SECONDS", "5"))
BASELINE_S3_BUCKET = os.getenv("BASELINE_S3_BUCKET")
AUDIT_S3_BUCKET = os.environ["AUDIT_S3_BUCKET"]
AUDIT_S3_PREFIX = os.getenv("AUDIT_S3_PREFIX", "window-feeder/")
INFERENCE_ENABLED_PARAMETER_NAME = os.environ["INFERENCE_ENABLED_PARAMETER_NAME"]
DRIFT_ALERT_SNS_TOPIC_ARN = os.environ["DRIFT_ALERT_SNS_TOPIC_ARN"]

DEFAULT_QUERIES = [
    {
        "name": "request_rate",
        "query": 'sum(rate(http_requests_total[5m])) by (service)',
    },
    {
        "name": "error_rate",
        "query": 'sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)',
    },
    {
        "name": "latency_p95",
        "query": (
            "histogram_quantile(0.95, "
            "sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))"
        ),
    },
]

ssm = boto3.client("ssm")
s3 = boto3.client("s3")
sns = boto3.client("sns")
session = boto3.Session()


def handler(event, context):
    run_id = str(uuid.uuid4())
    started_at = utc_now()

    audit = {
        "run_id": run_id,
        "started_at": started_at,
        "event": event,
        "status": "started",
    }

    try:
        if not inference_enabled():
            audit["status"] = "skipped"
            audit["reason"] = "inference_disabled"
            write_audit(audit)
            return response(200, audit)

        window = event.get("window") or AMP_QUERY_WINDOW
        predict_path = event.get("predict_path", "/v1/predict")
        queries = load_queries(event)

        metric_window = query_amp_window(queries, window)
        baseline_ref = build_baseline_ref()
        payload = {
            "run_id": run_id,
            "window": window,
            "started_at": started_at,
            "metric_source": "amp",
            "metrics": metric_window,
            "baseline": baseline_ref,
        }

        prediction = call_ai_engine(payload, predict_path)
        audit.update(
            {
                "status": "completed",
                "metric_count": count_metric_samples(metric_window),
                "prediction": prediction,
                "completed_at": utc_now(),
            }
        )

        write_audit(audit)

        if prediction.get("drift_detected") is True:
            publish_alert("drift_detected", audit)

        return response(200, audit)

    except Exception as exc:
        LOGGER.exception("Window Feeder failed")
        audit.update(
            {
                "status": "failed",
                "error": str(exc),
                "completed_at": utc_now(),
            }
        )
        write_audit(audit)
        publish_alert("window_feeder_failed", audit)
        return response(500, audit)


def inference_enabled():
    result = ssm.get_parameter(Name=INFERENCE_ENABLED_PARAMETER_NAME)
    value = result["Parameter"]["Value"].strip().lower()
    return value in ("1", "true", "yes", "enabled", "on")


def load_queries(event):
    if isinstance(event.get("queries"), list):
        return event["queries"]

    raw_queries = os.getenv("AMP_QUERIES_JSON")
    if raw_queries:
        return json.loads(raw_queries)

    return DEFAULT_QUERIES


def query_amp_window(queries, window):
    end = int(time.time())
    start = end - parse_duration_seconds(window)

    results = []
    for item in queries:
        name = item["name"]
        query = item["query"]
        data = amp_query_range(query=query, start=start, end=end, step=item.get("step", "60s"))
        results.append(
            {
                "name": name,
                "query": query,
                "result_type": data.get("resultType"),
                "result": data.get("result", []),
            }
        )

    return results


def amp_query_range(query, start, end, step):
    params = urllib.parse.urlencode(
        {
            "query": query,
            "start": start,
            "end": end,
            "step": step,
        }
    )
    url = (
        f"https://aps-workspaces.{REGION}.amazonaws.com"
        f"/workspaces/{AMP_WORKSPACE_ID}/api/v1/query_range?{params}"
    )
    signed_headers = sign_request("GET", url)

    request = urllib.request.Request(url, method="GET", headers=signed_headers)
    with urllib.request.urlopen(request, timeout=AI_ENGINE_TIMEOUT_SECONDS) as res:
        body = json.loads(res.read().decode("utf-8"))

    if body.get("status") != "success":
        raise RuntimeError(f"AMP query failed: {body}")

    return body["data"]


def sign_request(method, url, body=None, headers=None):
    credentials = session.get_credentials().get_frozen_credentials()
    aws_request = AWSRequest(method=method, url=url, data=body, headers=headers or {})
    SigV4Auth(credentials, "aps", REGION).add_auth(aws_request)
    return dict(aws_request.headers.items())


def call_ai_engine(payload, predict_path):
    url = AI_ENGINE_PREDICT_URL
    if predict_path and not url.endswith(predict_path):
        url = AI_ENGINE_PREDICT_URL.rstrip("/") + "/" + predict_path.lstrip("/")

    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Content-Type": "application/json",
            "Idempotency-Key": payload["run_id"],
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=AI_ENGINE_TIMEOUT_SECONDS) as res:
            response_body = res.read().decode("utf-8")
            return json.loads(response_body) if response_body else {}
    except urllib.error.HTTPError as exc:
        error_body = exc.read().decode("utf-8")
        raise RuntimeError(f"AI Engine returned HTTP {exc.code}: {error_body}") from exc


def write_audit(audit):
    key = build_audit_key(audit["run_id"])
    audit["audit_s3_uri"] = f"s3://{AUDIT_S3_BUCKET}/{key}"
    s3.put_object(
        Bucket=AUDIT_S3_BUCKET,
        Key=key,
        Body=json.dumps(audit, separators=(",", ":"), default=str).encode("utf-8"),
        ContentType="application/json",
    )


def publish_alert(reason, audit):
    sns.publish(
        TopicArn=DRIFT_ALERT_SNS_TOPIC_ARN,
        Subject=f"Window Feeder alert: {reason}",
        Message=json.dumps(
            {
                "reason": reason,
                "run_id": audit.get("run_id"),
                "status": audit.get("status"),
                "error": audit.get("error"),
                "audit_s3_uri": audit.get("audit_s3_uri"),
                "prediction": audit.get("prediction"),
            },
            indent=2,
            default=str,
        ),
    )


def build_baseline_ref():
    if not BASELINE_S3_BUCKET:
        return None

    return {
        "bucket": BASELINE_S3_BUCKET,
        "expected_prefixes": ["baselines/", "models/"],
    }


def build_audit_key(run_id):
    now = dt.datetime.now(dt.timezone.utc)
    prefix = AUDIT_S3_PREFIX.strip("/")
    digest = hashlib.sha256(run_id.encode("utf-8")).hexdigest()[:12]
    return f"{prefix}/{now:%Y/%m/%d}/{run_id}-{digest}.json"


def count_metric_samples(metric_window):
    count = 0
    for item in metric_window:
        for series in item.get("result", []):
            count += len(series.get("values", []))
    return count


def parse_duration_seconds(value):
    unit = value[-1]
    amount = int(value[:-1])
    multipliers = {
        "s": 1,
        "m": 60,
        "h": 3600,
        "d": 86400,
    }
    if unit not in multipliers:
        raise ValueError(f"Unsupported duration: {value}")
    return amount * multipliers[unit]


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def response(status_code, body):
    return {
        "statusCode": status_code,
        "body": json.dumps(body, default=str),
    }
