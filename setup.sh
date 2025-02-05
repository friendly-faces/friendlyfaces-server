#!/bin/bash

# Exit on any error
set -e

# Define color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script version
VERSION="2.0.0"

# Track completed steps
STEPS_FILE="/tmp/server_setup_progress"

# Function to print colored messages
print_message() {
    local level=$1
    local message=$2
    case $level in
        "info")  echo -e "${GREEN}[INFO] $message${NC}" ;;
        "warn")  echo -e "${YELLOW}[WARN] $message${NC}" ;;
        "error") echo -e "${RED}[ERROR] $message${NC}" ;;
    esac
}

# Function to get user input with validation
get_input() {
    local prompt=$1
    local var_name=$2
    local default=$3
    local value=""

    while [ -z "$value" ]; do
        if [ -n "$default" ]; then
            read -p "$prompt [$default]: " value
            value=${value:-$default}
        else
            read -p "$prompt: " value
        fi

        if [ -z "$value" ]; then
            print_message "warn" "Value cannot be empty"
        fi
    done
    
    eval "$var_name=\"$value\""
}

# Function to mark step as completed
mark_step_complete() {
    echo "$1" >> "$STEPS_FILE"
}

# Function to check if step is completed
is_step_completed() {
    if [ -f "$STEPS_FILE" ]; then
        grep -q "^$1\$" "$STEPS_FILE"
        return $?
    fi
    return 1
}

# Function to check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_message "error" "Please run this script as root or with sudo"
        exit 1
    fi
}

# Function to get configuration variables
get_config() {
    print_message "info" "Please enter the configuration details"
    
    # Get username
    get_input "Enter the username for the new user" "USERNAME"
    
    # Get SSH port
    get_input "Enter the SSH port" "SSH_PORT" "22"
    
    # Get Cloudflare token
    get_input "Enter your Cloudflare token" "CLOUDFLARE_TOKEN"
    
    # Get monitoring repository
    get_input "Enter the monitoring scripts repository URL" "MONITORING_REPO" "https://github.com/yourgithub/monitoring-scripts"
    
    # Get script names
    get_input "Enter the security monitoring script name" "SECURITY_SCRIPT" "security-monitor.sh"
    get_input "Enter the server monitoring script name" "SERVER_SCRIPT" "server-monitor.sh"
    
    # Get webhook URLs
    get_input "Enter Discord webhook URL for server monitoring" "MONITORING_WEBHOOK_URL"
    get_input "Enter Discord webhook URL for security monitoring" "SECURITY_WEBHOOK_URL"
    
    # Get monitoring thresholds
    get_input "Enter CPU usage alert threshold (%)" "ALERT_THRESHOLD_CPU" "80"
    get_input "Enter memory usage alert threshold (%)" "ALERT_THRESHOLD_MEM" "80"
    get_input "Enter disk usage alert threshold (%)" "ALERT_THRESHOLD_DISK" "85"
}

# Function to set up new user
setup_user() {
    if is_step_completed "user_setup"; then
        print_message "info" "User $USERNAME already exists, skipping user creation"
        return 0
    fi

    print_message "info" "Creating user: $USERNAME"
    adduser --gecos "" "$USERNAME" || return 1

    # Ensure user is in sudo group
    usermod -aG sudo "$USERNAME" || return 1

    mark_step_complete "user_setup"
    print_message "info" "User setup completed"
}

# Function to test monitoring setup
test_monitoring() {
    local script_path=$1
    local script_name=$(basename "$script_path")
    
    print_message "info" "Testing $script_name..."
    
    # Run the script as the new user
    if sudo -u "$USERNAME" /bin/bash "$script_path"; then
        print_message "info" "✅ $script_name executed successfully"
        
        # Check if Discord message was sent (look for success log)
        if sudo -u "$USERNAME" grep -q "Discord notification sent successfully" /tmp/monitoring_test.log 2>/dev/null; then
            print_message "info" "✅ Discord notification was sent successfully"
        else
            print_message "warn" "⚠️  Could not confirm if Discord notification was sent"
            print_message "info" "Please check your Discord channel for messages"
        fi
    else
        print_message "error" "❌ $script_name failed to execute"
        print_message "error" "Check the script output above for errors"
        return 1
    fi
}

