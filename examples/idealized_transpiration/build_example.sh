#!/usr/bin/env bash
if [ -z "${USE_ATS}" ]; then
    echo "Set USE_ATS prior to running the build_example script"
    exit 1
fi

# Vegetated (broadleaf deciduous forest PFT) analogue of idealized_evaporation
# -- dries the oakharbor_column domain via transpiration instead of
# bare-soil evaporation. Needs satellite-phenology (SP) mode, not the CN
# mode every other example uses, since prescribing a constant LAI directly
# (rather than growing it prognostically) requires ELM%SPBC instead of
# ELM%CNPRDCTCBC.
EXAMPLE_NAME=idealized_transpiration \
      DOMAIN_NAME=oakharbor_column \
      MET_DATA_BYPASS_DIR=atm_forcing.idealized_dry \
      COMPSET=ICBELMBC \
      RUN_STARTDATE=2000-01-01 \
      RUN_STOP_OPTION=ndays \
      RUN_STOP_N=5 \
      ../build_example.sh
