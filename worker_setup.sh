#!/bin/bash

# scheulder_setup.sh

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Installing pip"
curl -O https://bootstrap.pypa.io/get-pip.py
python get-pip.py --user
~/.local/bin/pip install awscli --upgrade --user
echo "Logging in to ECS registry"
export AWS_ACCESS_KEY_ID=${AWS_KEY}
export AWS_SECRET_ACCESS_KEY=${AWS_PRIVATE_KEY}
export AWS_DEFAULT_REGION=eu-west-1
$(~/.local/bin/aws ecr get-login --no-include-email)

# Assigning tags to instance derived from spot request
# See https://github.com/hashicorp/terraform/issues/3263#issuecomment-284387578
REGION=eu-west-1
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
SPOT_REQ_ID=$(~/.local/bin/aws --region $REGION ec2 describe-instances --instance-ids "$INSTANCE_ID"  --query 'Reservations[0].Instances[0].SpotInstanceRequestId' --output text)
if [ "$SPOT_REQ_ID" != "None" ] ; then
  TAGS=$(~/.local/bin/aws --region $REGION ec2 describe-spot-instance-requests --spot-instance-request-ids "$SPOT_REQ_ID" --query 'SpotInstanceRequests[0].Tags')
  ~/.local/bin/aws --region $REGION ec2 create-tags --resources "$INSTANCE_ID" --tags "$TAGS"
fi

echo "Starting docker container from image"
docker run -d -it --network host ${DOCKER_REG} /opt/conda/bin/dask-worker ${SCHEDULER_IP}:8786
