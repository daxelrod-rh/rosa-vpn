terraform {
  required_providers {
    rhcs = {
      version = ">= 1.6.9"
      source = "terraform-redhat/rhcs"
    }
  }
}

variable "token" {
  type      = string
  sensitive = true
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "developer_password" {
  type      = string
  sensitive = true
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      "app-code" = "MOBB-001"
      "cost-center" = "CC468"
      "owner" = "daxelrod_redhat.com"
      "service-phase" = "lab"
    }
  }
}

provider "rhcs" {
  token = var.token
}

module "rosa_public" {
  source = "git::https://github.com/rh-mobb/terraform-rosa.git?ref=makefile"

  hosted_control_plane = true
  private              = false
  multi_az             = false
  replicas             = 2
  cluster_name         = "daxelrod-v7"
  ocp_version          = "4.19.9"
  token                = var.token
  admin_password       = var.admin_password
  developer_password   = var.developer_password
  pod_cidr             = "10.128.0.0/14"
  service_cidr         = "172.30.0.0/16"
  compute_machine_type = "m5.xlarge"
  bastion_public_ssh_key = "/home/daxelrod/.ssh/id_ed25519.pub"
  bastion_public_ip = true

  tags = {
    "app-code" = "MOBB-001"
    "cost-center" = "CC468"
    "owner" = "daxelrod_redhat.com"
    "service-phase" = "lab"
  }
}

module "mpzn" {
  source = "terraform-redhat/rosa-hcp/rhcs//modules/machine-pool"
  version = "1.7.0"

  cluster_id = module.rosa_public.cluster_id
  name = "metalzn"
  openshift_version = "4.19.9"

  aws_node_pool = {
    instance_type = "m5zn.metal"
    tags = {}
  }

  subnet_id = module.rosa_public.private_subnet_ids[0]
  autoscaling = {
    enabled = false
    min_replicas = null
    max_replicas = null
  }
  replicas = 1
}

# Comment out everything after this line until the cluster is created and you can create a Service.

resource "aws_customer_gateway" "customer_gateway" {
  ip_address = "98.88.176.49" #Can only fill this in after creating a Service
  type = "ipsec.1"
  tags = {
    "Name" = "daxelrod-v7-cgw"
  }
}

resource "aws_vpn_gateway" "vpn_gw" {
  vpc_id = module.rosa_public.vpc_id #automatically does attachment

  tags = {
    "Name" = "daxelrod-v7-vpn-gateway"
  }
}

resource "aws_vpn_connection" "vpn" {
  customer_gateway_id = aws_customer_gateway.customer_gateway.id
  type = "ipsec.1"
  vpn_gateway_id = aws_vpn_gateway.vpn_gw.id
  static_routes_only = true
  preshared_key_storage = "Standard"
  local_ipv4_network_cidr = module.rosa_public.vpc_cidr
  remote_ipv4_network_cidr = "192.168.1.0/24"
  #tunnel1_preshared_key = #TODO make this static in here?
  #tunnel2_preshared_key = #TODO make this static in here?

  tags = {
    "Name" = "daxelrod-v7-vpn"
  }
}

resource "aws_vpn_connection_route" "vpn_route_cudn" {
  destination_cidr_block = "192.168.1.0/24" #TODO variable with remote_ipv4_network_cidr
  vpn_connection_id = aws_vpn_connection.vpn.id
}

data "aws_vpc" "rosa_vpc" {
  id = module.rosa_public.vpc_id
}

data "aws_route_table" "private_subnet_rt" {
  subnet_id = module.rosa_public.private_subnet_ids[0]
}

data "aws_route_table" "public_subnet_rt" {
  subnet_id = module.rosa_public.public_subnet_ids[0]
}

resource "aws_vpn_gateway_route_propagation" "default" {
  vpn_gateway_id = aws_vpn_gateway.vpn_gw.id
  route_table_id = data.aws_vpc.rosa_vpc.main_route_table_id
}

resource "aws_vpn_gateway_route_propagation" "private" {
  vpn_gateway_id = aws_vpn_gateway.vpn_gw.id
  route_table_id = data.aws_route_table.private_subnet_rt.id
}

resource "aws_vpn_gateway_route_propagation" "vpn_route_prop" {
  vpn_gateway_id = aws_vpn_gateway.vpn_gw.id
  route_table_id = data.aws_route_table.public_subnet_rt.id
}

# TODO turn on Propagated attribute for main route and all subnet routes?
