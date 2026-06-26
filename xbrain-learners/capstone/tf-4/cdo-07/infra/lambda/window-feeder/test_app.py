import os
import json
import pytest
import requests
from unittest.mock import Mock

# Import ham can test tu file app.py
# De import duoc, can them duong dan cua thu muc cha vao sys.path
import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

import app

# Ten cua SSM parameter dung cho test
TEST_PARAM_NAME = "/test/inference-enabled"

class FakeSsmClient:
    def __init__(self):
        self.parameters = {}

    def put_parameter(self, Name, Value, Type):
        self.parameters[Name] = {"Value": Value, "Type": Type}

    def get_parameter(self, Name):
        if Name not in self.parameters:
            raise KeyError(Name)
        return {"Parameter": self.parameters[Name]}


class FakeS3Client:
    def __init__(self):
        self.buckets = {}

    def create_bucket(self, Bucket):
        self.buckets[Bucket] = {}

    def put_object(self, Bucket, Key, Body, ContentType):
        self.buckets.setdefault(Bucket, {})[Key] = {
            "Body": Body,
            "ContentType": ContentType,
        }

    def list_objects_v2(self, Bucket):
        contents = [{"Key": key} for key in self.buckets.get(Bucket, {})]
        return {"Contents": contents} if contents else {}


class FakeSnsClient:
    def create_topic(self, Name):
        return {"TopicArn": f"arn:aws:sns:us-east-1:123456789012:{Name}"}

    def publish(self, **kwargs):
        return {"MessageId": "test-message-id"}

@pytest.fixture(scope='function')
def mock_aws_services(monkeypatch):
    """Fixture de mock cac dich vu AWS can thiet."""
    clients = {
        "ssm": FakeSsmClient(),
        "s3": FakeS3Client(),
        "sns": FakeSnsClient(),
        "timestream-query": Mock(),
    }
    monkeypatch.setattr(app, "ssm_client", clients["ssm"])
    monkeypatch.setattr(app, "s3_client", clients["s3"])
    monkeypatch.setattr(app, "sns_client", clients["sns"])
    monkeypatch.setattr(app, "timestream_query_client", clients["timestream-query"])
    yield clients

@pytest.fixture
def set_env_vars(monkeypatch):
    """Fixture de set bien moi truong cho Lambda."""
    monkeypatch.setenv("AWS_REGION", "us-east-1")
    monkeypatch.setenv("TIMESTREAM_DATABASE_NAME", "test-metrics-db")
    monkeypatch.setenv("TIMESTREAM_TABLE_NAME", "service-metrics")
    monkeypatch.setenv("TIMESTREAM_QUERY_WINDOW", "1h")
    monkeypatch.setenv("AI_ENGINE_PREDICT_URL", "http://test-ai-engine/v1/predict")
    monkeypatch.setenv("AI_ENGINE_TIMEOUT_SECONDS", "5")
    monkeypatch.setenv("AUDIT_S3_BUCKET", "test-audit-bucket")
    monkeypatch.setenv("AUDIT_S3_PREFIX", "test-prefix/")
    monkeypatch.setenv("INFERENCE_ENABLED_PARAMETER_NAME", "/test/inference-enabled")
    monkeypatch.setenv("DRIFT_ALERT_SNS_TOPIC_ARN", "arn:aws:sns:us-east-1:123456789012:test-drift-topic")

# ===================================
# Unit Tests for Helper Functions
# ===================================

def test_inference_is_enabled(mock_aws_services, set_env_vars):
    """Kiem tra truong hop inference duoc bat (enabled)."""
    # Chuan bi: Tao mot parameter "true" trong SSM gia lap
    mock_aws_services["ssm"].put_parameter(Name="/test/inference-enabled", Value="true", Type="String")

    # Thuc thi: Goi ham can test
    result = app.is_inference_enabled()

    # Khang dinh: Ket qua phai la True
    assert result is True

def test_write_audit_log(mock_aws_services, set_env_vars):
    """Kiem tra ham ghi audit log ra S3."""
    mock_aws_services["s3"].create_bucket(Bucket="test-audit-bucket")
    app.write_audit_log({"input": "data"}, {"output": "data"})

    # Kiem tra xem co object nao duoc tao ra trong bucket khong
    objects = mock_aws_services["s3"].list_objects_v2(Bucket="test-audit-bucket")
    assert len(objects["Contents"]) == 1
    assert objects["Contents"][0]["Key"].startswith("test-prefix/")

def test_publish_drift_alert_when_drift_detected(monkeypatch, set_env_vars):
    """Kiem tra ham gui SNS khi phat hien drift."""
    mock_sns_publish = Mock()
    monkeypatch.setattr(app.sns_client, "publish", mock_sns_publish)
    
    # Thuc thi voi du lieu co drift
    app.publish_drift_alert({"drift_detected": True, "details": "..."})

    # Khang dinh: Ham publish cua SNS duoc goi 1 lan
    mock_sns_publish.assert_called_once()

