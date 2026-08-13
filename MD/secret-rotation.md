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

```
