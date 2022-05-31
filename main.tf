# Create App VPC
module "app_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = var.vpcs.app_vpc.name
  cidr = var.vpcs.app_vpc.cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = [cidrsubnet(var.vpcs.app_vpc.cidr, 8, 0), cidrsubnet(var.vpcs.app_vpc.cidr, 8, 1), cidrsubnet(var.vpcs.app_vpc.cidr, 8, 2)]
  intra_subnets   = [cidrsubnet(var.vpcs.app_vpc.cidr, 8, 10), cidrsubnet(var.vpcs.app_vpc.cidr, 8, 11), cidrsubnet(var.vpcs.app_vpc.cidr, 8, 12)]

  enable_dns_hostnames = true
  enable_dns_support   = true
}

# Create Egress VPC
module "egress_vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = var.vpcs.egress_vpc.name
  cidr = var.vpcs.egress_vpc.cidr

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = [cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 0), cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 1), cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 2)]
  intra_subnets   = [cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 10), cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 11), cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 12)]
  public_subnets  = [cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 20), cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 21), cidrsubnet(var.vpcs.egress_vpc.cidr, 8, 22)]

  enable_dns_hostnames = true
  enable_dns_support   = true
}

# Create TGW
module "tgw" {
  source  = "terraform-aws-modules/transit-gateway/aws"
  version = "~> 2.0"

  name        = "egress-ha-tgw"
  description = "Egress TGW"

  vpc_attachments = {
    app_vpc = {
      vpc_id       = module.app_vpc.vpc_id
      subnet_ids   = module.app_vpc.intra_subnets
      dns_support  = true
      ipv6_support = false

      transit_gateway_default_route_table_association = false
      transit_gateway_default_route_table_propagation = false

      tgw_routes = [
        {
          destination_cidr_block = var.vpcs.app_vpc.cidr
        },
      ]
    }
    egress_vpc = {
      vpc_id       = module.egress_vpc.vpc_id
      subnet_ids   = module.egress_vpc.intra_subnets
      dns_support  = true
      ipv6_support = false

      transit_gateway_default_route_table_association = false
      transit_gateway_default_route_table_propagation = false

      tgw_routes = [
        {
          destination_cidr_block = var.vpcs.egress_vpc.cidr
        },
        {
          destination_cidr_block = "0.0.0.0/0"
        },
      ]
    }
  }
  tags = {
    Purpose = "tgw"
  }
}

# Create FQDN GW
resource "aviatrix_gateway" "fqdn_gw" {
  count = length(module.egress_vpc.public_subnets_cidr_blocks)

  cloud_type     = 1
  account_name   = var.aws_account
  gw_name        = "fqdn-gw-${count.index}"
  vpc_id         = module.egress_vpc.vpc_id
  vpc_reg        = var.aws_region
  gw_size        = "t2.micro"
  subnet         = module.egress_vpc.public_subnets_cidr_blocks[count.index]
  single_ip_snat = true

  tags = {
    name = "fqdn-gw-${count.index}"
  }

  depends_on = [module.egress_vpc]
}

# Create an empty blacklist tag
resource "aviatrix_fqdn" "blacklist_filter" {
  fqdn_tag     = "blacklist_tag"
  fqdn_enabled = true
  fqdn_mode    = "black"

  depends_on = [aviatrix_gateway.fqdn_gw]
}

# Allow Ingress from app-vpc to FQDN gateways
resource "aws_security_group_rule" "ingress_app_vpc" {
  count = length(aviatrix_gateway.fqdn_gw)

  description       = "Allow ingress from app-vpc"
  type              = "ingress"
  from_port         = 0
  to_port           = 65535
  protocol          = "all"
  cidr_blocks       = [var.vpcs.app_vpc.cidr]
  security_group_id = aviatrix_gateway.fqdn_gw[count.index].security_group_id

  depends_on = [aviatrix_gateway.fqdn_gw]
}

# Create SSM Instance Profile
module "ssm_instance_profile" {
  source  = "bayupw/ssm-instance-profile/aws"
  version = "1.0.0"
}

# Create VPC Endpoints for SSM in private subnets
module "ssm_vpc_endpoint" {
  source  = "bayupw/ssm-vpc-endpoint/aws"
  version = "1.0.0"

  vpc_id         = module.app_vpc.vpc_id
  vpc_subnet_ids = module.app_vpc.private_subnets

  depends_on = [module.ssm_instance_profile]
}

# Create EC2 instances to simulate app in App-VPC 
module "app_ec2" {
  count = length(module.app_vpc.private_subnets)

  source  = "bayupw/amazon-linux-2/aws"
  version = "1.0.0"

  vpc_id               = module.app_vpc.vpc_id
  subnet_id            = module.app_vpc.private_subnets[count.index]
  iam_instance_profile = module.ssm_instance_profile.aws_iam_instance_profile

  depends_on = [module.app_vpc, module.ssm_vpc_endpoint]
}

# Create default route for App-VPC via TGW
resource "aws_route" "app_vpc_to_internet" {
  count = length(module.app_vpc.private_route_table_ids)

  route_table_id         = module.app_vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [module.tgw]
}

# Create route to App-VPC on Egress-VPC via TGW
resource "aws_route" "egress_to_app_vpc" {
  route_table_id         = module.egress_vpc.public_route_table_ids[0]
  destination_cidr_block = var.vpcs.app_vpc.cidr
  transit_gateway_id     = module.tgw.ec2_transit_gateway_id

  depends_on = [module.tgw]
}