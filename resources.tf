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
