resource "aws_lb" "ingress_alb" {
  name               = "${local.common_name_suffix}-ingress-alb" # roboshop-dev-backend-alb
  internal           = false
  load_balancer_type = "application"
  security_groups    = [local.ingress_alb_sg_id]
  # it should be private subnet ids
  subnets            = local.public_subnet_ids

  enable_deletion_protection = false # prevents accidental deletion from UI

  tags = merge (
    local.common_tags,
    {
        Name = "${local.common_name_suffix}-ingress-alb"
    }
  )
}

resource "aws_lb_listener" "ingress_alb" {
  load_balancer_arn = aws_lb.ingress_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-3-2021-06"
  certificate_arn   = local.ingress_alb_certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/html"
      message_body = "<h1>Hi, I am from HTTPS ingress ALB</h1>"
      status_code  = "200"
    }
  }
}

resource "aws_route53_record" "ingress_alb" {
  zone_id = var.zone_id
  name    = "*.${var.domain_name}" # *.daws86s.fun
  type    = "A"
  allow_overwrite = true

  alias {
    # These are ALB details, not our domain details
    name                   = aws_lb.ingress_alb.dns_name
    zone_id                = aws_lb.ingress_alb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_lb_target_group" "frontend" {
  name     = "${local.common_name_suffix}-frontend"
  port     = 8080
  protocol = "HTTP"
  target_type = "ip"
  vpc_id   = local.vpc_id
  deregistration_delay = 60 # waiting period before deleting the instance

  health_check {
    healthy_threshold = 2
    interval = 10
    matcher = "200-299"
    path = "/"
    port = 8080
    protocol = "HTTP"
    timeout = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "frontend" {
  listener_arn = aws_lb_listener.ingress_alb.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }

  condition {
    host_header {
      values = ["${var.environment}.${var.domain_name}"] # dev.daws86s.fun
    }
  }
}
