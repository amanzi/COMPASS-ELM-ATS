#!/usr/bin/env bash

# NOTE:
# it is expected that this script is called with the following variables set:
#
# Required:
#  - CASE_NAME : name of the example
#  - INPUTDATA_NAME : ELM input dataset, e.g. "1x1pt_Oakharbor" (can we remove this?)
#  - USE_ATS : TRUE -- uses ATS physics
#              IC_ONLY -- uses ATS initial condition, for better comparison to ATS
#              FALSE -- no ATS at all
#
# Required but usually set by machine
#  - ELM_ATS_SRC_DIR : top-level directory
#  - E3SM_WORK_DIR : location of cases, run directories
#  - COMPILER : compiler name, used by CIME
#  - MACHINE_NAME : machine name, used by CIME
#
# Optional:
#  - DOMAIN_NAME : identifies the mesh file, domain.nc file, etc about the simulation domain, defaults to CASE_NAME)
#  - ATS_CASE_NAME : identifies the xml file/parameters for ATS
#  - COMPSET : E3SM compset, default is "ICB20TRCNPRDCTCBC"
#  - INPUTDATA_DIR : path to ELM input data directory, defaults to $E3SM_WORK_DIR/inputdata
#  - GITHUB_ACTIONS : is this run through CI?  Default is FALSE
#  - NTASKS : for parallel runs

# exit on error
set -e
shopt -s nullglob

# process directory structure
if [ -z "${ELM_ATS_SRC_DIR}" ]; then
    echo "Set ELM_ATS_SRC_DIR before running."
    exit 1
fi
if [ -z "${E3SM_WORK_DIR}" ]; then
    echo "Set E3SM_WORK_DIR before running."
    exit 1
fi

# process case/domain/ats_case names
if [ -z "${CASE_NAME}" ]; then
    echo "Set CASE_NAME before running."
    exit 1
fi
if [ -z "${DOMAIN_NAME}" ]; then
    export DOMAIN_NAME=${CASE_NAME}
fi
if [ -z "${ATS_CASE_NAME}" ]; then
    export ATS_CASE_NAME=${CASE_NAME}
fi

# process ELM input data
if [ -z "${INPUTDATA_NAME}" ]; then
    echo "Set INPUTDATA_NAME before running."
fi

# process compset
if [ -z "${COMPSET}" ]; then
    export COMPSET="ICB20TRCNPRDCTCBC"
fi

# by default, do not increase verbosity
if [ -z "${ATS_VERBOSITY}" ]; then
    export ATS_VERBOSITY=0
fi 

# use ats?
CASE_SUFFIX=
if [ -z "${USE_ATS}" ]; then
    echo "Set USE_ATS before running."
    exit 1
elif [ "${USE_ATS}" == "TRUE" ]; then
    CASE_SUFFIX=elm-ats
elif [ "${USE_ATS}" == "IC_ONLY" ]; then
    CASE_SUFFIX=ic_only
elif [ "${USE_ATS}" == "FALSE" ]; then
    CASE_SUFFIX=elm
else
    echo "USE_ATS must be one of TRUE, IC_ONLY, or FALSE"
fi
    
# CI?
if [ -z "${GITHUB_ACTIONS}" ]; then
    export GITHUB_ACTIONS=FALSE
fi

# Debug mode?
if [ -z "${DEBUG_MODE}" ]; then
    export DEBUG_MODE=FALSE
fi

CASE_DIR="${E3SM_WORK_DIR}/cases/${CASE_NAME}.${CASE_SUFFIX}"
E3SM_SRC_DIR="${ELM_ATS_SRC_DIR}/E3SM"
# Use GNU sed if available (gsed on macOS), otherwise plain sed
if command -v gsed &> /dev/null; then
    SED=gsed
else
    SED=sed
fi

# create the case
echo "Creating case"
echo "----------------------"
echo "${E3SM_SRC_DIR}/cime/scripts/create_newcase --case ${CASE_DIR} --res ELM_USRDAT --mach ${MACHINE_NAME} --compiler ${COMPILER_NAME} --compset ${COMPSET} --driver mct"
echo "----------------------"
${E3SM_SRC_DIR}/cime/scripts/create_newcase --case ${CASE_DIR} --res ELM_USRDAT --mach ${MACHINE_NAME} --compiler ${COMPILER_NAME} --compset ${COMPSET} --driver mct


# set up the case dir
echo ""
echo "Setting up case input"
echo "----------------------"
if [ "${GITHUB_ACTIONS}" = "TRUE" ]; then
    # Use EXAMPLE_DIR if set, otherwise fall back to CASE_NAME
    # This allows CASE_NAME to include suffixes like .np${NTASKS} for output
    # while EXAMPLE_DIR identifies the actual source directory
    SEARCH_DIR="${EXAMPLE_DIR:-${CASE_NAME}}"
    export CASE_SOURCE=$(find / -path "*/examples/${SEARCH_DIR}" 2>/dev/null)
    export SHARED_SOURCE=$(find / -path "*/examples/shared" 2>/dev/null)
else
    export CASE_SOURCE="./"
    export SHARED_SOURCE="../shared"
fi
echo "CASE_SOURCE = ${CASE_SOURCE}"
echo "SHARED_SOURCE = ${SHARED_SOURCE}"

