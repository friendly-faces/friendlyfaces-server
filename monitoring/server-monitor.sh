#!/bin/bash

source /opt/monitoring/.env

# Exit on error
set -e

# Load environment variables
DISCORD_WEBHOOK_URL=${MONITORING_WEBHOOK_URL:-""}
HOSTNAME=$(hostname)
ALERT_THRESHOLD_CPU=${ALERT_THRESHOLD_CPU:-80}
ALERT_THRESHOLD_MEM=${ALERT_THRESHOLD_MEM:-80}
ALERT_THRESHOLD_DISK=${ALERT_THRESHOLD_DISK:-85}

# Function to send Discord notification
send_discord_alert() {
    local title="$1"
    local description="$2"
    local color="$3"  # Decimal color value

    curl -H "Content-Type: application/json" \
         -X POST \
         -d "{
              \"embeds\": [{
                \"title\": \"$title\",
                \"description\": \"$description\",
                \"color\": $color,
                \"footer\": {
                  \"text\": \"Server: $HOSTNAME | $(date '+%Y-%m-%d %H:%M:%S')\"
                }
              }]
            }" \
         "$DISCORD_WEBHOOK_URL"
}

# Check if Discord webhook is configured
if [ -z "$DISCORD_WEBHOOK_URL" ]; then
    echo "Error: Discord webhook URL not configured"
    exit 1
fi

# Get CPU usage
cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print int($2)}')

# Get memory usage
mem_total=$(free -m | awk '/Mem:/ {print $2}')
mem_used=$(free -m | awk '/Mem:/ {print $3}')
mem_usage=$((mem_used * 100 / mem_total))

# Get disk usage for root partition
disk_usage=$(df -h / | awk 'NR==2 {print int($5)}')

# Initialize alert message
alert_needed=false
alert_message="🚨 **Resource Alert**\n\n"

# Check CPU usage
if [ "$cpu_usage" -gt "$ALERT_THRESHOLD_CPU" ]; then
    alert_needed=true
    alert_message+="**CPU Usage:** ${cpu_usage}% (Threshold: ${ALERT_THRESHOLD_CPU}%)\n"
fi

# Check memory usage
if [ "$mem_usage" -gt "$ALERT_THRESHOLD_MEM" ]; then
    alert_needed=true
    alert_message+="**Memory Usage:** ${mem_usage}% (${mem_used}MB/${mem_total}MB)\n"
fi

# Check disk usage
if [ "$disk_usage" -gt "$ALERT_THRESHOLD_DISK" ]; then
    alert_needed=true
    alert_message+="**Disk Usage:** ${disk_usage}% (Threshold: ${ALERT_THRESHOLD_DISK}%)\n"
fi

# Send alert if any threshold is exceeded
if [ "$alert_needed" = true ]; then
    send_discord_alert "Resource Monitor Alert" "$alert_message" "15158332"  # Red color
else
    # Send daily status update at midnight
    if [ "$(date '+%H:%M')" = "00:00" ]; then
        status_message="✅ **Daily Status Report**\n\n"
        status_message+="**CPU Usage:** ${cpu_usage}%\n"
        status_message+="**Memory Usage:** ${mem_usage}% (${mem_used}MB/${mem_total}MB)\n"
        status_message+="**Disk Usage:** ${disk_usage}%\n"
        send_discord_alert "Server Status Update" "$status_message" "3066993"  # Green color
    fi
fi

exit 0
