#!/usr/bin/env bash

# NOTE:
# it is expected that this script is called with the following variables set:
#
# Required:
#  - EXAMPLE_NAME : name of the example to be run
#  - USE_ATS : TRUE -- uses ATS physics
#              IC_ONLY -- uses ATS initial condition, for better comparison to ATS
#              FALSE -- no ATS at all
#
# Required but usually set by machine
#  - ELM_ATS_SRC_DIR : top-level directory of all source code.
#  - E3SM_WORK_DIR : parent location of all cases.
#  - COMPILER : compiler name, used by CIME
#  - MACHINE_NAME : machine name, used by CIME
#
# Optional:
#  - EXAMPLE_INPUTDATA_DIR : Location of the local example-specific
#                            inputdata, default is
#                            <ELM_ATS_SRC_DIR>/<EXAMPLE_NAME>/
#  - GLOBAL_INPUTDATA_DIR : path to ELM input data directory, defaults to
#                           <ELM_ATS_SRC_DIR>/inputdata
#
#  - ATS_FILENAME : identifies the xml input file for ATS,
#                   defaults to <EXAMPLE_NAME>.xml
#
#  - COMPSET : E3SM compset, default is "ICB20TRCNPRDCTCBC"
#  - RUN_STARTDATE : Start date, default is 2000-07-15, start of WY 2001
#  - RUN_STOP_OPTION : Units of STOP_N, default is years.
#  - RUN_STOP_N : Stop after N RUN_STOP_OPTIONs, default is 2
#
#  - DOMAIN_NAME : Stem shared by the ELM domain file and ATS mesh,
#                  defaults to EXAMPLE_NAME
#  - ELM_DOMAIN_FILENAME : Name of the domain file, defaults to
#                          domain.lnd.DOMAIN_NAME.nc
#  - ATS_DOMAIN_FILENAME : identifies the ATS mesh name, defaults to
#                          domain.lnd.DOMAIN_NAME.exo
# 
#  - SURF_DATA_NAME : ELM surface data / fsurdat filename, default is
#                     surfdata_EXAMPLE_NAME.nc
#  - MET_DATA_BYPASS_DIR : cpl_bypass forcing directory name (the seven
#                         ATS-subdaily_<VAR>_z<NN>.nc files plus
#                         zone_mappings.txt, see
#                         scripts/make_synthetic_forcing.py) Defaults
#                         to atm_forcing.<EXAMPLE_NAME>
#
#  - NTASKS : for parallel runs
#  - DEBUG : Set debug flags for ELM? Default is FALSE.
#
# NOTE on filename resolution: All files are searched for in the
# following order, and the first one found is used:
#  - EXAMPLE_SOURCE_DIR
#  - <ELM_ATS_SRC_DIR>/examples/shared
#  - GLOBAL_INPUTDATA_DIR/... (ELM shared global inputdata conventions apply)
#
# Returns:
#  - 0 if successful
#  - 1 if a variable is not found
#  - 2 if a file is not found
#  - 3 build or other failure
#


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

# process required parameters
# ---------------------------
if [ -z "${EXAMPLE_NAME}" ]; then
    echo "Set EXAMPLE_NAME before running."
    exit 1
fi

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
    exit 1
fi
    
# process optional parameters
# ---------------------------
# NTASKS is used for both proc count and to set
# a unique CASE_DIR for parallel vs serial
if [ -z "${NTASKS}" ]; then
    NTASKS=1
else
    CASE_SUFFIX=${CASE_SUFFIX}.np${NTASKS}
fi


CAMPAIGN_DIR="${E3SM_WORK_DIR}/${EXAMPLE_NAME}"
CASE_DIR="${CAMPAIGN_DIR}/${CASE_SUFFIX}"
E3SM_SRC_DIR="${ELM_ATS_SRC_DIR}/E3SM"

# compset
if [ -z "${COMPSET}" ]; then
    export COMPSET="ICB20TRCNPRDCTCBC"
fi

# Use GNU sed if available (gsed on macOS), otherwise plain sed
if [ -z "${SED}" ]; then
    if command -v gsed &> /dev/null; then
        SED=gsed
    else
        SED=sed
    fi
fi

# Debug mode?
if [ -z "${DEBUG}" ]; then
    DEBUG=FALSE
