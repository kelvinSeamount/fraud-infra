data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "${var.project}-${var.env}-vpc"
    Env     = var.env
    Project = var.project
  }
}

# ─── Public subnets ────────#
# Hold the NAT Gateway and any internet-facing load balancer. The
# kubernetes.io/role/elb tag is what lets the AWS Load Balancer Controller
# discover these subnets when it provisions a public NLB/ALB.
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = element(data.aws_availability_zones.available.names, count.index)
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${var.project}-${var.env}-public-subnet-${count.index + 1}"
    Env                      = var.env
    Project                  = var.project
    "kubernetes.io/role/elb" = "1"
  }
}

# ─── Private EKS subnets ────────────────────────────────────────────────────
# Both node groups (general + memory-optimized) land here. No public IPs;
# egress is via the NAT Gateway. The cluster-ownership tag is required for
# EKS to manage ENIs in these subnets.
resource "aws_subnet" "private_eks" {
  count             = length(var.private_eks_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_eks_subnet_cidrs[count.index]
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = {
    Name                              = "${var.project}-${var.env}-eks-private-subnet-${count.index + 1}"
    Env                               = var.env
    Project                           = var.project
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/${var.project}-${var.env}-cluster" = "owned"
  }
}

# ─── Private data subnets ───────────────────────────────────────────────────
# Deliberately NOT tagged for Kubernetes. Nothing in the cluster should ever
# schedule here — this tier is for managed data services only (RDS in Phase 1).
resource "aws_subnet" "private_data" {
  count             = length(var.private_data_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_data_subnet_cidrs[count.index]
  availability_zone = element(data.aws_availability_zones.available.names, count.index)

  tags = {
    Name    = "${var.project}-${var.env}-data-private-subnet-${count.index + 1}"
    Env     = var.env
    Project = var.project
    Tier    = "data"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name    = "${var.project}-${var.env}-igw"
    Env     = var.env
    Project = var.project
  }
}

# ─── NAT Gateway ────────────────────────────────────────────────────────────
# ONE NAT for the whole VPC. This is a deliberate cost trade-off: a per-AZ NAT
# would survive an AZ failure but doubles the ~$32/month NAT bill. For a
# portfolio cluster that gets destroyed nightly, single-NAT is correct.
# Say this out loud in an interview — it shows you priced the decision.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name    = "${var.project}-${var.env}-nat-eip"
    Env     = var.env
    Project = var.project
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name    = "${var.project}-${var.env}-nat-gw"
    Env     = var.env
    Project = var.project
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name    = "${var.project}-${var.env}-public-rt"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name    = "${var.project}-${var.env}-private-rt"
    Env     = var.env
    Project = var.project
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_eks" {
  count          = length(aws_subnet.private_eks)
  subnet_id      = aws_subnet.private_eks[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_data" {
  count          = length(aws_subnet.private_data)
  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = aws_route_table.private.id
}
