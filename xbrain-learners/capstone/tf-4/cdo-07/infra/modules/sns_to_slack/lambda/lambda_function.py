import json
import urllib.request
import os
import boto3

def get_slack_webhook():
    """
    Retrieves the Slack Webhook URL.
    1. Check for standard SLACK_WEBHOOK_URL environment variable first (for easy local testing).
    2. Check for SLACK_WEBHOOK_PARAMETER_NAME environment variable to query SSM Parameter Store.
    """
    webhook_url = os.environ.get("SLACK_WEBHOOK_URL")
    if webhook_url:
        return webhook_url
        
    ssm_parameter_name = os.environ.get("SLACK_WEBHOOK_PARAMETER_NAME")
    if ssm_parameter_name:
        try:
            print(f"Fetching Slack Webhook URL from SSM Parameter Store: {ssm_parameter_name}")
            ssm = boto3.client('ssm')
            # SecureString parameters require WithDecryption=True
            response = ssm.get_parameter(Name=ssm_parameter_name, WithDecryption=True)
            return response['Parameter']['Value']
        except Exception as e:
            print(f"CRITICAL: Failed to retrieve Slack Webhook from SSM Parameter Store ({ssm_parameter_name}): {str(e)}")
            
    return None

def format_slack_message(subject, message, sns_timestamp):
    """
    Formats the SNS subject and message into a Slack attachment with standard Block Kit components.
    Customizes colors and emojis based on keywords in the subject.
    """
    color = "#36a64f"  # Default green
    emoji = "ℹ️"
    
    subject_lower = subject.lower()
    
    # Check for warning/critical keywords
    if any(kwd in subject_lower for kwd in ["critical", "fail", "error", "drift-alert", "drift"]):
        color = "#E01E5A"  # Red/Pink
        emoji = "🚨"
    elif any(kwd in subject_lower for kwd in ["warning", "warn", "budget-alert", "budget"]):
        color = "#FF9900"  # Orange/Warning
        emoji = "⚠️"
    elif any(kwd in subject_lower for kwd in ["resolve", "ok", "success", "recovered"]):
        color = "#2EB67D"  # Green
        emoji = "✅"
        
    # Build standard Header block
    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": f"{emoji} {subject}",
                "emoji": True
            }
        }
    ]
    
    # Try to parse the SNS message payload as JSON to construct rich fields
    parsed_msg = None
    try:
        parsed_msg = json.loads(message)
    except Exception:
        pass
        
    if parsed_msg and isinstance(parsed_msg, dict):
        # Format JSON key-values into field markdown
        fields_text = ""
        # Handle specific common layouts (e.g., CloudWatch Alarm or Custom drift formats)
        for key, val in parsed_msg.items():
            # Format keys nicely
            formatted_key = key.replace('_', ' ').replace('-', ' ').title()
            if isinstance(val, (dict, list)):
                formatted_val = f"\n```json\n{json.dumps(val, indent=2)}\n```"
            else:
                formatted_val = f"`{val}`"
            fields_text += f"*• {formatted_key}:* {formatted_val}\n"
            
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": fields_text or "_Empty JSON properties_"
            }
        })
    else:
        # Standard plain-text message block
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"{message}"
            }
        })
        
    # Context footer with metadata
    blocks.append({
        "type": "context",
        "elements": [
            {
                "type": "mrkdwn",
                "text": f"🕒 *Time:* {sns_timestamp} | 📦 *Source:* AWS SNS"
            }
        ]
    })
    
    return {
        "text": f"{emoji} {subject}",
        "attachments": [
            {
                "color": color,
                "blocks": blocks
            }
        ]
    }

def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    webhook_url = get_slack_webhook()
    
    if not webhook_url:
        print("CRITICAL ERROR: Slack Webhook URL is not configured. Verify env variables and SSM permissions.")
        return {"statusCode": 500, "body": "Configuration Error: Slack Webhook URL missing."}
        
    for record in event.get('Records', []):
        sns = record.get('Sns', {})
        subject = sns.get('Subject') or "AWS Alert Notification"
        message = sns.get('Message') or "No details provided."
        timestamp = sns.get('Timestamp') or "N/A"
        
        # Build Slack Payload
        slack_payload = format_slack_message(subject, message, timestamp)
        
        # Prepare POST request
        req = urllib.request.Request(
            webhook_url,
            data=json.dumps(slack_payload).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        
        try:
            print(f"Sending payload to Slack Webhook for Subject: {subject}")
            with urllib.request.urlopen(req) as response:
                resp_body = response.read().decode('utf-8')
                print(f"Slack webhook endpoint response: {resp_body}")
        except Exception as e:
            print(f"ERROR: Failed to deliver message to Slack: {str(e)}")
            return {"statusCode": 500, "body": f"Failed to forward message: {str(e)}"}
            
    return {"statusCode": 200, "body": "Events processed and forwarded successfully."}
