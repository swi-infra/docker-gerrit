#!/bin/bash -e

PLUGIN=$1
VERSION=${2:-"master"}
PROVIDER=${3:-"gerritforge"}

if [ -z "$PLUGIN" ]; then
    echo "Pluging name not provided"
    exit 1
fi

case $PROVIDER in
    release)
        curl -fSsL \
            ${JENKINS_URL}/${PLUGIN}.jar \
            -o ${GERRIT_HOME}/${PLUGIN}.jar
        ;;
    gerritforge)
        GERRITFORGE_URL=https://gerrit-ci.gerritforge.com
        GERRITFORGE_BUILD=${3:-"lastSuccessfulBuild"}
        GERRITFORGE_ARTIFACT_DIR="${GERRITFORGE_BUILD}/artifact/bazel-genfiles/plugins"
        curl -fSsL \
            ${GERRITFORGE_URL}/job/plugin-${PLUGIN}-bazel-${VERSION}/${GERRITFORGE_ARTIFACT_DIR}/${PLUGIN}/${PLUGIN}.jar \
            -o ${GERRIT_HOME}/${PLUGIN}.jar
        ;;
    davido)
        curl -fSsL \
            https://github.com/davido/${PLUGIN}/releases/download/${VERSION}/${PLUGIN}.jar \
            -o ${GERRIT_HOME}/${PLUGIN}.jar
        ;;
    *)
        echo "Unknown provider $PROVIDER"
        exit 1
        ;;
esac


