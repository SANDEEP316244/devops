### EKS creation using eksctl

When the cluster is created successfully, We connect using Bastion Host with ec2-user

```
aws eks update-kubeconfig --region us-east-1 --name roboshop-dev
```