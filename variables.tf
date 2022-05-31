variable "aws_region" {
  type    = string
  default = "ap-southeast-2"
}

variable "aws_account" {
  type    = string
  default = "aws-account"
}

variable "vpcs" {
  description = "Maps of VPC attributes"
  type        = map(any)

  default = {
    app_vpc = {
      name = "App-VPC"
      cidr = "10.1.0.0/16"
    }
    egress_vpc = {
      name = "Egress-VPC"
      cidr = "10.100.0.0/16"
    }
  }
}