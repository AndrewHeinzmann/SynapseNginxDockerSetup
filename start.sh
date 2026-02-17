#!/bin/bash
# requires sudo privileges to copy cert and key
sudo -l &> /dev/null || { echo "Requires Sudo Privileges"; exit 1; }
# reset helper container in case of prior failure
docker container rm helperTEMP
# ugly if expression, the container ls returns the current directory-synapse|nginx-1 (ignoring different indexes)
# and tr is needed to lowercase because docker compose does that to the directory
if docker container ls -a --format='{{.Names}}' | grep -q "$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]')-synapse-1"; then
    synapseExitCode="$(docker container inspect "$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]')-synapse-1" --format='{{.State.ExitCode}}')"
    echo "Existing Synapse Container Found"
    echo "synapseExitCode: ${synapseExitCode}"
fi
if docker container ls -a --format='{{.Names}}' | grep -q "$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]')-nginx-1"; then
    nginxExitCode="$(docker container inspect "$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]')-nginx-1" --format='{{.State.ExitCode}}')"
    echo "Existing Nginx Container Found"
    echo "nginxExitCode: ${nginxExitCode}"
fi
if [[ ${synapseExitCode} && ${nginxExitCode} ]]; then
        echo -n "The containers seem healthy. Are you sure you want to rebuild? (y/n) "
        prompt='n'
        read -r prompt
        if [[ "${prompt,,}" != "y" ]]; then
                echo "Exiting"
                exit 0
        fi
fi


# set servername to replace in confs
servername=$(grep -- '^servername=' .env | awk 'BEGIN {FS="="} {print $2}')
if [[ -z "$servername" ]]; then
	echo "servername variable must be set"
	exit 1
fi


# check if secrets in .env
formsecret=$(grep -- '^formsecret=' .env | awk 'BEGIN {FS="="} {print $2}')
macaroonsecret=$(grep -- '^macaroonsecret=' .env | awk 'BEGIN {FS="="} {print $2}')
registrationsecret=$(grep -- '^registrationsecret=' .env | awk 'BEGIN {FS="="} {print $2}')
if [[ -z "$formsecret" ]]; then
	formsecret="$(cat /dev/urandom | tr -dc "[:alnum:]" | head -c 50)"
fi
if [[ -z "$macaroonsecret" ]]; then
	macaroonsecret="$(cat /dev/urandom | tr -dc "[:alnum:]" | head -c 50)"
fi
if [[ -z "$registrationsecret" ]]; then
	registrationsecret="$(cat /dev/urandom | tr -dc "[:alnum:]" | head -c 50)"
fi


# create volumes
echo "Creating Volumes or Checking if Existing"
docker volume create synapse || { echo "Failed To Create Volume: synapse"; exit 1; }
docker volume create nginxConf || { echo "Failed To Create Volume: nginxConf"; exit 1; }
docker volume create nginxConfD || { echo "Failed To Create Volume: nginxConfD"; exit 1; }
docker volume create nginxHTML || { echo "Failed To Create Volume: nginxHTML"; exit 1; }
echo "Volumes Successfully Created/Already Exist"


# need to make a dummy server for temporary challenge
# already done
#certbot certonly --standalone --preferred-challenges http -m INPUTEMAIL --agree-tos -d ${servername} || { echo "Couldn't install Certificates"; exit 1; }


# copy synapse homeserver.yaml to corresponding volume, using debian for a helper container to copy to volumes
echo "Configuring Synapse"
docker pull debian &> /dev/null || { echo "Cannot Pull debian Docker Image for temp copy"; exit 1; }
docker run -v synapse:/data --name helperTEMP debian || { echo "Cannot Create Temp Docker Container"; exit 1; }
# replace placeholders and save to other file called .tocopy, then copy to volume synapse
sed "s/INPUTSERVERNAME/${servername}/g" ./configs/synapse/homeserver.yaml > ./configs/synapse/homeserver.yaml.tocopy
sed -i "s/FORMSECRET/${formsecret}/g" ./configs/synapse/homeserver.yaml.tocopy
sed -i "s/MACAROONSECRET/${macaroonsecret}/g" ./configs/synapse/homeserver.yaml.tocopy 
sed -i "s/REGISTRATIONSECRET/${registrationsecret}/g" ./configs/synapse/homeserver.yaml.tocopy
docker cp ./configs/synapse/homeserver.yaml.tocopy helperTEMP:/data/homeserver.yaml || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
docker cp ./configs/synapse/homeserver.log.config helperTEMP:/data/homeserver.log.config || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
# copy from letsencrypt file on host, and if running Docker rootless it will change ownership to user, then copy into volume synapse
sudo cp --update=older "/etc/letsencrypt/live/${servername}/fullchain.pem" ./fullchain.pem
sudo chown "$USER:$USER" fullchain.pem
docker cp ./fullchain.pem helperTEMP:/data/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
sudo cp --update=older "/etc/letsencrypt/live/${servername}/privkey.pem" ./privkey.pem
sudo chown "$USER:$USER" privkey.pem
docker cp ./privkey.pem helperTEMP:/data/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
docker rm helperTEMP
# synapse likes things with user and group as 991, so chown 991:991
docker run -it --rm --mount type=volume,src=synapse,dst=/data debian chown -R 991:991 /data/

# copy .confs for nginx to volumes nginxConfD and nginxConf, replacing placeholders
echo "Configuring Nginx"
sed "s/INPUTSERVERNAME/${servername}/g" ./configs/nginxConfD/default.conf > ./configs/nginxConfD/default.conf.tocopy
sed "s/INPUTSERVERNAME/${servername}/g" ./configs/nginxConfD/synapseForward.conf > ./configs/nginxConfD/synapseForward.conf.tocopy
docker run -v nginxConfD:/confD --name helperTEMP debian || { echo "Cannot Create Temp Docker Container"; exit 1; }
docker cp ./configs/nginxConfD/default.conf.tocopy helperTEMP:/confD/default.conf || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
docker cp ./configs/nginxConfD/synapseForward.conf.tocopy helperTEMP:/confD/synapseForward.conf || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
docker rm helperTEMP
# copy cert and key to nginx
docker run -v nginxConf:/confbasedir --name helperTEMP debian || { echo "Cannot Create Temp Docker Container"; exit 1; }
docker cp ./fullchain.pem helperTEMP:/confbasedir/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
docker cp ./privkey.pem helperTEMP:/confbasedir/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
for file in ./configs/nginxbasedir/*; do
	docker cp "$file" helperTEMP:/confbasedir/
done
# remove the helper container
docker rm helperTEMP

# replace servername in docker-compose.yml, start docker compose
# check if servername is set in env, if not replace with sed -i
if [[ -z "$(grep -- '^servername=' .env | awk 'BEGIN {FS="="} {print $2}')" ]]; then
    sed -i "s/\${servername}/${servername}/g" docker-compose.yml
fi
echo "Starting Docker"
docker compose up -d --force-recreate
