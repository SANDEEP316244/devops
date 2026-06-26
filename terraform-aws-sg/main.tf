resource "aws_security_group" "main" {
  name        = var.sg_name # catalogue
  description = var.sg_description
  vpc_id      = var.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  tags = merge(
    var.sg_tags,
    local.common_tags,
    {
        Name = "${local.common_name_suffix}-${var.sg_name}" # roboshop-dev-catalogue
    }
  )
}