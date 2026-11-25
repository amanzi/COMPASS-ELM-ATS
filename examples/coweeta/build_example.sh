#!/usr/bin/env bash
# build_example.sh -- Create all four cases for the coweeta multi-stage spinup workflow.
#
# Usage:
#   ./build_example.sh [STAGE ...]
#
# With no arguments, builds the four main campaign stages (1a 1c 2 3) in
# order. Pass one or more stage names to build only those, e.g.
# `./build_example.sh 2` to rebuild just stage 2 while iterating on it, or
# `./build_example.sh 1c 2` to rebuild both. Stages are always attempted in
# canonical order (1a, 1c, 2, 3, 3b) regardless of the order given on the
# command line. Building a later stage alone assumes any earlier stage it
# depends on (for restart/IC wiring) was already built in a previous
# invocation -- this script does not check that.
#
# Stage 3b is NOT part of the default (no-argument) build -- it is an
# independent, optional comparison branch that only depends on stage 1a
# (not 1c/2/3), so it must be requested explicitly:
# `./build_example.sh 1a 3b`.
#
# Stages:
#   1a. ATS-only steady-state spinup (directory only, no CIME case)
#   1c. Spatially-reduced, one-flat-column-per-PFT ELM carbon spinup with
#       accelerated decomposition (~200 yr, cyclic forcing, no ATS at all).
#       Part of the default build: stage 2's ELM initial condition (carbon/
#       nitrogen/phosphorus pools, vegetation biomass) is derived from this
#       stage's restart, broadcast onto the full mesh by PFT type (see the
#       "Deriving stage 2 finidat" block below and
#       examples/coweeta/distribute_pft_finidat.py).
#   2.  ELM+ATS cyclic steady-state spinup (~10 yr, cyclic forcing, IC from
#       1a and a PFT-broadcast finidat derived from 1c's restart)
#   3.  ELM+ATS transient run (IC from stage 2)
#   3b. ELM+ATS transient run in Satellite Phenology (SP) mode -- prescribed
#       MODIS-derived monthly LAI/PFT climatology instead of CN-predicted
#       phenology, sidestepping stages 1c/2's CN spinup entirely. Restarts
#       ATS pressure directly from stage 1a (not stage 2) and starts ELM
#       cold (no finidat -- SP mode carries no carbon/nitrogen state).
#       Optional/independent: depends only on stage 1a, not 1c/2/3, and is
#       not part of the default build set (see above).
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
# No arguments -> build the four main campaign stages (1a 1c 2 3). Stage 3b
# is NOT included in the default build -- it's an independent, optional
# comparison branch depending only on stage 1a -- and must be named
# explicitly, e.g. `./build_example.sh 1a 3b`. Otherwise, build only the
# stages named on the command line (in canonical order, not command-line
# order).
if [ "$#" -eq 0 ]; then
    RUN_1A=true; RUN_1C=true; RUN_2=true; RUN_3=true; RUN_3B=false
else
    RUN_1A=false; RUN_1C=false; RUN_2=false; RUN_3=false; RUN_3B=false
    for stage in "$@"; do
        case "${stage}" in
            1a) RUN_1A=true ;;
            1c) RUN_1C=true ;;
            2)  RUN_2=true ;;
            3)  RUN_3=true ;;
            3b) RUN_3B=true ;;
            *)
                echo "ERROR: unknown stage '${stage}' (expected one or more of: 1a 1c 2 3 3b)"
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
# Stage 3b runs ELM in Satellite Phenology mode -- ICBELMBC selects SP mode
# intrinsically (same compset examples/oakharbor_column uses), unlike the CN
# compset above, so it needs no ELM_BLDNML_OPTS override.
COMPSET_STAGE3B="ICBELMBC"
E3SM_SRC_DIR="${ELM_ATS_SRC_DIR}/E3SM"
DIN_LOC_ROOT="${ELM_ATS_SRC_DIR}/inputdata"       # global mirror, read-only
DIN_LOC_CAMPAIGN="${CAMPAIGN_DIR}/inputdata"       # campaign-local, populated

