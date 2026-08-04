#!/usr/bin/env bash
# build_example.sh -- Create all four cases for the coweeta multi-stage spinup workflow.
#
# Usage:
#   ./build_example.sh [STAGE ...]
#
# With no arguments, builds all four stages (1a 1b 2 3) in order. Pass one or
# more stage names to build only those, e.g. `./build_example.sh 2` to rebuild
# just stage 2 while iterating on it, or `./build_example.sh 1b 2` to rebuild
# both. Stages are always attempted in canonical order (1a, 1b, 2, 3)
# regardless of the order given on the command line. Building a later stage
# alone assumes any earlier stage it depends on (for restart/IC wiring) was
# already built in a previous invocation -- this script does not check that.
#
# Stages:
#   1a. ATS-only steady-state spinup (directory only, no CIME case)
#   1b. ELM carbon spinup with accelerated decomposition (~200 yr, cyclic forcing)
#   2.  ELM+ATS cyclic steady-state spinup (~10 yr, cyclic forcing, IC from 1a+1b)
#   3.  ELM+ATS transient run (IC from stage 2)
#
# Required environment variables:
#   ELM_ATS_SRC_DIR   -- root of the ELM-ATS repository (typically set once,
#                        by a modulefile, alongside the other vars below
#                        except NTASKS)
#   E3SM_WORK_DIR     -- parent of the campaign dir (E3SM_WORK_DIR/Coweeta_Campaign0/)
#                        where the shared inputdata/ and all case dirs are created
#   MACHINE_NAME      -- CIME machine name (e.g. mac, docker-ats)
#   COMPILER_NAME     -- CIME compiler name (e.g. gnu)
#   NTASKS            -- number of MPI tasks. Set by the user for each build,
#                        not the modulefile -- this must match the partition
#                        count used in coweeta_elm_ats.ipynb's
#                        m2.partition(int(os.environ['NTASKS'])) call, since
#                        ATS's mesh decomposition and any checkpoint restart
#                        across stages both depend on a fixed process count.
#
# Meteorology (MET_SPINUP_FILE / MET_TRANSIENT_FILE from earlier revisions of
# this script) is no longer user-supplied: coweeta_aorc_elm.ipynb always
# writes atm_forcing_spinup/ and atm_forcing/ under examples/coweeta/, and
# stage_inputdata.sh picks them up from those fixed locations automatically.
#
# Optional environment variables:
#   CAMPAIGN_NAME     -- campaign directory name under E3SM_WORK_DIR
#                        (default: Coweeta_Campaign0)
#
# Inputdata roots:
#   DIN_LOC_ROOT     -- global ELM inputdata mirror (${ELM_ATS_SRC_DIR}/inputdata),
#                        read-only; aero/CO2/popdens/ndep are read from here
#                        directly, never copied into the campaign
#   DIN_LOC_CAMPAIGN -- campaign-local inputdata dir (${CAMPAIGN_DIR}/inputdata),
#                        populated by stage_inputdata.sh from examples/coweeta/

set -e
shopt -s nullglob

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------
for var in ELM_ATS_SRC_DIR E3SM_WORK_DIR MACHINE_NAME COMPILER_NAME NTASKS; do
    if [ -z "${!var}" ]; then
        echo "ERROR: ${var} must be set before running this script."
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Stage selection
# ---------------------------------------------------------------------------
# No arguments -> build all four stages. Otherwise, build only the stages
# named on the command line (in canonical order, not command-line order).
if [ "$#" -eq 0 ]; then
    RUN_1A=true; RUN_1B=true; RUN_2=true; RUN_3=true
else
    RUN_1A=false; RUN_1B=false; RUN_2=false; RUN_3=false
    for stage in "$@"; do
        case "${stage}" in
            1a) RUN_1A=true ;;
            1b) RUN_1B=true ;;
            2)  RUN_2=true ;;
            3)  RUN_3=true ;;
            *)
                echo "ERROR: unknown stage '${stage}' (expected one or more of: 1a 1b 2 3)"
                exit 1
                ;;
        esac
    done
fi

# ---------------------------------------------------------------------------
# Common settings
# ---------------------------------------------------------------------------
NAME=coweeta
CAMPAIGN_NAME="${CAMPAIGN_NAME:-Coweeta_Campaign0}"
CAMPAIGN_DIR="${E3SM_WORK_DIR}/${CAMPAIGN_NAME}"
COMPSET="ICB20TRCNPRDCTCBC"
E3SM_SRC_DIR="${ELM_ATS_SRC_DIR}/E3SM"
DIN_LOC_ROOT="${ELM_ATS_SRC_DIR}/inputdata"       # global mirror, read-only
DIN_LOC_CAMPAIGN="${CAMPAIGN_DIR}/inputdata"       # campaign-local, populated

