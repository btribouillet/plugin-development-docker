#!/bin/bash

# Prevent script from running as root (root-related actions will prompt for the needed credentials)
[[ $EUID -eq 0 ]] && echo "Do not run with sudo / as root." && exit 1

if ! [[ -f './config/php.ini' ]]; then
    echo '[!] Warning: config file(s) not found. Running make.sh.'
    /bin/bash ./make.sh
fi

source ./config/config.sh
PLATFORM=APPLE

trap stop_docker INT
function stop_docker {
    STOPPING=true
    docker-compose down
    wait $PROCESS
    exit
}

function find_environment {
	if [[ -f 'C:/Windows/System32/Drivers/Etc/hosts' ]]; then
		PLATFORM = WINDOWS;
	fi
}

if [[ -z "$@" ]]; then
    CONTAINERS=basic-wordpress
else
    CONTAINERS="$@"
fi

URL_basic_wordpress="http://${BASIC_HOST:-basic.wordpress.test}"
URL_woocommerce_wordpress="http://${WOOCOMMERCE_HOST:-woocommerce.wordpress.test}"
URL_multisite_wordpress="http://${MULTISITE_HOST:-multisite.wordpress.test}"
URL_multisitedomain_wordpress="http://${MULTISITE_HOST:-multisite.wordpress.test}"
URL_standalone_wordpress="http://${STANDALONE_HOST:-standalone.wordpress.test}"

PORT_basic_wordpress=1987
PORT_woocommerce_wordpress=1988
PORT_multisite_wordpress=1989
PORT_multisitedomain_wordpress=1991
PORT_standalone_wordpress=1990

USER_ID=`id -u`
GROUP_ID=`id -g`
DOCKERTEMPLATE='./containers/wordpress/Dockerfile.template'
DOCKERFILE='./containers/wordpress/Dockerfile'

#if [ ! -f "$DOCKERFILE" ]; then
    echo -n "Creating Dockerfile from template. $DOCKERTEMPLATE => $DOCKERFILE"
    cp "$DOCKERTEMPLATE" "$DOCKERFILE"
    
    sed -i -e "s/\$UID/${USER_ID}/g" "$DOCKERFILE"
    sed -i -e "s/\$GID/${GROUP_ID}/g" "$DOCKERFILE"
#fi

echo "Starting containers:"
for CONTAINER in $CONTAINERS; do
    echo "  - $CONTAINER"
done

echo "Ensuring all containers are built."
docker-compose build --pull --parallel $CONTAINERS

function boot_containers() {
    echo "Booting containers."
    docker-compose up --detach $CONTAINERS
}

function await_database_connection () {
    port = $1
    echo "Waiting for database connection at port $port..."
    
    if [ $PLATFORM == APPLE ]; then 
        until nc -z -v -w30 localhost ${port}; do
            echo "Waiting for database connection at port $port..."
            sleep 2
        done
    else if [ $PLATFORM == WINDOWS ]; then
        netstat -a -b | grep ${port};
        # until netstat -a -b | grep ${port}; do
        #     echo "Waiting for database connection at port $port..."
        #     sleep 2
        # done
    fi
}

boot_containers

if ! [ "$DOCKER_DB_NO_WAIT" ]; then
    echo "Waiting for databases to boot."
    for CONTAINER in $CONTAINERS; do
        PORT_VAR="PORT_${CONTAINER//-/_}"
        PORT=${!PORT_VAR}
        
        await_database_connection $PORT
    done
fi

# Then install WordPress.
for CONTAINER in $CONTAINERS; do
    echo "Checking if WordPress is installed in $CONTAINER..."

    docker exec -ti "$CONTAINER" /bin/bash -c 'until [[ -f .htaccess ]]; do sleep 1; done'
    docker exec -ti "$CONTAINER" /bin/bash -c 'wp --allow-root core is-installed 2>/dev/null'
    # $? is the exit code of the previous command.
    # We check if WP is installed, if it is not, it returns with exit code 1
    IS_INSTALLED=$?

    if [[ $IS_INSTALLED == 1 ]]; then
        echo "Installing WordPress for $CONTAINER..."

        docker exec -ti "$CONTAINER" /bin/bash -c 'mkdir -p /var/www/.wp-cli/packages; chown -R www-data: /var/www/.wp-cli;'
        docker exec --user "$USER_ID" -ti "$CONTAINER" /bin/bash -c 'php -d memory_limit=512M "$(which wp)" package install git@github.com:Yoast/wp-cli-faker.git'
        docker cp ./seeds "$CONTAINER":/seeds
        docker exec --user "$USER_ID" -ti "$CONTAINER" /seeds/"$CONTAINER"-seed.sh
    fi

    echo WordPress is installed.
done

echo "Waiting for containers to boot..."
for CONTAINER in $CONTAINERS; do
    URL_VAR="URL_${CONTAINER//-/_}"
    URL=${!URL_VAR}
    while [ "$BOOTED" != "true"  ]; do
        if curl -I "$URL" 2>/dev/null | grep -q -e "HTTP/1.1 200 OK" -e "HTTP/1.1 302 Found"; then
            BOOTED=true
        else
            sleep 2
            echo "Waiting for $CONTAINER to boot... Checking $URL"
        fi
    done
done

echo "Containers have booted! Happy developing!"
sleep 2

echo "Outputting logs now:"
docker-compose logs -f &
PROCESS=$!

while [ "$STOPPING" != 'true' ]; do
    CLOCK_SOURCE=$(docker exec -ti nginx-router-wordpress /bin/bash -c 'cat /sys/devices/system/clocksource/clocksource0/current_clocksource' | tr -d '[:space:]')
    if [[ "$CLOCK_SOURCE" != 'tsc' && "$CLOCK_SOURCE" != 'hyperv_clocksource_tsc_page' && "$STOPPING" != 'true' ]]; then
        echo "Restarting docker now to fix out-of-sync hardware clock!"
        docker ps -q | xargs -L1 docker stop
        
        if [ $PLATFORM === APPLE ]; then
            osascript -e 'quit app "Docker"'
        fi
        
        open --background -a Docker
        echo "Giving docker time to start..."
        until docker info 2> /dev/null 1> /dev/null; do
            sleep 2
            echo "Giving docker time to start..."
        done
        echo "Docker is up and running again! Booting containers!"
        boot_containers
    fi
    sleep 5
done
