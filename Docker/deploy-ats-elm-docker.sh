#!/bin/bash

# PETSC_VER=3.11.3
# TRILINOS_VER=12-18-55a7599733-Nov11

get_tpl_version()
#
#  Find version information and provide it for production installs
#
{
   local SBFile=${AMANZI_SOURCE_DIR}/config/SuperBuild/TPLVersions.cmake
   tpl_version_major=`grep AMANZI_TPLS_VERSION_MAJOR ${SBFile} | tr -cd '[[:digit:]]'`
   tpl_version_minor=`grep AMANZI_TPLS_VERSION_MINOR ${SBFile} | tr -cd '[[:digit:]]'`
   tpl_version_patch=`grep AMANZI_TPLS_VERSION_PATCH ${SBFile} | tr -cd '[[:digit:]]'`
   echo "${tpl_version_major}.${tpl_version_minor}.${tpl_version_patch}"
}

AMANZI_BRANCH=elm_ats
AMANZI_SOURCE_DIR=${ELM_ATS_SRC_DIR}/amanzi
AMANZI_TPLS_VER=`get_tpl_version`

ATS_SOURCE_DIR=$AMANZI_SOURCE_DIR/src/physics/ats

AMANZI_GIT_LATEST_TAG_VER=`(cd $AMANZI_SOURCE_DIR; git tag -l amanzi-* | tail -n1 | sed -e 's/amanzi-//')`
AMANZI_GIT_GLOBAL_HASH=`(cd $AMANZI_SOURCE_DIR; git rev-parse --short HEAD)`
AMANZI_VER="${AMANZI_GIT_LATEST_TAG_VER}_${AMANZI_GIT_GLOBAL_HASH}"

echo ""
echo "AMANZI_SOURCE_DIR = $AMANZI_SOURCE_DIR"
echo " - latest tag       $AMANZI_GIT_LATEST_TAG_VER"
echo " - global hash      $AMANZI_GIT_GLOBAL_HASH"
echo " - version string   $AMANZI_VER"
echo ""

ATS_GIT_LATEST_TAG_VER=`(cd $ATS_SOURCE_DIR; git tag -l ats-* | tail -n1 | sed -e 's/ats-//')`
ATS_GIT_GLOBAL_HASH=`(cd $ATS_SOURCE_DIR; git rev-parse --short HEAD)`
ATS_VER="${ATS_GIT_LATEST_TAG_VER}_${ATS_GIT_GLOBAL_HASH}"

echo "ATS_SOURCE_DIR =    $ATS_SOURCE_DIR"
echo " - latest tag       $ATS_GIT_LATEST_TAG_VER"
echo " - global hash      $ATS_GIT_GLOBAL_HASH"
echo " - version string   $ATS_VER"
echo ""

# Set REBUILD_ATS=true to rebuild ATS inside the container from the local
# amanzi/ + amanzi/src/physics/ats/ working tree rather than using the ATS
# prebuilt in the base image. Tune parallelism with ATS_BUILD_PARALLEL.
REBUILD_ATS=${REBUILD_ATS:-false}
ATS_BUILD_PARALLEL=${ATS_BUILD_PARALLEL:-4}
ATS_BUILD_TYPE=${ATS_BUILD_TYPE:-opt}

if [ "${REBUILD_ATS}" = "true" ]; then
  echo "REBUILD_ATS=true: rebuilding ATS from local source"
  echo " - amanzi at $AMANZI_GIT_GLOBAL_HASH, ats at $ATS_GIT_GLOBAL_HASH"
  echo " - build type:        $ATS_BUILD_TYPE"
  echo " - build parallelism: $ATS_BUILD_PARALLEL"
  echo ""
fi

docker build --pull --progress=plain --no-cache \
  --build-arg REBUILD_ATS="${REBUILD_ATS}" \
  --build-arg ATS_BUILD_PARALLEL="${ATS_BUILD_PARALLEL}" \
  --build-arg ATS_BUILD_TYPE="${ATS_BUILD_TYPE}" \
  --build-arg AMANZI_GIT_HASH="${AMANZI_GIT_GLOBAL_HASH}" \
  --build-arg ATS_GIT_HASH="${ATS_GIT_GLOBAL_HASH}" \
  -f Dockerfile-ATS-ELM -t metsi/ats:elm_api ../