# coweeta_elm_ats.ipynb's fixed output directory -- holds the mesh, domain,
# surfdata, ATS XMLs, and user_nl_elm files this script reads below. No
# manual copy step into examples/coweeta/ needed: re-run the notebook and
# its outputs land here directly.
ELM_OUTPUT_DIR="${ELM_ATS_SRC_DIR}/watershed_workflow/examples/Coweeta/elm_output_data"

DOMAIN_FILE=coweeta_domain.nc
ATS_XML_STAGE1A=coweeta_stage1a.xml
ATS_XML_STAGE2=coweeta_stage2.xml
ATS_XML_STAGE3=coweeta_stage3.xml
USER_NL_ELM_STAGE1B=user_nl_elm_stage1b
USER_NL_ELM_STAGE2=user_nl_elm_stage2
USER_NL_ELM_STAGE3=user_nl_elm_stage3
MEAN_PRECIP_FILE=coweeta_mean_precip_rain_mps.txt
PRECIP_ET_FACTOR=0.6

# Stage run-length/date constants -- hoisted here (rather than defined inline
# in each stage's block below) since later stages' RUN_REFDATE computations
# depend on earlier stages' START_YEAR/STOP_N even when this invocation only
# builds the later stage and skips the earlier one.
STAGE1B_START_YEAR=1
STAGE1B_STOP_N=200
STAGE2_START_YEAR=1
STAGE2_STOP_N=10

# user_nl_elm content (fsurdat, metdata_bypass, finidat, ats_inputfile, ...)
# is written entirely by coweeta_elm_ats.ipynb -- see that notebook's Stage
# 1b/2/3 sections (writeUserNlElmStage1b/2/3()) -- since user_nl_elm is ELM's
# own input file, exactly like the ATS XML, and belongs alongside it rather
# than as a heredoc in this general CIME-orchestration script. This script
# only copies the finished file into each case directory before case.setup.

# Derived case directories
DIR_1A="${CAMPAIGN_DIR}/1a_ats_spinup"
DIR_1B="${CAMPAIGN_DIR}/1b_elm_carbon_spinup"
DIR_2="${CAMPAIGN_DIR}/2_cyclic_steadystate"
DIR_3="${CAMPAIGN_DIR}/3_transient"

mkdir -p "${CAMPAIGN_DIR}"

echo ""
echo "================================================================="
echo " Building coweeta spinup campaign in ${CAMPAIGN_DIR}"
echo "================================================================="

# ---------------------------------------------------------------------------
# Stage all shared input data into CAMPAIGN_DIR/inputdata once, up front.
# All cases below reference this single shared location rather than keeping
# private copies, so CAMPAIGN_DIR is a single self-contained directory that
# can be rsynced onto HPC scratch space to run the whole campaign.
# ---------------------------------------------------------------------------
source "${ELM_ATS_SRC_DIR}/examples/coweeta/stage_inputdata.sh"

# ---------------------------------------------------------------------------
# Verify NTASKS matches the mesh partition count baked into
# coweeta_np${NTASKS}.exo by coweeta_elm_ats.ipynb's
# m2.partition(int(os.environ['NTASKS'])) call. The filename tag is the
# first guard against a mismatch (stage_inputdata.sh already warns if it's
# missing); this reads the partition count out of the mesh itself as a
# second, independent guard, in case a file was ever renamed by hand.
# writeExodus('one block') stores partition assignment as a named element
# variable ("partition") in the exodus file, so this is checkable directly
# from the mesh file without re-running the notebook or needing the full
# watershed_workflow/ATS Python environment -- only netCDF4.
# ---------------------------------------------------------------------------
MESH_FILE="${DIN_LOC_CAMPAIGN}/coweeta_np${NTASKS}.exo"

if [ ! -f "${MESH_FILE}" ]; then
    echo "ERROR: ${MESH_FILE} not found."
    echo "       Run coweeta_elm_ats.ipynb with NTASKS=${NTASKS} in its"
    echo "       environment and copy its output into examples/coweeta/."
    exit 1
fi

