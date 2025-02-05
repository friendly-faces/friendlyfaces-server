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
chown $SUDO_USER:$SUDO_USER "$BACKUP_DIR"

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
    chown $SUDO_USER:$SUDO_USER /var/www/wordpress/wp-content/mu-plugins
    
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

# Function to install and configure Nginx
setup_nginx() {
    if is_step_completed "nginx_setup"; then
        print_message "info" "Nginx already configured, skipping"
        return 0
    fi

    print_message "info" "Installing and configuring Nginx..."
    
    # Install Nginx
    apt install -y nginx
    
    # Create Nginx configuration for WordPress with Cloudflare Tunnel
    cat > "/etc/nginx/sites-available/${SITE_DOMAIN}.conf" <<EOF
server {
    listen 80;
    server_name localhost; 
    root /var/www/wordpress;
    index index.php;

    # Larger upload size
    client_max_body_size ${PHP_UPLOAD_MAX};

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src * data: 'unsafe-eval' 'unsafe-inline'" always;

    # Logging
    access_log /var/log/nginx/wordpress.access.log;
    error_log /var/log/nginx/wordpress.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    # Static files
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)\$ {
        expires max;
        log_not_found off;
    }

    # Deny access to sensitive files
    location ~ /\. {
        deny all;
    }

    location = /favicon.ico {
        log_not_found off;
        access_log off;
    }

    location = /robots.txt {
        allow all;
        log_not_found off;
        access_log off;
    }
}
EOF

    # Enable the site and remove default
    ln -sf "/etc/nginx/sites-available/${SITE_DOMAIN}.conf" /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Test and reload Nginx
    nginx -t && systemctl reload nginx
    
    mark_step_complete "nginx_setup"
}

# Function to install and configure PHP
setup_php() {
    if is_step_completed "php_setup"; then
        print_message "info" "PHP already configured, skipping"
        return 0
    fi

    print_message "info" "Installing and configuring PHP..."
    
    # Install PHP and extensions
    apt install -y php8.2-fpm php8.2-mysql php8.2-curl php8.2-gd php8.2-mbstring \
        php8.2-xml php8.2-zip php8.2-imagick php8.2-intl
    
    if [ "$USE_REDIS" = "true" ]; then
        apt install -y php8.2-redis
    fi
    
    # Configure PHP
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = ${PHP_UPLOAD_MAX}/" /etc/php/8.2/fpm/php.ini
    sed -i "s/post_max_size = .*/post_max_size = ${PHP_UPLOAD_MAX}/" /etc/php/8.2/fpm/php.ini
    sed -i "s/memory_limit = .*/memory_limit = ${PHP_MEMORY_LIMIT}/" /etc/php/8.2/fpm/php.ini
    sed -i "s/max_execution_time = .*/max_execution_time = ${PHP_MAX_EXECUTION_TIME}/" /etc/php/8.2/fpm/php.ini
    
    # Restart PHP-FPM
    systemctl restart php8.2-fpm
    
    mark_step_complete "php_setup"
}

# Function to install and configure MySQL if local
setup_mysql() {
    if [ "$DB_IS_LOCAL" != "true" ]; then
        return 0
    fi

    if is_step_completed "mysql_setup"; then
        print_message "info" "MySQL already configured, skipping"
        return 0
    fi

    print_message "info" "Installing and configuring MySQL..."
    
    # Install MySQL
    apt install -y mariadb-server
    
    # Create database and user
    mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};"
    mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
    mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    
    mark_step_complete "mysql_setup"
}

# Function to install WP-CLI
setup_wp_cli() {
    if is_step_completed "wp_cli_setup"; then
        print_message "info" "WP-CLI already installed, skipping"
        return 0
    fi

    print_message "info" "Installing WP-CLI..."
    
    # Download and install WP-CLI
    curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar
    mv wp-cli.phar /usr/local/bin/wp
    
    mark_step_complete "wp_cli_setup"
}

