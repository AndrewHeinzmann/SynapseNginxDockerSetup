#!/bin/bash
# requires sudo privileges to copy cert and key
sudo -l &> /dev/null || { echo "Requires Sudo Privileges"; exit 1; }
# reset helper container in case of prior failure
docker container rm helperTEMP


# set servername to replace in confs
servername''
if [[ -z "$servername" ]]; then
	echo "servername variable must be set"
	exit 1
fi


# check if secrets in .env
formsecret=$(grep -- 'formsecret=' .env | awk 'BEGIN {FS="="} {print $2}')
macaroonsecret=$(grep -- 'macaroonsecret=' .env | awk 'BEGIN {FS="="} {print $2}')
registrationsecret=$(grep -- 'registrationsecret=' .env | awk 'BEGIN {FS="="} {print $2}')
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
docker volume create synapse &> /dev/null || { echo "Failed To Create Volume: synapse"; exit 1; }
docker volume create nginxConf &> /dev/null || { echo "Failed To Create Volume: nginxConf"; exit 1; }
docker volume create nginxConfD &> /dev/null || { echo "Failed To Create Volume: nginxConfD"; exit 1; }
docker volume create nginxHTML &> /dev/null || { echo "Failed To Create Volume: nginxHTML"; exit 1; }


# need to make a dummy server for temporary challenge
# already done
#certbot certonly --standalone --preferred-challenges http -m INPUTEMAIL --agree-tos -d ${servername} || { echo "Couldn't install Certificates"; exit 1; }


# copy synapse homeserver.yaml to corresponding volume, using debian for a helper container to copy to volumes
docker pull debian &> /dev/null || { echo "Cannot Pull debian Docker Image for temp copy"; exit 1; }
docker run -v synapse:/data --name helperTEMP debian || { echo "Cannot Create Temp Docker Container"; exit 1; }
# replace placeholders and save to other file called .tocopy, then copy to volume synapse
sed "s/INPUTSERVERNAME/${servername}/g" ./configs/synapse/homeserver.yaml > ./configs/synapse/homeserver.yaml.tocopy
sed -i "s/FORMSECRET/${formsecret}/g" ./configs/synapse/homeserver.yaml.tocopy
sed -i "s/MACAROONSECRET/${macaroonsecret}/g" ./configs/synapse/homeserver.yaml.tocopy 
sed -i "s/REGISTRATIONSECRET/${registrationsecret}/g" ./configs/synapse/homeserver.yaml.tocopy
docker cp ./configs/synapse/homeserver.yaml.tocopy helperTEMP:/data/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
docker cp ./configs/synapse/homeserver.log.config helperTEMP:/data/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
# copy from letsencrypt file on host, and if running Docker rootless it will change ownership to user, then copy into volume synapse
sudo cp --update=none "/etc/letsencrypt/live/${servername}/fullchain.pem" ./fullchain.pem
sudo chown "$USER:$USER" fullchain.pem
docker cp ./fullchain.pem helperTEMP:/data/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
sudo cp --update=none "/etc/letsencrypt/live/${servername}/privkey.pem" ./privkey.pem
sudo chown "$USER:$USER" privkey.pem
docker cp ./privkey.pem helperTEMP:/data/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
docker rm helperTEMP
# synapse likes things with user and group as 991, so chown 991:991
docker run -it --rm --mount type=volume,src=synapse,dst=/data debian chown -R 991:991 /data/

# copy .confs for nginx to volumes nginxConfD and nginxConf, replacing placeholders
sed "s/INPUTSERVERNAME/${servername}/g" ./configs/nginxConfD/default.conf > ./configs/nginxConfD/default.conf.tocopy
sed "s/INPUTSERVERNAME/${servername}/g" ./configs/nginxConfD/synapseForward.conf > ./configs/nginxConfD/synapseForward.conf.tocopy
docker run -v nginxConfD:/confD --name helperTEMP debian || { echo "Cannot Create Temp Docker Container"; exit 1; }
docker cp ./configs/nginxConfD/default.conf.tocopy helperTEMP:/confD/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
docker cp ./configs/nginxConfD/synapseForward.conf.tocopy helperTEMP:/confD/ || { echo "Cannot Copy From Config Directory to Volume"; exit 1; }
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
sed -i "s/INPUTSERVERNAME/${servername}/g" docker-compose.yml
docker compose up -d