fi

# CI?
if [ -z "${GITHUB_ACTIONS}" ]; then
    export GITHUB_ACTIONS=FALSE
fi

# set up places to search
if [ -z "${EXAMPLE_INPUTDATA_DIR}" ]; then
    EXAMPLE_INPUTDATA_DIR=${ELM_ATS_SRC_DIR}/examples/${EXAMPLE_NAME}
fi
if [ -z "${SHARED_INPUTDATA_DIR}" ]; then
    SHARED_INPUTDATA_DIR=${ELM_ATS_SRC_DIR}/examples/shared
fi
if [ -z "${GLOBAL_INPUTDATA_DIR}" ]; then
    GLOBAL_INPUTDATA_DIR=${ELM_ATS_SRC_DIR}/inputdata
fi

# Searches for filename in:
#   - EXAMPLE_INPUTDATA_DIR
#   - SHARED_INPUTDATA_DIR
#   - GLOBAL_INPUTDATA_DIR/${global_loc} (if provided)
#
# Usage: find_file filename found_loc_var [global_loc]
#
# Assigns the found path into the variable named by found_loc_var (bash 3.2
# has no `local -n` namerefs, so this uses eval to assign by name -- filename
# is never attacker-controlled here, only ever example-owned literals/paths
# from this script's own variables, so this is safe from injection).
# If the file is found in GLOBAL_INPUTDATA_DIR, found_loc_var is set to the
# empty string. If the file is found elsewhere, found_loc_var is set to the
# path of that file.
#
# Returns 0 if the file is found, 1 otherwise
#
find_file() {
    local filename="$1"
    local found_loc_var="$2"
    local global_loc="$3"
    if [ -e "${EXAMPLE_INPUTDATA_DIR}/${filename}" ]; then
        eval "${found_loc_var}=\"\${EXAMPLE_INPUTDATA_DIR}/\${filename}\""
        return 0
    elif [ -e "${SHARED_INPUTDATA_DIR}/${filename}" ]; then
        eval "${found_loc_var}=\"\${SHARED_INPUTDATA_DIR}/\${filename}\""
        return 0
    elif [ -n "${global_loc}" ] && [ -e "${GLOBAL_INPUTDATA_DIR}/${global_loc}/${filename}" ]; then
        eval "${found_loc_var}="
        return 0
    else
        eval "${found_loc_var}="
        echo "Unable to find file ${filename}"
        return 1
    fi
}

# Usage: find_file_or_die filename found_loc_var [global_loc]
find_file_or_die() {
    find_file "$1" "$2" "$3" || exit 2
}

# Find files need for simulation
# ------------------------------
    # ATS input file

# domain for ELM
if [ -z "${DOMAIN_NAME}" ]; then
    DOMAIN_NAME=${EXAMPLE_NAME}
fi

if [ -z "${ELM_DOMAIN_FILENAME}" ]; then
    ELM_DOMAIN_FILENAME=domain.lnd.${DOMAIN_NAME}.nc
fi
find_file_or_die "${ELM_DOMAIN_FILENAME}" ELM_DOMAIN_FILENAME_FOUND "share/domains/domain.clm"

# fsurdata
if [ -z "${SURF_DATA_FILENAME}" ]; then
    if find_file "surfdata_${EXAMPLE_NAME}.nc" SURF_DATA_FILENAME_FOUND "lnd/clm2/surfdata_map"; then
        SURF_DATA_FILENAME="surfdata_${EXAMPLE_NAME}.nc"
    elif find_file "surfdata_${DOMAIN_NAME}.nc" SURF_DATA_FILENAME_FOUND "lnd/clm2/surfdata_map"; then
        SURF_DATA_FILENAME="surfdata_${DOMAIN_NAME}.nc"
    else
        echo "Unable to find surfdata file (tried surfdata_${EXAMPLE_NAME}.nc and surfdata_${DOMAIN_NAME}.nc)"
        exit 2
    fi
else
    find_file_or_die "${SURF_DATA_FILENAME}" SURF_DATA_FILENAME_FOUND "lnd/clm2/surfdata_map"
fi

# met data folder
if [ -z "${MET_DATA_BYPASS_DIR}" ]; then
    MET_DATA_BYPASS_DIR=atm_forcing.datm7.${EXAMPLE_NAME}
