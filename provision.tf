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
