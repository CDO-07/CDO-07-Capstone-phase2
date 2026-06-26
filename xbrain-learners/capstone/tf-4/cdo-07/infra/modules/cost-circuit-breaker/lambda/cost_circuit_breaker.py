import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ssm = boto3.client("ssm")


def handler(event, context):
    parameter_name = os.environ["SSM_PARAMETER_NAME"]
    disabled_value = os.environ.get("DISABLED_VALUE", "false")

    response = ssm.put_parameter(
        Name=parameter_name,
        Type="String",
        Value=disabled_value,
        Overwrite=True,
    )

    logger.info(
        "cost circuit breaker disabled inference: parameter=%s version=%s request_id=%s",
        parameter_name,
        response.get("Version"),
        getattr(context, "aws_request_id", None),
    )

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "parameter_name": parameter_name,
                "value": disabled_value,
                "version": response.get("Version"),
            }
        ),
    }
