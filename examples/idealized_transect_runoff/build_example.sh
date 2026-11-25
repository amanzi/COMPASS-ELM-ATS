#!/usr/bin/env bash
if [ -z "${USE_ATS}" ]; then
    echo "Set USE_ATS prior to running the build_example script"
    exit 1
fi

if [ -z "${NTASKS}" ]; then
    echo "Setting NTASKS = 2"
    NTASKS=2
fi

# Test 5: transect runoff+baseflow -- same 5-column mesh as test 4, but
# SLOPED (1% grade, 5m drop over 500m -- see domain.lnd.oakharbor_transect.exo).
# Uses the same idealized forcing and run length as tests 1 and 4 (see
# examples/shared/atm_forcing.idealized_wet) so all three runoff-generation
# tests differ only by mesh (flat column / flat 5-column / sloped
# 5-column).
NTASKS=${NTASKS} \
      EXAMPLE_NAME=idealized_transect_runoff \
      DOMAIN_NAME=oakharbor_transect \
      MET_DATA_BYPASS_DIR=atm_forcing.idealized_wet \
      RUN_STARTDATE=2000-01-01 \
      RUN_STOP_OPTION=ndays \
      RUN_STOP_N=5 \
      ../build_example.sh