# coweeta_elm_ats.ipynb's fixed output directory -- holds the mesh, domain,
# surfdata, ATS XMLs, and user_nl_elm files this script reads below. No
# manual copy step into examples/coweeta/ needed: re-run the notebook and
# its outputs land here directly.
ELM_OUTPUT_DIR="${ELM_ATS_SRC_DIR}/watershed_workflow/examples/Coweeta/elm_output_data"

DOMAIN_FILE=coweeta_domain.nc
SURFDATA_FILE=coweeta_surfdata.nc
DOMAIN_FILE_STAGE1C=coweeta_1c_domain.nc
SURFDATA_FILE_STAGE1C=coweeta_1c_surfdata.nc
ATS_XML_STAGE1A=coweeta_stage1a.xml
ATS_XML_STAGE2=coweeta_stage2.xml
ATS_XML_STAGE3=coweeta_stage3.xml
ATS_XML_STAGE3B=coweeta_stage3b.xml
USER_NL_ELM_STAGE1C=user_nl_elm_stage1c
USER_NL_ELM_STAGE2=user_nl_elm_stage2
USER_NL_ELM_STAGE3=user_nl_elm_stage3
USER_NL_ELM_STAGE3B=user_nl_elm_stage3b
SURFDATA_FILE_STAGE3B=coweeta_stage3b_surfdata.nc
MEAN_PRECIP_FILE=coweeta_mean_precip_rain_mps.txt
PRECIP_ET_FACTOR=0.6

# Script that broadcasts stage 1c's per-PFT ELM restart onto the full mesh
# (by PFT type -- see the "Deriving stage 2 finidat" block below), and the
# crosswalk/output filenames it consumes/produces.
DISTRIBUTE_SCRIPT="${ELM_ATS_SRC_DIR}/examples/coweeta/distribute_pft_finidat.py"
PFT_CROSSWALK_FILE=coweeta_1c_pft_crosswalk.json
FINIDAT_STAGE2_FILE=coweeta_stage2_finidat.nc

# Stage run-length/date constants -- hoisted here (rather than defined inline
# in each stage's block below) since later stages' RUN_REFDATE computations
# depend on earlier stages' START_YEAR/STOP_N even when this invocation only
# builds the later stage and skips the earlier one. STAGE3_STARTDATE is
# likewise hoisted (not just defined inline in stage 3's block) since stage
# 3b needs the same transient start date and may be built without stage 3.
STAGE1C_START_YEAR=1
STAGE1C_STOP_N=200
STAGE2_START_YEAR=1
STAGE2_STOP_N=10
STAGE3_STARTDATE=2010-10-01  # actual transient start date -- must fall within
# atm_forcing_transient's real coverage (start_year/end_year baked into its
# ATS-subdaily_*.nc files by coweeta_aorc_elm.ipynb, currently 2010-2022);
# a start date before start_year hits the same out-of-bounds forcing-record
# page read that the oakharbor_column CPL_BYPASS fix addressed. Shared by
# stages 3 and 3b.
STAGE3_STOP_N=3  # ~2010-10-01 to 2013-10-01 -- kept inside the 2010-2014
# window covered by the MODIS LAI/LULC data cached for stage 3b's Satellite
# Phenology surfdata (see coweeta_elm_ats.py's modis_start_year/
# modis_end_year), even though atm_forcing_transient's own AORC coverage
# extends further (to 2022). Shared by stages 3 and 3b so both stay
# consistent with the same simulated period.

# user_nl_elm content (fsurdat, metdata_bypass, finidat, ats_inputfile, ...)
# is written entirely by coweeta_elm_ats.ipynb -- see that notebook's Stage
# 1c/2/3 sections (writeUserNlElmStage1c/2/3()) -- since user_nl_elm is ELM's
# own input file, exactly like the ATS XML, and belongs alongside it rather
# than as a heredoc in this general CIME-orchestration script. This script
# only copies the finished file into each case directory before case.setup.

