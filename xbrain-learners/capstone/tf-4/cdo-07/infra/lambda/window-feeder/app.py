# lambda/window-feeder/app.py

import os
import json
import logging
from datetime import datetime, timezone

import boto3
import requests
from botocore.config import Config

# =================================================================
# Hằng số và cấu hình
# =================================================================
# Cấu hình logging.
# Best practice là đặt mức độ log thông qua biến môi trường.
LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logger = logging.getLogger()
logger.setLevel(LOG_LEVEL)

REGION = os.environ.get("AWS_REGION", "us-east-1")
TIMESTREAM_DATABASE_NAME = os.environ.get("TIMESTREAM_DATABASE_NAME")
TIMESTREAM_TABLE_NAME = os.environ.get("TIMESTREAM_TABLE_NAME")
TIMESTREAM_QUERY_WINDOW = os.environ.get("TIMESTREAM_QUERY_WINDOW")
AI_ENGINE_PREDICT_URL = os.environ.get("AI_ENGINE_PREDICT_URL")
AI_ENGINE_TIMEOUT_SECONDS = int(os.environ.get("AI_ENGINE_TIMEOUT_SECONDS", "5"))
AUDIT_S3_BUCKET = os.environ.get("AUDIT_S3_BUCKET")
AUDIT_S3_PREFIX = os.environ.get("AUDIT_S3_PREFIX")
INFERENCE_ENABLED_PARAMETER_NAME = os.environ.get("INFERENCE_ENABLED_PARAMETER_NAME")
DRIFT_ALERT_SNS_TOPIC_ARN = os.environ.get("DRIFT_ALERT_SNS_TOPIC_ARN")

# Tải và kiểm tra cấu hình runtime từ biến môi trường của Lambda.
# Hàm này được gọi bên trong các hàm khác thay vì chỉ lúc import để unit test
# có thể vá biến môi trường trước khi chạy mã Lambda.
def load_config():
    """Nạp lại cấu hình từ environment để Lambda và unit test dùng cùng một luồng chạy."""
    global REGION
    global TIMESTREAM_DATABASE_NAME, TIMESTREAM_TABLE_NAME, TIMESTREAM_QUERY_WINDOW
    global AI_ENGINE_PREDICT_URL, AI_ENGINE_TIMEOUT_SECONDS
    global AUDIT_S3_BUCKET, AUDIT_S3_PREFIX, INFERENCE_ENABLED_PARAMETER_NAME, DRIFT_ALERT_SNS_TOPIC_ARN

    required = [
        "AWS_REGION",
        "TIMESTREAM_DATABASE_NAME",
        "TIMESTREAM_TABLE_NAME",
        "TIMESTREAM_QUERY_WINDOW",
        "AI_ENGINE_PREDICT_URL",
        "AI_ENGINE_TIMEOUT_SECONDS",
        "AUDIT_S3_BUCKET",
        "AUDIT_S3_PREFIX",
        "INFERENCE_ENABLED_PARAMETER_NAME",
        "DRIFT_ALERT_SNS_TOPIC_ARN",
    ]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise RuntimeError(f"Missing required environment variables: {', '.join(missing)}")

    REGION = os.environ["AWS_REGION"]
    TIMESTREAM_DATABASE_NAME = os.environ["TIMESTREAM_DATABASE_NAME"]
    TIMESTREAM_TABLE_NAME = os.environ["TIMESTREAM_TABLE_NAME"]
    TIMESTREAM_QUERY_WINDOW = os.environ["TIMESTREAM_QUERY_WINDOW"]
    AI_ENGINE_PREDICT_URL = os.environ["AI_ENGINE_PREDICT_URL"]
    AI_ENGINE_TIMEOUT_SECONDS = int(os.environ["AI_ENGINE_TIMEOUT_SECONDS"])
    AUDIT_S3_BUCKET = os.environ["AUDIT_S3_BUCKET"]
    AUDIT_S3_PREFIX = os.environ["AUDIT_S3_PREFIX"]
    INFERENCE_ENABLED_PARAMETER_NAME = os.environ["INFERENCE_ENABLED_PARAMETER_NAME"]
    DRIFT_ALERT_SNS_TOPIC_ARN = os.environ["DRIFT_ALERT_SNS_TOPIC_ARN"]

# =================================================================
# Khởi tạo AWS client
# =================================================================
# Khởi tạo các client của AWS SDK (boto3) bên ngoài hàm handler.
# Điều này cho phép Lambda tái sử dụng kết nối giữa các lần gọi, giúp cải thiện hiệu năng.
boto_config = Config(
    region_name=REGION,
    retries={'max_attempts': 3, 'mode': 'standard'} # Tự động thử lại 3 lần nếu có lỗi tạm thời
)
ssm_client = boto3.client("ssm", config=boto_config) # Dùng để đọc tham số từ SSM Parameter Store
timestream_query_client = boto3.client("timestream-query", config=boto_config) # Dùng để truy vấn Amazon Timestream
s3_client = boto3.client("s3", config=boto_config)   # Dùng để ghi audit log vào S3
sns_client = boto3.client("sns", config=boto_config) # Dùng để gửi cảnh báo tới SNS

