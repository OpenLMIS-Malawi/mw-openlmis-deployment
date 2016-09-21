curl -sL https://github.com/OpenLMIS/openlmis-deployment/archive/master.tar.gz | tar xz

curl -L https://github.com/docker/compose/releases/download/1.8.0/docker-compose-`uname -s`-`uname -m` > docker-compose

chmod +x docker-compose

cp -r ./openlmis-deployment-master/monitoring/* ./

docker-compose up -d