# Derived case directories
DIR_1A="${CAMPAIGN_DIR}/1a_ats_spinup"
DIR_1C="${CAMPAIGN_DIR}/1c_pft_columns"
DIR_2="${CAMPAIGN_DIR}/2_cyclic_steadystate"
DIR_3="${CAMPAIGN_DIR}/3_transient"
DIR_3B="${CAMPAIGN_DIR}/3b_transient_sp"

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
# Stage 1c: spatially-reduced, one-flat-column-per-PFT ELM carbon spinup
# ---------------------------------------------------------------------------
# No ATS involvement at all -- no ATS XML, no domain_decomp_type, no
# ats_inputdir/ats_inputfile. Runs on a synthetic domain/surfdata pair (one
# flat gridcell per PFT present in Coweeta, each 100% covered by that PFT,
# all at the same representative centroid position/soil type) built by
# coweeta_elm_ats.ipynb's Stage 1c section, driven by cyclic forcing (see
# writeUserNlElmStage1c()). This stage's restart is stage 2's ELM initial
# condition: the "Deriving stage 2 finidat" block below broadcasts each of
# these per-PFT columns' full state (carbon/nitrogen/phosphorus pools,
# vegetation biomass) onto every full-mesh cell that shares its PFT type,
# via examples/coweeta/distribute_pft_finidat.py. Serial (NTASKS=1): a
# handful of gridcells, no ATS mesh-partition file to keep in sync, no need
# for parallelism -- this is what makes it affordable to run the 200-year
# accelerated-decomposition spinup that would be too expensive on the full
# ~2700-cell mesh.
# ---------------------------------------------------------------------------
if ${RUN_1C}; then
echo ""
echo "--- Stage 1c: spatially-reduced per-PFT ELM carbon spinup ---"

if [ ! -f "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE1C}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE1C} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi
if [ ! -f "${DIN_LOC_CAMPAIGN}/${DOMAIN_FILE_STAGE1C}" ]; then
    echo "ERROR: ${DIN_LOC_CAMPAIGN}/${DOMAIN_FILE_STAGE1C} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi
if [ ! -f "${DIN_LOC_CAMPAIGN}/${SURFDATA_FILE_STAGE1C}" ]; then
    echo "ERROR: ${DIN_LOC_CAMPAIGN}/${SURFDATA_FILE_STAGE1C} not found. Run coweeta_elm_ats.ipynb first."
    exit 1
fi

${E3SM_SRC_DIR}/cime/scripts/create_newcase \
    --case "${DIR_1C}" \
    --res ELM_USRDAT \
    --mach "${MACHINE_NAME}" \
    --compiler "${COMPILER_NAME}" \
    --compset "${COMPSET}"

sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE1C}" > "${DIR_1C}/user_nl_elm"
cd "${DIR_1C}"

# RUNDIR/EXEROOT default (from machine config) to $ELM_ATS_SRC_DIR/work/$CASE,
# one level shallower than this campaign's nested case directories -- set
# explicitly so the run/build dirs land under DIR_1C regardless of machine config.
./xmlchange RUNDIR="${DIR_1C}/run"
./xmlchange EXEROOT="${DIR_1C}/bld"

# Domain and surface data -- stage 1c's own synthetic per-PFT files, not the
# full Coweeta domain -- read directly from the shared campaign inputdata,
# no per-case copy
./xmlchange ELM_USRDAT_NAME=${NAME}
./xmlchange ATM_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange LND_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange ATM_DOMAIN_FILE="${DOMAIN_FILE_STAGE1C}"
./xmlchange LND_DOMAIN_FILE="${DOMAIN_FILE_STAGE1C}"

# Input data
./xmlchange MOSART_MODE=NULL,DOUT_S=FALSE,DIN_LOC_ROOT="${DIN_LOC_ROOT}"
./xmlchange DIN_LOC_ROOT_CLMFORC="${DIN_LOC_CAMPAIGN}/atm/datm7"

# Run length: 200 years of cyclic spinup, checkpointing every 2 years so a
# killed/interrupted run can be resumed from the latest restart file instead
# of starting over.
./xmlchange RUN_STARTDATE=$(printf '%04d-01-01' "${STAGE1C_START_YEAR}")
./xmlchange STOP_OPTION=nyears,STOP_N=${STAGE1C_STOP_N}
./xmlchange REST_OPTION=nyears,REST_N=2
./xmlchange NTASKS=1
./xmlchange NTASKS_PER_INST=1
./xmlchange PIO_TYPENAME=netcdf
./xmlchange BATCH_SYSTEM=none
./xmlchange DEBUG=FALSE

