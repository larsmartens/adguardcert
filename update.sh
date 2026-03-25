#!/bin/bash

case version in
*-*)
    ;;
*)
    git checkout -B master origin/master
    ./generate_changelog.sh
    cat module/module.prop | (
    IFS="="
    while read k v; do
        read $k <<< "$v"
    done
    cat << EOF > update.json
{
  "version": "$version",
  "versionCode": $versionCode,
  "zipUrl": "https://github.com/larsmartens/adguardcert/releases/download/$version/adguardcert-$version.zip",
  "changelog": "https://raw.githubusercontent.com/larsmartens/adguardcert/master/changelog.md"
}
EOF
    )
    git add update.json changelog.md
    git commit -m "skipci: Update update.json" || true
    ;;
esac
