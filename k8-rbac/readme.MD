OpenID connect create
```
eksctl utils associate-iam-oidc-provider --cluster roboshop-dev --approve
```

Create service account
```
eksctl create iamserviceaccount --cluster roboshop-dev --name secret-reader --namespace roboshop --attach-policy-arn arn:aws:iam::160885265516:policy/RoboShopMySQLSecretReader --approve
```

Get secret value
```
aws secretsmanager get-secret-value --secret-id roboshop/dev/mysql_password --query SecretString --output text
```
