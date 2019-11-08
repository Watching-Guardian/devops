#!/usr/bin/env bash
# This script will install a new BookStack instance on a fresh Centos 7 server. Tested on CentOS Linux release 7.6.1810 (minimal).
# This script is experimental!
# This script will install Apache2 or nginx, and MySQL 5.7 or MariaDB 10.3

# Check root level permissions
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: The installation script must be run as root" >&2
    exit 1
fi

# Check if OS is CentOS 7
# Comment next section, if you want to skip this check
if [[ "$(grep 'CentOS Linux release 7' /etc/redhat-release)" != "CentOS Linux release 7".* ]]; then
    echo "Error: The OS is not CentOS 7" >&2
    exit 1
fi

# Fetch domain to use from first provided parameter,
# Otherwise request the user to input their domain
DOMAIN=$1
if [ -z $1 ]; then
    echo -e "\nEnter the domain you want to host BookStack and press [ENTER]\nExample: "$HOSTNAME""
    read DOMAIN
fi
if [ -z $DOMAIN ]; then
    DOMAIN=$HOSTNAME
    echo -e "Using domain: "$DOMAIN""
else
    echo -e "Using domain: "$DOMAIN""
fi

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')

# Install core system packages
yum -y -q install epel-release yum-utils
yum -y -q install https://centos7.iuscommunity.org/ius-release.rpm
rpm -Uvh https://mirror.webtatic.com/yum/el7/webtatic-release.rpm
yum -y -q install git curl wget unzip policycoreutils-python php72u php72u-fpm php72u-gd php72u-mbstring php72u-mysqlnd php72u-pdo php72u-tidy php72u-cli php72u-json php72u-xsl php72u-xml php72u-ldap php72u-common php72u-mcrypt php72u-curl php72u-tokenizer
# Select web-server
echo -e "\v"
PS3='Please select your web-server: '
options=("Apache2" "nginx" "Quit")
select opt in "${options[@]}";
do
    case $opt in
        "Apache2")
            echo "Installing Apache2..."
            WEBSERVER="httpd"
            yum -y -q install httpd mod_ssl
            break
            ;;
        "nginx")
            echo "Installing nginx..."
            WEBSERVER="nginx"
            yum -y -q install nginx
            break
            ;;
        "Quit")
            echo "Exiting..."
            exit 1
            ;;
        *) echo "Invalid option $REPLY";;
    esac
done

# Select database
PS3='Please select your database-server: '
options=("MySQL" "MariaDB" "Quit")
select opt in "${options[@]}";
do
    case $opt in
        "MySQL")
            echo -e "Installing MySQL...\n"
            DATABASE="mysql"
            yum -y -q install https://dev.mysql.com/get/mysql80-community-release-el7-1.noarch.rpm
            yum-config-manager --disable mysql80-community > /dev/null
            yum-config-manager --enable mysql57-community > /dev/null
            yum -y -q install mysql-community-server
            break
            ;;
        "MariaDB")
            echo -e "Installing MariaDB...\n"
            DATABASE="mariadb"
            cat > /etc/yum.repos.d/MariaDB.repo <<EOL
# MariaDB 10.3 CentOS repository
[mariadb]
name = MariaDB
baseurl = http://yum.mariadb.org/10.3/centos7-amd64
gpgkey=https://yum.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOL
            yum -y -q install MariaDB-server
            break
            ;;
        "Quit")
            echo "Exiting..."
            exit 1
            ;;
        *) echo "Invalid option $REPLY";;
    esac
done

# Set up database
# Password generator string is not optimal. Should be reworked.
MYSQL_ROOT_PASS=8Gl"$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 18)\$"
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 15)\$"
case $DATABASE in
        "mysql")
            systemctl enable mysqld && systemctl start mysqld
            MYSQL_TEMP_PASS="$(grep 'temporary password' /var/log/mysqld.log | grep -o '............$')"
            
            # MySQL change root password
            mysql --user root --password="$MYSQL_TEMP_PASS" --connect-expired-password --execute="ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';"
           ;;
        "mariadb")
            systemctl enable mariadb && systemctl start mariadb

            # MariaDB change root password
            mysql --user root --execute="ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT_PASS';"
           ;;
esac
		   
# Create Database
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="CREATE DATABASE bookstack;"
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="CREATE USER 'bookstack'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql --user root --password="$MYSQL_ROOT_PASS" --execute="GRANT ALL ON bookstack.* TO 'bookstack'@'localhost';FLUSH PRIVILEGES;"

