# ELK Installation

Extend the disk, you must have atleast 60GB
```bash
sudo growpart /dev/nvme0n1 4
```
```bash
sudo lvextend -L +20G /dev/RootVG/rootVol
sudo lvextend -L +20G /dev/RootVG/varVol
```
```bash
sudo xfs_growfs /
```
```bash
sudo xfs_growfs /var
```
Add the repo
```bash
vim /etc/yum.repos.d/elasticsearch.repo
```
```bash
[elasticsearch]
name=Elasticsearch repository for 9.x packages
baseurl=https://artifacts.elastic.co/packages/9.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
type=rpm-md
```

Install elasticsearch, kibana, logstash
```bash
dnf install elasticsearch kibana logstash nginx -y
```

```bash
systemctl start elasticsearch
systemctl start kibana
```
**We can use nginx as reverse proxy for easy web access**

```bash
rm -rf /etc/nginx/nginx.conf
```

```bash
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    include /etc/nginx/conf.d/*.conf;
  ## Kibana Config
  upstream kibana {
    server 127.0.0.1:5601;
    keepalive 15;
  }

  server {
    listen 80;

    location / {
      proxy_pass http://kibana;
      proxy_redirect off;
      proxy_buffering off;

      proxy_http_version 1.1;
      proxy_set_header Connection "Keep-Alive";
      proxy_set_header Proxy-Connection "Keep-Alive";
    }

  }
}
```

Generate an enrollment token for Kibana instance.
```bash
/usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana
```

Kibana Verification
```bash
/usr/share/kibana/bin/kibana-verification-code
```
Reset admin password
```bash
/usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic
```

## Filebeat
Create one EC2 for filebeat

Add the repo
```bash
vim /etc/yum.repos.d/elasticsearch.repo
```
```bash
[elasticsearch]
name=Elasticsearch repository for 9.x packages
baseurl=https://artifacts.elastic.co/packages/9.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
type=rpm-md
```
```
dnf install filebeat -y
```
Install any application to get the logs, I am installing nginx here
```
dnf install nginx -y
systemctl start nginx
```

Let's push nginx logs to elasticsearch. Edit the filebeat config.
```bash
vim /etc/filebeat/filebeat.yml
```

enabled: true <br/>
inputs: nginx access log <br/>
outputs: elastic <br/>
ssl_verification: none <br/>
protocol: https <br/>

* Go to stack management and see the data in index management
* Create an index for that
* Now we can see logs in disover

### Logstash
```
systemctl start logstash
```
logstash configuration
```
vim /etc/logstash/conf.d/nginx-access-log.conf
```

Edit filebeat config to send logs to logstash

Create index again, and see the logs are converted to structured

### Sending EKS logs to ELK

```bash
helm repo add elastic https://helm.elastic.co
```
```
helm install filebeat elastic/filebeat -f filebeat.yml
```

Change logstash config to receive EKS container logs. Final logstash config is
```bash

```