#!/usr/bin/env bash
if [ -z "${USE_ATS}" ]; then
    echo "Set USE_ATS prior to running the build_example script"
    exit 1
fi

EXAMPLE_NAME=idealized_evaporation \
      DOMAIN_NAME=oakharbor_column \
      SURF_DATA_FILENAME=surfdata_oakharbor_column_bareground.nc \
      MET_DATA_BYPASS_DIR=atm_forcing.idealized_dry \
      RUN_STARTDATE=2000-01-01 \
      RUN_STOP_OPTION=ndays \
      RUN_STOP_N=20 \
      ../build_example.sh