# PHP settup
#This will prevent PHP from trying to execute parts of the path if the file that was passed in to process is not found.
#This could be used by malicious users to execute arbitrary code
grep -i "cgi.fix_pathinfo=0" /etc/php.ini > /dev/null
if [ $? -ne 0 ]
then
sed -i "s/;cgi.fix_pathinfo=1/cgi.fix_pathinfo=0/g" /etc/php.ini
fi

# Download BookStack
cd /var/www
git clone https://github.com/BookStackApp/BookStack.git --branch release --single-branch bookstack
BOOKSTACK_DIR="/var/www/bookstack"
cd $BOOKSTACK_DIR

# Install composer
EXPECTED_SIGNATURE=$(wget https://composer.github.io/installer.sig -O - -q)
curl -s https://getcomposer.org/installer > composer-setup.php
ACTUAL_SIGNATURE=$(php -r "echo hash_file('SHA384', 'composer-setup.php');")

if [ "$EXPECTED_SIGNATURE" = "$ACTUAL_SIGNATURE" ]; then
    php composer-setup.php --quiet
    RESULT=$?
    rm composer-setup.php
else
    >&2 echo 'ERROR: Invalid composer installer signature'
    rm composer-setup.php
    exit 1
fi

# Install BookStack composer dependancies
php composer.phar install

# Copy and update BookStack environment variables
cp .env.example .env
sed -i.bak 's/DB_DATABASE=.*$/DB_DATABASE=bookstack/' .env
sed -i.bak 's/DB_USERNAME=.*$/DB_USERNAME=bookstack/' .env
sed -i.bak "s/DB_PASSWORD=.*\$/DB_PASSWORD=$DB_PASS/" .env
echo "APP_URL="
# Generate the application key
php artisan key:generate --no-interaction --force
# Migrate the databases
php artisan migrate --no-interaction --force

# SElinux permissions
if [[ "$(getenforce)" == "Enforcing" ]]; then
    echo -e "\nSElinux mode is 'Enforcing', trying to set correct context..."
    setsebool -P httpd_can_sendmail 1
    setsebool -P httpd_can_network_connect 1
    semanage fcontext -a -t httpd_sys_rw_content_t "${BOOKSTACK_DIR}/public/uploads(/.*)?"
    semanage fcontext -a -t httpd_sys_rw_content_t "${BOOKSTACK_DIR}/storage(/.*)?"
    semanage fcontext -a -t httpd_sys_rw_content_t "${BOOKSTACK_DIR}/bootstrap/cache(/.*)?"
    restorecon -R "$BOOKSTACK_DIR"
fi

# Change folders permissions
chmod -R 754 bootstrap/cache public/uploads storage
chmod -R o+X bootstrap/cache public/uploads storage

# Set up web-server
case $WEBSERVER in
        "httpd")
           # Set files and folders owner
           chown apache:apache -R bootstrap/cache public/uploads storage

           # Set up apache
           cat >/etc/httpd/conf.d/bookstack.conf <<EOL
<VirtualHost *:80>
        ServerName ${DOMAIN}
        ServerAdmin webmaster@localhost
        DocumentRoot /var/www/bookstack/public/
    <Directory /var/www/bookstack/public/>
        Options Indexes FollowSymLinks
        AllowOverride None
        Require all granted
        <IfModule mod_rewrite.c>
            <IfModule mod_negotiation.c>
                Options -MultiViews -Indexes
            </IfModule>
            RewriteEngine On
            # Handle Authorization Header
            RewriteCond %{HTTP:Authorization} .
            RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
            # Redirect Trailing Slashes If Not A Folder...
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteCond %{REQUEST_URI} (.+)/$
            RewriteRule ^ %1 [L,R=301]
            # Handle Front Controller...
            RewriteCond %{REQUEST_FILENAME} !-d
            RewriteCond %{REQUEST_FILENAME} !-f
            RewriteRule ^ index.php [L]
        </IfModule>
    </Directory>
        ErrorLog logs/error_log
        CustomLog logs/access_log combined
