#!/usr/bin/env bash
# stage_inputdata.sh -- Populate a campaign's shared inputdata/ directory.
#
# Sourced by build_example.sh. Given DIN_LOC_CAMPAIGN (the campaign's shared
# inputdata/ dir), DIN_LOC_ROOT (the global ELM inputdata mirror), and
# ELM_ATS_SRC_DIR, this copies:
#   - Coweeta-specific mesh/domain/surfdata/forcing files from
#     watershed_workflow/examples/Coweeta/elm_output_data/, the fixed output
#     directory both coweeta_elm_ats.py and coweeta_aorc_elm.ipynb write
#     to -- including the atm_forcing/ and atm_forcing_spinup/ directories
#     the latter notebook produces, stage 1c's synthetic per-PFT
#     domain/surfdata files (coweeta_1c_domain.nc/coweeta_1c_surfdata.nc),
#     and stage 3b's Satellite Phenology surfdata (coweeta_stage3b_surfdata.nc)
#
# into DIN_LOC_CAMPAIGN, so that only DIN_LOC_CAMPAIGN -- not the full global
# mirror -- needs to travel with the campaign (e.g. after an rsync to HPC
# scratch). The handful of global ELM datasets (aerosol deposition, CO2,
# population density, N deposition) that user_nl_elm references via
# $DIN_LOC_ROOT are left in place in DIN_LOC_ROOT and merely checked for
# existence here, not copied.
#
# Copies are idempotent (cp -n): safe to re-run against an existing campaign.
#
# Required variables (set by the caller):
#   DIN_LOC_CAMPAIGN -- campaign's shared inputdata/ directory
#   DIN_LOC_ROOT      -- global ELM inputdata mirror (read-only)
#   ELM_ATS_SRC_DIR   -- root of the ELM-ATS repository
#   NTASKS            -- MPI rank count; selects coweeta_np${NTASKS}.exo/.h5,
#                         the mesh partitioned for this task count by
#                         coweeta_elm_ats.ipynb's m2.partition() call

if [ -z "${DIN_LOC_CAMPAIGN}" ]; then
    echo "ERROR: DIN_LOC_CAMPAIGN must be set before sourcing stage_inputdata.sh"
    exit 1
fi
if [ -z "${DIN_LOC_ROOT}" ]; then
    echo "ERROR: DIN_LOC_ROOT must be set before sourcing stage_inputdata.sh"
    exit 1
fi
if [ -z "${ELM_ATS_SRC_DIR}" ]; then
    echo "ERROR: ELM_ATS_SRC_DIR must be set before sourcing stage_inputdata.sh"
    exit 1
fi
if [ -z "${NTASKS}" ]; then
    echo "ERROR: NTASKS must be set before sourcing stage_inputdata.sh"
    exit 1
fi

ELM_OUTPUT_DIR="${ELM_ATS_SRC_DIR}/watershed_workflow/examples/Coweeta/elm_output_data"

echo ""
echo "--- Staging campaign inputdata: ${DIN_LOC_CAMPAIGN} ---"

mkdir -p "${DIN_LOC_CAMPAIGN}"

# Mesh files are tagged with NTASKS (coweeta_np<N>.exo/.h5) since the mesh
# partition is fixed at build time and must match this run's MPI rank count
# -- see coweeta_elm_ats.ipynb's m2.partition(int(os.environ['NTASKS']))
# call. Copied no-clobber (cp -n): a later stage's ATS checkpoint restart is
# keyed to this exact partition, so once any stage has run against a given
# mesh file it must never be silently swapped out from under a resumed
# workflow.
for f in "coweeta_np${NTASKS}.exo" "coweeta_np${NTASKS}.h5"; do
    if [ -f "${ELM_OUTPUT_DIR}/${f}" ]; then
        cp -n "${ELM_OUTPUT_DIR}/${f}" "${DIN_LOC_CAMPAIGN}/" 2>/dev/null || true
    fi
done

# Domain / surfdata / soil properties / precip files: plain inputs with no
# restart-continuity constraint, so always refreshed from
# elm_output_data/ -- unlike the mesh above, re-running coweeta_elm_ats.ipynb
# (e.g. after a fsurdat/WATSAT change) must actually update the campaign copy
# rather than silently keeping a stale one (cp -n previously left these
# untouched on repeat runs, which is the bug this comment is warning against).
for f in coweeta_domain.nc coweeta_surfdata.nc coweeta_subsurface_properties.csv \
         coweeta_mean_precip_rain_mps.txt \
         coweeta_1c_domain.nc coweeta_1c_surfdata.nc coweeta_stage3b_surfdata.nc; do
    if [ -f "${ELM_OUTPUT_DIR}/${f}" ]; then
        cp "${ELM_OUTPUT_DIR}/${f}" "${DIN_LOC_CAMPAIGN}/"
    fi
done

if [ ! -f "${DIN_LOC_CAMPAIGN}/coweeta_np${NTASKS}.exo" ]; then
    echo "  WARNING: ${ELM_OUTPUT_DIR}/coweeta_np${NTASKS}.exo not found."
    echo "           Run coweeta_elm_ats.ipynb with NTASKS=${NTASKS} in its"
    echo "           environment (elm_output_data/ is written automatically)."
fi

# Met forcing directories (cpl_bypass format), from coweeta_aorc_elm.ipynb's
# fixed output directory names -- atm_forcing_spinup/ (cyclic, used by
# stages 1b/2) and atm_forcing/ (transient, used by stage 3, staged here as
# atm_forcing_transient to disambiguate from the spinup copy).
if [ -e "${ELM_OUTPUT_DIR}/atm_forcing_spinup" ] && [ ! -e "${DIN_LOC_CAMPAIGN}/atm_forcing_spinup" ]; then
    cp -rn "${ELM_OUTPUT_DIR}/atm_forcing_spinup" "${DIN_LOC_CAMPAIGN}/atm_forcing_spinup"
fi
if [ -e "${ELM_OUTPUT_DIR}/atm_forcing" ] && [ ! -e "${DIN_LOC_CAMPAIGN}/atm_forcing_transient" ]; then
    cp -rn "${ELM_OUTPUT_DIR}/atm_forcing" "${DIN_LOC_CAMPAIGN}/atm_forcing_transient"
fi

# Global ELM datasets (aero, CO2, popdens, ndep) -- read directly from
# DIN_LOC_ROOT via $DIN_LOC_ROOT in user_nl_elm; just checked for existence
# here, never copied.
AERO_FILE=atm/cam/chem/trop_mozart_aero/aero/aerosoldep_monthly_1850_mean_1.9x2.5_c090421.nc
CO2_FILE=atm/datm7/CO2/fco2_datm_1765-2007_c100614.nc
POPDENS_FILE=lnd/clm2/firedata/clmforc.Li_2012_hdm_0.5x0.5_AVHRR_simyr1850-2010_c130401.nc
NDEP_FILE=lnd/clm2/ndepdata/fndep_elm_cbgc_exp_simyr1849-2101_1.9x2.5_c190103.nc

for f in "${AERO_FILE}" "${CO2_FILE}" "${POPDENS_FILE}" "${NDEP_FILE}"; do
    if [ ! -f "${DIN_LOC_ROOT}/${f}" ]; then
        echo "  WARNING: ${DIN_LOC_ROOT}/${f} not found (needed via \$DIN_LOC_ROOT in user_nl_elm)"
    fi
done

echo "--- Campaign inputdata staged at ${DIN_LOC_CAMPAIGN} ---"
