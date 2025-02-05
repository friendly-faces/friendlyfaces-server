#!/bin/bash

# Script version
VERSION="1.0.0"

# Parse command line arguments
FORCE_TEST=false
while [ $# -gt 0 ]; do
    case "$1" in
        -t|--test)
            FORCE_TEST=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [-t|--test]"
            exit 1
            ;;
    esac
done

# First find the script's directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Load environment variables with proper error handling
if [ -f "${SCRIPT_DIR}/.env" ]; then
    source "${SCRIPT_DIR}/.env"
else
    echo "Error: .env file not found in ${SCRIPT_DIR}"
    exit 1
fi

# Exit on error
set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Required environment variables with defaults
DISCORD_WEBHOOK_URL=${MONITORING_WEBHOOK_URL:-""}
HOSTNAME=$(hostname)
ALERT_THRESHOLD_CPU=${ALERT_THRESHOLD_CPU:-80}
ALERT_THRESHOLD_MEM=${ALERT_THRESHOLD_MEM:-80}
ALERT_THRESHOLD_DISK=${ALERT_THRESHOLD_DISK:-85}

# Logging function
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        "INFO")  echo -e "${GREEN}[${timestamp}] [INFO] ${message}${NC}" ;;
        "WARN")  echo -e "${YELLOW}[${timestamp}] [WARN] ${message}${NC}" ;;
        "ERROR") echo -e "${RED}[${timestamp}] [ERROR] ${message}${NC}" ;;
    esac
}

# Function to send Discord notification with better error handling
send_discord_alert() {
    local title="$1"
    local description="$2"
    local color="$3"  # Decimal color value
    local max_retries=3
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        response=$(curl -s -w "\n%{http_code}" -H "Content-Type: application/json" \
             -X POST \
             -d "{
                  \"embeds\": [{
                    \"title\": \"$title\",
                    \"description\": \"$description\",
                    \"color\": $color,
                    \"footer\": {
                      \"text\": \"Server: $HOSTNAME | $(date '+%Y-%m-%d %H:%M:%S') | v${VERSION}\"
                    }
                  }]
                }" \
             "$DISCORD_WEBHOOK_URL")
        
        status_code=$(echo "$response" | tail -n1)
        response_body=$(echo "$response" | head -n-1)

        if [ "$status_code" = "204" ]; then
            log "INFO" "Discord notification sent successfully"
            return 0
        else
            retry_count=$((retry_count + 1))
            if [ $retry_count -lt $max_retries ]; then
                log "WARN" "Failed to send Discord notification (attempt $retry_count/$max_retries). Retrying..."
                sleep 5
            else
                log "ERROR" "Failed to send Discord notification after $max_retries attempts. Status code: $status_code"
                return 1
            fi
        fi
    done
}