</VirtualHost>
EOL

           # Set up php-fpm
           sed -c -i "s/\(^ *SetHandler *\).*/\1\"proxy\:fcgi\:\/\/127\.0\.0\.1\:9000\"/" /etc/httpd/conf.d/php.conf
	   sed -c -i "s/\(user *= *\).*/\1apache/" /etc/php-fpm.d/www.conf
           sed -c -i "s/\(group *= *\).*/\1apache/" /etc/php-fpm.d/www.conf
	   sed -i "s/;listen.owner = php-fpm/listen.owner = apache/" /etc/php-fpm.d/www.conf
	   sed -i "s/;listen.group = php-fpm/listen.group = apache/" /etc/php-fpm.d/www.conf
	   sed -i "s/;listen.mode = 0660/listen.mode = 0660/" /etc/php-fpm.d/www.conf
           systemctl enable php-fpm && systemctl start php-fpm

           # Start Apache2
           systemctl enable httpd && systemctl start httpd
           ;;
            
        "nginx")
           # Set files and folders owner
           chown nginx:nginx -R bootstrap/cache public/uploads storage
           
           # Set up php-fpm
           sed -c -i "s/\(user *= *\).*/\1$WEBSERVER/" /etc/php-fpm.d/www.conf
           sed -c -i "s/\(group *= *\).*/\1$WEBSERVER/" /etc/php-fpm.d/www.conf
	   sed -i "s/;listen.owner = php-fpm/listen.owner = $WEBSERVER/" /etc/php-fpm.d/www.conf
	   sed -i "s/;listen.group = php-fpm/listen.group = $WEBSERVER/" /etc/php-fpm.d/www.conf
	   sed -i "s/;listen.mode = 0660/listen.mode = 0660/" /etc/php-fpm.d/www.conf
           systemctl enable php-fpm && systemctl start php-fpm
           
           # Set up nginx
           cat >/etc/nginx/conf.d/bookstack.conf <<EOL
server {
  listen 80 default_server;
  listen [::]:80 default_server;

  server_name ${DOMAIN};

  root /var/www/bookstack/public;
  index index.php index.html;

  location / {
    try_files \$uri \$uri/ /index.php?\$query_string;
  }

  location ~ ^/(?:\.htaccess|data|config|db_structure\.xml|README) {
    deny all;
  }

  location ~ \.php$ {
    fastcgi_split_path_info ^(.+\.php)(/.+)$;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    fastcgi_param PATH_INFO \$fastcgi_path_info;
    fastcgi_pass 127.0.0.1:9000;
  }
}
EOL

           # Remove 'default_server' value in nginx.conf
           sed -i 's/\<default_server\>//g' /etc/nginx/nginx.conf

           # Start nginx
           systemctl enable nginx && systemctl start nginx
            ;;
esac

# Config Firewalld
read -p "Do you want to configure Firewalld ? [y/n] "  responseF
if [ "$responseF" == "y" ]
then
	if [[ "$(systemctl is-active firewalld)" == "active" ]]; then
	    echo -e "\nAdding firewalld service rule... "
	    firewall-cmd --add-service=http && firewall-cmd --permanent --add-service=http > /dev/null
	    firewall-cmd --reload > /dev/null
	fi
fi

# Config LDAP
read -p "Do you want to configure LDAP ? [y/n] "  responseL
if [ "$responseL" == "y" ]
then

echo -e "\nEnter the address of your ldap server and press [ENTER]\n"
        read LDAP_SERVER
echo -e "\nEnter the DN of user and press [ENTER]\n"
        read LDAP_BASE_DN
echo -e "\nEnter the DN of your ldap and press [ENTER]\n Example: CN=account,OU=users,DC=contoso,DC=com"
        read LDAP_DN
echo -e "\nEnter the password of your ldap server and press [ENTER]\n"
        read LDAP_PASS

        cat <<EOL >> /var/www/bookstack/.env

# Authentication method to use
# Can be 'standard' or 'ldap'
AUTH_METHOD=ldap

# LDAP configuration
LDAP_SERVER=$LDAP_SERVER
LDAP_BASE_DN=$LDAP_BASE_DN
LDAP_DN="$LDAP_DN"
LDAP_PASS=$LDAP_PASS
LDAP_USER_FILTER=(|(mail=${user})(sAMAccountName=${user}))
LDAP_EMAIL_ATTRIBUTE=mail
LDAP_VERSION=3

EOL

else
        echo "you can add the configuration manually in /var/www/bookstack/.env"
fi

echo -e "\v"
echo "#############################################################################"
echo "Setup Finished, Your BookStack instance should now be installed."
if [ "$responseL" != "y" ]
then
	echo "You can login with the email 'admin@admin.com' and password of 'password'."
else 
	echo "You can login with your ldap username and password."
fi
echo -e "Database "$DATABASE" was installed with a root password: "$MYSQL_ROOT_PASS"."
echo -e "Your web-server config file: /etc/"$WEBSERVER"/conf.d/bookstack.conf"
echo ""
echo -e "You can access your BookStack instance at: http://$CURRENT_IP/ or http://$DOMAIN/"
exit 0
