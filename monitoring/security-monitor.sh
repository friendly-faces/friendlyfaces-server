#!/bin/bash

source /opt/monitoring/.env

# Exit on error
set -e

# Load environment variables
DISCORD_WEBHOOK_URL=${SECURITY_WEBHOOK_URL:-""}
HOSTNAME=$(hostname)
CHECK_PERIOD=${CHECK_PERIOD:-3600}  # Default to last hour

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

# Initialize alert message
alert_message=""
alert_needed=false

# Check failed SSH attempts (using auth.log)
failed_ssh=$(grep "Failed password" /var/log/auth.log | grep -c "$(date -d "@$(($(date +%s) - CHECK_PERIOD))" '+%b %d')")
if [ "$failed_ssh" -gt 0 ]; then
    alert_needed=true
    alert_message+="🔑 **Failed SSH Attempts:** ${failed_ssh} in the last hour\n\n"
fi

# Check Fail2ban status
banned_ips=$(fail2ban-client status sshd | grep "Currently banned:" | grep -o '[0-9]*')
if [ "$banned_ips" -gt 0 ]; then
    alert_needed=true
    alert_message+="🚫 **Currently Banned IPs:** ${banned_ips}\n\n"
fi

# Check UFW blocked connections
ufw_blocks=$(grep -c "UFW BLOCK" /var/log/ufw.log)
if [ "$ufw_blocks" -gt 0 ]; then
    alert_needed=true
    alert_message+="🛡️ **UFW Blocked Connections:** ${ufw_blocks}\n\n"
fi

# Check for modified system files
if [ -f "/var/lib/aide/aide.db" ]; then
    aide_check=$(aide --check | grep -c "found differences")
    if [ "$aide_check" -gt 0 ]; then
        alert_needed=true
        alert_message+="⚠️ **Modified System Files Detected!**\n"
    fi
fi

# Check for large files in /tmp
large_files=$(find /tmp -type f -size +100M | wc -l)
if [ "$large_files" -gt 0 ]; then
    alert_needed=true
    alert_message+="📁 **Large Files in /tmp:** ${large_files} files over 100MB\n\n"
fi

# Check for unauthorized SUID files
new_suid=$(find / -type f -perm -4000 -print 2>/dev/null | grep -v -f /root/suid_baseline.txt)
if [ ! -z "$new_suid" ]; then
    alert_needed=true
    alert_message+="⚠️ **New SUID Files Detected:**\n\`\`\`\n${new_suid}\n\`\`\`\n"
fi

# Check running processes
suspicious_procs=$(ps aux | grep -E "cryptominer|masscan|nmap|nikto" | grep -v grep)
if [ ! -z "$suspicious_procs" ]; then
    alert_needed=true
    alert_message+="⚠️ **Suspicious Processes Detected:**\n\`\`\`\n${suspicious_procs}\n\`\`\`\n"
fi

# Send alert if any security issues were found
if [ "$alert_needed" = true ]; then
    send_discord_alert "Security Alert" "$alert_message" "15158332"  # Red color
else
    # Send daily security status at midnight
    if [ "$(date '+%H:%M')" = "00:00" ]; then
        status_message="✅ **Daily Security Report**\n\n"
        status_message+="- No security issues detected\n"
        status_message+="- UFW Status: Active\n"
        status_message+="- Fail2ban Status: Active\n"
        send_discord_alert "Security Status Update" "$status_message" "3066993"  # Green color
    fi
fi

exit 0