# Real AD spinup requires -bgc_spinup on, which can only be set via the
# ELM_BLDNML_OPTS case-xml variable (build-namelist command-line flag) --
# spinup_state cannot be set directly in user_nl_elm (it's a *derived*
# namelist value; namelist_defaults.xml keys it off bgc_spinup on/off, and
# build-namelist fatal-errors if a direct spinup_state setting disagrees).
# ELM_BLDNML_OPTS is compset-derived and NOT additive (config_component.xml),
# so append to the exact existing value for this compset rather than
# overwriting. Without this, user_nl_elm's nyears_ad_carbon_only/
# spinup_mortality_factor are silently inert (spinup_state defaults to 0),
# while spinup_mortality_factor still applies unconditionally regardless of
# spinup_state (GapMortalityMod.F90 has no spinup_state gate) -- i.e. 10x
# mortality with none of AD's compensating fast decomposition/carbon-only
# allocation, which is not what this stage intends.
./xmlchange ELM_BLDNML_OPTS="-bgc bgc -nutrient cnp -nutrient_comp_pathway rd  -soil_decomp ctc -methane -bgc_spinup on"

./case.setup
echo -e '\nstring(APPEND CPPDEFS " -DCPL_BYPASS -DUSE_ATS_LIB")' >> cmake_macros/universal.cmake
./case.build

echo "  Created ${DIR_1C}"
echo "  To run: pushd ${DIR_1C} && ./case.submit"
cd "${ELM_ATS_SRC_DIR}/examples/coweeta"
fi


# ---------------------------------------------------------------------------
# Deriving stage 2 finidat: broadcast stage 1c's per-PFT restart onto the
# full mesh
# ---------------------------------------------------------------------------
# Stage 2's ELM initial condition (carbon/nitrogen/phosphorus pools,
# vegetation biomass) is derived from stage 1c's *actual* restart output, not
# a predicted filename -- unlike the old stage-1b lookup, there is no "assume
# the full run happened" fallback here, since distribute_pft_finidat.py needs
# real per-column state to broadcast, not just a filename to point finidat
# at. If stage 1c hasn't actually been run (case.submit, not just
# case.build) yet, fail here with a clear message rather than silently
# producing a garbage or missing finidat file.
# ---------------------------------------------------------------------------
if ${RUN_2}; then
echo ""
echo "--- Deriving stage 2 finidat from stage 1c's PFT-column restart ---"

STAGE1C_CASE="$(basename "${DIR_1C}")"
LATEST_1C_RESTART=$(ls "${DIR_1C}/run/${STAGE1C_CASE}.elm.r."????"-01-01-00000.nc" 2>/dev/null | sort | tail -1)
if [ -z "${LATEST_1C_RESTART}" ]; then
    echo "ERROR: no stage 1c restart file found at"
    echo "         ${DIR_1C}/run/${STAGE1C_CASE}.elm.r.<YYYY>-01-01-00000.nc"
    echo "       Stage 2's ELM initial condition is derived from stage 1c's"
    echo "       actual output (not a predicted filename) -- build and run"
    echo "       stage 1c first:"
    echo "         pushd ${DIR_1C} && ./case.submit"
    echo "       then re-run this script."
    exit 1
fi
echo "  Using stage 1c restart: ${LATEST_1C_RESTART}"

python3 "${DISTRIBUTE_SCRIPT}" \
    --stage1c-restart "${LATEST_1C_RESTART}" \
    --full-surfdata "${DIN_LOC_CAMPAIGN}/${SURFDATA_FILE}" \
    --crosswalk "${ELM_OUTPUT_DIR}/${PFT_CROSSWALK_FILE}" \
    --output "${DIN_LOC_CAMPAIGN}/${FINIDAT_STAGE2_FILE}"

if [ ! -f "${DIN_LOC_CAMPAIGN}/${FINIDAT_STAGE2_FILE}" ]; then
    echo "ERROR: distribute_pft_finidat.py did not produce ${DIN_LOC_CAMPAIGN}/${FINIDAT_STAGE2_FILE}"
    exit 1
fi
echo "  Wrote ${DIN_LOC_CAMPAIGN}/${FINIDAT_STAGE2_FILE}"
fi


