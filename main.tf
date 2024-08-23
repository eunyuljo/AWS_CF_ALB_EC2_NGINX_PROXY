provider "aws" {
  region = "ap-northeast-2"
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "main_az1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = "ap-northeast-2a"
}

resource "aws_subnet" "main_az2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.20.0/24"
  availability_zone = "ap-northeast-2c"
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "a_az1" {
  subnet_id      = aws_subnet.main_az1.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "a_az2" {
  subnet_id      = aws_subnet.main_az2.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_security_group" "alb_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "app_lb" {
  name               = "app-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            =  [aws_subnet.main_az1.id, aws_subnet.main_az2.id]  

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "app_tg" {
  name     = "app-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200-399"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

resource "aws_instance" "app_server" {
  ami           = "ami-07d737d4d8119ad79"  # 최신 Amazon Linux 2 AMI 사용
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.main_az1.id
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]  # security_groups 대신 vpc_security_group_ids 사용

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              amazon-linux-extras install nginx1.12 -y
              systemctl start nginx
              systemctl enable nginx

              cat <<EOT > /etc/nginx/nginx.conf
              user nginx;
              worker_processes auto;
              error_log /var/log/nginx/error.log;
              pid /var/run/nginx.pid;

              events {
                  worker_connections 1024;
              }

              http {
                  include /etc/nginx/mime.types;
                  default_type application/octet-stream;
                  sendfile on;
                  keepalive_timeout 65;

                  server {
                      listen 80;
                      server_name _;
                      location / {
                          proxy_pass http://localhost;
                          proxy_set_header Host \$host;
                          proxy_set_header X-Real-IP \$remote_addr;
                          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                          proxy_set_header X-Forwarded-Proto \$scheme;
                      }
                  }
              }
              EOT

              systemctl restart nginx
              EOF

  tags = {
    Name = "NginxAppServer"
  }
}


resource "aws_lb_target_group_attachment" "app_tg_attachment" {
  target_group_arn = aws_lb_target_group.app_tg.arn
  target_id        = aws_instance.app_server.id
  port             = 80
}
