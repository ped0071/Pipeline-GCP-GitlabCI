#!/bin/bash

if [ $# -le 5 ]
then
  echo "must have at least 6 arguments"
  echo "#1 - instance group name"
  echo "#2 - your desired git branch for deploy (master|develop|*)"
  echo "#3 - ssh key path for instance connection (/path/to/key)"
  echo "#4 - region default"
  echo "#5 - script path"
  echo "#6 - name project in gcp"
  
  exit 1
fi

ig_name=$1
desired_branch=$2
key_path=$3
region=$4
script_path=$5
project_name=$6

echo "get random instance info (instance_name and ip_address)"
instance_name=$(gcloud compute instance-groups list-instances --format=json $ig_name --region=southamerica-east1 --limit=1 | grep instance | sed 's/.*instances\///g;s/\".*//g' | cut -d/ -f4)
zone=$(gcloud compute instances list --filter=name=$instance_name --format='get(zone)' --quiet | awk -F/ '{print $NF}')
ip_address=$(gcloud compute instances describe $instance_name --format='get(networkInterfaces[0].accessConfigs[0].natIP)' --zone=$zone --quiet)
echo "selected instance: [id:$instance_name] [zone:$zone] [ip_address:$ip_address]"

echo "detach instance"
gcloud compute instance-groups managed abandon-instances $ig_name --instances $instance_name --region $region > /dev/null

echo "update instance repository"
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no user@$ip_address "cd $script_path; git reset --hard HEAD; git checkout $desired_branch; git pull; exit"

echo "stop instance"
gcloud compute instances stop $instance_name --zone=$zone > /dev/null

echo "create image from updated instance"
timestamp=$(date +%s)
ami_name=$ig_name-v$timestamp
ami=$(gcloud compute images create $ami_name --project=$project_name --source-disk=$instance_name --source-disk-zone=$zone --format='get(name)')
until gcloud compute images describe $ami_name --format='value(status)' | grep READY > /dev/null
do 
  echo "waiting for image build"
  sleep 15
done

echo "create a instance template"
gcloud compute instance-templates create $ami_name --project=$project_name --machine-type=e2-small --network-interface=network=default,network-tier=PREMIUM --no-restart-on-failure --maintenance-policy=TERMINATE --provisioning-model=SPOT --instance-termination-action=STOP --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append --tags=http-server,https-server --create-disk=auto-delete=yes,boot=yes,image=projects/$project_name/global/images/$ami_name,mode=rw,size=10,type=pd-balanced --no-shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring --reservation-affinity=any > /dev/null

echo "start instance group refresh"
gcloud beta compute instance-groups managed rolling-action start-update $ig_name --project=$project_name --type='proactive' --max-surge=0 --max-unavailable=5 --min-ready=0 --minimal-action='replace' --most-disruptive-allowed-action='replace' --replacement-method='recreate' --version=template=projects/$project_name/global/instanceTemplates/$ami_name --region=$region > /dev/null

echo "killing instance $instance_name"
gcloud compute instances delete $instance_name --zone=$zone --quiet > /dev/null
echo "end deploy script - wait for instance group refresh"