# ---------------------------------------------------------------------------
# Stage 2: ELM+ATS cyclic steady-state (~10 yr, IC from stages 1a and 1c)
# ---------------------------------------------------------------------------
# RUN_TYPE=startup (cold start), with ELM state overridden by finidat --
# there is no real "reference case" to hybrid-restart from any more, since
# the finidat file is a freestanding NetCDF built by distribute_pft_finidat.py
# above, not a previous case's own restart output. (RUN_TYPE=hybrid would
# have ELM's buildnml also synthesize its own RUN_REFCASE-derived finidat
# guess pointing at a nonexistent file -- harmless today only because the
# explicit finidat in user_nl_elm is merged in afterwards and wins, but
# there's no reference case at all in this pipeline any more, so startup is
# the correct RUN_TYPE, not merely an equivalent one.) ATS pressure restarts
# from stage 1a's checkpoint_final.h5 (already baked into coweeta_stage2.xml
# by the notebook's Stage 2 section, and entirely independent of ELM's
# RUN_TYPE). Runs ~10 years of cyclic forcing to reach coupled steady state.
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
sed -e "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
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

# Cold start (startup), with ELM state overridden by finidat -- see block
# comment above for why this is startup, not hybrid.
./xmlchange RUN_TYPE=startup
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
# was already copied into place above, before case.setup; its finidat entry
# points at DIN_LOC_CAMPAIGN/coweeta_stage2_finidat.nc, written by the
# "Deriving stage 2 finidat" block above.

./case.setup
echo -e '\nstring(APPEND CPPDEFS " -DCPL_BYPASS -DUSE_ATS_LIB")' >> cmake_macros/universal.cmake
./case.build

echo "  Created ${DIR_2}"
echo "  ELM finidat  : ${DIN_LOC_CAMPAIGN}/${FINIDAT_STAGE2_FILE}"
echo "  ATS restart  : ../1a_ats_spinup/run/checkpoint_final.h5"
echo "  (ATS restart path is set now, but the file won't exist until stage 1a actually runs)"
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

# Same logic as stage 2's stage-1b lookup above: prefer stage 2's latest
# actual restart on disk (debug/iterate case), falling back to the filename
# its full STAGE2_STOP_N-year run will eventually produce if none exists yet
# (from-scratch build-everything-up-front case).
STAGE2_CASE="$(basename "${DIR_2}")"
LATEST_2_RESTART=$(ls "${DIR_2}/run/${STAGE2_CASE}.elm.r."????"-01-01-00000.nc" 2>/dev/null | sort | tail -1)
if [ -z "${LATEST_2_RESTART}" ]; then
    STAGE2_RESTART_YEAR=$((STAGE2_START_YEAR + STAGE2_STOP_N))
    LATEST_2_RESTART=$(printf '%s/run/%s.elm.r.%04d-01-01-00000.nc' "${DIR_2}" "${STAGE2_CASE}" "${STAGE2_RESTART_YEAR}")
    echo "  No stage 2 restart found yet -- assuming a full ${STAGE2_STOP_N}-year run:"
    echo "    ${LATEST_2_RESTART}"
else
    STAGE2_RESTART_YEAR=$(basename "${LATEST_2_RESTART}" | sed -E 's/.*\.elm\.r\.([0-9]{4})-01-01-00000\.nc/\1/')
    if [ "${STAGE2_RESTART_YEAR}" -lt "$((STAGE2_START_YEAR + STAGE2_STOP_N))" ]; then
        echo "  WARNING: using stage 2 restart at year ${STAGE2_RESTART_YEAR}, short of its"
        echo "           ${STAGE2_STOP_N}-year target -- coupled state may not be at cyclic steady state."
    fi
    echo "  Using stage 2 restart: ${LATEST_2_RESTART} (year ${STAGE2_RESTART_YEAR})"
fi

sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE3}" > "${DIR_3}/${ATS_XML_STAGE3}"
sed -e "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    -e "s|${STAGE2_CASE}\.elm\.r\.[0-9]\{4\}-01-01-00000\.nc|$(basename "${LATEST_2_RESTART}")|g" \
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

