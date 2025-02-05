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
STEPS_FILE="/tmp/wordpress_setup_progress"

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

# Function to get system memory info
get_system_memory() {
    TOTAL_RAM_MB=$(free -m | awk '/Mem:/ {print $2}')
    AVAILABLE_RAM_MB=$(free -m | awk '/Mem:/ {print $7}')
}

# Function to get WordPress configuration
get_wordpress_config() {
    print_message "info" "Please enter WordPress configuration details"
    
    # Site Details
    get_input "Enter the site domain (can be changed later, e.g., example.com)" "SITE_DOMAIN"
    get_input "Enter the site title (can be changed later)" "SITE_TITLE"
    get_input "Enter admin email" "ADMIN_EMAIL"
    
    # Database Configuration
    print_message "info" "Database Configuration"
    PS3="Select database type: "
    select DB_TYPE in "Managed Database" "Local Database"; do
        case $DB_TYPE in
            "Managed Database")
                get_input "Enter database host" "DB_HOST"
                get_input "Enter database name" "DB_NAME"
                get_input "Enter database user" "DB_USER"
                get_input "Enter database password" "DB_PASSWORD"
                DB_IS_LOCAL="false"
                break
                ;;
            "Local Database")
                get_input "Enter database name" "DB_NAME" "wordpress"
                get_input "Enter database user" "DB_USER" "wordpress"
                get_input "Enter database password" "DB_PASSWORD"
                DB_HOST="localhost"
                DB_IS_LOCAL="true"
                break
                ;;
            *) print_message "warn" "Invalid option" ;;
        esac
    done
    
    # Media Storage Configuration
    print_message "info" "Media Storage Configuration"
    PS3="Select media storage type: "
    select STORAGE_TYPE in "S3/Spaces Storage" "Local Storage"; do
        case $STORAGE_TYPE in
            "S3/Spaces Storage")
                USE_S3="true"
                get_input "Enter S3 endpoint (e.g., https://nyc3.digitaloceanspaces.com)" "S3_ENDPOINT"
                get_input "Enter access key" "S3_ACCESS_KEY"
                get_input "Enter secret key" "S3_SECRET_KEY"
                get_input "Enter bucket name" "S3_BUCKET"
                break
                ;;
            "Local Storage")
                USE_S3="false"
                break
                ;;
            *) print_message "warn" "Invalid option" ;;
        esac
    done
    
    # Redis Configuration
    get_system_memory
    print_message "info" "Redis Configuration"
    PS3="Select Redis configuration: "
    select REDIS_TYPE in "No Redis" "Local Redis" "Remote Redis"; do
        case $REDIS_TYPE in
            "No Redis")
                USE_REDIS="false"
                break
                ;;
            "Local Redis")
                USE_REDIS="true"
                REDIS_IS_LOCAL="true"
                REDIS_HOST="localhost"
                REDIS_PORT="6379"
                # Calculate recommended Redis memory (20% of available RAM)
                RECOMMENDED_REDIS_MB=$((AVAILABLE_RAM_MB / 5))
                print_message "info" "Recommended Redis memory: ${RECOMMENDED_REDIS_MB}MB (20% of available RAM)"
                get_input "Enter Redis memory limit in MB" "REDIS_MEMORY_LIMIT" "${RECOMMENDED_REDIS_MB}"
                break
                ;;
            "Remote Redis")
                USE_REDIS="true"
                REDIS_IS_LOCAL="false"
                get_input "Enter Redis host" "REDIS_HOST"
                get_input "Enter Redis port" "REDIS_PORT" "6379"
                get_input "Enter Redis password" "REDIS_PASSWORD"
                break
                ;;
            *) print_message "warn" "Invalid option" ;;
        esac
    done
    
    # Backup Configuration
    print_message "info" "Backup Configuration"
    PS3="Would you like to configure automated backups? "
    select BACKUP_CONFIG in "Yes" "No"; do
        case $BACKUP_CONFIG in
            "Yes")
                USE_BACKUPS="true"
                # Only ask about database backups if using local database
                if [ "$DB_IS_LOCAL" = "true" ]; then
                    BACKUP_DB="true"
                    print_message "info" "Database backups will be included as you're using a local database"
                else
                    BACKUP_DB="false"
                    print_message "info" "Database backups skipped as you're using a managed database"
                fi
                get_input "Enter backup frequency (in days)" "BACKUP_FREQUENCY" "1"
                get_input "Enter backup retention period (in days)" "BACKUP_RETENTION" "7"
                break
                ;;
            "No")
                USE_BACKUPS="false"
                break
                ;;
            *) print_message "warn" "Invalid option" ;;
        esac
    done
    
    # WordPress Update Configuration
    print_message "info" "WordPress Update Configuration"
    
    # Core Updates
    PS3="Select WordPress core update strategy: "
    select WP_CORE_UPDATES in "No automatic updates" "Minor updates only" "All updates"; do
        case $WP_CORE_UPDATES in
            "No automatic updates"|"Minor updates only"|"All updates")
                break
                ;;
            *) print_message "warn" "Invalid option" ;;
        esac
    done
    
    # Plugin Updates
    print_message "info" "Enable automatic plugin updates? (y/N)"
    read -r WP_PLUGIN_UPDATES
    
    # Theme Updates
    print_message "info" "Enable automatic theme updates? (y/N)"
    read -r WP_THEME_UPDATES
    
    # PHP Configuration
    print_message "info" "PHP Configuration"
    get_input "Enter maximum upload size (e.g., 64M)" "PHP_UPLOAD_MAX" "64M"
    get_input "Enter maximum execution time (seconds)" "PHP_MAX_EXECUTION_TIME" "300"
    get_input "Enter memory limit" "PHP_MEMORY_LIMIT" "256M"
}

