variable "instanceType" {
  type    = "string"
  default = "c5.2xlarge"
}

variable "spotPrice" {
  # Note needed for on-demand instances
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

# By defining the AWS keys as variables we can get them from the command line and pass them to the provisioning scripts
variable "awsKey" {}
variable "awsPrivateKey" {}