# cp over example files to the case directory
cp -r ${CASE_SOURCE}/* ${CASE_DIR}/
if [ "${USE_ATS}" != "FALSE" ]; then
    if [ -e "${SHARED_SOURCE}/${DOMAIN_NAME}.exo" ]; then
	    cp ${SHARED_SOURCE}/${DOMAIN_NAME}.exo ${CASE_DIR}/
    fi
    if [ -e "${SHARED_SOURCE}/${DOMAIN_NAME}.h5" ]; then
	    cp ${SHARED_SOURCE}/${DOMAIN_NAME}.h5 ${CASE_DIR}/
    fi
    if [ -e "${SHARED_SOURCE}/${ATS_CASE_NAME}.xml" ]; then
	    cp ${SHARED_SOURCE}/${ATS_CASE_NAME}.xml ${CASE_DIR}/
    fi
fi

cd ${CASE_DIR}

# make sure there is a clean endline -- an extra doesn't hurt
echo "" >> user_nl_elm

# override surfdata if specified
if [ -n "${SURF_DATA_FILE}" ]; then
    echo " fsurdat = '\${DIN_LOC_ROOT}/lnd/clm2/surfdata_map/${SURF_DATA_FILE}'" >> user_nl_elm
fi

# ATS-specific
if [ "${USE_ATS}" != "FALSE" ]; then
    ${SED} -i "s^MESH_FILENAME^${CASE_DIR}/${DOMAIN_NAME}^g" ${ATS_CASE_NAME}.xml

    if [ "${USE_ATS}" == "TRUE" ]; then
	    echo " use_ats = .true." >> user_nl_elm
    else
	    echo " use_ats_ic = .true." >> user_nl_elm
    fi
    echo " ats_inputdir = '${CASE_DIR}'" >> user_nl_elm
    echo " ats_inputfile = '${ATS_CASE_NAME}.xml'" >> user_nl_elm
    echo " domain_decomp_type = 'ats'" >> user_nl_elm
    echo " ats_verbosity = ${ATS_VERBOSITY}" >> user_nl_elm
fi


# ELM
./xmlchange MOSART_MODE=NULL,DOUT_S=FALSE,DIN_LOC_ROOT=${ELM_ATS_SRC_DIR}/inputdata
./xmlchange DIN_LOC_ROOT_CLMFORC=\$DIN_LOC_ROOT/atm/datm7
./xmlchange ELM_USRDAT_NAME=${INPUTDATA_NAME}

# try to find the domain.nc file: these are now example specific
if [ -z "${DOMAIN_FILE}" ]; then
    if [ -e ${INPUTDATA_DIR}/share/domains/domain.clm/domain.lnd.${INPUTDATA_NAME}.nc ]; then
	    DOMAIN_FILE=domain.lnd.${INPUTDATA_NAME}.nc
    else
	    matches=(${INPUTDATA_DIR}/share/domains/domain.clm/domain.lnd.${INPUTDATA_NAME}*.nc)
        if (( ${#matches[@]} == 1 )); then
            file="${matches[0]}"
            DOMAIN_FILE="${file##*/}"
        elif (( ${#matches[@]} == 0)); then
            echo "Cannot find domain file for ${INPUTDATA_NAME} in ${INPUTDATA_DIR}/share/domains/domain.clm"
            exit 1
        else 
            echo "Domain file ambiguous (more than one found) for ${INPUTDATA_NAME} in ${INPUTDATA_DIR}/share/domains/domain.clm"
            exit 2
        fi        
    fi
fi
    
./xmlchange ATM_DOMAIN_PATH=\$DIN_LOC_ROOT/share/domains/domain.clm
./xmlchange LND_DOMAIN_PATH=\$DIN_LOC_ROOT/share/domains/domain.clm
./xmlchange ATM_DOMAIN_FILE=${DOMAIN_FILE}
./xmlchange LND_DOMAIN_FILE=${DOMAIN_FILE}

# set the number of tasks
if [ -z "${NTASKS}" ]; then
    NTASKS=1
fi
./xmlchange NTASKS=${NTASKS}
./xmlchange NTASKS_PER_INST=${NTASKS}

./xmlchange PIO_TYPENAME=netcdf
./xmlchange RUN_STARTDATE=2000-07-15
./xmlchange STOP_OPTION=nyears,STOP_N=2
./xmlchange BATCH_SYSTEM=none
./xmlchange DEBUG=${DEBUG_MODE}

# setup the case
echo ""
echo "Running case.setup"
echo "----------------------"
./case.setup
echo -e '\nstring(APPEND CPPDEFS " -DCPL_BYPASS -DUSE_ATS_LIB")' >> cmake_macros/universal.cmake

# build
echo ""
echo "Running case.build"
echo "----------------------"
./case.build


echo ""
echo "Run the case yourself:"
echo "----------------------"
echo "pushd ${CASE_DIR} && ./case.submit"
if [ "$GITHUB_ACTIONS" = "TRUE" ]; then
  ./case.submit --no-batch

  # case.submit --no-batch swallows run failures (env_batch.py),
  # so independently verify the simulation completed.
  if grep -q "case.run success" "${CASE_DIR}/CaseStatus"; then
    echo "Simulation completed successfully."
  else
    echo "ERROR: Simulation failed! CaseStatus contents:"
    cat "${CASE_DIR}/CaseStatus"
    exit 1
  fi
fi
