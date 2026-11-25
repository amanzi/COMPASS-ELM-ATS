#!/usr/bin/env bash
if [ -z "${USE_ATS}" ]; then
    echo "Set USE_ATS prior to running the build_example script"
    exit 1
fi

# Test 1: saturation-driven runoff -- single-column sand column under
# continuous idealized rain, watching the water table rise and QOVER/
# H2OSFC turn on as the column saturates from below.
EXAMPLE_NAME=idealized_saturation_runoff \
      DOMAIN_NAME=oakharbor_column \
      SURF_DATA_FILENAME=surfdata_oakharbor_column_bareground.nc \
      MET_DATA_BYPASS_DIR=atm_forcing.idealized_wet \
      RUN_STARTDATE=2000-01-01 \
      RUN_STOP_OPTION=ndays \
      RUN_STOP_N=5 \
      ../build_example.sh
