## for secret rotation to improve security

### update secret.tf
```
resource "aws_secretsmanager_secret_version" "mysql" {
  secret_id = aws_secretsmanager_secret.mysql.id
  secret_string = jsonencode({
    engine   = "mysql"
    host     = "<your-nlb-hostname>"
    port     = 3306
    username = "root"
    password = random_password.mysql_password.result
    dbname   = "bankapp"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
```

### update mysql-external-secret.yml

```
refreshInterval shortened from 1h to 15m, and MYSQL_DATABASE's property changed from database -> dbname to match the new schema.

```

### add a mysql-rotation.tf file

```
It is the file that sets up automatic password rotation for MySQL — it's the AWS-side infrastructure that makes the whole rotation pipeline you just tested possible

aws_serverlessapplicationrepository_cloudformation_stack.mysql_rotation -> this reource the one that does the actual createSecret → setSecret → testSecret → finishSecret sequence.

aws_security_group.mysql_rotation_lambda -> A firewall rule set at the AWS network level, controlling what the Lambda is allowed to talk to: outbound to port 3306 (to reach MySQL) and outbound to 443 (to reach the Secrets Manager API to read/write the secret).

aws_secretsmanager_secret_rotation.mysql -> The actual "turn rotation on" switch — it tells AWS Secrets Manager "use that Lambda from step 1 to rotate this specific secret (bankapp/mysql), automatically, every 30 days" (automatically_after_days = 30). This is also what you were bypassing today by manually running aws secretsmanager rotate-secret to test it immediately instead of waiting a month.

IMPORTANCE- before this file the password was once set by terraform and remain static forever. this file make the password change automatic on a schedule.

The host field it targets comes from terraform/secrets.tf's aws_secretsmanager_secret_version.mysql — which itself had to be updated to point at mysql-internal-lb.
as the mysql pod has headless service we need to create a extra load balancer service which connect the lambda to the pod.


```

### update network policy

```
 - from:
        - ipBlock:
            cidr: 10.0.0.0/16              # your VPC CIDR, or narrow to just the Lambda's subnet CIDRs
      ports:
        - port: 3306

add a ingress block in network policy for mysql and provide vpc CIDR to have access across all the reource in vpc
```

### add a reloader application argocd/reloader-app.yml

```
this is a important which restarts the pods secret is changed. Stakater Reloader watches Secrets/ConfigMaps and triggers a rolling restart automatically when they change

NOTE- verify the chart version before committing

helm repo add stakater https://stakater.github.io/stakater-charts --force-update
helm search repo stakater/reloader

```

### add annotation to deployment to restart when secret is changed.

```

## add to both bankapp deployment and mysql statefulset

reloader.stakater.com/auto: "true"  -> add this under metadata.annotations

```

### apply terraform and k8s resource.

```
then there is a manual trigger you have to add mysql-internal-lb external-IP to the secrets.tf host.
reapply terraform
```

### check manual if everything is working

```
get current pass
kubectl get secret mysql-secret -n newbankapp -o jsonpath='{.data.MYSQL_ROOT_PASSWORD}' | base64 -d
echo
----------------

trigger manual rotation
aws secretsmanager rotate-secret --secret-id bankapp/mysql --region eu-north-1
---------------

watch logs autmatically run and succeed
aws logs tail /aws/lambda/bankapp-mysql-rotation --follow --region eu-north-1

---------------

confirm the password is changed

aws secretsmanager get-secret-value --secret-id bankapp/mysql --region eu-north-1 --query SecretString --output text

-----------------

check pods restarted or not

kubectl get pods -n newbankapp -l app=bankapp
kubectl get pods -n newbankapp -l app=mysql-app

---------------------

Confirm the app is working with new password

kubectl exec -n newbankapp deploy/bankapp-dep -- env | grep MYSQL_PASSWORD

check if pods s using latest pass or not

----------------------

```

if get into any issue or password not updated

```
where the stuck rotation actually failed
aws secretsmanager describe-secret --secret-id bankapp/mysql --region eu-north-1

Lambda's actual logs for why it stalled
aws logs tail /aws/lambda/bankapp-mysql-rotation --region eu-north-1 --since 1d

aws secretsmanager cancel-rotate-secret --secret-id bankapp/mysql --region eu-north-1
cancel the currect stuck rotation

aws secretsmanager get-secret-value --secret-id bankapp/mysql --region eu-north-1 --query SecretString --output text
hows the pass in secret manager

update the secret manually with new external-IP of mysql-loadbalancer-elb
aws secretsmanager put-secret-value \
  --secret-id bankapp/mysql \
  --region eu-north-1 \
  --secret-string '{"engine":"mysql","host":"acd55e35ea9344c158f02db97576fe25-df46a853f7cecd40.elb.eu-north-1.amazonaws.com","port":3306,"username":"root","password":"UFXhaIfWUKQS","dbname":"bankapp"}'

then run

aws secretsmanager cancel-rotate-secret --secret-id bankapp/mysql --region eu-north-1
aws secretsmanager rotate-secret --secret-id bankapp/mysql --region eu-north-1
aws logs tail /aws/lambda/bankapp-mysql-rotation --region eu-north-1 --follow

```

IMPORTANT ->

```
lifecycle {
    ignore_changes = [secret_string]
  }

add above in secrets.tf so that terraform only applies the password first time. then never touch it again, regardless of what changes in AWS afterward

```

