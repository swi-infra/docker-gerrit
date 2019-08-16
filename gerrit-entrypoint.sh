#!/usr/bin/env bash
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

set_password_env() {
  local env_name="$1"
  local cfg="$2"

  set +x
  local value
  local env_name_file="${env_name}_FILE"
  if [ -n "${!env_name}" ]; then
    value="${!env_name}"
  elif [ -n "${!env_name_file}" ]; then
    if [ ! -e "${!env_name_file}" ]; then
      echo "File '${!env_name_file} doesn't exist"
      exit 1
    fi

    value="$(cat "${!env_name_file}")"
  fi

  if [ -n "$value" ]; then
    echo "Setting password for ${cfg}"
    if [[ "$cfg" == "rabbitmq"* ]]; then
      set_rabbitmq_config "${cfg}" "${value}"
    else
      set_secure_config "${cfg}" "${value}"
    fi
  fi

  set -x
}

FIRST_RUN=false

if [ -n "${JAVA_HEAPLIMIT}" ]; then
  JAVA_MEM_OPTIONS="-Xmx${JAVA_HEAPLIMIT}"
fi

if [ "$1" = "/gerrit-start.sh" ]; then
  # If you're mounting ${GERRIT_SITE} to your host, you this will default to root.
  # This obviously ensures the permissions are set correctly for when gerrit starts.
  find "${GERRIT_SITE}/" ! -user `id -u ${GERRIT_USER}` -exec chown ${GERRIT_USER} {} \;

  # Initialize Gerrit if ${GERRIT_SITE}/etc doesn't exist.
  SHOULD_INIT=false
  if [ ! -e "${GERRIT_SITE}/etc" ] || [ ! -e "${GERRIT_SITE}/bin/gerrit.sh" ]; then
    SHOULD_INIT=true
    echo "First time initialize gerrit..."
    FIRST_RUN=true
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
  su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/events-log.jar ${GERRIT_SITE}/plugins/events-log.jar
  [ -z "${AMQP_URI}" ] || su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/rabbitmq.jar ${GERRIT_SITE}/plugins/rabbitmq.jar
  [ -z "${GRAPHITE_HOST}" ] || su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/metrics-reporter-graphite.jar ${GERRIT_SITE}/plugins/metrics-reporter-graphite.jar

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
  set_password_env AMQP_PASSWORD amqp.password

  # Section exchange
  [ -z "${EXCHANGE_NAME}" ] || set_rabbitmq_config exchange.name "${EXCHANGE_NAME}"

  # Section download
  if [ -n "${DOWNLOAD_SCHEMES}" ]; then
    set_gerrit_config --unset-all download.scheme || true
    for s in ${DOWNLOAD_SCHEMES}; do
      set_gerrit_config --add download.scheme ${s}
    done
  fi
  if [ -n "${DOWNLOAD_COMMANDS}" ]; then
    set_gerrit_config --unset-all download.command || true
    for c in ${DOWNLOAD_COMMANDS}; do
      set_gerrit_config --add download.command ${c}
    done
  fi

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

  # Section cache
  if [[ "${JAVA_SLAVE}" == "true" ]]; then
      CACHE_SSHKEYS_MAXAGE=${CACHE_SSHKEYS_MAXAGE:-60s}
      echo "Setting cache 'sshkeys' maxAge to ${CACHE_SSHKEYS_MAXAGE}"
  fi
  [ -z "${CACHE_SSHKEYS_MAXAGE}" ]       || set_gerrit_config cache.sshkeys.maxAge "${CACHE_SSHKEYS_MAXAGE}"

  # Section core
  [ -z "${CORE_PACKEDGITLIMIT}" ]        || set_gerrit_config core.packedGitLimit "${CORE_PACKEDGITLIMIT}"
  [ -z "${CORE_PACKEDGITOPENFILES}" ]    || set_gerrit_config core.packedGitOpenFiles "${CORE_PACKEDGITOPENFILES}"
  [ -z "${CORE_PACKEDGITWINDOWSIZE}" ]   || set_gerrit_config core.packedGitWindowSize "${CORE_PACKEDGITWINDOWSIZE}"

  # Section sshd
  [ -z "${LISTEN_ADDR}" ]                || set_gerrit_config sshd.listenAddress "${LISTEN_ADDR}"
  [ -z "${SSHD_ADVERTISE_ADDR}" ]        || set_gerrit_config sshd.advertisedAddress "${SSHD_ADVERTISE_ADDR}"
  [ -z "${SSHD_ENABLE_COMPRESSION}" ]    || set_gerrit_config sshd.enableCompression "${SSHD_ENABLE_COMPRESSION}"
  [ -z "${SSHD_THREADS}" ]               || set_gerrit_config sshd.threads "${SSHD_THREADS}"
  [ -z "${SSHD_BATCHTHREADS}" ]          || set_gerrit_config sshd.batchThreads "${SSHD_BATCHTHREADS}"
  [ -z "${SSHD_STREAMTHREADS}" ]         || set_gerrit_config sshd.streamThreads "${SSHD_STREAMTHREADS}"
  [ -z "${SSHD_IDLETIMEOUT}" ]           || set_gerrit_config sshd.idleTimeout "${SSHD_IDLETIMEOUT}"
  [ -z "${SSHD_WAITTIMEOUT}" ]           || set_gerrit_config sshd.waitTimeout "${SSHD_WAITTIMEOUT}"
  [ -z "${SSHD_MAXCONNECTIONSPERUSER}" ] || set_gerrit_config sshd.maxConnectionsPerUser "${SSHD_MAXCONNECTIONSPERUSER}"
  [ -z "${SSHD_COMMANDSTARTTHREADS}" ]   || set_gerrit_config sshd.commandStartThreads "${SSHD_COMMANDSTARTTHREADS}"

  # Section transfer
  [ -z "${TRANSFER_TIMEOUT}" ] || set_gerrit_config transfer.timeout "${TRANSFER_TIMEOUT}"

  # Section database
  # docker --link is deprecated. All DB_* environment variables will be replaced by DATABASE_* below.
  # All kinds of database.type are supported.
  [ -z "${DATABASE_TYPE}" ]     || set_gerrit_config database.type     "${DATABASE_TYPE}"
  [ -z "${DATABASE_HOSTNAME}" ] || set_gerrit_config database.hostname "${DATABASE_HOSTNAME}"
  [ -z "${DATABASE_PORT}" ]     || set_gerrit_config database.port     "${DATABASE_PORT}"
  [ -z "${DATABASE_DATABASE}" ] || set_gerrit_config database.database "${DATABASE_DATABASE}"
  [ -z "${DATABASE_USERNAME}" ] || set_gerrit_config database.username "${DATABASE_USERNAME}"
  set_password_env DATABASE_PASSWORD database.password
  # JDBC URL
  [ -z "${DATABASE_URL}" ] || set_gerrit_config database.url "${DATABASE_URL}"
  # Other database options
  [ -z "${DATABASE_CONNECTION_POOL}" ] || set_secure_config database.connectionPool "${DATABASE_CONNECTION_POOL}"
  [ -z "${DATABASE_POOL_LIMIT}" ]      || set_secure_config database.poolLimit "${DATABASE_POOL_LIMIT}"
  [ -z "${DATABASE_POOL_MIN_IDLE}" ]   || set_secure_config database.poolMinIdle "${DATABASE_POOL_MIN_IDLE}"
  [ -z "${DATABASE_POOL_MAX_IDLE}" ]   || set_secure_config database.poolMaxIdle "${DATABASE_POOL_MAX_IDLE}"
  [ -z "${DATABASE_POOL_MAX_WAIT}" ]   || set_secure_config database.poolMaxWait "${DATABASE_POOL_MAX_WAIT}"

  # Section noteDB
  [ -z "${NOTEDB_ACCOUNTS_SEQUENCEBATCHSIZE}" ] || set_gerrit_config noteDB.accounts.sequenceBatchSize "${NOTEDB_ACCOUNTS_SEQUENCEBATCHSIZE}"
  [ -z "${NOTEDB_CHANGES_AUTOMIGRATE}" ]        || set_gerrit_config noteDB.changes.autoMigrate "${NOTEDB_CHANGES_AUTOMIGRATE}"

  # Section auth
  [ -z "${AUTH_TYPE}" ]                    || set_gerrit_config auth.type "${AUTH_TYPE}"
  [ -z "${AUTH_HTTP_HEADER}" ]             || set_gerrit_config auth.httpHeader "${AUTH_HTTP_HEADER}"
  [ -z "${AUTH_EMAIL_FORMAT}" ]            || set_gerrit_config auth.emailFormat "${AUTH_EMAIL_FORMAT}"
  [ -z "${AUTH_USER_NAME_TO_LOWER_CASE}" ] || set_gerrit_config auth.userNameToLowerCase "${AUTH_USER_NAME_TO_LOWER_CASE}"
  [ -z "${AUTH_REGISTER_URL}" ]            || set_gerrit_config auth.registerUrl "${AUTH_REGISTER_URL}"

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
    set_password_env LDAP_PASSWORD ldap.password
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
    su-exec ${GERRIT_USER} cp -f ${GERRIT_HOME}/oauth.jar ${GERRIT_SITE}/plugins/oauth.jar

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

    # Keycloak
    [ -z "${OAUTH_KEYCLOAK_CLIENT_ID}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-keycloak-oauth.client-id "${OAUTH_KEYCLOAK_CLIENT_ID}"
    [ -z "${OAUTH_KEYCLOAK_CLIENT_SECRET}" ] || set_gerrit_config plugin.gerrit-oauth-provider-keycloak-oauth.client-secret "${OAUTH_KEYCLOAK_CLIENT_SECRET}"
    [ -z "${OAUTH_KEYCLOAK_REALM}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-keycloak-oauth.realm "${OAUTH_KEYCLOAK_REALM}"
    [ -z "${OAUTH_KEYCLOAK_ROOT_URL}" ]      || set_gerrit_config plugin.gerrit-oauth-provider-keycloak-oauth.root-url "${OAUTH_KEYCLOAK_ROOT_URL}"

    # CAS
    [ -z "${OAUTH_CAS_ROOT_URL}" ]           || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.root-url "${OAUTH_CAS_ROOT_URL}"
    [ -z "${OAUTH_CAS_CLIENT_ID}" ]          || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.client-id "${OAUTH_CAS_CLIENT_ID}"
    [ -z "${OAUTH_CAS_CLIENT_SECRET}" ]      || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.client-secret "${OAUTH_CAS_CLIENT_SECRET}"
    [ -z "${OAUTH_CAS_LINK_OPENID}" ]        || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.link-to-existing-openid-accounts "${OAUTH_CAS_LINK_OPENID}"
    [ -z "${OAUTH_CAS_FIX_LEGACY_USER_ID}" ] || set_gerrit_config plugin.gerrit-oauth-provider-cas-oauth.fix-legacy-user-id "${OAUTH_CAS_FIX_LEGACY_USER_ID}"

    # AirVantage
    [ -z "${OAUTH_AIRVANTAGE_CLIENT_ID}" ]         || set_gerrit_config plugin.gerrit-oauth-provider-airvantage-oauth.client-id "${OAUTH_AIRVANTAGE_CLIENT_ID}"
    [ -z "${OAUTH_AIRVANTAGE_CLIENT_SECRET}" ]     || set_gerrit_config plugin.gerrit-oauth-provider-airvantage-oauth.client-secret "${OAUTH_AIRVANTAGE_CLIENT_SECRET}"
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
    postgresql) [ -z "${DB_PORT_5432_TCP_ADDR}" ]  || wait_for_database ${DB_PORT_5432_TCP_ADDR} ${DB_PORT_5432_TCP_PORT} ;;
    mysql)      [ -z "${DB_PORT_3306_TCP_ADDR}" ]  || wait_for_database ${DB_PORT_3306_TCP_ADDR} ${DB_PORT_3306_TCP_PORT} ;;
    *)          ;;
  esac
  # docker --link is deprecated. All DB_* environment variables will be replaced by DATABASE_* below.
  [ ${#DATABASE_HOSTNAME} -gt 0 ] && [ ${#DATABASE_PORT} -gt 0 ] && wait_for_database ${DATABASE_HOSTNAME} ${DATABASE_PORT}

  # Determine if reindex is necessary
  NEED_REINDEX=0
  if [ -z "$(ls -A $GERRIT_SITE/cache)" ]; then
    echo "Empty secondary index, reindexing..."
    NEED_REINDEX=1
  # MIGRATE_TO_NOTEDB_OFFLINE will override IGNORE_VERSIONCHECK
  elif [ -n "${IGNORE_VERSIONCHECK}" ] && [ -z "${MIGRATE_TO_NOTEDB_OFFLINE}" ]; then
    echo "Don't perform a version check and never do a full reindex"
    NEED_REINDEX=0
  fi

  if [[ "${JAVA_SLAVE}" != "true" ]]; then
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
      cat "${GERRIT_SITE}/logs/error_log" || true

      echo "Emptying cache ..."
      rm -rf $GERRIT_SITE/cache
    fi
  fi

  if [ -e "${GERRIT_SITE}/etc/should_init" ]; then
    SHOULD_INIT=true
    echo "Reinit gerrit..."
  fi

  if [[ "$SHOULD_INIT" == "true" ]]; then
    if ! su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" init --batch -d "${GERRIT_SITE}" --no-reindex; then
       echo "... failed"
       exit 1
    fi
  fi

  if [ ${NEED_REINDEX} -eq 1 ]; then
    if [ -n "${MIGRATE_TO_NOTEDB_OFFLINE}" ]; then
      echo "Migrating changes from ReviewDB to NoteDB..."
      su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" migrate-to-note-db -d "${GERRIT_SITE}"
    else
      echo "Reindexing..."
      su-exec ${GERRIT_USER} java ${JAVA_OPTIONS} ${JAVA_MEM_OPTIONS} -jar "${GERRIT_WAR}" reindex --verbose -d "${GERRIT_SITE}"
    fi
    if [ $? -eq 0 ]; then
      echo "Upgrading is OK. Writing versionfile ${GERRIT_VERSIONFILE}"
      su-exec ${GERRIT_USER} touch "${GERRIT_VERSIONFILE}"
      su-exec ${GERRIT_USER} echo "${GERRIT_VERSION}" > "${GERRIT_VERSIONFILE}"
      echo "${GERRIT_VERSIONFILE} written."
    else
      echo "Upgrading fail!"
    fi
  fi
fi

exec "$@"

