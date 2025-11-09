#! /bin/bash

# Iterate over all the .patch files for the current project
for patch_file in certora/patches/[A-Z]*.patch; do
    git apply "$patch_file"
done

# Apply patch for libraries
cd lib/openzeppelin-contracts
git apply ../../certora/patches/lib_openzeppelin-contracts_MessageHashUtils.patch
cd ../../