# Hybrid start from end of stage 2 (STAGE3_STARTDATE set in the shared
# constants block above)
./xmlchange RUN_TYPE=hybrid
./xmlchange RUN_REFCASE="${STAGE2_CASE}"
./xmlchange RUN_REFDATE=$(printf '%04d-01-01' "${STAGE2_RESTART_YEAR}")
./xmlchange RUN_REFTOD=0
./xmlchange RUN_STARTDATE=${STAGE3_STARTDATE}

# Run length
./xmlchange STOP_OPTION=nyears,STOP_N=${STAGE3_STOP_N}
./xmlchange NTASKS=${NTASKS}
./xmlchange NTASKS_PER_INST=${NTASKS}
./xmlchange PIO_TYPENAME=netcdf
./xmlchange BATCH_SYSTEM=none
./xmlchange DEBUG=FALSE

# ATS XML's mesh reference (written by coweeta_elm_ats.py as the literal
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
echo "  ELM finidat  : ../2_cyclic_steadystate/run/$(basename "${LATEST_2_RESTART}")"
echo "  ATS restart  : ../2_cyclic_steadystate/run/checkpoint_final.h5"
echo "  (ATS restart path is set now, but the file won't exist until stage 2 actually runs)"
echo "  To run: pushd ${DIR_3} && ./case.submit"
cd "${ELM_ATS_SRC_DIR}/examples/coweeta"
fi


# ---------------------------------------------------------------------------
# Stage 3b: ELM+ATS transient run, Satellite Phenology mode (IC from stage 1a
# only -- skips stages 1c/2 entirely)
# ---------------------------------------------------------------------------
# RUN_TYPE=startup (cold start), like stage 2 -- there is no ELM reference
# case to restart from here (SP mode carries no carbon/nitrogen state, and
# stage 3b never runs a coupled cyclic steady-state spinup), so no finidat is
# set at all. ATS pressure restarts from stage 1a's checkpoint_final.h5
# (already baked into coweeta_stage3b.xml by the notebook's Stage 3b section)
# instead of stage 2's or stage 3's. Uses the same transient AORC forcing and
# real calendar as stage 3. Built with COMPSET_STAGE3B (ICBELMBC, Satellite
# Phenology) instead of the campaign's default CN compset -- no
# ELM_BLDNML_OPTS override needed, since ICBELMBC selects SP mode
# intrinsically (see stage 1c's block above for why the CN stages need that
# override and this one doesn't).
# ---------------------------------------------------------------------------
if ${RUN_3B}; then
echo ""
echo "--- Stage 3b: Transient run (Satellite Phenology mode) ---"

if [ ! -d "${DIR_1A}" ]; then
    echo "ERROR: ${DIR_1A} not found. Stage 3b restarts ATS pressure from stage 1a's"
    echo "       checkpoint -- build and run stage 1a first:"
    echo "         ./build_example.sh 1a"
    echo "         cd ${DIR_1A}/run && mpiexec -n ${NTASKS} ats --xml_file=../${ATS_XML_STAGE1A}"
    echo "       then re-run this script with stage 3b."
    exit 1
