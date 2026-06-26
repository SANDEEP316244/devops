resource "aws_instance" "workstation" {
    ami = local.ami_id
    instance_type = "t3.micro"
    vpc_security_group_ids = [aws_security_group.workstation.id]
    iam_instance_profile = aws_iam_instance_profile.workstation.name
    # need more for terraform
    root_block_device {
        volume_size = 50
        volume_type = "gp3" # or "gp2", depending on your preference
    }

    user_data = file("workstation.sh")
    
    tags = merge (
        local.common_tags,
        {
            Name = "${var.project_name}-${var.environment}-workstation"
        }
    )

    # 🔹 Destroy-time provisioner to delete the EKS cluster
  provisioner "remote-exec" {
    when = destroy

    connection {
      type        = "ssh"
      user        = "ec2-user"
      host        = self.public_ip
      password = "DevOps321"
    }

    inline = [
      "echo 'Deleting EKS cluster from workstation...'",
      "eksctl delete cluster --config-file=/opt/eks/cluster.yaml || echo 'Cluster delete failed or already gone'"
    ]
  }
}



resource "aws_iam_instance_profile" "workstation" {
  name = "workstation"
  role = "BastionTerraformAdmin"
}


resource "aws_security_group" "workstation" {
  name   = "workstation"

  egress {
    from_port        = 0 # from port 0 to to port 0 means all ports
    to_port          = 0 
    protocol         = "-1" # -1 means all protocols
    cidr_blocks      = ["0.0.0.0/0"] # internet
  }

  ingress {
    from_port        = 0 # from port 0 to to port 0 means all ports
    to_port          = 0 
    protocol         = "-1" # -1 means all protocols
    cidr_blocks      = ["0.0.0.0/0"] # internet
  }

  tags = {
    Name = "workstation"
  }

}


# resource "terraform_data" "catalogue" {
#   triggers_replace = [
#     aws_instance.workstation.id
#   ]
  
#   connection {
#     type     = "ssh"
#     user     = "ec2-user"
#     password = "DevOps321"
#     host     = aws_instance.workstation.public_ip
#   }

  
#   provisioner "remote-exec" {
#     when    = destroy
#     inline = [
#         "eksctl delete cluster --config-file=/opt/eks/cluster.yaml"
#     ]
#   }
# }
