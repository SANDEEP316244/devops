resource "aws_instance" "terraform" {
    ami = var.ami_id
    instance_type = lookup(var.instance_type, terraform.workspace )
    vpc_security_group_ids = [aws_security_group.allow_all.id]
    tags = merge(
      local.common_tags,
      {
        Name = "${local.common_name}-workspace"
      }
    )
}

resource "aws_security_group" "allow_all" {
  name   = "${local.common_name}-workspace"

  egress {
    from_port        = var.egress_from_port
    to_port          = var.egress_to_port
    protocol         = "-1" # -1 means all protocols
    cidr_blocks      = var.cidr
  }

  ingress {
    from_port        = var.ingress_from_port
    to_port          = var.ingress_to_port
    protocol         = var.protocol
    cidr_blocks      = var.cidr
  }

  tags = merge(
      local.common_tags,
      {
        Name = "${local.common_name}-workspace"
      }
  )

}