install_wordpress() {
    if is_step_completed "wordpress_install"; then
        print_message "info" "WordPress already installed, skipping"
        return 0
    fi
    print_message "info" "Installing WordPress..."
    
    mkdir -p /var/www/wordpress
    chown $SUDO_USER:$SUDO_USER /var/www/wordpress
    
    # Download WordPress as current user
    cd /var/www
    sudo -u $SUDO_USER wp core download --path=wordpress
    
    # Create wp-config.php
    sudo -u $SUDO_USER wp config create \
        --path=/var/www/wordpress \
        --dbname="${DB_NAME}" \
        --dbuser="${DB_USER}" \
        --dbpass="${DB_PASSWORD}" \
        --dbhost="${DB_HOST}" \
        --extra-php <<PHP
define('WP_DEBUG', false);
define('FORCE_SSL_ADMIN', true);
if ( isset( $_SERVER['HTTP_X_FORWARDED_PROTO'] ) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https' ) {
    $_SERVER['HTTPS'] = 'on';
}
define('WP_MEMORY_LIMIT', '${PHP_MEMORY_LIMIT}');
define('FS_METHOD', 'direct');
PHP
    
    # Set up Redis configuration if enabled
    if [ "$USE_REDIS" = "true" ]; then
        sudo -u $SUDO_USER wp config set WP_CACHE true --raw --path=/var/www/wordpress
        sudo -u $SUDO_USER wp config set WP_REDIS_HOST "${REDIS_HOST}" --path=/var/www/wordpress
        sudo -u $SUDO_USER wp config set WP_REDIS_PORT "${REDIS_PORT}" --path=/var/www/wordpress
        if [ -n "$REDIS_PASSWORD" ]; then
            sudo -u $SUDO_USER wp config set WP_REDIS_PASSWORD "${REDIS_PASSWORD}" --path=/var/www/wordpress
        fi
    fi
    
    # Set up S3 configuration if enabled
    if [ "$USE_S3" = "true" ]; then
        sudo -u $SUDO_USER wp config set S3_UPLOADS_BUCKET "${S3_BUCKET}" --path=/var/www/wordpress
        sudo -u $SUDO_USER wp config set S3_UPLOADS_KEY "${S3_ACCESS_KEY}" --path=/var/www/wordpress
        sudo -u $SUDO_USER wp config set S3_UPLOADS_SECRET "${S3_SECRET_KEY}" --path=/var/www/wordpress
        sudo -u $SUDO_USER wp config set S3_UPLOADS_ENDPOINT "${S3_ENDPOINT}" --path=/var/www/wordpress
    fi
    
    # Generate a random admin password and store it in a variable
    ADMIN_PASS=$(openssl rand -base64 12)
    
    # Install WordPress with the generated admin password
    sudo -u $SUDO_USER wp core install \
        --path=/var/www/wordpress \
        --url="https://${SITE_DOMAIN}" \
        --title="${SITE_TITLE}" \
        --admin_user=admin \
        --admin_password="${ADMIN_PASS}" \
        --admin_email="${ADMIN_EMAIL}"
    
    # Set correct permissions but keep wp-config.php under user ownership
    cp /var/www/wordpress/wp-config.php /tmp/wp-config.tmp
    chown -R www-data:www-data /var/www/wordpress
    mv /tmp/wp-config.tmp /var/www/wordpress/wp-config.php
    chown $SUDO_USER:$SUDO_USER /var/www/wordpress/wp-config.php
    
    find /var/www/wordpress/ -type d -exec chmod 755 {} \;
    find /var/www/wordpress/ -type f -exec chmod 644 {} \;
    
    mark_step_complete "wordpress_install"
}

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
    
    # Print summary of configurations, including the generated admin password
    cat <<EOF

${GREEN}Installation Complete!${NC}

WordPress has been installed with the following configuration:
- Site URL: https://${SITE_DOMAIN}
- Admin URL: https://${SITE_DOMAIN}/wp-admin/
- Admin Email: ${ADMIN_EMAIL}
- Admin Password: ${ADMIN_PASS}
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
