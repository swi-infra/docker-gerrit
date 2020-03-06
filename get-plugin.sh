#!/bin/bash

PLUGIN=$1
VERSION=$2
PROVIDER=${3:-"gerritforge"}

if [ -z "$PLUGIN" ]; then
    echo "Plugin name not provided"
    exit 1
fi

get_plugin() {
    local version=$1
    local artifact_type=$2

    local ret=1
    case $PROVIDER in
        release)
            curl -fSsL \
                ${JENKINS_URL}/${PLUGIN}.jar \
                -o ${GERRIT_HOME}/${PLUGIN}.jar
            ret=$?
            ;;
        gerritforge)
            GERRITFORGE_URL=https://gerrit-ci.gerritforge.com
            GERRITFORGE_BUILD=${3:-"lastSuccessfulBuild"}
            GERRITFORGE_ARTIFACT_DIR="${GERRITFORGE_BUILD}/artifact/bazel-${artifact_type}/plugins"
            curl -fSsL \
                ${GERRITFORGE_URL}/job/plugin-${PLUGIN}-bazel-${version}/${GERRITFORGE_ARTIFACT_DIR}/${PLUGIN}/${PLUGIN}.jar \
                -o ${GERRIT_HOME}/${PLUGIN}.jar
            ret=$?
            ;;
        davido)
            curl -fSsL \
                https://github.com/davido/${PLUGIN}/releases/download/${version}/${PLUGIN}.jar \
                -o ${GERRIT_HOME}/${PLUGIN}.jar
            ret=$?
            ;;
        *)
            echo "Unknown provider $PROVIDER"
            exit 1
            ;;
    esac

    if [ $ret -eq 0 ]; then
        exit 0
    fi

    return $ret
}

if [ -n "$VERSION" ]; then
    echo "[${PLUGIN}] Getting $VERSION"
    get_plugin "$VERSION"
else
    for artifact_type in bin genfiles; do
        for version in $(echo "${PLUGIN_VERSIONS}" | tr ',' ' '); do
            echo "[${PLUGIN}] Trying $version $artifact_type"
            get_plugin "$version" "$artifact_type" "$4"
        done
    done
fi

exit 1