# =================================================================
# Các hàm hỗ trợ
# =================================================================

# Đọc cờ điều khiển vận hành từ SSM Parameter Store.
# Nếu tham số này không đúng bằng "true", Lambda sẽ thoát sớm và không
# truy vấn Timestream hoặc gọi AI Engine.
def is_inference_enabled() -> bool:
    """Kiểm tra "cổng" điều khiển hoạt động trong SSM Parameter Store."""
    load_config()
    try:
        logger.info(f"Checking SSM parameter: {INFERENCE_ENABLED_PARAMETER_NAME}")
        parameter = ssm_client.get_parameter(Name=INFERENCE_ENABLED_PARAMETER_NAME)
        is_enabled = parameter["Parameter"]["Value"].lower() == "true"
        logger.info(f"Inference enabled status: {is_enabled}")
        return is_enabled
    except Exception as e:
        logger.error(f"Failed to read SSM parameter: {e}")
        # An toàn là trên hết: nếu không đọc được tham số, mặc định là hệ thống đang tắt.
        return False

# Chuyển một giá trị ô Timestream thành giá trị Python thông thường.
# Timestream có thể trả về dạng scalar, array, row và time-series, nên hàm hỗ trợ
# này chuẩn hóa dữ liệu trước khi payload được gửi đến AI Engine.
def _parse_timestream_value(value: dict):
    if value.get("NullValue"):
        return None
    if "ScalarValue" in value:
        return value["ScalarValue"]
    if "TimeSeriesValue" in value:
        return [
            {
                "time": item["Time"],
                "value": _parse_timestream_value(item["Value"]),
            }
            for item in value["TimeSeriesValue"]
        ]
    if "ArrayValue" in value:
        return [_parse_timestream_value(item) for item in value["ArrayValue"]]
    if "RowValue" in value:
        return _parse_timestream_row(value["RowValue"])
    return None

# Chuyển một dòng Timestream thành dictionary với khóa là tên cột.
# Điều này giúp mã phía sau không phụ thuộc vào cấu trúc phản hồi lồng nhau của Timestream.
def _parse_timestream_row(row: dict) -> dict:
    return {
        column["Name"]: _parse_timestream_value(value)
        for column, value in zip(row["ColumnInfo"], row["Data"])
    }

# Truy vấn cửa sổ metrics trượt từ Amazon Timestream.
# Đây là phía đọc của luồng nạp dữ liệu Kinesis -> Firehose -> Transformer -> Timestream
# được thể hiện trong sơ đồ kiến trúc.
def query_timestream_metrics() -> dict:
    """Truy vấn dữ liệu metrics trong khoảng thời gian gần nhất từ Amazon Timestream."""
    load_config()
    query = f'''
        SELECT
          time,
          service_id,
          tenant_id,
          metric_type,
          measure_name,
          measure_value::double AS value
        FROM "{TIMESTREAM_DATABASE_NAME}"."{TIMESTREAM_TABLE_NAME}"
        WHERE time >= ago({TIMESTREAM_QUERY_WINDOW})
        ORDER BY time DESC
    '''

    logger.info(
        "Querying Timestream table %s.%s with window %s",
        TIMESTREAM_DATABASE_NAME,
        TIMESTREAM_TABLE_NAME,
        TIMESTREAM_QUERY_WINDOW,
    )

    try:
        response = timestream_query_client.query(QueryString=query)
        rows = [
            _parse_timestream_row({
                "ColumnInfo": response["ColumnInfo"],
                "Data": row["Data"],
            })
            for row in response.get("Rows", [])
        ]
        logger.info("Successfully queried %d rows from Timestream.", len(rows))
        return {
            "source": "timestream",
            "database": TIMESTREAM_DATABASE_NAME,
            "table": TIMESTREAM_TABLE_NAME,
            "window": TIMESTREAM_QUERY_WINDOW,
            "rows": rows,
        }
    except Exception as e:
        logger.error(f"Error querying Timestream: {e}")
        raise

# Gửi payload metrics Timestream đã chuẩn hóa đến API /v1/predict của AI Engine.
# Timeout được cấu hình nên thấp hơn timeout của Lambda để lỗi được trả về có thể dự đoán,
# thay vì treo cho đến khi Lambda bị kết thúc.
def invoke_ai_engine(metrics_data: dict) -> dict:
    """Gửi dữ liệu metrics đến AI Engine để nhận dự báo."""
    load_config()
    logger.info(f"Invoking AI Engine at: {AI_ENGINE_PREDICT_URL}")
    
    try:
        response = requests.post(
            AI_ENGINE_PREDICT_URL,
            json=metrics_data, # Gửi dữ liệu dưới dạng JSON
            timeout=AI_ENGINE_TIMEOUT_SECONDS, # Đặt thời gian chờ để tránh Lambda bị treo
            # auth=aws_auth # Bỏ comment dòng này nếu ALB của bạn được bảo vệ bằng IAM
        )
        response.raise_for_status()  # Ném HTTPError nếu phản hồi lỗi (4xx hoặc 5xx)
        logger.info(f"AI Engine responded with status: {response.status_code}")
        return response.json()
    except requests.exceptions.RequestException as e:
        logger.error(f"Failed to invoke AI Engine: {e}")
        raise