# Function to setup Redis
setup_redis() {
    if [ "$USE_REDIS" != "true" ]; then
        return 0
    fi

    if [ "$REDIS_IS_LOCAL" = "true" ]; then
        print_message "info" "Installing and configuring local Redis..."
        
        # Install Redis
        apt install -y redis-server
        
        # Configure Redis
        cat > /etc/redis/redis.conf <<EOF
bind 127.0.0.1
port 6379
maxmemory ${REDIS_MEMORY_LIMIT}mb
maxmemory-policy allkeys-lru
EOF
        
        # Enable and start Redis
        systemctl enable redis-server
        systemctl restart redis-server
    fi
    
    # Install Redis PHP extension
    apt install -y php8.2-redis
}

# Function to setup backups
setup_backups() {
    if [ "$USE_BACKUPS" != "true" ]; then
        return 0
    fi

    print_message "info" "Setting up automated backups..."
    
    # Create backup script
    cat > /opt/scripts/wordpress-backup.sh <<EOF
#!/bin/bash

BACKUP_DIR="/var/backups/wordpress"
SITE_DIR="/var/www/wordpress"
DATE=\$(date +%Y%m%d)

# Create backup directory
mkdir -p "\$BACKUP_DIR"

# Backup wp-content
tar -czf "\$BACKUP_DIR/wp-content-\$DATE.tar.gz" "\$SITE_DIR/wp-content"
EOF

    # Add database backup if using local database
    if [ "$BACKUP_DB" = "true" ]; then
        cat >> /opt/scripts/wordpress-backup.sh <<EOF

# Backup database
wp db export "\$BACKUP_DIR/database-\$DATE.sql" --path="\$SITE_DIR"
EOF
    fi

    # Add cleanup logic
    cat >> /opt/scripts/wordpress-backup.sh <<EOF

# Clean up old backups
find "\$BACKUP_DIR" -type f -mtime +${BACKUP_RETENTION} -delete
EOF

    chmod +x /opt/scripts/wordpress-backup.sh
    
    # Add to crontab
    BACKUP_SCHEDULE="0 0 */${BACKUP_FREQUENCY} * *"  # Run at midnight every X days
    (crontab -l 2>/dev/null; echo "$BACKUP_SCHEDULE /opt/scripts/wordpress-backup.sh") | sort -u | crontab -
}

