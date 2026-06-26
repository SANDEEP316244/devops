Frontend Load balancer is listening on port number 443
https://daws86s-dev.fun -> frontend ALB
Rule -> traffic coming to ALB it goes to frontend target group

backend-alb-dev.daws86s.fun -> backend ALB

catalogue.backend-alb-dev.daws86s.fun -> catalogue target group

1. create mongodb ec2 instance
2. connect to it
3. run ansible playbook

from bastion we can connect mongodb. run terraform code in bastion

bastion -> mongodb remote-exec provisioner

null_resource in terraform?

null_resource in terraform will not create any resource. but it is used to configure the instance using provisioner. it follows terraform lifecycle

null_resource is deprecated, now it is used as terraform_data

mongodb_bastion

terraform init, before that run aws configure

terraform taint
===============
taint is like paint, if you paint someone it is polluted. need to create again

when a resource is corrupted we can mark it as taint, so that terraform will recreate it next time

IAM Roles
=========
authentication and authorisation

authentication -> are you belongs to organisation or not
authorisation -> prove yourself that you have access or not

User
Group
Permissions
Role -> Trainee, SE, ASE, Consultant, TL, TM, DM, MD, ED, CEO

Role has permissions

Permissions are attached to role, role is attached to user

Roles are created for AWS services

rm -rf .git
git init
git branch -M main
git remote add origin <your-url>