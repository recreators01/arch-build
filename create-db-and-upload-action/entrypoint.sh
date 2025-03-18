#!/bin/bash
set -e

init_path=$PWD
mkdir upload_packages
find $local_path -type f -name "*.tar.zst" -exec cp {} ./upload_packages/ \;

cd upload_packages || exit 1

echo "::group::Adding packages to the repo"

repo-add "./${repo_name:?}.db.tar.gz" ./*.tar.zst

echo "::endgroup::"