# Lưu input và phản hồi AI thành một object audit trong S3.
# Lỗi audit chỉ được ghi log và không raise vì lỗi quan sát không nên chặn
# luồng inference chính sau khi dự báo đã hoàn tất.
def write_audit_log(input_data: dict, output_data: dict):
    """Ghi một bản ghi kiểm toán (audit record) vào S3."""
    load_config()
    timestamp = datetime.now(timezone.utc)
    audit_record = {
        "invocation_time_utc": timestamp.isoformat(),
        "source": "window-feeder",
        "input_to_ai_engine": input_data,
        "response_from_ai_engine": output_data,
    }
    
    # Sử dụng timestamp trong tên file (key) để đảm bảo tính duy nhất.
    s3_key = f"{AUDIT_S3_PREFIX.strip('/')}/{timestamp.strftime('%Y/%m/%d/%H-%M-%S-%f')}.json"
    
    logger.info(f"Writing audit log to s3://{AUDIT_S3_BUCKET}/{s3_key}")
    try:
        s3_client.put_object(
            Bucket=AUDIT_S3_BUCKET,
            Key=s3_key,
            Body=json.dumps(audit_record, indent=2),
            ContentType="application/json"
        )
    except Exception as e:
        logger.error(f"Failed to write audit log to S3: {e}")
        # Không raise lỗi ở đây, vì việc ghi audit thất bại không nên làm dừng luồng xử lý chính.

# Chỉ phát cảnh báo drift khi phản hồi AI đánh dấu rõ ràng drift_detected.
# SNS topic sẽ phân phối cảnh báo đến các kênh thông báo như Slack hoặc quy trình on-call.
def publish_drift_alert(ai_response: dict):
    """Gửi cảnh báo độ lệch (drift) tới SNS nếu AI Engine phát hiện."""
    load_config()
    if ai_response.get("drift_detected", False): # Kiểm tra có 'drift_detected' trong phản hồi của AI
        message = {
            "default": json.dumps(ai_response, indent=2),
            "subject": f"Drift Detected in {os.environ.get('AWS_LAMBDA_FUNCTION_NAME', 'window-feeder')}",
            "message": f"AI Engine detected a drift. Details: \n{json.dumps(ai_response, indent=2)}"
        }
        logger.warning(f"Drift detected. Publishing alert to {DRIFT_ALERT_SNS_TOPIC_ARN}")
        try:
            sns_client.publish(
                TopicArn=DRIFT_ALERT_SNS_TOPIC_ARN,
                Message=json.dumps({'default': json.dumps(message)}),
                MessageStructure='json'
            )
        except Exception as e:
            logger.error(f"Failed to publish SNS alert: {e}")


# =================================================================
# Handler chính của Lambda
# =================================================================

# Điểm vào của Lambda, được EventBridge gọi theo lịch đã cấu hình.
# Hàm này điều phối toàn bộ workflow window-feeder: kiểm tra cờ điều khiển,
# truy vấn metrics, dự báo AI, ghi audit và cảnh báo drift nếu cần.
def handler(event, context):
    """
    Hàm xử lý chính của Lambda (entry point).
    Điều phối toàn bộ quy trình: Kiểm tra Cổng -> Truy vấn -> Dự báo -> Ghi Audit -> Cảnh báo.
    """
    load_config()
    logger.info(f"Handler started. Event: {json.dumps(event)}")

    # Bước 1: Kiểm tra "cổng" điều khiển hoạt động
    if not is_inference_enabled():
        logger.warning("Inference is disabled via SSM parameter. Exiting.")
        return {"statusCode": 200, "body": "Inference disabled."}

    try:
        # Bước 2: Truy vấn dữ liệu chuỗi thời gian
        metrics_data = query_timestream_metrics()
        if not metrics_data.get("rows"):
            logger.warning("No metrics data returned from Timestream. Exiting.")
            return {"statusCode": 200, "body": "No metrics data."}

        # Bước 3: Gọi đến AI Engine để dự báo
        ai_response = invoke_ai_engine(metrics_data)

        # Bước 4: Ghi lại nhật ký kiểm toán (luôn thực hiện, dù dự báo thành công hay không)
        write_audit_log(input_data=metrics_data, output_data=ai_response)

        # Bước 5: Xử lý và gửi cảnh báo nếu có độ lệch
        publish_drift_alert(ai_response)

        logger.info("Handler finished successfully.")
        return {"statusCode": 200, "body": json.dumps(ai_response)}

    except Exception as e:
        # Xử lý mọi lỗi không mong muốn xảy ra trong quá trình thực thi
        logger.critical(f"An unhandled error occurred in the handler: {e}", exc_info=True)
        # Tùy chọn: bạn có thể gửi một cảnh báo lỗi tới SNS tại đây.
        # Raise lại exception để AWS Lambda biết rằng lần thực thi này đã thất bại.
        raise
