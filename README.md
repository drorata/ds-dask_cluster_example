# Moving from local machine to Dask cluster using Terraform

Author: Dror Atariah

## Introduction

As part of the never-ending effort to improve [reBuy](https://www.rebuy.de/) and turn it into a market leader, we recently decided to tackle the challenges of our customer services agents.
As a first step, a dump of tagged emails was created and the first goal was set: build a POC that tags the emails automatically.
To that end, NLP had to be used and a lengthy (and greedy) [grid search](http://scikit-learn.org/stable/modules/generated/sklearn.model_selection.GridSearchCV.html) had to be executed.
So lengthy, that 4 cores of a notebook were working for couple of hours with no results.
This was the point when I decided to explore [`dask`](http://dask.pydata.org/en/latest/) and its sibling [`distributed`](https://distributed.readthedocs.io/en/latest/).
In this tutorial/post we shall discuss how to take a local code doing grid search using Scikit-Learn to a cluster of AWS (EC2) nodes.

## Start locally

We start with a minimal example of data loading and grid search the hyperparameters.
The project's structure might be:

```
.
├── data
├── models
└── src
```

In `./src` we may include some special tools, functions and classes that we would like to use in the project or in a more complicated pipeline.
We will show later how to include these tools in the distributed environment.
Note that it is having the structure of a python project and should include a `setup.py` at the project's root.
We start with a simple example:

```python
from sklearn.datasets import load_digits
from sklearn.svm import SVC
from sklearn.model_selection import GridSearchCV
# from src import myfoo # An example included from `src`

param_space = {'C': [1e-4, 1, 1e4],
               'gamma': [1e-3, 1, 1e3],
               'class_weight': [None, 'balanced']}

model = SVC(kernel='rbf')

digits = load_digits()

search = GridSearchCV(model, param_space, cv=3)
search.fit(digits.data, digits.target)
```

A little more elaborated version of this example can be found in the docker image defined [here](./Dockerfile).
You can try it out by cloning this repository and running the following:

```bash
docker build . -t dask-example
docker run --rm dask-example ./gridsearch_local.py
```

So far, so good.
But, imagine the data set is larger and the hyperparameters' space is more complicated.
Things will turn virtually impossible to run on a local machine.
At this point there are at least two possible courses of action:

1. Use more computing power
2. Optimize the search and/or be smarter

In this post we take the former.
A seemingly easy way to scale out the local machine to a cluster is [`dask`](http://dask.pydata.org/en/latest/).
To start with, staying on the local machine, let's try out the [`LocalCluster`](https://distributed.readthedocs.io/en/latest/local-cluster.html).
Checkout [`gridsearch_local_dask.py`](./gridsearch_local_dask.py) which you can try out by

```bash
docker run -it --rm dask-example ./gridsearch_local_dask.py
```

This already feels a little faster, isn't it?
But, we *need* to scale out and to that end we want to have a cluster of EC2 nodes that can be used.
There are two main steps:

1. Bundle the computation environment in a Docker image
2. Run a `dask` cluster where each node has the computation environment



## Bundle the computation environment

For the `dask` cluster to function, each node has to have the same computation environment.
Docker is a straightforward way to make this happen.
The way to go is to define a `Dockerfile`:

```docker
FROM continuumio/miniconda3

RUN mkdir project

COPY requirements.txt /project/requirements.txt
COPY src/ /project/src
COPY setup.py /project/setup.py
WORKDIR /project
RUN pip install -r requirements.txt
```

The local `requirements.txt` and `setup.py` are loaded to the image.
It is recommendad to include `bokeh` in `requirements.txt`; otherwise the web dashboard of `dask` won't work.
The `Dockerfile` can include further steps like `RUN apt-get update && apt-get install -y build-essential freetds-dev` or `RUN python -m nltk.downloader punkt`.
If `./src` includes needed classes, functions etc., then make sure you include something like `-e .` or merely `.` in `requirements.txt`; this way these dependencies will be available in the image.
It is important to include in the `Dockerfile` all the components needed for the computation environment!

Next, the image should be placed in a location accessible to EC2 instances.
It is time to push the image to a Docker registry.
In this tutorial, we use the AWS service - ECS but you can use other options like `DockerHub`.
I assume you have [`awscli`](https://aws.amazon.com/cli/) installed and the credentials are known.
You can log in to the registry simply by

```bash
# Execute from the project's root
$(aws ecr get-login --no-include-email)
docker build -t image-name .
docker tag image-name:latest repo.url/image-name:latest
docker push repo.url/image-name:latest
```

It is time to setup the nodes of the cluster.

## Defining the Dask cluster

We take a declarative approach and use [`terraform`](www.terraform.io) to setup the nodes of the cluster.
Note that in this example we utilize the AWS Spots; you can easily change the code and use the regular on-demand instances.
This is left as an exercise.
We use two groups of file to define the cluster:

- `.tf` instructions: parsed by `terraform` and defining what instances to use, what tags, regions, etc.
- Provisioning shell scripts: installing needed tools on the nodes


### `.tf` files

When using `terraform` all `.tf` files are read and concatenated.
There are more details of course; a good entry point would be [this](https://www.terraform.io/docs/configuration/index.html).
In our example we organize the `.tf` files as follows:

- `terraform.tf`: general settings
- `vars.tf`: variables definitions which can be used from the CLI
- `provision.tf`: instructions how to call the provisioning scripts
- `resources.tf`: definition of the resources
- `output.tf`: definition of outputs provided by `terraform`

#### `terraform.tf`

```
provider "aws" {
  region = "eu-west-1"
}
```

#### `vars.tf`

```
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

#### `provision.tf`

```
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

#### `resources.tf`

This is the core of the settings, here we put everything together and define the requests for the AWS spots.

```
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

Here are some important elements to note:

1. The [AMI](http://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html) I use is the one for `eu-west-1` which is optimized for Docker and provided by Amazon. It is possible to use other images, but it is important that they will support `docker`.
2. Define the private IP of the scheduler. You will need to use it when starting the workers and it is easier to *know* the IP than to *find* it
3. Indicate how many workers should be used

#### `output.tf`

`terraform` allows the definition of various outputs.
As always, more details can be found [here](https://www.terraform.io/intro/getting-started/outputs.html).

```
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

### Provisioning scripts

The `user_data` fields in `resources.tf` indicate what script should be used for the provisioning on the nodes.
We provide two templates of scripts which will be filled with the needed variables from `terraform`; one script for the scheduler and one for the workers.

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
docker run -d -it --network host ${DOCKER_REG} /opt/conda/bin/dask-scheduler
```

The scripts for the workers and for the scheduler are identical, except the last line.
For the workers we should have

```
docker run -d -it --network host ${DOCKER_REG} /opt/conda/bin/dask-worker ${SCHEDULER_IP}:8786
```

Note that we start `dask-worker` instead of `dask-scheduler` and we indeicate the private IP of the scheduler.
**Important** to note the `--network host`.
Intuitively, this makes sure that the containers' networks and their corresponding hosts will be the same and therefore the different containers on different hosts will be able to communicate.



## Running the cluster

We can now run the cluster.
To that end, we need to execute two commands.
First, `terraform init`.
This one prepares the tool and make it ready to start the nodes.
Next we have to `apply` the instructions.
This we do by invoking:

```bash
TF_VAR_awsKey=YOUR_AWS_KEY \
TF_VAR_awsPrivateKey=YOUR_AWS_PRIVATE_KEY \
terraform apply -var 'workersNum=2' -var 'instanceType="t2.small"' \
-var 'spotPrice=0.2' -var 'schedulerPrivateIp="172.31.36.170"' \
-var 'dockerRegistry="repo.url/image-name:latest"'
```

Note that we use two environment variables for the AWS keys.
Other variables defined in `var.tf` are passed as parameters.
Once finished, you can access the newly created scheduler node by: `ssh -i ~/.aws/key.pem ec2-user@$(terraform output scheduler-info)`.
In the cluster you can check the log at `/var/log/user-data.log`.
You can also check the status of the running Docker containers using `docker ps`.
Lastly, if everything went well, you should be able to access the web interface of the cluster.
Its address can be found by invoking `terraform output scheduler-status`.


## Grid search on the cluster

The moment we have been waiting for: run our hyperparameters grid search on the `dask` cluster.
To do so, we can use a code similar to [`./gridsearch_local_dask.py`](./gridsearch_local_dask.py).
Only changing the client's address is needed:

```python
#!/usr/bin/env python

from sklearn.datasets import load_digits
from sklearn.svm import SVC
from sklearn.model_selection import train_test_split as tts
from sklearn.metrics import classification_report
from distributed import Client, LocalCluster
from dask_searchcv import GridSearchCV
# from src import myfoo # An example included from `src`


def main():
    param_space = {'C': [1e-4, 1, 1e4],
                   'gamma': [1e-3, 1, 1e3],
                   'class_weight': [None, 'balanced']}

    model = SVC(kernel='rbf')

    digits = load_digits()

    X_train, X_test, y_train, y_test = tts(digits.data, digits.target,
                                           test_size=0.3)

    print("Starting local cluster")
    client = Client(x.y.z.w:8786)
    print(client)

    print("Start searching")
    search = GridSearchCV(model, param_space, cv=3)
    search.fit(X_train, y_train)

    print("Prepare report")
    print(classification_report(
        y_true=y_test, y_pred=search.best_estimator_.predict(X_test))
    )


if __name__ == '__main__':
    main()
```

Running this script would start the grid search on the `dask` cluster.
This can be monitored on the web dashboard.
If you have a running cluster at `x.y.z.w`, you can try it out:

```bash
docker run -it --rm -p 8786:8786 dask-example ./gridsearch_cluster_dask.py x.y.z.w
```

## Yet to be discussed

* You might want to explore `terraform workspace`; this can help you run several clusters from the same directory. For example when running different experiements at the same time.
* Enable a node with Jupyter server so the local notebook won't be needed