fi
find_file_or_die "${MET_DATA_BYPASS_DIR}" MET_DATA_BYPASS_DIR_FOUND "atm/datm7"

# ATS files
if [ "${USE_ATS}" != "FALSE" ]; then
    if [ -z "${ATS_DOMAIN_FILENAME}" ]; then
        ATS_DOMAIN_FILENAME=domain.lnd.${DOMAIN_NAME}.exo
    fi
    find_file_or_die "${ATS_DOMAIN_FILENAME}" ATS_DOMAIN_FILENAME_FOUND "share/domains/domain.clm"

    if [ -z "${ATS_FILENAME}" ]; then
        ATS_FILENAME=${EXAMPLE_NAME}.xml
    fi
    find_file_or_die "${ATS_FILENAME}" ATS_FILENAME_FOUND
fi

# create the case
echo "Creating case"
echo "----------------------"
echo "${E3SM_SRC_DIR}/cime/scripts/create_newcase --case ${CASE_DIR} --res ELM_USRDAT --mach ${MACHINE_NAME} --compiler ${COMPILER_NAME} --compset ${COMPSET}"
echo "----------------------"
${E3SM_SRC_DIR}/cime/scripts/create_newcase --case ${CASE_DIR} --res ELM_USRDAT --mach ${MACHINE_NAME} --compiler ${COMPILER_NAME} --compset ${COMPSET}

# set up the case dir
echo ""
echo "Setting up case input"
echo "----------------------"
cd ${CASE_DIR}

# Start user_nl_elm from the example's own file (physics/namelist settings
# the example author wrote -- flanduse_timeseries, do_transient_pfts,
# hist_fincl*, spinup options, aero/CO2/ndep/popdens file paths, etc.), if
# it provides one. create_newcase's own user_nl_elm is otherwise empty, so
# without this the settings below would be all that ends up in the case.
if [ -e "${EXAMPLE_INPUTDATA_DIR}/user_nl_elm" ]; then
    echo "  user_nl_elm  : ${EXAMPLE_INPUTDATA_DIR}/user_nl_elm"
    cat "${EXAMPLE_INPUTDATA_DIR}/user_nl_elm" >> user_nl_elm
fi

# make sure there is a clean endline -- an extra doesn't hurt
echo "" >> user_nl_elm

# copy over files
if [ ! -z "${ELM_DOMAIN_FILENAME_FOUND}" ]; then
    echo "  ELM domain   : ${ELM_DOMAIN_FILENAME_FOUND}"
    ./xmlchange ATM_DOMAIN_PATH=${CASE_DIR}
    ./xmlchange LND_DOMAIN_PATH=${CASE_DIR}
    cp ${ELM_DOMAIN_FILENAME_FOUND} ${CASE_DIR}
else
    echo "  ELM domain   : ${ELM_DOMAIN_FILENAME} (found in GLOBAL_INPUTDATA_DIR, not copied)"
fi
./xmlchange ATM_DOMAIN_FILE=${ELM_DOMAIN_FILENAME}
./xmlchange LND_DOMAIN_FILE=${ELM_DOMAIN_FILENAME}

if [ -z "${SURF_DATA_FILENAME_FOUND}" ]; then
    echo "  surfdata     : ${SURF_DATA_FILENAME} (found in GLOBAL_INPUTDATA_DIR, not copied)"
    echo " fsurdat = '\${DIN_LOC_ROOT}/lnd/clm2/surfdata_map/${SURF_DATA_FILENAME}'" >> user_nl_elm
else
    echo "  surfdata     : ${SURF_DATA_FILENAME_FOUND}"
    cp ${SURF_DATA_FILENAME_FOUND} ${CASE_DIR}
    echo " fsurdat = '${CASE_DIR}/${SURF_DATA_FILENAME}'" >> user_nl_elm
fi

if [ -z "${MET_DATA_BYPASS_DIR_FOUND}" ]; then
    echo "  met forcing  : ${MET_DATA_BYPASS_DIR} (found in GLOBAL_INPUTDATA_DIR, not copied)"
    echo " metdata_bypass = '\${DIN_LOC_ROOT}/atm/datm7/${MET_DATA_BYPASS_DIR}'" >> user_nl_elm
    ./xmlchange DIN_LOC_ROOT_CLMFORC=\${DIN_LOC_ROOT}/atm/datm7
