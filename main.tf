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
resource "aws_vpc" "cnn" {
  cidr_block                       = "10.0.0.0/16"
  assign_generated_ipv6_cidr_block = true
  enable_dns_hostnames             = true

  tags = {
    Name = "cnn"
  }
}

resource "aws_subnet" "public1" {
  vpc_id                          = aws_vpc.cnn.id
  cidr_block                      = "10.0.1.0/24"
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.cnn.ipv6_cidr_block, 8, 1)
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags = {
    Name = "public1"
  }
}

resource "aws_subnet" "public2" {
  vpc_id                          = aws_vpc.cnn.id
  cidr_block                      = "10.0.2.0/24"
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.cnn.ipv6_cidr_block, 8, 2)
  map_public_ip_on_launch         = true
  assign_ipv6_address_on_creation = true

  tags = {
    Name = "public2"
  }
}

resource "aws_internet_gateway" "igw1" {
  vpc_id = aws_vpc.cnn.id
}

resource "aws_egress_only_internet_gateway" "eigw1" {
  vpc_id = aws_vpc.cnn.id
}

resource "aws_route_table" "public_route" {
  vpc_id = aws_vpc.cnn.id

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

resource "aws_ecs_cluster" "cnn" {
  name = "cnn"

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


resource "aws_ecs_task_definition" "otel1" {
  family                   = "otel1"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_tasks_execution_role.arn



  container_definitions = jsonencode([
    {
      name  = "otel1"
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

resource "aws_security_group" "otel1" {
  name        = "otel1"
  description = "otel1"
  vpc_id      = aws_vpc.cnn.id

  ingress {
    description      = "All from VPC for otel1"
    from_port        = 9876
    to_port          = 9876
    protocol         = "tcp"
    cidr_blocks      = [aws_vpc.cnn.cidr_block]
    ipv6_cidr_blocks = [aws_vpc.cnn.ipv6_cidr_block]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "otel1"
  }
}

resource "aws_ecs_service" "otel1_service" {
  name            = "otel1"
  cluster         = aws_ecs_cluster.cnn.id
  task_definition = aws_ecs_task_definition.otel1.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  network_configuration {
    security_groups  = [aws_security_group.otel1.id]
    subnets          = [aws_subnet.public1.id, aws_subnet.public2.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.otelecsblue.arn
    container_name   = "otel1"
    container_port   = 9876
  }
}


# create a load balancer

resource "aws_security_group" "otel1_alb" {
  name        = "otel1_alb"
  description = "otel1_alb"
  vpc_id      = aws_vpc.cnn.id

  ingress {
    description      = "All from internet to LB "
    from_port        = 80
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "otel1_alb"
  }
}

resource "aws_lb" "otelecs" {
  name               = "otelecs"
  internal           = false
  subnets            = [aws_subnet.public1.id, aws_subnet.public2.id]
  load_balancer_type = "application"
  security_groups    = [aws_security_group.otel1_alb.id]

}

resource "aws_lb_target_group" "otelecsblue" {
  name     = "otelecsblue"
  port     = 9876
  protocol = "HTTP"
  vpc_id   = aws_vpc.cnn.id
  target_type = "ip"
  

  health_check {
    path                = "/"
    interval            = 60
    port                = 9876
    protocol            = "HTTP"
    timeout             = 3
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200-299"
  }
}

resource "aws_lb_target_group" "otelecsgreen" {
  name     = "otelecsgreen"
  port     = 9876
  protocol = "HTTP"
  vpc_id   = aws_vpc.cnn.id
  target_type = "ip"
  

  health_check {
    path                = "/"
    interval            = 60
    port                = 9876
    protocol            = "HTTP"
    timeout             = 3
    healthy_threshold   = 3
    unhealthy_threshold = 3
    matcher             = "200-299"
  }
}

resource "aws_lb_listener" "otelecsblue" {
  load_balancer_arn = aws_lb.otelecs.arn
  port              = "80"
  protocol          = "HTTP"
  # ssl_policy        = "ELBSecurityPolicy-2016-08"
  # certificate_arn   = "arn:aws:iam::187416307283:server-certificate/test_cert_rab3wuqwgja25ct3n4jdj2tzu4"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.otelecsblue.arn
  }
}

resource "aws_lb_listener" "otelecsgreen" {
  load_balancer_arn = aws_lb.otelecs.arn
  port              = "81"
  protocol          = "HTTP"
  # ssl_policy        = "ELBSecurityPolicy-2016-08"
  # certificate_arn   = "arn:aws:iam::187416307283:server-certificate/test_cert_rab3wuqwgja25ct3n4jdj2tzu4"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.otelecsgreen.arn
  }
}
