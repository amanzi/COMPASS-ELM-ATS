#!/usr/bin/env bash
if [ -z "${USE_ATS}" ]; then
    echo "Set USE_ATS prior to running the build_example script"
    exit 1
fi

if [ -z "${NTASKS}" ]; then
    echo "Setting NTASKS = 2"
    NTASKS=2
fi

# Test 4: parallelism/replication -- 5-column flat transect mesh, same
# idealized continuous-rain forcing as test 1 (idealized_saturation_runoff),
# run at NTASKS=2 (uneven columns-per-rank: 3 on one rank, 2 on the other)
# to exercise MPI decomposition correctness rather than a specific physics
# signal -- deliberately not NTASKS=5 (which would give exactly one column
# per rank and not test multi-column-per-rank behavior at all).
NTASKS=${NTASKS} \
      EXAMPLE_NAME=idealized_saturation_runoff_replicated \
      DOMAIN_NAME=oakharbor_transect_flat \
      MET_DATA_BYPASS_DIR=atm_forcing.idealized_wet \
      RUN_STARTDATE=2000-01-01 \
      RUN_STOP_OPTION=ndays \
      RUN_STOP_N=5 \
      ../build_example.sh