def test_publish_drift_alert_when_no_drift(monkeypatch, set_env_vars):
    """Kiem tra ham KHONG gui SNS khi khong co drift."""
    mock_sns_publish = Mock()
    monkeypatch.setattr(app.sns_client, "publish", mock_sns_publish)
    
    # Thuc thi voi du lieu khong co drift
    app.publish_drift_alert({"drift_detected": False})

    # Khang dinh: Ham publish cua SNS khong duoc goi
    mock_sns_publish.assert_not_called()

# ===================================
# Integration Tests for Main Handler
# ===================================

def test_handler_happy_path_with_drift(mock_aws_services, set_env_vars, monkeypatch):
    """Kiem tra toan bo luong xu ly thanh cong va co phat hien drift."""
    # Chuan bi: Mock tat ca cac dependency
    mock_aws_services["ssm"].put_parameter(Name="/test/inference-enabled", Value="true", Type="String")
    mock_aws_services["s3"].create_bucket(Bucket="test-audit-bucket")
    mock_aws_services["sns"].create_topic(Name="test-drift-topic")
    
    mock_timestream_query = Mock(return_value={
        "ColumnInfo": [
            {"Name": "time", "Type": {"ScalarType": "TIMESTAMP"}},
            {"Name": "service_id", "Type": {"ScalarType": "VARCHAR"}},
            {"Name": "tenant_id", "Type": {"ScalarType": "VARCHAR"}},
            {"Name": "metric_type", "Type": {"ScalarType": "VARCHAR"}},
            {"Name": "measure_name", "Type": {"ScalarType": "VARCHAR"}},
            {"Name": "value", "Type": {"ScalarType": "DOUBLE"}},
        ],
        "Rows": [
            {
                "Data": [
                    {"ScalarValue": "2026-06-26 00:00:00.000000000"},
                    {"ScalarValue": "payment-gw"},
                    {"ScalarValue": "tenant-a"},
                    {"ScalarValue": "latency_ms"},
                    {"ScalarValue": "p95"},
                    {"ScalarValue": "123.4"},
                ]
            }
        ],
    })
    monkeypatch.setattr(app.timestream_query_client, "query", mock_timestream_query)
    mock_sns_publish = Mock()
    monkeypatch.setattr(app.sns_client, "publish", mock_sns_publish)

    mock_response = Mock()
    mock_response.status_code = 200
    mock_response.json.return_value = {"prediction": "ok", "drift_detected": True}
    mock_response.raise_for_status.return_value = None
    monkeypatch.setattr(app.requests, "post", Mock(return_value=mock_response))

    # Thuc thi
    response = app.handler({}, None)

    # Khang dinh
    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["drift_detected"] is True
    
    # Kiem tra audit log da duoc ghi
    objects = mock_aws_services["s3"].list_objects_v2(Bucket="test-audit-bucket")
    assert len(objects["Contents"]) == 1

    # Kiem tra canh bao drift da duoc gui
    mock_sns_publish.assert_called_once()

def test_handler_inference_disabled(mock_aws_services, set_env_vars):
    """Kiem tra truong hop inference bi tat (disabled)."""
    # Chuan bi: Tao mot parameter "false" trong SSM gia lap
    mock_aws_services["ssm"].put_parameter(Name="/test/inference-enabled", Value="false", Type="String")

    # Thuc thi
    response = app.handler({}, None)

    # Khang dinh: Ham tra ve ngay lap tuc
    assert response["statusCode"] == 200
    assert response["body"] == "Inference disabled."

def test_handler_ai_engine_fails(mock_aws_services, set_env_vars, monkeypatch):
    """Kiem tra truong hop AI Engine tra ve loi 500."""
    # Chuan bi
    mock_aws_services["ssm"].put_parameter(Name="/test/inference-enabled", Value="true", Type="String")
    mock_timestream_query = Mock(return_value={
        "ColumnInfo": [
            {"Name": "time", "Type": {"ScalarType": "TIMESTAMP"}},
            {"Name": "service_id", "Type": {"ScalarType": "VARCHAR"}},
            {"Name": "tenant_id", "Type": {"ScalarType": "VARCHAR"}},
            {"Name": "metric_type", "Type": {"ScalarType": "VARCHAR"}},
            {"Name": "measure_name", "Type": {"ScalarType": "VARCHAR"}},
            {"Name": "value", "Type": {"ScalarType": "DOUBLE"}},
        ],
        "Rows": [
            {
                "Data": [
                    {"ScalarValue": "2026-06-26 00:00:00.000000000"},
                    {"ScalarValue": "payment-gw"},
                    {"ScalarValue": "tenant-a"},
                    {"ScalarValue": "latency_ms"},
                    {"ScalarValue": "p95"},
                    {"ScalarValue": "123.4"},
                ]
            }
        ],
    })
    monkeypatch.setattr(app.timestream_query_client, "query", mock_timestream_query)

    mock_response = Mock()
    mock_response.raise_for_status.side_effect = requests.exceptions.HTTPError("500 Server Error")
    monkeypatch.setattr(app.requests, "post", Mock(return_value=mock_response))

    # Thuc thi va khang dinh rang ham se raise exception
    with pytest.raises(Exception) as excinfo:
        app.handler({}, None)

    assert "500 Server Error" in str(excinfo.value)
