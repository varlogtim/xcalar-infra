FROM isuper/java-oracle:jre_8
MAINTAINER Xcalar <info@xcalar.com>

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y git curl vim-nox postgresql-client

ENV GERRIT_USER gerrit2
ENV GERRIT_HOME /home/${GERRIT_USER}
ENV GERRIT_WAR ${GERRIT_HOME}/gerrit.war
ENV GERRIT_VERSION 2.12

RUN useradd -m ${GERRIT_USER}

RUN curl -sSL https://www.gerritcodereview.com/download/gerrit-${GERRIT_VERSION}.war > ${GERRIT_WAR}


RUN curl -o /usr/bin/gosu -sSL "https://github.com/tianon/gosu/releases/download/1.7/gosu-amd64" && chmod +x /usr/bin/gosu
RUN curl -fsSL "https://github.com/just-containers/s6-overlay/releases/download/v1.17.0.0/s6-overlay-amd64.tar.gz" | tar zx -C /
RUN chown -R ${GERRIT_USER}:${GERRIT_USER} $GERRIT_HOME

USER $GERRIT_USER
WORKDIR $GERRIT_HOME

#ENV JAVA_HOME /usr/lib/jvm/java-7-openjdk-amd64/jre
RUN java -jar $GERRIT_WAR init --batch -d ${GERRIT_HOME}/gerrit
RUN java -jar $GERRIT_WAR reindex -d ${GERRIT_HOME}/gerrit

RUN curl -sSL https://github.com/davido/gerrit-oauth-provider/releases/download/v2.11.3/gerrit-oauth-provider.jar > ${GERRIT_HOME}/gerrit/plugins/gerrit-oauth-provider.jar
RUN curl -sSL http://netstore.int.xcalar.com/users/amit/events-log.jar > ${GERRIT_HOME}/gerrit/plugins/events-log.jar
# clobber the gerrit config. set the URL to localhost:8080
#ADD gerrit.config $GERRIT_HOME/gerrit/etc/gerrit.config
#ADD secure.config $GERRIT_HOME/gerrit/etc/secure.config

# https://gerrit-documentation.storage.googleapis.com/Documentation/2.9.3/config-gerrit.html#auth
# ENV AUTH_TYPE OpenID

ENV AUTH_TYPE DEVELOPMENT_BECOME_ANY_ACCOUNT

ADD start.sh /app/start.sh
EXPOSE 8080 29418
CMD ["/app/start.sh"]
