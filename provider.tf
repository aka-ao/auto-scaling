# AWS基本設定
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = "ap-northeast-1"
}

resource "aws_vpc" "auto-scaling" {
  cidr_block = "10.0.0.0/16"

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "auto_scaling"
  }
}

data "aws_route_table" "auto-scaling" {
  vpc_id = aws_vpc.auto-scaling.id
}

resource "aws_route" "route" {
  route_table_id = data.aws_route_table.auto-scaling.id
  gateway_id = aws_internet_gateway.auto-scaling.id
  destination_cidr_block = "0.0.0.0/0"
}


resource "aws_internet_gateway" "auto-scaling" {
  vpc_id = aws_vpc.auto-scaling.id
}

resource "aws_security_group" "auto-scaling" {
  vpc_id = aws_vpc.auto-scaling.id
  name = "elb_ec2"
  ingress {
    from_port = 80
    protocol = "TCP"
    to_port = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 22
    protocol = "TCP"
    to_port = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "subnets" {
  count = 2
  //  # 先程作成したVPCを参照し、そのVPC内にSubnetを立てる
  vpc_id = aws_vpc.auto-scaling.id

  cidr_block = "10.0.${count.index+1}.0/24"

  # Subnetを作成するAZ
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "aws-auto-scaling-subnet-${count.index + 1}"
  }
}

resource "aws_key_pair" "auto-scaling" {
  public_key = file("~/.ssh/id_rsa.pub")
}

resource "aws_alb" "auto-scaling" {
  name = "auto-scaling"
  subnets = aws_subnet.subnets.*.id
  security_groups = [aws_security_group.auto-scaling.id]

}

resource "aws_lb_target_group" "lb_target_group" {
  name = "auto-scaling"
  protocol = "HTTP"
  port = "80"
  vpc_id = aws_vpc.auto-scaling.id
  health_check {
    protocol = "HTTP"
    path = "/"
  }
}

output "lb_result" {
  value = aws_alb.auto-scaling.dns_name
}

resource "aws_lb_listener" "auto-scaling" {
  load_balancer_arn = aws_alb.auto-scaling.arn
  port = 80
  protocol = "HTTP"

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.lb_target_group.arn
  }
}


resource "aws_launch_configuration" "dev_api" {
  name = "dev-api"
  image_id = "ami-0bc8ae3ec8e338cbc"
  instance_type = "t2.micro"
  key_name = aws_key_pair.auto-scaling.id
  security_groups = [aws_security_group.auto-scaling.id]

  user_data = <<EOF
  #!/bin/bash
  sudo yum install -y httpd
  sudo yum install -y mysql
  sudo systemctl start httpd
  sudo systemctl enable httpd
  sudo usermod -a -G apache ec2-user
  sudo chown -R ec2-user:apache /var/www
  sudo chmod 2775 /var/www
  find /var/www -type d -exec chmod 2775 {} \;
  find /var/www -type f -exec chmod 0664 {} \;
  echo `hostname` > /var/www/html/index.html
  EOF

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_key_pair.auto-scaling,
    aws_security_group.auto-scaling
  ]
}

resource "aws_autoscaling_group" "dev_api" {
  max_size = 3
  min_size = 2
  launch_configuration = aws_launch_configuration.dev_api.id
  vpc_zone_identifier = [aws_subnet.subnets[0].id,aws_subnet.subnets[1].id]
  target_group_arns = [aws_lb_target_group.lb_target_group.arn]

}