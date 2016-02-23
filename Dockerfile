FROM ubuntu:trusty

# Install packages
ENV DEBIAN_FRONTEND noninteractive
# Purge des comptes mysql
#RUN rm -rf /var/lib/mysql/mysql/

RUN apt-get update && \
  apt-get -yq install wget libssl1.0.0 python mysql-server-5.6 redis-server pwgen openssh-server && \
  wget -q http://packages.couchbase.com/releases/3.1.0/couchbase-server-enterprise_3.1.0-debian7_amd64.deb -O couchbase-server-community.deb && \
  dpkg -i couchbase-server-community.deb && \
  rm couchbase-server-community.deb

RUN wget -q http://mirrors.kernel.org/ubuntu/pool/universe/w/whois/mkpasswd_5.0.0ubuntu3_amd64.deb -O mkpasswd.deb && \
  dpkg -i mkpasswd.deb && \
  rm mkpasswd.deb && \
  rm -rf /var/lib/apt/lists/*

# Add MySQL configuration
ADD my.cnf /etc/mysql/my.cnf
ADD mysqld_charset.cnf /etc/mysql/conf.d/mysqld_charset.cnf

# Add MySQL scripts
ADD import_sql.sh /import_sql.sh
ADD run.sh /run.sh
ADD redis.conf /etc/redis/redis.conf
RUN chmod 755 /*.sh

# Exposed ENV
ENV MYSQL_USER admin
ENV MYSQL_PASS **Random**
# Couchbase
ENV PATH /opt/couchbase/bin:/opt/couchbase/bin/tools:$PATH

# Add VOLUMEs to allow backup of config and databases
VOLUME  ["/var/log/redis", "/var/lib/mysql", "/var/log/mysql", "/var/run/mysqld"]

# Mysql=>3306 Redis=> 6379 Couchbase=>439 8091 8092 11209 11210 11211 18886 18887 18888
EXPOSE 3306 6379 4369 8091 8092 11209 11210 11211 18886 18887 18888 
CMD ["/run.sh"]