# Validation function for webhook URL
validate_webhook() {
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        log "ERROR" "Discord webhook URL not configured in .env file"
        exit 1
    fi

    if [[ ! "$DISCORD_WEBHOOK_URL" =~ ^https://discord\.com/api/webhooks/ ]]; then
        log "ERROR" "Invalid Discord webhook URL format"
        exit 1
    fi
}

# Function to get system metrics with error handling
get_system_metrics() {
    # Get CPU usage (average over last minute for more accuracy)
    cpu_usage=$(top -bn2 -d1 | grep "Cpu(s)" | tail -n1 | awk '{print int($2)}')
    if [ -z "$cpu_usage" ]; then
        log "WARN" "Failed to get CPU usage"
        cpu_usage="N/A"
    fi

    # Get memory usage
    if ! mem_info=$(free -m); then
        log "WARN" "Failed to get memory information"
        mem_total="N/A"
        mem_used="N/A"
        mem_usage="N/A"
    else
        mem_total=$(echo "$mem_info" | awk '/Mem:/ {print $2}')
        mem_used=$(echo "$mem_info" | awk '/Mem:/ {print $3}')
        mem_usage=$((mem_used * 100 / mem_total))
    fi

    # Get disk usage for all mounted partitions
    if ! disk_info=$(df -h | grep '^/dev/' | awk '{print $6 ": " $5}'); then
        log "WARN" "Failed to get disk information"
        disk_usage="N/A"
    else
        disk_usage=$(df -h / | awk 'NR==2 {print int($5)}')
    fi

    # Get system load averages
    load_avg=$(cat /proc/loadavg | awk '{print $1, $2, $3}')

    # Get number of processes
    processes=$(ps aux | wc -l)

    # Get system uptime
    uptime=$(uptime -p)
}

# Main monitoring logic
main() {
    log "INFO" "Starting server monitoring check..."
    
    # Validate webhook
    validate_webhook

    # Get system metrics
    get_system_metrics

    # If test flag is set, force send a status report
    if [ "$FORCE_TEST" = true ]; then
        log "INFO" "Running in test mode - sending immediate status report"
        status_message="🔍 **Test Status Report**\n\n"
        status_message+="**System Overview:**\n"
        status_message+="- CPU Usage: ${cpu_usage}%\n"
        status_message+="- Load Average: ${load_avg}\n"
        status_message+="- Memory Usage: ${mem_usage}% (${mem_used}MB/${mem_total}MB)\n"
        status_message+="- Disk Usage: ${disk_usage}%\n"
        status_message+="- Process Count: ${processes}\n"
        status_message+="- System Uptime: ${uptime}\n\n"
        status_message+="**Disk Details:**\n\`\`\`\n${disk_info}\n\`\`\`\n\n"
        status_message+="*This is a test message sent during setup/verification.*"
        
        send_discord_alert "🔧 Server Monitor Test" "$status_message" "3447003"  # Blue color
        return
    fi

    # Initialize alert message
    alert_needed=false
    alert_message="🚨 **Resource Alert**\n\n"
    
    # Check CPU usage
    if [ "$cpu_usage" != "N/A" ] && [ "$cpu_usage" -gt "$ALERT_THRESHOLD_CPU" ]; then
        alert_needed=true
        alert_message+="**CPU Usage:** ${cpu_usage}% (Threshold: ${ALERT_THRESHOLD_CPU}%)\n"
        alert_message+="**Load Average:** ${load_avg}\n"
    fi

    # Check memory usage
    if [ "$mem_usage" != "N/A" ] && [ "$mem_usage" -gt "$ALERT_THRESHOLD_MEM" ]; then
        alert_needed=true
        alert_message+="**Memory Usage:** ${mem_usage}% (${mem_used}MB/${mem_total}MB)\n"
    fi

    # Check disk usage
    if [ "$disk_usage" != "N/A" ] && [ "$disk_usage" -gt "$ALERT_THRESHOLD_DISK" ]; then
        alert_needed=true
        alert_message+="**Disk Usage:** ${disk_usage}% (Threshold: ${ALERT_THRESHOLD_DISK}%)\n"
        alert_message+="**Disk Details:**\n\`\`\`\n${disk_info}\n\`\`\`\n"
    fi

    # Add process count and uptime to the message
    alert_message+="\n**Additional Info:**\n"
    alert_message+="- Process Count: ${processes}\n"
    alert_message+="- System Uptime: ${uptime}\n"

    # Send alert if any threshold is exceeded
    if [ "$alert_needed" = true ]; then
        send_discord_alert "⚠️ Resource Monitor Alert" "$alert_message" "15158332"  # Red color
    else
        # Send daily status update between 9:00-9:04 AM
        current_hour=$(date '+%H')
        current_min=$(date '+%M')
        if [ "$current_hour" = "09" ] && [ "$current_min" -lt "04" ]; then
            status_message="✅ **Daily Status Report**\n\n"
            status_message+="**System Overview:**\n"
            status_message+="- CPU Usage: ${cpu_usage}%\n"
            status_message+="- Load Average: ${load_avg}\n"
            status_message+="- Memory Usage: ${mem_usage}% (${mem_used}MB/${mem_total}MB)\n"
            status_message+="- Disk Usage: ${disk_usage}%\n"
            status_message+="- Process Count: ${processes}\n"
            status_message+="- System Uptime: ${uptime}\n\n"
            status_message+="**Disk Details:**\n\`\`\`\n${disk_info}\n\`\`\`"
            
            send_discord_alert "📊 Server Status Update" "$status_message" "3066993"  # Green color
        fi
    fi

    log "INFO" "Monitoring check completed"
}

# Trap errors
trap 'log "ERROR" "Script failed on line $LINENO"' ERR

# Run main function
main

exit 0
