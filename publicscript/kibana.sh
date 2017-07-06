#!/bin/bash

set -eux

# @sacloud-once
# @sacloud-desc-begin
# Fluentd, Elasticsearch, Kibana���C���X�g�[������X�N���v�g�ł��B
# fluent-plugin-dstat��L���ɂ���ƁAdstat���C���X�g�[�����A
# dstat�̎��s���ʂ��ۑ�����A�������邱�Ƃ��ł��܂��B
# CentOS 7.x�n�݂̂ɑΉ����Ă���X�N���v�g�ł��B
# �T�[�o�쐬��Ahttp://<�T�[�o��IP�A�h���X>/ �ɃA�N�Z�X���������B
# �o�^����Basic�F�؂Ń��O�C������ƁAKibana�̃R���g���[���p�l�����\������܂��B
# @sacloud-desc-end
# @sacloud-text required ex="user" shellarg basicuser 'Basic�F�؂̃��[�U��'
# @sacloud-password required ex="" shellarg basicpass 'Basic�F�؂̃p�X���[�h'
# @sacloud-checkbox default="" shellarg enabledstat 'fluent-plugin-dstat��L���ɂ���'

#===== Sacloud Vars =====#
BASIC_USER=@@@basicuser@@@
BASIC_PASS=@@@basicpass@@@
FLUENT_PLUGIN_DSTAT_ENABLED=@@@enabledstat@@@
if [ -z $FLUENT_PLUGIN_DSTAT_ENABLED ]; then
    FLUENT_PLUGIN_DSTAT_ENABLED="0"
fi
#===== Sacloud Vars =====#

#===== Common =====#
yum update -y
echo "[*] Installing fluentd required plugins..."
yum install -y gcc wget curl libcurl-devel
echo "[*] Installing elasticsearch required plugins..."
yum install -y java-1.8.0-openjdk
echo "[*] Installing httpd-tools..."
yum install -y httpd-tools
yum install -y --enablerepo=epel nginx
echo "[*] Opening Nginx(80/tcp)..."
firewall-cmd --add-service=http --zone=public --permanent
if [ $FLUENT_PLUGIN_DSTAT_ENABLED = "1" ]; then
    echo "[*] Installing dstat..."
    yum install -y dstat
fi
echo "[*] Opening Fluentd(24224/tcp)..."
firewall-cmd --add-port=24224/tcp --zone=public --permanent
firewall-cmd --reload
#===== Common =====#

#===== Fluentd =====#
echo "[*] Installing td-agent..."
curl -L http://toolbelt.treasuredata.com/sh/install-redhat-td-agent2.sh | sh
echo "[*] Installing td-agent-gem (fluent-plugin-elasticsearch)"
td-agent-gem install fluent-plugin-elasticsearch

if [ $FLUENT_PLUGIN_DSTAT_ENABLED = "1" ]; then
    echo "[*] Installing td-agent-gem (fluent-plugin-dstat)"
    td-agent-gem install fluent-plugin-dstat

    echo "[*] Configuring /etc/td-agent/td-agent.conf..."
    cat << __EOT__ >> /etc/td-agent/td-agent.conf

<source>
    type dstat
    tag dstat.__HOSTNAME__
    option -cmdgn
    delay 3
</source>

<match dstat.**>
    type copy
    <store>
        type elasticsearch
        host localhost
        port 9200

        logstash_format true
        logstash_prefix logstash
        type_name dstat
        flush_interval 20
    </store>
</match>
__EOT__
fi
#===== Fluentd =====#

#===== Elastic Search =====#
echo "[*] Installing elasticsearch..."
rpm -ivh https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-5.4.0.rpm
echo "[*] Enable & Start elasticsearch..."
systemctl enable elasticsearch
systemctl start elasticsearch
echo "[+] success"
#===== Elastic Search =====#

#===== Kibana =====#
echo "[*] Installing Kibana..."
rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch
cat << __EOT__ >> /etc/yum.repos.d/kibana.repo
[kibana-5.x]
name=Kibana repository for 5.x packages
baseurl=https://artifacts.elastic.co/packages/5.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
__EOT__
yum update -y
yum install -y kibana

echo "[*] Enable & Start Kibana..."
systemctl enable kibana
systemctl start kibana
#===== Kibana =====#

#===== Change Logstash Template =====#
if [ $FLUENT_PLUGIN_DSTAT_ENABLED = "1" ]; then
    echo "[*] Change Logstash Template..."
    cat << __EOT__ | curl -XPUT http://localhost:9200/_template/logstash-tmpl -d @-
{
  "template": "logstash-*",
  "mappings": {
    "dstat": {
      "dynamic_templates": [
        {
          "string_to_double": {
            "match_mapping_type": "string",
            "path_match": "dstat.*",
            "mapping": { "type": "double" }
          }
        }
      ]
    }
  }
}
__EOT__
fi

echo "[*] Enable & Start td-agent..."
systemctl enable td-agent
systemctl start td-agent
echo "[+] success"
#===== Change Logstash Template =====#

#===== Nginx =====#
htpasswd -b -c /etc/nginx/.htpasswd $BASIC_USER $BASIC_PASS
cat << __EOT__ > /etc/nginx/nginx.conf
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;

# Load dynamic modules. See /usr/share/nginx/README.dynamic.
include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    # Load modular configuration files from the /etc/nginx/conf.d directory.
    # See http://nginx.org/en/docs/ngx_core_module.html#include
    # for more information.
    include /etc/nginx/conf.d/*.conf;

    server {
        listen       80 default_server;
        listen       [::]:80 default_server;
        server_name  _;
        root         /usr/share/nginx/html;

        # Load configuration files for the default server block.
        include /etc/nginx/default.d/*.conf;

        location / {
                    proxy_pass http://localhost:5601/;
                    auth_basic "Restricted";
                    auth_basic_user_file /etc/nginx/.htpasswd;
        }

        error_page 404 /404.html;
            location = /40x.html {
        }

        error_page 500 502 503 504 /50x.html;
            location = /50x.html {
        }
    }
}
__EOT__
systemctl enable nginx
systemctl start nginx
#===== Nginx =====#

echo "[+] Install Finished."