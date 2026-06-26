locals{
    ami_id = data.aws_ami.joindevops.id
    sonar_ami_id = data.aws_ami.sonarqube.id
    common_tags = {
        Project = var.project
        Environment = var.environment
        Terraform = "true"
    }
}