else
    echo "  met forcing  : ${MET_DATA_BYPASS_DIR_FOUND}"
    cp -r ${MET_DATA_BYPASS_DIR_FOUND} ${CASE_DIR}
    echo " metdata_bypass = '${CASE_DIR}/${MET_DATA_BYPASS_DIR}'" >> user_nl_elm
fi

# ATS-specific
if [ "${USE_ATS}" != "FALSE" ]; then
    # copy over files
    echo "  ATS xml      : ${ATS_FILENAME_FOUND}"
    cp ${ATS_FILENAME_FOUND} ${CASE_DIR}
    echo "  ATS mesh     : ${ATS_DOMAIN_FILENAME_FOUND}"
    cp ${ATS_DOMAIN_FILENAME_FOUND} ${CASE_DIR}

    # Multi-column meshes (transects) ship a partition-map .h5 sidecar
    # alongside the .exo, same basename, referenced via the same
    # MESH_FILENAME.h5 placeholder -- copy it too if present. Single-column
    # meshes have no partition map to store, so this is optional.
    ATS_DOMAIN_FILENAME_H5=${ATS_DOMAIN_FILENAME%.exo}.h5
    if find_file "${ATS_DOMAIN_FILENAME_H5}" ATS_DOMAIN_FILENAME_H5_FOUND "share/domains/domain.clm"; then
        echo "  ATS mesh h5  : ${ATS_DOMAIN_FILENAME_H5_FOUND}"
        cp ${ATS_DOMAIN_FILENAME_H5_FOUND} ${CASE_DIR}
    fi

    # sed replace MESH_FILENAME with the mesh file's stem -- the ATS xml
    # template appends its own ".exo"/".h5" extensions after MESH_FILENAME,
    # so substitute ATS_DOMAIN_FILENAME with its extension stripped, not the
    # full filename (else the extension ends up doubled, e.g. "foo.exo.exo").
    ATS_DOMAIN_FILENAME_STEM=${ATS_DOMAIN_FILENAME%.exo}
    ${SED} -i "s^MESH_FILENAME^${CASE_DIR}/${ATS_DOMAIN_FILENAME_STEM}^g" ${CASE_DIR}/${ATS_FILENAME}

    if [ "${USE_ATS}" == "TRUE" ]; then
	echo " use_ats_hydro = .true." >> user_nl_elm
    elif [ "${USE_ATS}" == "IC_ONLY" ]; then
	echo " use_ats_ic = .true." >> user_nl_elm
    fi

    echo " ats_inputdir = '${CASE_DIR}'" >> user_nl_elm
    echo " ats_inputfile = '${ATS_FILENAME}'" >> user_nl_elm
    echo " domain_decomp_type = 'ats'" >> user_nl_elm

    
fi

# ELM
./xmlchange MOSART_MODE=NULL,DOUT_S=FALSE,DIN_LOC_ROOT=${ELM_ATS_SRC_DIR}/inputdata
./xmlchange ELM_USRDAT_NAME=${DOMAIN_NAME}

./xmlchange NTASKS=${NTASKS}
./xmlchange NTASKS_PER_INST=${NTASKS}

./xmlchange PIO_TYPENAME=netcdf

# run length -- overridable per-test (e.g. short idealized/synthetic-forcing
# diagnostics don't want the default 2-year real-met run length)
if [ -z "${RUN_STARTDATE}" ]; then
    RUN_STARTDATE=2000-07-15
fi
if [ -z "${RUN_STOP_OPTION}" ]; then
    RUN_STOP_OPTION=nyears
fi
if [ -z "${RUN_STOP_N}" ]; then
    RUN_STOP_N=2
fi
./xmlchange RUN_STARTDATE=${RUN_STARTDATE}
./xmlchange STOP_OPTION=${RUN_STOP_OPTION},STOP_N=${RUN_STOP_N}
./xmlchange BATCH_SYSTEM=none
./xmlchange DEBUG=${DEBUG}

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
echo "Running the case"
echo "----------------------"
if [ "$GITHUB_ACTIONS" = "TRUE" ]; then
    ./case.submit --no-batch
else
    ./case.submit
fi