MESH_PARTITION_COUNT=$(python3 -c "
import netCDF4
import numpy as np
ds = netCDF4.Dataset('${MESH_FILE}')
name_var = ds.variables['name_elem_var'][:]
names = [name_var[i].tobytes().split(b'\x00')[0].decode('utf-8', errors='ignore')
         for i in range(name_var.shape[0])]
idx = names.index('partition') + 1  # exodus element var indices are 1-based
vals = ds.variables[f'vals_elem_var{idx}eb1'][:]
print(len(np.unique(vals)))
")

if [ "${MESH_PARTITION_COUNT}" != "${NTASKS}" ]; then
    echo "ERROR: NTASKS=${NTASKS} does not match the mesh partition count"
    echo "       (${MESH_PARTITION_COUNT}) baked into ${MESH_FILE}."
    echo "       Re-run coweeta_elm_ats.ipynb with NTASKS=${NTASKS} in its"
    echo "       environment, copy the new coweeta_np${NTASKS}.exo/.h5 and"
    echo "       coweeta_stage*.xml into examples/coweeta/, and re-run this script."
    exit 1
fi
echo "  NTASKS=${NTASKS} matches mesh partition count (${MESH_PARTITION_COUNT})"


# ---------------------------------------------------------------------------
# Stage 1a: ATS-only steady-state spinup
# ---------------------------------------------------------------------------
# This is a pure ATS run -- no CIME case needed. The XML (case file) lives in
# DIR_1A. coweeta_elm_ats.ipynb's Stage 1a section writes mesh references in
# the XML as the literal placeholder DIN_LOC_CAMPAIGN/coweeta_np<NTASKS>.exo;
# the sed substitution below rewrites that token to the actual absolute
# DIN_LOC_CAMPAIGN path when the file is copied into DIR_1A. The mesh itself
# lives only once, in DIN_LOC_CAMPAIGN (staged above).
#
# coweeta_elm_ats.ipynb writes coweeta_stage1a.xml with a placeholder token,
# STEADYSTATE_PRECIP_MPS, in place of the steady-state surface-precipitation
# value (that notebook does not download meteorology). coweeta_aorc_elm.ipynb
# separately downloads AORC and writes the domain/time-mean rain rate [m/s] to
# coweeta_mean_precip_rain_mps.txt. Here we merge the two: substitute the
# placeholder with PRECIP_ET_FACTOR times that mean rate (reduced to roughly
# account for ET, so the steady state isn't oversaturated).
# ---------------------------------------------------------------------------
if ${RUN_1A}; then
echo ""
echo "--- Stage 1a: ATS-only steady-state spinup ---"
mkdir -p "${DIR_1A}/run"

if [ ! -f "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE1A}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${ATS_XML_STAGE1A} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi
if [ ! -f "${DIN_LOC_CAMPAIGN}/${MEAN_PRECIP_FILE}" ]; then
    echo "ERROR: ${DIN_LOC_CAMPAIGN}/${MEAN_PRECIP_FILE} not found. Run coweeta_aorc_elm.ipynb first."
    exit 1
fi

MEAN_PRECIP_MPS=$(cat "${DIN_LOC_CAMPAIGN}/${MEAN_PRECIP_FILE}")
STEADYSTATE_PRECIP_MPS=$(python3 -c "print(${PRECIP_ET_FACTOR} * ${MEAN_PRECIP_MPS})")

sed -e "s/STEADYSTATE_PRECIP_MPS/${STEADYSTATE_PRECIP_MPS}/g" \
    -e "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE1A}" > "${DIR_1A}/${ATS_XML_STAGE1A}"

echo "  Created ${DIR_1A}"
echo "  Steady-state precip = ${PRECIP_ET_FACTOR} x ${MEAN_PRECIP_MPS} = ${STEADYSTATE_PRECIP_MPS} m/s"
echo "  To run: cd ${DIR_1A}/run && mpiexec -n ${NTASKS} ats --xml_file=../${ATS_XML_STAGE1A}"
fi


# ---------------------------------------------------------------------------
# Stage 1b: ELM carbon spinup (accelerated decomposition, cyclic forcing)
# ---------------------------------------------------------------------------
# ATS is not involved in this stage: no use_ats/domain_decomp_type/
# ats_inputdir/ats_inputfile in the namelist below. ELM uses its own native
# hydrology, but runs on the same per-cell domain decomposition as the ATS
# mesh (via ATM/LND_DOMAIN_FILE), so its restart state lines up with the
# coupled stages that follow. Runs for ~200 years with const_climate_hist
# and accelerated decomposition (nyears_ad_carbon_only / spinup_mortality_factor).
# ---------------------------------------------------------------------------
if ${RUN_1B}; then
echo ""
echo "--- Stage 1b: ELM carbon spinup ---"

if [ ! -f "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE1B}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE1B} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi

${E3SM_SRC_DIR}/cime/scripts/create_newcase \
    --case "${DIR_1B}" \
    --res ELM_USRDAT \
    --mach "${MACHINE_NAME}" \
    --compiler "${COMPILER_NAME}" \
    --compset "${COMPSET}"

sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE1B}" > "${DIR_1B}/user_nl_elm"
cd "${DIR_1B}"

# RUNDIR/EXEROOT default (from machine config) to $ELM_ATS_SRC_DIR/work/$CASE,
# one level shallower than this campaign's nested case directories -- set
# explicitly so the run/build dirs land under DIR_1B regardless of machine config.
./xmlchange RUNDIR="${DIR_1B}/run"
./xmlchange EXEROOT="${DIR_1B}/bld"

# Domain and surface data -- read directly from the shared campaign inputdata,
# no per-case copy
./xmlchange ELM_USRDAT_NAME=${NAME}
./xmlchange ATM_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange LND_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange ATM_DOMAIN_FILE="${DOMAIN_FILE}"
./xmlchange LND_DOMAIN_FILE="${DOMAIN_FILE}"

# Input data
./xmlchange MOSART_MODE=NULL,DOUT_S=FALSE,DIN_LOC_ROOT="${DIN_LOC_ROOT}"
./xmlchange DIN_LOC_ROOT_CLMFORC="${DIN_LOC_CAMPAIGN}/atm/datm7"

# Run length: 200 years of cyclic spinup, checkpointing every 2 years so a
# killed/interrupted run can be resumed from the latest restart file instead
# of starting over.
./xmlchange RUN_STARTDATE=$(printf '%04d-01-01' "${STAGE1B_START_YEAR}")
./xmlchange STOP_OPTION=nyears,STOP_N=${STAGE1B_STOP_N}
./xmlchange REST_OPTION=nyears,REST_N=2
./xmlchange NTASKS=${NTASKS}
./xmlchange NTASKS_PER_INST=${NTASKS}
./xmlchange PIO_TYPENAME=netcdf
./xmlchange BATCH_SYSTEM=none
./xmlchange DEBUG=FALSE

./case.setup
echo -e '\nstring(APPEND CPPDEFS " -DCPL_BYPASS -DUSE_ATS_LIB")' >> cmake_macros/universal.cmake
./case.build

echo "  Created ${DIR_1B}"
echo "  To run: pushd ${DIR_1B} && ./case.submit"
cd "${ELM_ATS_SRC_DIR}/examples/coweeta"
fi


# ---------------------------------------------------------------------------
# Stage 2: ELM+ATS cyclic steady-state (~10 yr, IC from stages 1a and 1b)
# ---------------------------------------------------------------------------
# RUN_TYPE=hybrid. ELM state restarts from stage 1b's finidat (already
# baked into user_nl_elm_stage2 by coweeta_elm_ats.ipynb's
# writeUserNlElmStage2()); ATS pressure restarts from stage 1a's
# checkpoint_final.h5 (already baked into coweeta_stage2.xml by that
# notebook's Stage 2 section). Runs ~10 years of cyclic forcing to reach
# coupled steady state.
# ---------------------------------------------------------------------------
if ${RUN_2}; then
echo ""
echo "--- Stage 2: ELM+ATS cyclic steady-state ---"

if [ ! -f "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE2}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${ATS_XML_STAGE2} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi
if [ ! -f "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE2}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE2} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi

${E3SM_SRC_DIR}/cime/scripts/create_newcase \
    --case "${DIR_2}" \
    --res ELM_USRDAT \
    --mach "${MACHINE_NAME}" \
    --compiler "${COMPILER_NAME}" \
    --compset "${COMPSET}"

sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE2}" > "${DIR_2}/${ATS_XML_STAGE2}"
sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE2}" > "${DIR_2}/user_nl_elm"
cd "${DIR_2}"

# RUNDIR/EXEROOT default (from machine config) to $ELM_ATS_SRC_DIR/work/$CASE,
# one level shallower than this campaign's nested case directories -- set
# explicitly so the run/build dirs land under DIR_2 regardless of machine config.
./xmlchange RUNDIR="${DIR_2}/run"
./xmlchange EXEROOT="${DIR_2}/bld"

# Domain and surface data -- read directly from the shared campaign inputdata,
# no per-case copy
./xmlchange ELM_USRDAT_NAME=${NAME}
./xmlchange ATM_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange LND_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange ATM_DOMAIN_FILE="${DOMAIN_FILE}"
./xmlchange LND_DOMAIN_FILE="${DOMAIN_FILE}"

# Input data
./xmlchange MOSART_MODE=NULL,DOUT_S=FALSE,DIN_LOC_ROOT="${DIN_LOC_ROOT}"
./xmlchange DIN_LOC_ROOT_CLMFORC="${DIN_LOC_CAMPAIGN}/atm/datm7"

# Hybrid start from end of stage 1b
./xmlchange RUN_TYPE=hybrid
./xmlchange RUN_REFCASE=$(basename "${DIR_1B}")
./xmlchange RUN_REFDATE=$(printf '%04d-01-01' "$((STAGE1B_START_YEAR + STAGE1B_STOP_N))")
./xmlchange RUN_REFTOD=0
./xmlchange RUN_STARTDATE=$(printf '%04d-01-01' "${STAGE2_START_YEAR}")

# Run length: 10 years of cyclic spinup
./xmlchange STOP_OPTION=nyears,STOP_N=${STAGE2_STOP_N}
./xmlchange NTASKS=${NTASKS}
./xmlchange NTASKS_PER_INST=${NTASKS}
./xmlchange PIO_TYPENAME=netcdf
./xmlchange BATCH_SYSTEM=none
./xmlchange DEBUG=FALSE

# ATS XML's mesh reference (written by coweeta_elm_ats.ipynb as the literal
# placeholder DIN_LOC_CAMPAIGN/coweeta_np<NTASKS>.exo) was rewritten above to
# the actual absolute DIN_LOC_CAMPAIGN path by the sed substitution when the
# file was copied into DIR_2. Its restart-file reference to stage 1a's
# checkpoint (../../1a_ats_spinup/run/checkpoint_final.h5) is already correct
# relative to DIR_2/run/, since that's a campaign-relative sibling path, not
# an inputdata path. user_nl_elm (fsurdat/finidat/metdata_bypass/ats_inputfile)
# was already copied into place above, before case.setup.

./case.setup
echo -e '\nstring(APPEND CPPDEFS " -DCPL_BYPASS -DUSE_ATS_LIB")' >> cmake_macros/universal.cmake
./case.build

echo "  Created ${DIR_2}"
echo "  ELM finidat  : ../1b_elm_carbon_spinup/run/1b_elm_carbon_spinup.elm.r.0201-01-01-00000.nc"
echo "  ATS restart  : ../1a_ats_spinup/run/checkpoint_final.h5"
echo "  (both paths are set now, but the files won't exist until stages 1a/1b actually run)"
echo "  To run: pushd ${DIR_2} && ./case.submit"
cd "${ELM_ATS_SRC_DIR}/examples/coweeta"
fi


# ---------------------------------------------------------------------------
# Stage 3: ELM+ATS transient run (IC from stage 2)
# ---------------------------------------------------------------------------
# RUN_TYPE=hybrid, initialized from the end of stage 2. Uses transient met
# forcing (const_climate_hist=.false.) and the actual simulation calendar.
#
# Note RUN_REFDATE (the date stamped on stage 2's restart file, which uses
# stage 2's own synthetic 1-based calendar) is independent of RUN_STARTDATE
# (this run's own clock, an actual calendar date) -- CIME's hybrid restart
# reads state from the reference file but starts the new run's clock fresh
# at RUN_STARTDATE.
# ---------------------------------------------------------------------------
if ${RUN_3}; then
echo ""
echo "--- Stage 3: Transient run ---"

if [ ! -f "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE3}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${ATS_XML_STAGE3} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi
if [ ! -f "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE3}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE3} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi

${E3SM_SRC_DIR}/cime/scripts/create_newcase \
    --case "${DIR_3}" \
    --res ELM_USRDAT \
    --mach "${MACHINE_NAME}" \
    --compiler "${COMPILER_NAME}" \
    --compset "${COMPSET}"

sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE3}" > "${DIR_3}/${ATS_XML_STAGE3}"
sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE3}" > "${DIR_3}/user_nl_elm"
cd "${DIR_3}"

# RUNDIR/EXEROOT default (from machine config) to $ELM_ATS_SRC_DIR/work/$CASE,
# one level shallower than this campaign's nested case directories -- set
# explicitly so the run/build dirs land under DIR_3 regardless of machine config.
./xmlchange RUNDIR="${DIR_3}/run"
./xmlchange EXEROOT="${DIR_3}/bld"

# Domain and surface data -- read directly from the shared campaign inputdata,
# no per-case copy
./xmlchange ELM_USRDAT_NAME=${NAME}
./xmlchange ATM_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange LND_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange ATM_DOMAIN_FILE="${DOMAIN_FILE}"
./xmlchange LND_DOMAIN_FILE="${DOMAIN_FILE}"

# Input data
./xmlchange MOSART_MODE=NULL,DOUT_S=FALSE,DIN_LOC_ROOT="${DIN_LOC_ROOT}"
./xmlchange DIN_LOC_ROOT_CLMFORC="${DIN_LOC_CAMPAIGN}/atm/datm7"

# Hybrid start from end of stage 2
STAGE3_STARTDATE=2000-10-01  # actual transient start date

./xmlchange RUN_TYPE=hybrid
./xmlchange RUN_REFCASE=$(basename "${DIR_2}")
./xmlchange RUN_REFDATE=$(printf '%04d-01-01' "$((STAGE2_START_YEAR + STAGE2_STOP_N))")
./xmlchange RUN_REFTOD=0
./xmlchange RUN_STARTDATE=${STAGE3_STARTDATE}

# Run length
./xmlchange STOP_OPTION=nyears,STOP_N=20
./xmlchange NTASKS=${NTASKS}
./xmlchange NTASKS_PER_INST=${NTASKS}
./xmlchange PIO_TYPENAME=netcdf
./xmlchange BATCH_SYSTEM=none
./xmlchange DEBUG=FALSE

# ATS XML's mesh reference (written by coweeta_elm_ats.ipynb as the literal
# placeholder DIN_LOC_CAMPAIGN/coweeta_np<NTASKS>.exo) was rewritten above to
# the actual absolute DIN_LOC_CAMPAIGN path by the sed substitution when the
# file was copied into DIR_3. Its restart-file reference to stage 2's
# checkpoint (../../2_cyclic_steadystate/run/checkpoint_final.h5) is already
# correct relative to DIR_3/run/, since that's a campaign-relative sibling
# path, not an inputdata path. user_nl_elm was already copied into place
# above, before case.setup.

./case.setup
echo -e '\nstring(APPEND CPPDEFS " -DCPL_BYPASS -DUSE_ATS_LIB")' >> cmake_macros/universal.cmake
./case.build

echo "  Created ${DIR_3}"
echo "  ELM finidat  : ../2_cyclic_steadystate/run/2_cyclic_steadystate.elm.r.0011-01-01-00000.nc"
echo "  ATS restart  : ../2_cyclic_steadystate/run/checkpoint_final.h5"
echo "  (both paths are set now, but the files won't exist until stage 2 actually runs)"
echo "  To run: pushd ${DIR_3} && ./case.submit"
cd "${ELM_ATS_SRC_DIR}/examples/coweeta"
fi


# ---------------------------------------------------------------------------
echo ""
echo "================================================================="
echo " Requested stage(s) built in campaign ${CAMPAIGN_DIR}"
echo " (rsync this whole directory, including inputdata/, to run elsewhere)"
echo ""
echo " Restart/IC wiring (finidat and ATS restart file) is set for every"
echo " stage built below -- each stage must simply be run in order, since"
echo " its ICs are read from files the previous stage's case.submit produces:"
echo ""
if ${RUN_1A}; then
echo "  1a. ATS steady-state spinup (manual ATS run):"
echo "        cd ${DIR_1A}/run && mpiexec -n ${NTASKS} ats --xml_file=../${ATS_XML_STAGE1A}"
echo ""
fi
if ${RUN_1B}; then
echo "  1b. ELM carbon spinup:"
echo "        pushd ${DIR_1B} && ./case.submit"
echo ""
fi
if ${RUN_2}; then
echo "  2.  ELM+ATS cyclic steady-state (after 1a and 1b complete):"
echo "        pushd ${DIR_2} && ./case.submit"
echo ""
fi
if ${RUN_3}; then
echo "  3.  Transient run (after stage 2 completes):"
echo "        pushd ${DIR_3} && ./case.submit"
echo ""
fi
echo "================================================================="
