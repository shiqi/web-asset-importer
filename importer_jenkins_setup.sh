#!/bin/bash

source ./importer_jenkins_config.sh

#cleaning up any residual containers from leftover tests
setup
# cleanup lockfile on error
trap cleanup ERR

# checking lock
exec 200>$lockfile
flock -n 200 || { echo "Another instance of the script is already running. Exiting."; exit 1; }


unset PYTHONPATH

export PYTHONPATH=$python_path:$PYTHONPATH

echo $PYTHONPATH

rm -r venv

sleep 5

python3.12 -m venv venv

source venv/bin/activate

# Print Python version
echo "Python version:"
python --version

# Upgrade pip and install requirements

pip install --upgrade pip

git config --global --add safe.directory "$(pwd)"

git submodule update --init --remote --force

# waiting for submodule to populate
timeout=300
interval=2
elapsed=0

while [ ! -f ${metadata_requirements_path} ]; do
  if [ $elapsed -ge $timeout ]; then
    echo "Timeout reached: ${metadata_requirements_path} not found"
    exit 1
  fi
  echo "Waiting for ${metadata_requirements_path} to exist..."
  sleep $interval
  elapsed=$((elapsed + interval))
done

echo "${metadata_requirements_path} found"

pip install -r requirements.txt

# creating databases

docker run --name mariadb-specify \
  -e MARIADB_ROOT_PASSWORD=password \
  -e MARIADB_CHARSET=utf8mb4 \
  -e MARIADB_COLLATION=utf8mb4_general_ci \
  -d -p 3310:3306 mariadb:10.11


echo "specify db running"

(
cd PIC_dbcreate || exit
./run_picdb.sh

echo "Picbatch db running"
)

sleep 10

docker exec -i mariadb-specify mariadb -u root -ppassword  < ../jenkins_ddls/specify_jenkins_ddl.sql

sleep 10

echo "specify db populated"

# setting up test server
(
# stable cas server is a git cloned repo of cas-web-asset-server master branch with ssh key for fetch.
cd ../stable_cas-server || exit
source venv/bin/activate
source ./server_jenkins_config.sh
git config --global --add safe.directory "$(pwd)"
git fetch --all
# change to master before PR
git stash
git checkout master
git reset --hard origin/master
convert_to_http
cp nginx_test.conf nginx.conf
git submodule update --init --remote --force
docker stop image-server bottle-nginx && docker rm image-server bottle-nginx
sleep 5
docker-compose up -d
max_wait=1200
elapsed=0

until [ "$(docker-compose ps -q | xargs docker inspect -f '{{.State.Status}}' 2>/dev/null | grep -cv 'running')" -eq 0 ] || [ "$elapsed" -ge "$max_wait" ]; do
    echo "Waiting for all containers to be running... (${elapsed}s elapsed)"
    sleep 5
    elapsed=$((elapsed + 5))
done

if [ "$elapsed" -ge "$max_wait" ]; then
    echo "Error: Containers did not reach a healthy state within ${max_wait} seconds."
    exit 1
fi

echo "All containers are healthy."
)

# tests
( cd ./tests || exit
./casbotany_sqlite_create.sh
)

exit_code=$?

if [ $exit_code -ne 0 ]; then
  echo "Pytest reported some failed tests"
  exit $exit_code
fi

echo "All tests passed"
