# Moving from local machine to Dask cluster

Author: Dror Atariah

## Introduction

As part of the never-ending effort to improve reBuy and turn it into a market leader, we recently decided to tackle the challenges of our customer services agents.
As a first step, a dump of tagged emails was created and the first goal was set: build a POC that tags the emails automatically.
To that end, NLP had to be used and a lengthy (and greedy) [grid search](http://scikit-learn.org/stable/modules/generated/sklearn.model_selection.GridSearchCV.html) had to be executed.
So lengthy, that 4 cores of a notebook were working for couple of hours with no results.
This was the point when I decided to explore [`dask`](http://dask.pydata.org/en/latest/) and its sibling [`distributed`](https://distributed.readthedocs.io/en/latest/).

In this tutorial/post we shall discuss how to take a local code doing grid search using Scikit-Learn to a cluster of AWS (EC2) nodes.

## Basic local implementation

We start with a minimal example of data loading, pipeline setting and grid search the hyperparameters.
The project's structure is:

```
.
├── data
├── models
└── src
```

In `./src` we may include some special tools, functions and classes that we would like to use in the project.
We will show later how to include these tools in the distributed environment.
Note that it is having the structure of a python project and should include a `setup.py`.
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
You can try it out by:

```bash
docker build . -t dask-example
docker run --rm dask-example ./gridsearch_local.py
```

So far, so good.
But, imagine the data set is larger and the hyperparameters' space is more complicated.
Things will turn virtually impossible to run on a local machine.
At this point there are two possible courses of action:

1. Use more computing power
2. Optimize the search and/or be smarter

In this post we take the first course.

## Dask cluster

A seemingly easy way to scale out the local machine to a cluster is [`dask`](http://dask.pydata.org/en/latest/).
To start with, staying on the local machine, let's try out the `LocalCluster`.
Checkout [`gridsearch_local_dask.py`](./gridsearch_local_dask.py) which you can try out by

```bash
docker run -it --rm dask-example ./gridsearch_local_dask.py
```

This already feels a little faster, isn't it?
But, we *need* to scale out and to that end we want to have a cluster of EC2 nodes that can be used.
A boilerplate code which we would like to have is:

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

This is almost the same code as the one in the example using a local cluster.
The only difference is we have specified an IP where a `dask` scheduler should be found.
We will take the steps to set up a proper cluster on EC2 nodes.
For building the `dask` cluster we would need:

1. Define the computing environment using `Docker`
2. Push the Docker image to [ECS](https://aws.amazon.com/ecs/). `DockerHub` can be used as well.
3. Instantiate the cluster on AWS.

Obviously, it is possible to do everything manually, but we would like to be more structured.

### Docker image

First, an easy way to make sure the same environment will be available on all nodes of the cluster, is to define a `Dockerfile`:

```docker
FROM continuumio/miniconda3

RUN mkdir project

COPY requirements.txt /project/requirements.txt
COPY src/ /project/src
COPY setup.py /project/setup.py
WORKDIR /project
RUN pip install -r requirements.txt
RUN python -m nltk.downloader punkt
```

The local `requirements.txt` and `setup.py` are loaded to the image.
The `Dockerfile` can include further steps like `RUN apt-get update && apt-get install -y build-essential freetds-dev` or `RUN python -m nltk.downloader punkt`.
If `./src` includes needed classes, functions etc., then make sure you include something like `-e .` or merely `.` in `requirements.txt`; this way the these dependencies will be available in the image.
It is important to include in the `Dockerfile` all the components needed for the computation environment.

It is time to push the image to a Docker registry.
I assume you have `awscli` installed and the credentials are known.
You can log in to the registry simply by

```bash
# Execute from the project's root
$(aws ecr get-login --no-include-email)
docker build -t image-name .
docker tag image-name:latest repo.url/image-name:latest
docker push repo.url/image-name:latest
```

### Scripting the nodes

For the sake of easy reproducibility, readability, maintenance etc. we will use [terraform](terraform.io) for the definition of the nodes.
This approach needs the following files:

1. `terraform.tf` including region's definition
2. `instance.tf` including the nodes definitions
3. `worker_setup.sh` and `scheduler_setup.sh`; two provisioning scripts to be called from `terraform`.

#### `terraform.tf`

The simplest part:

```
provider "aws" {
  region = "eu-west-1"
}
```

#### `instance.tf`

This file describes what nodes to start, what instance types, what names etc. etc.

```
variable "instanceType" {
  type    = "string"
  default = "c5.2xlarge"
}

variable "contact" {
  type = "string"
  default = "u.name"
}

variable "department" {
  type = "string"
  default = "DS"
}

variable "subnet" {
  default = "subnet-777aaaaa"
}

variable "securityGroup" {
  type = "string"
  default = "sg-ffff7777"
}

resource "aws_instance" "dask-scheduler" {
  ami                         = "ami-4cbe0935" # [1]
  instance_type               = "${var.instanceType}"
  key_name                    = "dask_poc"
  security_groups             = ["${var.securityGroup}"]
  subnet_id                   = "${var.subnet}"
  associate_public_ip_address = true
  private_ip                  = "172.31.36.190" # [2]
  user_data                   = "${file("scheulder_setup.sh")}" [4]
  tags {
    Name = "dask-scheduler",
    Department = "${var.department}",
    contact = "${var.contact}"
  }
}

resource "aws_instance" "dask-worker" {
  count                       = 4
  ami                         = "ami-4cbe0935" # [1]
  instance_type               = "${var.instanceType}"
  key_name                    = "dask_poc"
  subnet_id                   = "${var.subnet}"
  security_groups             = ["${var.securityGroup}"]
  associate_public_ip_address = true
  user_data                   = "${file("worker_setup.sh")}" [4]
  tags {
    Name = "dask-worker${count.index}",
    Department = "${var.department}",
    contact = "${var.contact}"
  }
}

output "scheduler-info" { # [3]
  value = "${aws_instance.dask-scheduler.public_ip}"
}
```

Here are some points to keep in mind:

1. The [AMI](http://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html) I use is the one for `eu-west-1` which is optimized for Docker and provided by Amazon. It is possible to use other images as bases, but it is important that they will support `docker`.
2. It is needed to define the private IP of the scheduler. You will need to use it when starting the workers and it is easier to know the IP than to find it.
3. Nice trick of `terraform` enabling access to different outputs
4. The last step is to direct what provisioning script the setup should use.

#### Provisioning scripts

We need two scripts that will install the computing environment on each node and start the scheduler and workers.

##### Scheduler

```bash
#!/bin/bash

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Installing pip"
curl -O https://bootstrap.pypa.io/get-pip.py
python get-pip.py --user
~/.local/bin/pip install awscli --upgrade --user
echo "Logging in to ECS registry"
export AWS_ACCESS_KEY_ID=YOUR_KEY
export AWS_SECRET_ACCESS_KEY=YOUR_PRIVATE_KEY
export AWS_DEFAULT_REGION=select_region
$(~/.local/bin/aws ecr get-login --no-include-email)

echo "Starting docker container from image"
docker run -d -it --network host repo.url/image-name /opt/conda/bin/dask-scheduler
```

This script is straightforward.
First it installs the `aws` CLI.
Then, it logs into the registry (to which we pushed the docker image earlier).
Lastly, it starts a docker container and runs it as a scheduler.
The **important piece** here is to use `--network host`.
Roughly speaking, this exposes the container fully on the host.

When SSHing to the machine, you could see the log of this script at `/var/log/user-data.log`.
The log of the running Docker image can be found using `docker logs container_id` where the `container_id` can be found using `docker ps`.

##### Workers

```bash
#!/bin/bash

exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo "Installing pip"
curl -O https://bootstrap.pypa.io/get-pip.py
python get-pip.py --user
~/.local/bin/pip install awscli --upgrade --user
echo "Logging in to ECS registry"
export AWS_ACCESS_KEY_ID=YOUR_KEY
export AWS_SECRET_ACCESS_KEY=YOUR_PRIVATE_KEY
export AWS_DEFAULT_REGION=select_region
$(~/.local/bin/aws ecr get-login --no-include-email)

echo "Starting docker container from image"
docker run -d -it --network host repo.url/image-name /opt/conda/bin/dask-worker 172.31.36.190:8786
```

The important point here is that we specify the private IP of the scheduler as defined in `instances.tf`.


## Ready to distribute

It is time to enjoy the hard work.
In the project's root (where the `.tf` files and the provisioning scripts reside) run:

```
terraform init
terraform apply
```

Follow the prompt.
Once `terraform` finishes, you can SSH to the nodes.
Note, it takes a little longer before you can start using the cluster as first the provisioning scripts have to finish on all nodes.

It is now time to run the script we started with.
The only thing to change is the IP of the scheduler; in particular it can be found by `terraform output scheduler-info`.
It is suggested to include `bokeh` in the `requirements.txt`.
This way `bokeh` will be installed on the workers and the scheduler and expose a  monitoring tool of the cluster as described [here](http://distributed.readthedocs.io/en/latest/web.html).

If all went smoothly, and you have a running `dask` cluster at `x.y.z.w`, then you could run the distributed version of the example as provided in the docker image:

```bash
docker run -it --rm -p 8786:8786 dask-example ./gridsearch_cluster_dask.py x.y.z.w
```

Note that you need to forward the port `8786`.

## Yet to be implemented

* Utilize [spots](https://aws.amazon.com/ec2/spot/)
* Enable a node with Jupyter server so the local notebook won't be needed
