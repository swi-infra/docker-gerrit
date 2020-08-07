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
    local url

    if [[ "$version" == "http"* ]]; then
        url="$version"
    else
        case $PROVIDER in
            release)
                url="${JENKINS_URL}/${PLUGIN}.jar"
                ;;
            gerritforge)
                local sub_plugin="$PLUGIN"
                if [[ $PLUGIN == "owners-autoassign" ]]; then
                    sub_plugin="owners"
                fi
                GERRITFORGE_URL=https://gerrit-ci.gerritforge.com
                GERRITFORGE_BUILD=${3:-"lastSuccessfulBuild"}
                GERRITFORGE_ARTIFACT_DIR="${GERRITFORGE_BUILD}/artifact/bazel-${artifact_type}/plugins"
                url="${GERRITFORGE_URL}/job/plugin-${sub_plugin}-bazel-${version}/${GERRITFORGE_ARTIFACT_DIR}/${sub_plugin}/${PLUGIN}.jar"
                ;;
            davido)
                url="https://github.com/davido/${PLUGIN}/releases/download/${version}/${PLUGIN}.jar"
                ;;
            *)
                echo "[${PLUGIN}] Unknown provider $PROVIDER"
                exit 1
                ;;
        esac
    fi

    if [ -n "$url" ]; then
        echo "[${PLUGIN}] URL: $url"
        curl -fSsL \
            "${url}" \
            -o "${GERRIT_HOME}/${PLUGIN}.jar"
        ret=$?
    fi

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
