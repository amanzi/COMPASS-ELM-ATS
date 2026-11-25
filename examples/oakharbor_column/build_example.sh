#!/usr/bin/env bash
if [ -z "${USE_ATS}" ]; then
    echo "Set USE_ATS prior to running the build_example script"
    exit 1
fi

EXAMPLE_NAME=oakharbor_column \
      MET_DATA_BYPASS_DIR=atm_forcing.datm7.GSWP3.0.5d.v2.c180716_Oakharbor-Grid/cpl_bypass_full \
      COMPSET=ICBELMBC \
      ../build_example.sh
