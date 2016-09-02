FROM centos:6
MAINTAINER Ronan Ducamp r.ducamp@gmail.com
RUN yum -y install epel-release vim net-tools wget
COPY mariadb.repo /etc/yum.repos.d/mariadb.repo 
RUN yum -y install  http://www.percona.com/downloads/percona-release/redhat/0.1-3/percona-release-0.1-3.noarch.rpm
RUN yum -y install MariaDB-Galera-server MariaDB-client galera percona-xtrabackup
RUN yum clean all
RUN mkdir /var/log/mysql/
RUN chkconfig mysql on
COPY server.cnf /etc/my.cnf.d/server.cnf
RUN mysql_install_db
RUN chown -R mysql:mysql /var/log/mysql/
RUN chown -R mysql:mysql /var/lib/mysql/
RUN /etc/init.d/mysql start --wsrep-new-cluster && \
    mysqladmin -u root password "root" && \
    mysql -u root -proot -e "DELETE FROM mysql.user WHERE User='';" && \
    mysql -u root -proot -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1');" && \
    mysql -u root -proot -e "DROP DATABASE test;" && \
    mysql -u root -proot -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" && \
    mysql -u root -proot -e "GRANT ALL PRIVILEGES ON *.* TO sst@'%' IDENTIFIED BY 'sstrulez';" && \
    mysql -u root -proot -e "FLUSH PRIVILEGES;"

VOLUME /var/lib/mysql/ /etc/my.cnf.d/ /var/log/mysql/

#COPY docker-entrypoint.sh /entrypoint.sh
#ENTRYPOINT ["/entrypoint.sh"]

EXPOSE 3306 4444 4567 4568 8888

