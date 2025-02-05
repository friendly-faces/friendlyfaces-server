#!/bin/bash

# Script version
VERSION="1.0.0"

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
DISCORD_WEBHOOK_URL=${SECURITY_WEBHOOK_URL:-""}
HOSTNAME=$(hostname)
CHECK_PERIOD=${CHECK_PERIOD:-3600}  # Default to last hour
LARGE_FILE_THRESHOLD=${LARGE_FILE_THRESHOLD:-100}  # MB
SUSPICIOUS_PROCESS_LIST=${SUSPICIOUS_PROCESS_LIST:-"cryptominer|masscan|nmap|nikto|nc.traditional|nethunter|metasploit"}

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

# Function to send Discord notification with retry mechanism
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

# Function to check service status
check_service_status() {
    local service_name="$1"
    if systemctl is-active --quiet "$service_name"; then
        echo "Active"
    else
        echo "Inactive"
    fi
}

# Function to perform security checks
perform_security_checks() {
    local alert_message=""
    local alert_needed=false

    # Check failed SSH attempts with date filtering
    log "INFO" "Checking failed SSH attempts..."
    if [ -f "/var/log/auth.log" ]; then
        failed_ssh=$(grep "Failed password" /var/log/auth.log | grep -c "$(date -d "@$(($(date +%s) - CHECK_PERIOD))" '+%b %d')" || true)
        if [ "$failed_ssh" -gt 0 ]; then
            alert_needed=true
            alert_message+="🔑 **Failed SSH Attempts:** ${failed_ssh} in the last hour\n"
            # Add details of the last few attempts
            alert_message+="Last attempts:\n\`\`\`\n$(grep "Failed password" /var/log/auth.log | tail -n3)\n\`\`\`\n"
        fi
    else
        log "WARN" "auth.log not found"
    fi

    # Check Fail2ban status with error handling
    log "INFO" "Checking Fail2ban status..."
    if command -v fail2ban-client >/dev/null 2>&1; then
        banned_ips=$(fail2ban-client status sshd | grep "Currently banned:" | grep -o '[0-9]*' || echo "0")
        if [ "$banned_ips" -gt 0 ]; then
            alert_needed=true
            alert_message+="🚫 **Currently Banned IPs:** ${banned_ips}\n"
            # Add details of banned IPs
            alert_message+="IP Details:\n\`\`\`\n$(fail2ban-client status sshd | grep "Banned IP list:")\n\`\`\`\n"
        fi
    else
        log "WARN" "fail2ban-client not installed"
    fi

    # Check UFW blocked connections with better date filtering
    log "INFO" "Checking UFW blocks..."
    if [ -f "/var/log/ufw.log" ]; then
        ufw_blocks=$(grep -c "UFW BLOCK" /var/log/ufw.log || true)
        if [ "$ufw_blocks" -gt 0 ]; then
            alert_needed=true
            alert_message+="🛡️ **UFW Blocked Connections:** ${ufw_blocks}\n"
            # Add details of recent blocks
            alert_message+="Recent blocks:\n\`\`\`\n$(grep "UFW BLOCK" /var/log/ufw.log | tail -n3)\n\`\`\`\n"
        fi
    else
        log "WARN" "ufw.log not found"
    fi

    # Check for modified system files using AIDE
    log "INFO" "Checking system file integrity..."
    if command -v aide >/dev/null 2>&1 && [ -f "/var/lib/aide/aide.db" ]; then
        aide_output=$(aide --check 2>&1 || true)
        aide_check=$(echo "$aide_output" | grep -c "found differences" || true)
        if [ "$aide_check" -gt 0 ]; then
            alert_needed=true
            alert_message+="⚠️ **Modified System Files Detected!**\n"
            alert_message+="Details:\n\`\`\`\n$(echo "$aide_output" | head -n5)\n\`\`\`\n"
        fi
    else
        log "WARN" "AIDE not installed or database not initialized"
    fi

    # Check for large files in /tmp with better filtering
    log "INFO" "Checking for large files..."
    large_files=$(find /tmp -type f -size +"${LARGE_FILE_THRESHOLD}"M -ls 2>/dev/null || true)
    if [ ! -z "$large_files" ]; then
        alert_needed=true
        alert_message+="📁 **Large Files in /tmp:**\n\`\`\`\n${large_files}\n\`\`\`\n"
    fi

    # Check for unauthorized SUID files
    log "INFO" "Checking for unauthorized SUID files..."
    if [ -f "/root/suid_baseline.txt" ]; then
        new_suid=$(find / -type f -perm -4000 -print 2>/dev/null | grep -v -f /root/suid_baseline.txt || true)
        if [ ! -z "$new_suid" ]; then
            alert_needed=true
            alert_message+="⚠️ **New SUID Files Detected:**\n\`\`\`\n${new_suid}\n\`\`\`\n"
        fi
    else
        log "WARN" "SUID baseline file not found"
    fi

    # Check for suspicious processes with enhanced detection
    log "INFO" "Checking for suspicious processes..."
    suspicious_procs=$(ps aux | grep -E "$SUSPICIOUS_PROCESS_LIST" | grep -v grep || true)
    if [ ! -z "$suspicious_procs" ]; then
        alert_needed=true
        alert_message+="⚠️ **Suspicious Processes Detected:**\n\`\`\`\n${suspicious_procs}\n\`\`\`\n"
    fi

    # Check listening ports
    log "INFO" "Checking listening ports..."
    unusual_ports=$(netstat -tuln | grep LISTEN || true)
    if [ ! -z "$unusual_ports" ]; then
        alert_message+="👂 **Listening Ports:**\n\`\`\`\n${unusual_ports}\n\`\`\`\n"
    fi

    # Return results
    echo "$alert_needed::$alert_message"
}

# Main function
main() {
    log "INFO" "Starting security check..."

    # Validate webhook URL
    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        log "ERROR" "Discord webhook URL not configured"
        exit 1
    fi

    # Perform security checks
    IFS="::" read -r alert_needed alert_message <<< "$(perform_security_checks)"

    # Send alerts based on results
    if [ "$alert_needed" = true ]; then
        send_discord_alert "🚨 Security Alert" "$alert_message" "15158332"  # Red color
    else
        # Send daily security status at midnight
        if [ "$(date '+%H:%M')" = "00:00" ]; then
            # Get service statuses
            ufw_status=$(check_service_status "ufw")
            fail2ban_status=$(check_service_status "fail2ban")
            
            status_message="✅ **Daily Security Report**\n\n"
            status_message+="**Service Status:**\n"
            status_message+="- UFW: ${ufw_status}\n"
            status_message+="- Fail2ban: ${fail2ban_status}\n\n"
            status_message+="**System Status:**\n"
            status_message+="- All security checks passed\n"
            status_message+="- No suspicious activities detected\n"
            status_message+="- System integrity verified\n"
            
            send_discord_alert "🛡️ Security Status Update" "$status_message" "3066993"  # Green color
        fi
    fi

    log "INFO" "Security check completed"
}

# Trap errors
trap 'log "ERROR" "Script failed on line $LINENO"' ERR

# Run main function
main

exit 0