# Function to configure WordPress updates
configure_updates() {
    # Create mu-plugin for update configuration
    mkdir -p /var/www/wordpress/wp-content/mu-plugins
    
    cat > /var/www/wordpress/wp-content/mu-plugins/update-control.php <<EOF
<?php
/*
Plugin Name: Update Control
Description: Controls automatic updates
Version: 1.0
*/

// Configure core updates
define('WP_AUTO_UPDATE_CORE', '${WP_CORE_UPDATES}');

// Configure plugin updates
add_filter('auto_update_plugin', function() {
    return ${WP_PLUGIN_UPDATES};
});

// Configure theme updates
add_filter('auto_update_theme', function() {
    return ${WP_THEME_UPDATES};
});
EOF
}

[... Previous functions like setup_nginx(), setup_php(), etc. remain the same but adapted for our choices ...]

# Main function
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_message "error" "Please run this script as root or with sudo"
        exit 1
    fi
    
    print_message "info" "Starting WordPress installation (v${VERSION})..."
    
    # Get configuration
    get_wordpress_config
    
    # Create web root directory
    mkdir -p /var/www/wordpress
    
    # Run setup functions based on choices
    setup_nginx
    setup_php
    
    if [ "$DB_IS_LOCAL" = "true" ]; then
        setup_mysql
    fi
    
    if [ "$USE_REDIS" = "true" ]; then
        setup_redis
    fi
    
    setup_wp_cli
    install_wordpress
    configure_updates
    
    if [ "$USE_BACKUPS" = "true" ]; then
        setup_backups
    fi
    
    print_message "info" "WordPress installation completed successfully!"
    
    # Print summary of configurations
    cat <<EOF

${GREEN}Installation Complete!${NC}

WordPress has been installed with the following configuration:
- Site URL: https://${SITE_DOMAIN}
- Admin URL: https://${SITE_DOMAIN}/wp-admin/
- Database: $([ "$DB_IS_LOCAL" = "true" ] && echo "Local" || echo "Managed")
- Media Storage: $([ "$USE_S3" = "true" ] && echo "S3/Spaces" || echo "Local")
- Redis Caching: $([ "$USE_REDIS" = "true" ] && echo "Enabled" || echo "Disabled")
$([ "$USE_REDIS" = "true" ] && [ "$REDIS_IS_LOCAL" = "true" ] && echo "  - Redis Memory: ${REDIS_MEMORY_LIMIT}MB")
- Backups: $([ "$USE_BACKUPS" = "true" ] && echo "Enabled (Every ${BACKUP_FREQUENCY} days, kept for ${BACKUP_RETENTION} days)" || echo "Disabled")
- Updates:
  - Core: ${WP_CORE_UPDATES}
  - Plugins: $([ "${WP_PLUGIN_UPDATES}" = "true" ] && echo "Automatic" || echo "Manual")
  - Themes: $([ "${WP_THEME_UPDATES}" = "true" ] && echo "Automatic" || echo "Manual")

${YELLOW}Next Steps:${NC}
1. Access your WordPress admin panel at https://${SITE_DOMAIN}/wp-admin/
2. Configure your chosen theme
3. Set up Cloudflare Tunnel to point to localhost:80

${YELLOW}Monitoring:${NC}
- PHP error log: /var/log/php8.2-fpm.log
- Nginx error log: /var/log/nginx/error.log
$([ "$USE_REDIS" = "true" ] && echo "- Redis log: /var/log/redis/redis-server.log")
$([ "$USE_BACKUPS" = "true" ] && echo "- Backup log: /var/log/syslog (via cron)")

EOF
}

# Run main function
main "$@"
