class: center, middle

# Moving from local machine to `dask` cluster

Dr. Dror Atariah @ rebuy

`drorata @` ![](./GitHub-Mark-32px.png)

---

# Agenda

1. Motivation
2. Brief intro to `dask`
2. Deep-dive

---

class: center, middle

# Introduction

---

## Normal getting started

* Get the data
* Clean
* Visualize
* Explore
* Build model
* etc.
--

.center[ALL HAPPENS *LOCALLY*]
.center[<img src="./ibm_pc.jpg" width="300">]

---

## Things get uglier

E.g. preform grid search
--
.center[**THIS** is what you need!]
.center[<img src="./data_center.jpg" width="500">]

---

class: center, middle

# `dask`

---

## Say hello to `dask`

.center["Dask is a flexible parallel computing library for analytic computing."[[1]](https://dask.pydata.org/en/latest/)]

**Some highlights:**

* Mimics `pandas`, `numpy` and others
* Complex algorithms
* Scale from local to clusters
* [Actively developed](https://github.com/dask/dask/graphs/contributors)

---

class: center, middle

# dj turn it up!

---

## A simple local example

```python
from sklearn.datasets import load_digits
from sklearn.svm import SVC
from sklearn.model_selection import GridSearchCV
# <<<>>><<<>>><<<>>><<<>>><<<>>><<<>>><<<>>><<<>>><<<>>>
# from src import myfoo # An example included from `src`
# <<<>>><<<>>><<<>>><<<>>><<<>>><<<>>><<<>>><<<>>><<<>>>

param_space = {'C': [1e-4, 1, 1e4],
               'gamma': [1e-3, 1, 1e3],
               'class_weight': [None, 'balanced']}

model = SVC(kernel='rbf')

digits = load_digits()

search = GridSearchCV(model, param_space, cv=3)
search.fit(digits.data, digits.target)
```

---

## Even uglier

Now imagine more complex hyperparameters space

.center[<img src="./hyper_params.jpg" width="400">]

.center[*Local machine is not enough...*]

---

## `dask` plays local

```python
from sklearn.datasets import load_digits
from sklearn.svm import SVC
from distributed import Client, LocalCluster
from dask_searchcv import GridSearchCV

def main():
    param_space = {'C': [1e-4, 1, 1e4], 'gamma': [1e-3, 1, 1e3],
                   'class_weight': [None, 'balanced']}

    model = SVC(kernel='rbf')

    digits = load_digits()

    X, y = (digits.data, digits.target)

    cluster = LocalCluster()
    client = Client(cluster)

    search = GridSearchCV(model, param_space, cv=3)
    search.fit(X, y)

if __name__ == '__main__':
    main()
```

---

class: center, middle

# Moving to the cluster

Amazon EC2

---

## Main steps

* Dockerize the environment
* Prepare the cluster
* Action!

--

**Remark:** You might want to try [`dask-ec2`](https://github.com/dask/dask-ec2)

---

## Dockerize local example

First step towards stable environment

```docker
FROM continuumio/miniconda3

RUN mkdir project

COPY requirements.txt /project/requirements.txt
COPY src/ /project/src
COPY setup.py /project/setup.py
WORKDIR /project
RUN pip install -r requirements.txt
```

--

Push to `ECR`

```bash
# Execute from the project's root
$(aws ecr get-login --no-include-email)
docker build -t image-name .
docker tag image-name:latest repo.url/image-name:latest
docker push repo.url/image-name:latest
```

---

## Define the cluster

Take a declarative approach using [`Terraform`](https://www.terraform.io/)

- `terraform.tf`
- `vars.tf`
- `provision.tf`
- `resources.tf`
- `output.tf`

---

### `terraform.tf`

```yml
provider "aws" {
  region = "eu-west-1"
}
```


---

### `vars.tf`

```yml
variable "instanceType" {
  type    = "string"
  default = "c5.2xlarge"
}

variable "spotPrice" {
  # Not needed for on-demand instances
  default = "0.1"
}

variable "contact" {
  type = "string"
  default = "d.atariah"
}

variable "department" {
  type = "string"
  default = "My wonderful department"
}
```

---

### `vars.tf` - cont'

```yml
variable "subnet" {
  default = "subnet-007"
}

variable "securityGroup" {
  type = "string"
  default = "sg-42"
}

variable "workersNum" {
  default = "4"
}

variable "schedulerPrivateIp" {
  # We predefine a private IP for the scheduler; it will be used by the workers
  default = "172.31.36.190"
}

variable "dockerRegistry" {
  default = ""
}

# By defining the AWS keys as variables we can get them from the command line
# and pass them to the provisioning scripts
variable "awsKey" {}
variable "awsPrivateKey" {}
```

---

### `provision.tf`

```yml
data "template_file" "scheduler_setup" {
  template = "${file("scheulder_setup.sh")}" # see the shell script bellow
  vars {
    # Use the AWS keys passed from the terraform CLI
    AWS_KEY = "${var.awsKey}"
    AWS_PRIVATE_KEY = "${var.awsPrivateKey}"
    DOCKER_REG = "${var.dockerRegistry}"
  }
}

data "template_file" "worker_setup" {
  template = "${file("worker_setup.sh")}" # see the shell script bellow
  vars {
    AWS_KEY = "${var.awsKey}"
    AWS_PRIVATE_KEY = "${var.awsPrivateKey}"
    DOCKER_REG = "${var.dockerRegistry}"
    SCHEDULER_IP = "${var.schedulerPrivateIp}"
  }
}
```

---

### `worker_setup.sh`

```bash
#!/bin/bash

# scheduler_setup.sh

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
set -x

echo "Installing pip"
curl -O https://bootstrap.pypa.io/get-pip.py
python get-pip.py --user
~/.local/bin/pip install awscli --upgrade --user
echo "Logging in to ECS registry"
export AWS_ACCESS_KEY_ID=${AWS_KEY}
export AWS_SECRET_ACCESS_KEY=${AWS_PRIVATE_KEY}
export AWS_DEFAULT_REGION=eu-west-1
$(~/.local/bin/aws ecr get-login --no-include-email)
```

---

### `worker_setup.sh` - cont'

```bash
# Assigning tags to instance derived from spot request
# See https://github.com/hashicorp/terraform/issues/3263#issuecomment-284387578
REGION=eu-west-1
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
SPOT_REQ_ID=$(~/.local/bin/aws --region $REGION ec2 describe-instances \
 --instance-ids "$INSTANCE_ID"  --query \
  'Reservations[0].Instances[0].SpotInstanceRequestId' --output text)
if [ "$SPOT_REQ_ID" != "None" ] ; then
  TAGS=$(~/.local/bin/aws --region $REGION ec2 \
  describe-spot-instance-requests --spot-instance-request-ids \
  "$SPOT_REQ_ID" --query 'SpotInstanceRequests[0].Tags')
  ~/.local/bin/aws --region $REGION ec2 create-tags --resources \
   "$INSTANCE_ID" --tags "$TAGS"
fi

echo "Starting docker container from image"
docker run -d -it --network host ${DOCKER_REG} /opt/conda/bin/dask-worker ${SCHEDULER_IP}:8786
```

---

### `resources.tf` - Scheduler

```yml
resource "aws_spot_instance_request" "dask-scheduler" {
  ami                         = "ami-4cbe0935" # [1]
  instance_type               = "${var.instanceType}"
  spot_price                  = "${var.spotPrice}"
  wait_for_fulfillment        = true
  key_name                    = "dask_poc"
  security_groups             = ["${var.securityGroup}"]
  subnet_id                   = "${var.subnet}"
  associate_public_ip_address = true
  private_ip                  = "${var.schedulerPrivateIp}" # [2]
  user_data                   = "${data.template_file.scheduler_setup.rendered}"
  tags {
    Name = "${terraform.workspace}-dask-scheduler",
    Department = "${var.department}",
    contact = "${var.contact}"
  }
}
```

---

### `resources.tf` - Worker

```yml
resource "aws_spot_instance_request" "dask-worker" {
  count                       = "${var.workersNum}" # [3]
  ami                         = "ami-4cbe0935" # [1]
  instance_type               = "${var.instanceType}"
  spot_price                  = "${var.spotPrice}"
  wait_for_fulfillment        = true
  key_name                    = "dask_poc"
  subnet_id                   = "${var.subnet}"
  security_groups             = ["${var.securityGroup}"]
  associate_public_ip_address = true
  user_data                   = "${data.template_file.worker_setup.rendered}"
  tags {
    Name = "${terraform.workspace}-dask-worker${count.index}",
    Department = "${var.department}",
    contact = "${var.contact}"
  }
}
```

---

### `output.tf`

```yml
output "scheduler-info" {
  value = "${aws_spot_instance_request.dask-scheduler.public_ip}"
}

output "workers-info" {
  value = "${join(",",aws_spot_instance_request.dask-worker.*.public_ip)}"
}

output "scheduler-status" {
  value = "http://${aws_spot_instance_request.dask-scheduler.public_ip}:8787/status"
}
```

---

class: center, middle

## Action!

---

### Spin the nodes

```bash
TF_VAR_awsKey=YOUR_AWS_KEY \
TF_VAR_awsPrivateKey=YOUR_AWS_PRIVATE_KEY \
terraform apply -var 'workersNum=2' -var 'instanceType="t2.small"' \
-var 'spotPrice=0.2' -var 'schedulerPrivateIp="172.31.36.170"' \
-var 'dockerRegistry="repo.url/image-name:latest"'
```

---

### Do some grid search

```python
#!/usr/bin/env python

from sklearn.datasets import load_digits
from sklearn.svm import SVC
from sklearn.model_selection import train_test_split as tts
from distributed import Client, LocalCluster
from dask_searchcv import GridSearchCV

def main():
    param_space = {'C': [1e-4, 1, 1e4], 'gamma': [1e-3, 1, 1e3],
                   'class_weight': [None, 'balanced']}

    model = SVC(kernel='rbf')
    digits = load_digits()
    X_train, X_test, y_train, y_test = tts(digits.data, digits.target,
                                           test_size=0.3)
    client = Client(x.y.z.w:8786)

    search = GridSearchCV(model, param_space, cv=3)
    search.fit(X_train, y_train)

if __name__ == '__main__':
    main()
```

---

# Summary and remarks

* For this task many 2-cores are better than many 16-cores
* Use `terraform output *` to atumate stuff
* Checkout `http://x.y.z.w:8787/status` (if you have `bokeh`)
* [Sources are available](https://github.com/rebuy-de/ds-dask_cluster_example)
* Become a full-stack data scientist
