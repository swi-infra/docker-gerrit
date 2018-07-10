FROM openjdk:8-jre-alpine

MAINTAINER zsx <thinkernel@gmail.com>

# Overridable defaults
ENV GERRIT_HOME /var/gerrit
ENV GERRIT_SITE ${GERRIT_HOME}/review_site
ENV GERRIT_WAR ${GERRIT_HOME}/gerrit.war
ENV GERRIT_VERSION bazel-stable-2.15
ENV GERRIT_USER gerrit
ENV GERRIT_INIT_ARGS ""

# Add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN adduser -D -h "${GERRIT_HOME}" -g "Gerrit User" -s /sbin/nologin "${GERRIT_USER}"

RUN set -x \
    && apk add --update --no-cache git openssh openssl bash perl perl-cgi git-gitweb curl su-exec procmail jq

RUN mkdir /docker-entrypoint-init.d

# Download gerrit.war
RUN curl -fSsL https://gerrit-ci.gerritforge.com/job/Gerrit-${GERRIT_VERSION}/lastSuccessfulBuild/artifact/gerrit/bazel-bin/release.war -o $GERRIT_WAR
# Only for local test
#COPY gerrit-${GERRIT_VERSION}.war $GERRIT_WAR

# Download Plugins
COPY get-plugin.sh /

# delete-project
RUN /get-plugin.sh delete-project stable-2.15

# events-log
# This plugin is required by gerrit-trigger plugin of Jenkins.
RUN /get-plugin.sh events-log stable-2.15

# gitiles
RUN /get-plugin.sh gitiles stable-2.15

# metrics-reporter-graphite
RUN /get-plugin.sh metrics-reporter-graphite master-stable-2.15

# lfs
RUN /get-plugin.sh lfs stable-2.15

# oauth2 plugin
RUN /get-plugin.sh gerrit-oauth-provider v2.14.6.2 davido

# importer
RUN /get-plugin.sh importer stable-2.15

# readonly
RUN /get-plugin.sh readonly stable-2.15

# rabbitmq
RUN /get-plugin.sh rabbitmq stable-2.15

# Ensure the entrypoint scripts are in a fixed location
COPY gerrit-entrypoint.sh /
COPY gerrit-start.sh /

# A directory has to be created before a volume is mounted to it.
# So gerrit user can own this directory.
RUN su-exec ${GERRIT_USER} mkdir -p $GERRIT_SITE

# Gerrit site directory is a volume, so configuration and repositories
# can be persisted and survive image upgrades.
VOLUME $GERRIT_SITE

ENTRYPOINT ["/gerrit-entrypoint.sh"]

EXPOSE 8080 29418

CMD ["/gerrit-start.sh"]