# Modified setup_monitoring function
setup_monitoring() {
    if is_step_completed "monitoring_setup"; then
        print_message "info" "Monitoring already configured, skipping"
        return 0
    fi

    print_message "info" "Setting up monitoring scripts..."
    
    # Create monitoring directory with proper ownership
    mkdir -p /opt/monitoring
    chown "$USERNAME:$USERNAME" /opt/monitoring
    
    # Switch to the monitoring directory
    cd /opt/monitoring
    
    # Download monitoring scripts as the new user
    sudo -u "$USERNAME" curl -O "${MONITORING_REPO}/${SECURITY_SCRIPT}"
    sudo -u "$USERNAME" curl -O "${MONITORING_REPO}/${SERVER_SCRIPT}"
    
    # Set executable permissions
    chmod +x "${SECURITY_SCRIPT}" "${SERVER_SCRIPT}"
    chown "$USERNAME:$USERNAME" "${SECURITY_SCRIPT}" "${SERVER_SCRIPT}"
    
    # Create .env file with collected settings
    print_message "info" "Creating environment file..."
    cat > /opt/monitoring/.env <<EOF
# Server monitoring settings
MONITORING_WEBHOOK_URL=${MONITORING_WEBHOOK_URL}
ALERT_THRESHOLD_CPU=${ALERT_THRESHOLD_CPU}
ALERT_THRESHOLD_MEM=${ALERT_THRESHOLD_MEM}
ALERT_THRESHOLD_DISK=${ALERT_THRESHOLD_DISK}

# Security monitoring settings
SECURITY_WEBHOOK_URL=${SECURITY_WEBHOOK_URL}
EOF

    # Set proper permissions for .env file
    chown "$USERNAME:$USERNAME" /opt/monitoring/.env
    chmod 600 /opt/monitoring/.env
    
    # Test both monitoring scripts
    print_message "info" "Testing monitoring setup..."
    print_message "info" "This will send test notifications to your Discord channels"
    
    # Test server monitoring
    test_monitoring "/opt/monitoring/${SERVER_SCRIPT}"
    server_test_result=$?
    
    # Test security monitoring
    test_monitoring "/opt/monitoring/${SECURITY_SCRIPT}"
    security_test_result=$?
    
    # Add cronjobs only if tests passed
    if [ $server_test_result -eq 0 ] && [ $security_test_result -eq 0 ]; then
        print_message "info" "Setting up cron jobs..."
        sudo -u "$USERNAME" bash -c '
            (crontab -l 2>/dev/null | grep -v "'${SECURITY_SCRIPT}'"; echo "*/15 * * * * /opt/monitoring/'${SECURITY_SCRIPT}'") | sort -u | crontab -
            (crontab -l 2>/dev/null | grep -v "'${SERVER_SCRIPT}'"; echo "*/5 * * * * /opt/monitoring/'${SERVER_SCRIPT}'") | sort -u | crontab -
        '
        print_message "info" "✅ Cron jobs set up successfully"
    else
        print_message "error" "❌ Monitoring tests failed - please check the errors above"
        print_message "error" "Cron jobs were NOT set up due to test failures"
        return 1
    fi
    
    mark_step_complete "monitoring_setup"
    print_message "info" "Monitoring setup completed successfully!"
}

[Previous SSH, security, and Cloudflared setup functions remain the same but with proper ownership settings]

# Main function
main() {
    check_root
    get_config
    
    print_message "info" "Starting server setup (v${VERSION})..."
    
    # Run setup functions
    update_system
    install_essentials
    setup_user
    configure_ssh
    setup_security
    setup_cloudflared
    setup_monitoring
    
    print_message "info" "Base server setup completed successfully!"
    
    # Print next steps
    cat <<EOF

${GREEN}Next steps:${NC}
1. Log out and log back in as '${USERNAME}'
2. Verify folder permissions: 'ls -la /opt/monitoring'
3. Verify Cloudflared service status: 'systemctl status cloudflared'
4. Check monitoring scripts in /opt/monitoring
5. Review crontab entries: 'crontab -l'

${YELLOW}Important:${NC}
- SSH is configured on port ${SSH_PORT}
- Root login is disabled
- UFW is enabled and configured
- Fail2ban is active
- Monitoring scripts are scheduled via cron
- All necessary folders and files are owned by ${USERNAME}

For any issues, check system logs and service statuses.
EOF
}

# Run main function
main "$@"