fi
if [ ! -f "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE3B}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${ATS_XML_STAGE3B} not found. Run coweeta_elm_ats.py first."
    exit 1
fi
if [ ! -f "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE3B}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE3B} not found. Run coweeta_elm_ats.py first."
    exit 1
fi
if [ ! -f "${ELM_OUTPUT_DIR}/${SURFDATA_FILE_STAGE3B}" ]; then
    echo "ERROR: ${ELM_OUTPUT_DIR}/${SURFDATA_FILE_STAGE3B} not found. Run coweeta_elm_ats.py first."
    exit 1
fi

${E3SM_SRC_DIR}/cime/scripts/create_newcase \
    --case "${DIR_3B}" \
    --res ELM_USRDAT \
    --mach "${MACHINE_NAME}" \
    --compiler "${COMPILER_NAME}" \
    --compset "${COMPSET_STAGE3B}"

sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${ATS_XML_STAGE3B}" > "${DIR_3B}/${ATS_XML_STAGE3B}"
sed "s|DIN_LOC_CAMPAIGN|${DIN_LOC_CAMPAIGN}|g" \
    "${ELM_OUTPUT_DIR}/${USER_NL_ELM_STAGE3B}" > "${DIR_3B}/user_nl_elm"
cd "${DIR_3B}"

# RUNDIR/EXEROOT default (from machine config) to $ELM_ATS_SRC_DIR/work/$CASE,
# one level shallower than this campaign's nested case directories -- set
# explicitly so the run/build dirs land under DIR_3B regardless of machine config.
./xmlchange RUNDIR="${DIR_3B}/run"
./xmlchange EXEROOT="${DIR_3B}/bld"

# Domain and surface data -- read directly from the shared campaign inputdata,
# no per-case copy. Note fsurdat itself (the SP-mode surfdata with
# MONTHLY_LAI/etc.) is set in user_nl_elm, not here -- ATM/LND_DOMAIN_FILE is
# the coarser ELM_USRDAT domain file, shared with every other stage.
./xmlchange ELM_USRDAT_NAME=${NAME}
./xmlchange ATM_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange LND_DOMAIN_PATH="${DIN_LOC_CAMPAIGN}"
./xmlchange ATM_DOMAIN_FILE="${DOMAIN_FILE}"
./xmlchange LND_DOMAIN_FILE="${DOMAIN_FILE}"

# Input data
./xmlchange MOSART_MODE=NULL,DOUT_S=FALSE,DIN_LOC_ROOT="${DIN_LOC_ROOT}"
./xmlchange DIN_LOC_ROOT_CLMFORC="${DIN_LOC_CAMPAIGN}/atm/datm7"

# Cold start (startup) -- no ELM reference case, see block comment above.
./xmlchange RUN_TYPE=startup
./xmlchange RUN_STARTDATE=${STAGE3_STARTDATE}

# Run length -- same as stage 3 (STAGE3_STOP_N set in the shared constants
# block above)
./xmlchange STOP_OPTION=nyears,STOP_N=${STAGE3_STOP_N}
./xmlchange NTASKS=${NTASKS}
./xmlchange NTASKS_PER_INST=${NTASKS}
./xmlchange PIO_TYPENAME=netcdf
./xmlchange BATCH_SYSTEM=none
./xmlchange DEBUG=FALSE

# ATS XML's mesh reference (written by coweeta_elm_ats.py as the literal
# placeholder DIN_LOC_CAMPAIGN/coweeta_np<NTASKS>.exo) was rewritten above to
# the actual absolute DIN_LOC_CAMPAIGN path by the sed substitution when the
# file was copied into DIR_3B. Its restart-file reference to stage 1a's
# checkpoint (../../1a_ats_spinup/run/checkpoint_final.h5) is already correct
# relative to DIR_3B/run/, since that's a campaign-relative sibling path, not
# an inputdata path. user_nl_elm was already copied into place above, before
# case.setup.

./case.setup
echo -e '\nstring(APPEND CPPDEFS " -DCPL_BYPASS -DUSE_ATS_LIB")' >> cmake_macros/universal.cmake
./case.build

echo "  Created ${DIR_3B}"
echo "  ELM finidat  : (none -- cold start, Satellite Phenology mode)"
echo "  ATS restart  : ../1a_ats_spinup/run/checkpoint_final.h5"
echo "  (ATS restart path is set now, but the file won't exist until stage 1a actually runs)"
echo "  To run: pushd ${DIR_3B} && ./case.submit"
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
if ${RUN_1C}; then
echo "  1c. Spatially-reduced per-PFT ELM carbon spinup:"
echo "        pushd ${DIR_1C} && ./case.submit"
echo ""
fi
if ${RUN_2}; then
echo "  2.  ELM+ATS cyclic steady-state (after 1a and 1c complete):"
echo "        pushd ${DIR_2} && ./case.submit"
echo ""
fi
if ${RUN_3}; then
echo "  3.  Transient run (after stage 2 completes):"
echo "        pushd ${DIR_3} && ./case.submit"
echo ""
fi
if ${RUN_3B}; then
echo "  3b. Transient run, Satellite Phenology mode (after 1a completes only --"
echo "      independent of 1c/2/3):"
echo "        pushd ${DIR_3B} && ./case.submit"
echo ""
fi
echo "================================================================="
