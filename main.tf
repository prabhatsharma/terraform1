terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.66.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}



// Create a VPC
resource "aws_vpc" "cnn4" {
  cidr_block                       = "10.0.0.0/16"
  assign_generated_ipv6_cidr_block = true
  enable_dns_hostnames             = true

  tags = {
    Name = "cnn4"
  }
}

resource "aws_subnet" "public1" {
  vpc_id                          = aws_vpc.cnn4.id
  cidr_block                      = "10.0.1.0/24"
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.cnn4.ipv6_cidr_block, 8, 1)
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags = {
    Name = "public1"
  }
}

resource "aws_subnet" "public2" {
  vpc_id                          = aws_vpc.cnn4.id
  cidr_block                      = "10.0.2.0/24"
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.cnn4.ipv6_cidr_block, 8, 2)
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags = {
    Name = "public2"
  }
}

resource "aws_internet_gateway" "igw1" {
  vpc_id = aws_vpc.cnn4.id
}

resource "aws_egress_only_internet_gateway" "eigw1" {
  vpc_id = aws_vpc.cnn4.id
}

resource "aws_route_table" "public_route" {
  vpc_id = aws_vpc.cnn4.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw1.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_egress_only_internet_gateway.eigw1.id
  }
}

resource "aws_route_table_association" "public1" {
  subnet_id      = aws_subnet.public1.id
  route_table_id = aws_route_table.public_route.id
}

resource "aws_route_table_association" "public2" {
  subnet_id      = aws_subnet.public2.id
  route_table_id = aws_route_table.public_route.id
}


# Create ECS cluster

resource "aws_ecs_cluster" "cnn4" {
  name = "cnn4"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

data "aws_iam_policy_document" "ecs_tasks_execution_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com", "ecs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_tasks_execution_role" {
  name               = "ecsTasksExecutionRoleTF"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_execution_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_tasks_execution_role_private_ecr" {
  role       = aws_iam_role.ecs_tasks_execution_role.id
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_tasks_execution_role_public_ecr" {
  role       = aws_iam_role.ecs_tasks_execution_role.id
  policy_arn = "arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicReadOnly"
}


resource "aws_ecs_task_definition" "otel3" {
  family                   = "otel3"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_tasks_execution_role.arn



  container_definitions = jsonencode([
    {
      name  = "otel3"
      image = "public.ecr.aws/p6d6n2q4/otel1:v12"

      essential = true
      portMappings = [
        {
          "hostPort" : 9876,
          "protocol" : "tcp",
          "containerPort" : 9876
        }
      ]
    }
  ])
}

resource "aws_security_group" "otel3" {
  name        = "otel3"
  description = "otel3"
  vpc_id      = aws_vpc.cnn4.id

  ingress {
    description      = "All from VPC for otel3"
    from_port        = 9876
    to_port          = 9876
    protocol         = "tcp"
    cidr_blocks      = [aws_vpc.cnn4.cidr_block]
    ipv6_cidr_blocks = [aws_vpc.cnn4.ipv6_cidr_block]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "otel3"
  }
}

resource "aws_ecs_service" "otel3_service" {
  name            = "otel3"
  cluster         = aws_ecs_cluster.cnn4.id
  task_definition = aws_ecs_task_definition.otel3.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    security_groups  = [aws_security_group.otel3.id]
    subnets          = [aws_subnet.public1.id, aws_subnet.public2.id]
    assign_public_ip = true
  }
}


# create a load balancer

# resource "aws_lb" "alb" {
#   name               = "alb1"
#   internal           = false
#   subnets            = [aws_subnet.public1.id, aws_subnet.public2.id]
#   load_balancer_type = "application"
#   security_groups    = [aws_security_group.otel3.id]

# }
