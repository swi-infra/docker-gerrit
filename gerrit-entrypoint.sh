#!/usr/bin/env sh
set -xe

set_gerrit_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/gerrit.config" "$@"
}

set_secure_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/secure.config" "$@"
}

wait_for_database() {
  echo "Waiting for database connection $1:$2 ..."
  until nc -z $1 $2; do
    sleep 1
  done

  # Wait to avoid "panic: Failed to open sql connection pq: the database system is starting up"
  sleep 1
}

set_graphite_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/metrics-reporter-graphite.config" "$@"
}

set_notedb_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/notedb.config" "$@"
}

set_lfs_config() {
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/etc/lfs.config" "$@"
}

set_rabbitmq_config() {
  su-exec ${GERRIT_USER} mkdir -p "${GERRIT_SITE}/data/rabbitmq"
  su-exec ${GERRIT_USER} git config -f "${GERRIT_SITE}/data/rabbitmq/rabbitmq.config" "$@"
}

first_run=false

if [ -n "${JAVA_HEAPLIMIT}" ]; then
  JAVA_MEM_OPTIONS="-Xmx${JAVA_HEAPLIMIT}"
fi

if [ "$1" = "/gerrit-start.sh" ]; then
  # If you're mounting ${GERRIT_SITE} to your host, you this will default to root.
  # This obviously ensures the permissions are set correctly for when gerrit starts.
  find "${GERRIT_SITE}/" ! -user `id -u ${GERRIT_USER}` -exec chown ${GERRIT_USER} {} \;

  # Initialize Gerrit if ${GERRIT_SITE}/etc doesn't exist.
  SHOULD_INIT=false
  if ! [ -e "${GERRIT_SITE}/etc" ]; then
    SHOULD_INIT=true
    echo "First time initialize gerrit..."
    first_run=true
  fi

  if [ -e "${GERRIT_SITE}/etc/should_init" ]; then
    SHOULD_INIT=true
    echo "Reinit gerrit..."
  fi

  if [[ "$SHOULD_INIT" == "true" ]]; then
    if ! su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --batch --no-auto-start -d "${GERRIT_SITE}" ${GERRIT_INIT_ARGS}; then
       echo "... failed, retrying"
       if ! su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --batch --no-auto-start -d "${GERRIT_SITE}" ${GERRIT_INIT_ARGS}; then
           echo "...failed again"
           exit 1
       fi
    fi
  fi

  # Install external plugins
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/delete-project.jar ${GERRIT_SITE}/plugins/delete-project.jar
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/events-log.jar ${GERRIT_SITE}/plugins/events-log.jar
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/importer.jar ${GERRIT_SITE}/plugins/importer.jar
  [ -z "${AMQP_URI}" ] || su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/rabbitmq.jar ${GERRIT_SITE}/plugins/rabbitmq.jar
  [ -z "${GRAPHITE_HOST}" ] || su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/metrics-reporter-graphite.jar ${GERRIT_SITE}/plugins/metrics-reporter-graphite.jar
  [[ "${WITH_VERIFY_STATUS}" != "true" ]] || su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/verify-status.jar ${GERRIT_SITE}/plugins/verify-status.jar

  # Dynamically download plugins
  for plugin_info in ${GET_PLUGINS//,/ }; do
    plugin_name=$(echo "${plugin_info/:/ }" | awk '{print $1}')
    plugin_version=$(echo "${plugin_info/:/ }" | awk '{print $2}')
    plugin_provider=$(echo "${plugin_info/:/ }" | awk '{print $3}')

    /get-plugin.sh $plugin_name $plugin_version $plugin_provider
    su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/$plugin_name.jar ${GERRIT_SITE}/plugins/$plugin_name.jar
  done

  # Provide a way to customise this image
  echo
  for f in /docker-entrypoint-init.d/*; do
    case "$f" in
      *.sh)    echo "$0: running $f"; source "$f" ;;
      *.nohup) echo "$0: running $f"; nohup  "$f" & ;;
      *)       echo "$0: ignoring $f" ;;
    esac
    echo
  done

  # Determine serverId from All-Projects.git if not specified externally
  if [ -z "${SERVER_ID}" ]; then
    if [ -e "${GERRIT_SITE}/git/All-Projects.git" ]; then
      git clone "${GERRIT_SITE}/git/All-Projects.git" "/tmp/All-Projects"
      cd "/tmp/All-Projects"
      git ls-remote origin
      META_REF="$(git ls-remote origin | grep -e '/meta$' | tail -1 | awk '{print $2}')"
      if [ -n "${META_REF}" ]; then
        git fetch origin "${META_REF}"
        git checkout FETCH_HEAD
        SERVER_ID="$(jq -r '.comments[0].serverId' $(ls -1))"
      fi
    fi
  fi

  # Customize rabbitmq.config

  # Section amqp
  [ -z "${AMQP_URI}" ] || set_rabbitmq_config amqp.uri "${AMQP_URI}"
  [ -z "${AMQP_USERNAME}" ] || set_rabbitmq_config amqp.username "${AMQP_USERNAME}"
  [ -z "${AMQP_PASSWORD}" ] || set_rabbitmq_config amqp.password "${AMQP_PASSWORD}"

  # Section exchange
  [ -z "${EXCHANGE_NAME}" ] || set_rabbitmq_config exchange.name "${EXCHANGE_NAME}"

  # Section message
  [ -z "${MESSAGE_DELIVERYMODE}" ] || set_rabbitmq_config message.deliveryMode "${MESSAGE_DELIVERYMODE}"
  [ -z "${MESSAGE_PRIORITY}" ] || set_rabbitmq_config message.priority "${MESSAGE_PRIORITY}"
  [ -z "${MESSAGE_ROUTINGKEY}" ] || set_rabbitmq_config message.routingKey "${MESSAGE_ROUTINGKEY}"

  # Customize gerrit.config

  # Section gerrit
  [ -z "${WEBURL}" ] || set_gerrit_config gerrit.canonicalWebUrl "${WEBURL}"
  [ -z "${GITHTTPURL}" ] || set_gerrit_config gerrit.gitHttpUrl "${GITHTTPURL}"
  [ -z "${UI}" ] || set_gerrit_config gerrit.ui "${UI}"
  [ -z "${SERVER_ID}" ] || set_gerrit_config gerrit.serverId "${SERVER_ID}"

  # Section sshd
  [ -z "${LISTEN_ADDR}" ]         || set_gerrit_config sshd.listenAddress "${LISTEN_ADDR}"
  [ -z "${SSHD_THREADS}" ]        || set_gerrit_config sshd.threads "${SSHD_THREADS}"
  [ -z "${SSHD_BATCHTHREADS}" ]   || set_gerrit_config sshd.batchThreads "${SSHD_BATCHTHREADS}"
  [ -z "${SSHD_STREAMTHREADS}" ]  || set_gerrit_config sshd.streamThreads "${SSHD_STREAMTHREADS}"
  [ -z "${SSHD_IDLETIMEOUT}" ]    || set_gerrit_config sshd.idleTimeout "${SSHD_IDLETIMEOUT}"
  [ -z "${SSHD_WAITTIMEOUT}" ]    || set_gerrit_config sshd.waitTimeout "${SSHD_WAITTIMEOUT}"

  # Section transfer
  [ -z "${TRANSFER_TIMEOUT}" ] || set_gerrit_config transfer.timeout "${TRANSFER_TIMEOUT}"

  # Section database
  if [ "${DATABASE_TYPE}" = 'postgresql' ]; then
    set_gerrit_config database.type "${DATABASE_TYPE}"
    [ -z "${DB_PORT_5432_TCP_ADDR}" ]    || set_gerrit_config database.hostname "${DB_PORT_5432_TCP_ADDR}"
    [ -z "${DB_PORT_5432_TCP_PORT}" ]    || set_gerrit_config database.port "${DB_PORT_5432_TCP_PORT}"
    [ -z "${DB_ENV_POSTGRES_DB}" ]       || set_gerrit_config database.database "${DB_ENV_POSTGRES_DB}"
    [ -z "${DB_ENV_POSTGRES_USER}" ]     || set_gerrit_config database.username "${DB_ENV_POSTGRES_USER}"
    [ -z "${DB_ENV_POSTGRES_PASSWORD}" ] || set_secure_config database.password "${DB_ENV_POSTGRES_PASSWORD}"
  fi

  # Section database
  if [ "${DATABASE_TYPE}" = 'mysql' ]; then
    set_gerrit_config database.type "${DATABASE_TYPE}"
    [ -z "${DB_PORT_3306_TCP_ADDR}" ] || set_gerrit_config database.hostname "${DB_PORT_3306_TCP_ADDR}"
    [ -z "${DB_PORT_3306_TCP_PORT}" ] || set_gerrit_config database.port "${DB_PORT_3306_TCP_PORT}"
    [ -z "${DB_ENV_MYSQL_DB}" ]       || set_gerrit_config database.database "${DB_ENV_MYSQL_DB}"
    [ -z "${DB_ENV_MYSQL_USER}" ]     || set_gerrit_config database.username "${DB_ENV_MYSQL_USER}"
    [ -z "${DB_ENV_MYSQL_PASSWORD}" ] || set_secure_config database.password "${DB_ENV_MYSQL_PASSWORD}"
  fi

  # Section auth
  [ -z "${AUTH_TYPE}" ]                    || set_gerrit_config auth.type "${AUTH_TYPE}"
  [ -z "${AUTH_HTTP_HEADER}" ]             || set_gerrit_config auth.httpHeader "${AUTH_HTTP_HEADER}"
  [ -z "${AUTH_EMAIL_FORMAT}" ]            || set_gerrit_config auth.emailFormat "${AUTH_EMAIL_FORMAT}"
  [ -z "${AUTH_USER_NAME_TO_LOWER_CASE}" ] || set_gerrit_config auth.userNameToLowerCase "${AUTH_USER_NAME_TO_LOWER_CASE}"
  if [ -z "${AUTH_GIT_BASIC_AUTH_POLICY}" ]; then
    case "${AUTH_TYPE}" in
      LDAP|LDAP_BIND)
        set_gerrit_config auth.gitBasicAuthPolicy "LDAP"
        ;;
      HTTP|HTTP_LDAP)
        set_gerrit_config auth.gitBasicAuthPolicy "${AUTH_TYPE}"
        ;;
      *)
    esac
  else
    set_gerrit_config auth.gitBasicAuthPolicy "${AUTH_GIT_BASIC_AUTH_POLICY}"
  fi

  # Set OAuth provider
  if [ "${AUTH_TYPE}" = 'OAUTH' ]; then
    [ -z "${AUTH_GIT_OAUTH_PROVIDER}" ] || set_gerrit_config auth.gitOAuthProvider "${AUTH_GIT_OAUTH_PROVIDER}"
  fi

  if [ -z "${AUTH_TYPE}" ] || [ "${AUTH_TYPE}" = 'OpenID' ] || [ "${AUTH_TYPE}" = 'OpenID_SSO' ]; then
    [ -z "${AUTH_ALLOWED_OPENID}" ] || set_gerrit_config auth.allowedOpenID "${AUTH_ALLOWED_OPENID}"
    [ -z "${AUTH_TRUSTED_OPENID}" ] || set_gerrit_config auth.trustedOpenID "${AUTH_TRUSTED_OPENID}"
    [ -z "${AUTH_OPENID_DOMAIN}" ]  || set_gerrit_config auth.openIdDomain "${AUTH_OPENID_DOMAIN}"
  fi

  # Section ldap
  if [ "${AUTH_TYPE}" = 'LDAP' ] || [ "${AUTH_TYPE}" = 'LDAP_BIND' ] || [ "${AUTH_TYPE}" = 'HTTP_LDAP' ]; then
    [ -z "${LDAP_SERVER}" ]                   || set_gerrit_config ldap.server "${LDAP_SERVER}"
    [ -z "${LDAP_SSLVERIFY}" ]                || set_gerrit_config ldap.sslVerify "${LDAP_SSLVERIFY}"
    [ -z "${LDAP_GROUPSVISIBLETOALL}" ]       || set_gerrit_config ldap.groupsVisibleToAll "${LDAP_GROUPSVISIBLETOALL}"
    [ -z "${LDAP_USERNAME}" ]                 || set_gerrit_config ldap.username "${LDAP_USERNAME}"
    [ -z "${LDAP_PASSWORD}" ]                 || set_secure_config ldap.password "${LDAP_PASSWORD}"
    [ -z "${LDAP_REFERRAL}" ]                 || set_gerrit_config ldap.referral "${LDAP_REFERRAL}"
    [ -z "${LDAP_READTIMEOUT}" ]              || set_gerrit_config ldap.readTimeout "${LDAP_READTIMEOUT}"
    [ -z "${LDAP_ACCOUNTBASE}" ]              || set_gerrit_config ldap.accountBase "${LDAP_ACCOUNTBASE}"
    [ -z "${LDAP_ACCOUNTSCOPE}" ]             || set_gerrit_config ldap.accountScope "${LDAP_ACCOUNTSCOPE}"
    [ -z "${LDAP_ACCOUNTPATTERN}" ]           || set_gerrit_config ldap.accountPattern "${LDAP_ACCOUNTPATTERN}"
    [ -z "${LDAP_ACCOUNTFULLNAME}" ]          || set_gerrit_config ldap.accountFullName "${LDAP_ACCOUNTFULLNAME}"
    [ -z "${LDAP_ACCOUNTEMAILADDRESS}" ]      || set_gerrit_config ldap.accountEmailAddress "${LDAP_ACCOUNTEMAILADDRESS}"
    [ -z "${LDAP_ACCOUNTSSHUSERNAME}" ]       || set_gerrit_config ldap.accountSshUserName "${LDAP_ACCOUNTSSHUSERNAME}"
    [ -z "${LDAP_ACCOUNTMEMBERFIELD}" ]       || set_gerrit_config ldap.accountMemberField "${LDAP_ACCOUNTMEMBERFIELD}"
    [ -z "${LDAP_FETCHMEMBEROFEAGERLY}" ]     || set_gerrit_config ldap.fetchMemberOfEagerly "${LDAP_FETCHMEMBEROFEAGERLY}"
    [ -z "${LDAP_GROUPBASE}" ]                || set_gerrit_config ldap.groupBase "${LDAP_GROUPBASE}"
    [ -z "${LDAP_GROUPSCOPE}" ]               || set_gerrit_config ldap.groupScope "${LDAP_GROUPSCOPE}"
    [ -z "${LDAP_GROUPPATTERN}" ]             || set_gerrit_config ldap.groupPattern "${LDAP_GROUPPATTERN}"
    [ -z "${LDAP_GROUPMEMBERPATTERN}" ]       || set_gerrit_config ldap.groupMemberPattern "${LDAP_GROUPMEMBERPATTERN}"
    [ -z "${LDAP_GROUPNAME}" ]                || set_gerrit_config ldap.groupName "${LDAP_GROUPNAME}"
    [ -z "${LDAP_LOCALUSERNAMETOLOWERCASE}" ] || set_gerrit_config ldap.localUsernameToLowerCase "${LDAP_LOCALUSERNAMETOLOWERCASE}"
    [ -z "${LDAP_AUTHENTICATION}" ]           || set_gerrit_config ldap.authentication "${LDAP_AUTHENTICATION}"
    [ -z "${LDAP_USECONNECTIONPOOLING}" ]     || set_gerrit_config ldap.useConnectionPooling "${LDAP_USECONNECTIONPOOLING}"
    [ -z "${LDAP_CONNECTTIMEOUT}" ]           || set_gerrit_config ldap.connectTimeout "${LDAP_CONNECTTIMEOUT}"
  fi

  # Section OAUTH general
  if [ "${AUTH_TYPE}" = 'OAUTH' ]  ; then
    su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/gerrit-oauth-provider.jar ${GERRIT_SITE}/plugins/gerrit-oauth-provider.jar

    [ -z "${OAUTH_ALLOW_EDIT_FULL_NAME}" ]     || set_gerrit_config oauth.allowEditFullName "${OAUTH_ALLOW_EDIT_FULL_NAME}"
    [ -z "${OAUTH_ALLOW_REGISTER_NEW_EMAIL}" ] || set_gerrit_config oauth.allowRegisterNewEmail "${OAUTH_ALLOW_REGISTER_NEW_EMAIL}"

    # Google
    [ -z "${OAUTH_GOOGLE_RESTRICT_DOMAIN}" ]       || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.domain "${OAUTH_GOOGLE_RESTRICT_DOMAIN}"
    [ -z "${OAUTH_GOOGLE_CLIENT_ID}" ]             || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.client-id "${OAUTH_GOOGLE_CLIENT_ID}"
    [ -z "${OAUTH_GOOGLE_CLIENT_SECRET}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.client-secret "${OAUTH_GOOGLE_CLIENT_SECRET}"
    [ -z "${OAUTH_GOOGLE_LINK_OPENID}" ]           || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.link-to-existing-openid-accounts "${OAUTH_GOOGLE_LINK_OPENID}"
    [ -z "${OAUTH_GOOGLE_USE_EMAIL_AS_USERNAME}" ] || set_gerrit_config plugin.gerrit-oauth-provider-google-oauth.use-email-as-username "${OAUTH_GOOGLE_USE_EMAIL_AS_USERNAME}"

    # Github
    [ -z "${OAUTH_GITHUB_CLIENT_ID}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-github-oauth.client-id "${OAUTH_GITHUB_CLIENT_ID}"
    [ -z "${OAUTH_GITHUB_CLIENT_SECRET}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-github-oauth.client-secret "${OAUTH_GITHUB_CLIENT_SECRET}"

    # GitLab
    [ -z "${OAUTH_GITLAB_ROOT_URL}" ]          || set_gerrit_config plugin.gerrit-oauth-provider-gitlab-oauth.root-url "${OAUTH_GITLAB_ROOT_URL}"
    [ -z "${OAUTH_GITLAB_CLIENT_ID}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-gitlab-oauth.client-id "${OAUTH_GITLAB_CLIENT_ID}"
    [ -z "${OAUTH_GITLAB_CLIENT_SECRET}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-gitlab-oauth.client-secret "${OAUTH_GITLAB_CLIENT_SECRET}"

    # Bitbucket
    [ -z "${OAUTH_BITBUCKET_CLIENT_ID}" ]          || set_gerrit_config plugin.gerrit-oauth-provider-bitbucket-oauth.client-id "${OAUTH_BITBUCKET_CLIENT_ID}"
    [ -z "${OAUTH_BITBUCKET_CLIENT_SECRET}" ]      || set_gerrit_config plugin.gerrit-oauth-provider-bitbucket-oauth.client-secret "${OAUTH_BITBUCKET_CLIENT_SECRET}"
    [ -z "${OAUTH_BITBUCKET_FIX_LEGACY_USER_ID}" ] || set_gerrit_config plugin.gerrit-oauth-provider-bitbucket-oauth.fix-legacy-user-id "${OAUTH_BITBUCKET_FIX_LEGACY_USER_ID}"

    # Office365
    [ -z "${OAUTH_OFFICE365_USE_EMAIL_AS_USERNAME}" ] || set_gerrit_config plugin.gerrit-oauth-provider-office365-oauth.use-email-as-username "${OAUTH_OFFICE365_USE_EMAIL_AS_USERNAME}"
    [ -z "${OAUTH_OFFICE365_CLIENT_ID}" ]             || set_gerrit_config plugin.gerrit-oauth-provider-office365-oauth.client-id "${OAUTH_OFFICE365_CLIENT_ID}"
    [ -z "${OAUTH_OFFICE365_CLIENT_SECRET}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-office365-oauth.client-secret "${OAUTH_OFFICE365_CLIENT_SECRET}"
  fi

  # Section container
  [ -z "${JAVA_HEAPLIMIT}" ] || set_gerrit_config container.heapLimit "${JAVA_HEAPLIMIT}"
  [ -z "${JAVA_OPTIONS}" ]   || set_gerrit_config container.javaOptions "${JAVA_OPTIONS}"
  [ -z "${JAVA_SLAVE}" ]     || set_gerrit_config container.slave "${JAVA_SLAVE}"

  # Section sendemail
  if [ -z "${SMTP_SERVER}" ]; then
    set_gerrit_config sendemail.enable false
  else
    set_gerrit_config sendemail.enable true
    set_gerrit_config sendemail.smtpServer "${SMTP_SERVER}"
    if [ "smtp.gmail.com" = "${SMTP_SERVER}" ]; then
      echo "gmail detected, using default port and encryption"
      set_gerrit_config sendemail.smtpServerPort 587
      set_gerrit_config sendemail.smtpEncryption tls
    fi
    [ -z "${SMTP_SERVER_PORT}" ] || set_gerrit_config sendemail.smtpServerPort "${SMTP_SERVER_PORT}"
    [ -z "${SMTP_USER}" ]        || set_gerrit_config sendemail.smtpUser "${SMTP_USER}"
    [ -z "${SMTP_PASS}" ]        || set_secure_config sendemail.smtpPass "${SMTP_PASS}"
    [ -z "${SMTP_ENCRYPTION}" ]      || set_gerrit_config sendemail.smtpEncryption "${SMTP_ENCRYPTION}"
    [ -z "${SMTP_SSL_VERIFY}" ]      || set_gerrit_config sendemail.sslVerify "${SMTP_SSL_VERIFY}"
    [ -z "${SMTP_CONNECT_TIMEOUT}" ] || set_gerrit_config sendemail.connectTimeout "${SMTP_CONNECT_TIMEOUT}"
    [ -z "${SMTP_FROM}" ]            || set_gerrit_config sendemail.from "${SMTP_FROM}"
    [ -z "${SMTP_ALLOWED_DOMAIN}" ]  || set_gerrit_config sendemail.allowedDomain "${SMTP_ALLOWED_DOMAIN}"
  fi
  [ -z "${SMTP_ENABLE}" ] || set_gerrit_config sendemail.enable "${SMTP_ENABLE}"

  # Section user
  [ -z "${USER_NAME}" ]             || set_gerrit_config user.name "${USER_NAME}"
  [ -z "${USER_EMAIL}" ]            || set_gerrit_config user.email "${USER_EMAIL}"
  [ -z "${USER_ANONYMOUS_COWARD}" ] || set_gerrit_config user.anonymousCoward "${USER_ANONYMOUS_COWARD}"

  # Section plugins
  set_gerrit_config plugins.allowRemoteAdmin true

  # Section plugin events-log
  set_gerrit_config plugin.events-log.storeUrl ${GERRIT_EVENTS_LOG_STOREURL:-"jdbc:h2:${GERRIT_SITE}/db/ChangeEvents"}

  # Section plugin metrics-reporter-graphite
  [ -z "${GRAPHITE_HOST}" ]   || set_graphite_config graphite.host "${GRAPHITE_HOST}"
  [ -z "${GRAPHITE_PORT}" ]   || set_graphite_config graphite.port "${GRAPHITE_PORT}"
  [ -z "${GRAPHITE_PREFIX}" ] || set_graphite_config graphite.prefix "${GRAPHITE_PREFIX}"
  [ -z "${GRAPHITE_RATE}" ]   || set_graphite_config graphite.rate "${GRAPHITE_RATE}"

  # Section noteDb
  set_notedb_config noteDb.changes.autoMigrate false
  set_notedb_config noteDb.changes.trial false
  set_notedb_config noteDb.changes.write true
  set_notedb_config noteDb.changes.read true
  set_notedb_config noteDb.changes.sequence true
  set_notedb_config noteDb.changes.primaryStorage "note db"
  set_notedb_config noteDb.changes.disableReviewDb true

  # Section LFS
  if [[ "${LFS_ENABLE}" == "true" ]]; then
      echo "Enabling LFS"

      set_gerrit_config lfs.plugin "lfs"

      [ -z "${LFS_STORAGE}" ] || set_lfs_config storage.backend "${LFS_STORAGE}"

      if [[ "${LFS_STORAGE}" == "fs" ]]; then
          [ -z "${LFS_FS_DIRECTORY}" ]         || set_lfs_config fs.directory "${LFS_FS_DIRECTORY}"
          [ -z "${LFS_FS_EXPIRATIONSECONDS}" ] || set_lfs_config fs.expirationSeconds "${LFS_FS_EXPIRATIONSECONDS}"
      elif [[ "${LFS_STORAGE}" == "s3" ]]; then
          [ -z "${LFS_S3_REGION}" ]            || set_lfs_config s3.region "${LFS_S3_REGION}"
          [ -z "${LFS_S3_BUCKET}" ]            || set_lfs_config s3.bucket "${LFS_S3_BUCKET}"
          [ -z "${LFS_S3_STORAGECLASS}" ]      || set_lfs_config s3.storageClass "${LFS_S3_STORAGECLASS}"
          [ -z "${LFS_S3_EXPIRATIONSECONDS}" ] || set_lfs_config s3.expirationSeconds "${LFS_S3_EXPIRATIONSECONDS}"
          [ -z "${LFS_S3_DISABLESSLVERIFY}" ]  || set_lfs_config s3.disableSslVerify "${LFS_S3_DISABLESSLVERIFY}"
          [ -z "${LFS_S3_ACCESSKEY}" ]         || set_lfs_config s3.accessKey "${LFS_S3_ACCESSKEY}"
          [ -z "${LFS_S3_SECRETKEY}" ]         || set_lfs_config s3.secretKey "${LFS_S3_SECRETKEY}"
      else
          echo "LFS: Unsupported storage backend '${LFS_STORAGE}'"
          exit 1
      fi
  fi

  # Section httpd
  [ -z "${HTTPD_LISTENURL}" ]     || set_gerrit_config httpd.listenUrl "${HTTPD_LISTENURL}"
  [ -z "${HTTPD_MAXQUEUED}" ]     || set_gerrit_config httpd.maxQueued "${HTTPD_MAXQUEUED}"
  [ -z "${HTTPD_IDLETIMEOUT}" ]   || set_gerrit_config httpd.idleTimeout "${HTTPD_IDLETIMEOUT}"

  # Section gitweb
  case "$GITWEB_TYPE" in
     "gitiles") su-exec $GERRIT_USER cp -f $GERRIT_HOME/gitiles.jar $GERRIT_SITE/plugins/gitiles.jar ;;
     "") # Gitweb by default
        set_gerrit_config gitweb.cgi "/usr/share/gitweb/gitweb.cgi"
        export GITWEB_TYPE=gitweb
     ;;
  esac
  set_gerrit_config gitweb.type "$GITWEB_TYPE"

  # Section theme (only valid for GWT UI)
  [ -z "${THEME_BACKGROUNDCOLOR}" ]             || set_gerrit_config theme.backgroundColor "${THEME_BACKGROUNDCOLOR}"
  [ -z "${THEME_TOPMENUCOLOR}" ]                || set_gerrit_config theme.topMenuColor "${THEME_TOPMENUCOLOR}"
  [ -z "${THEME_TEXTCOLOR}" ]                   || set_gerrit_config theme.textColor "${THEME_TEXTCOLOR}"
  [ -z "${THEME_TRIMCOLOR}" ]                   || set_gerrit_config theme.trimColor "${THEME_TRIMCOLOR}"
  [ -z "${THEME_SELECTIONCOLOR}" ]              || set_gerrit_config theme.selectionColor "${THEME_SELECTIONCOLOR}"
  [ -z "${THEME_CHANGETABLEOUTDATEDCOLOR}" ]    || set_gerrit_config theme.changeTableOutdatedColor "${THEME_CHANGETABLEOUTDATEDCOLOR}"
  [ -z "${THEME_TABLEODDROWCOLOR}" ]            || set_gerrit_config theme.tableOddRowColor "${THEME_TABLEODDROWCOLOR}"
  [ -z "${THEME_TABLEEVENROWCOLOR}" ]           || set_gerrit_config theme.tableEvenRowColor "${THEME_TABLEEVENROWCOLOR}"

  # Additional configuration in /etc/gerrit/*.config.d/

  for cfg in $(find /etc/gerrit/ -maxdepth 1 -type d -name "*.config.d"); do
      for file in $(find "${cfg}" -name "*.config"); do
          cat $file >> "${GERRIT_SITE}/etc/$(basename ${cfg/.d})"
      done
  done

  # Private key
  for key in ssh_host_key ssh_host_rsa_key ssh_host_dsa_key ssh_host_ecdsa_key ssh_host_ecdsa_384_key ssh_host_ecdsa_521_key ssh_host_ed25519_key; do
    if [ -e "${GERRIT_HOME}/${key}" ]; then
      cp "${GERRIT_HOME}/${key}" "${GERRIT_SITE}/etc/"
      chown ${GERRIT_USER} "${GERRIT_SITE}/etc/${key}"

      if [ -e "${GERRIT_HOME}/${key}.pub" ]; then
        cp "${GERRIT_HOME}/${key}.pub" "${GERRIT_SITE}/etc/"
        chown ${GERRIT_USER} "${GERRIT_SITE}/etc/${key}.pub"
      fi

      if [ -e "${GERRIT_SITE}/etc/ssh_host_key" ] && [[ "$key" != "ssh_host_key" ]]; then
        rm -rf ${GERRIT_SITE}/etc/ssh_host_key
      fi
    fi
  done

  case "${DATABASE_TYPE}" in
    postgresql) wait_for_database ${DB_PORT_5432_TCP_ADDR} ${DB_PORT_5432_TCP_PORT} ;;
    mysql)      wait_for_database ${DB_PORT_3306_TCP_ADDR} ${DB_PORT_3306_TCP_PORT} ;;
    *)          ;;
  esac

  if [[ "${JAVA_SLAVE}" != "true" ]]; then

    # Determine if reindex is necessary
    NEED_REINDEX=0
    if [ -z "$(ls -A $GERRIT_SITE/cache)" ]; then
      echo "Empty secondary index, reindexing..."
      NEED_REINDEX=1
    fi

    echo "Upgrading gerrit..."
    su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --batch -d "${GERRIT_SITE}" ${GERRIT_INIT_ARGS}
    if [ $? -eq 0 ]; then
      GERRIT_VERSIONFILE="${GERRIT_SITE}/gerrit_version"

      if [ -n "${IGNORE_VERSIONCHECK}" ]; then
        echo "Do not perform a version check"
      else
        # Check whether its a good idea to do a full upgrade
        echo "Checking version file ${GERRIT_VERSIONFILE}"
        if [ -f "${GERRIT_VERSIONFILE}" ]; then
          OLD_GERRIT_VER="V$(cat ${GERRIT_VERSIONFILE})"
          GERRIT_VER="V${GERRIT_VERSION}"
          echo " have old gerrit version ${OLD_GERRIT_VER}"
          if [ "${OLD_GERRIT_VER}" == "${GERRIT_VER}" ]; then
            echo " same gerrit version, no upgrade necessary ${OLD_GERRIT_VER} == ${GERRIT_VER}"
          else
            echo " gerrit version mismatch #${OLD_GERRIT_VER}# != #${GERRIT_VER}#"
            NEED_REINDEX=1
          fi
        else
          echo " gerrit version file does not exist, upgrade necessary"
          NEED_REINDEX=1
        fi
      fi

      if [ ${NEED_REINDEX} -eq 1 ]; then
        echo "Reindexing..."
        su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" reindex --verbose -d "${GERRIT_SITE}"
        if [ $? -eq 0 ]; then
          echo "Upgrading is OK. Writing versionfile ${GERRIT_VERSIONFILE}"
          su-exec ${GERRIT_USER} touch "${GERRIT_VERSIONFILE}"
          su-exec ${GERRIT_USER} echo "${GERRIT_VERSION}" > "${GERRIT_VERSIONFILE}"
          echo "${GERRIT_VERSIONFILE} written."
        else
          echo "Upgrading fail!"
        fi
        NEED_REINDEX=0
      fi
    else
      echo "Something wrong..."
      cat "${GERRIT_SITE}/logs/error_log"

      echo "Emptying cache ..."
      rm -rf $GERRIT_SITE/cache
    fi

    if [ ${NEED_REINDEX} -eq 1 ]; then
      echo "Reindexing ..."
      su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" reindex --verbose -d "${GERRIT_SITE}"
    fi
  fi
fi

exec "$@"

