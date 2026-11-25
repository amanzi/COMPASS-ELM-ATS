# Coweeta ELM+ATS Multi-Stage Spinup

This directory builds the coupled ELM+ATS simulation of the Coweeta watershed
via a four-stage spinup workflow, driven by `build_example.sh`. Each stage
initializes from the previous stage's final state, so they must be run in
order.

A fifth, optional stage (3b) provides an independent comparison run in
Satellite Phenology mode -- see "Stage 3b" below. Unlike 1a/1c/2/3, it does
not depend on the other stages beyond 1a, and is not built by default.

(The older single-case, non-spinup `build_example.sh` this replaced has been
removed now that the multi-stage workflow is working end to end.)

## The four stages

**Stage 1a -- ATS-only steady-state spinup**
A pure ATS run, uncoupled from ELM. Drives the mesh with a spatially
uniform, constant-in-time precipitation rate (derived from the domain- and
time-mean AORC rain rate) until subsurface + surface flow reach steady
state. This is not a CIME case -- it's a bare ATS run in
`1a_ats_spinup/run/`. Its role is to produce a physically reasonable
starting pressure field for the coupled runs, without waiting on ELM's much
slower carbon spinup.

**Stage 1b -- ELM carbon spinup (ELM-only, no ATS)**
Runs ELM by itself -- native ELM hydrology, no ATS coupling -- for ~200
years with accelerated decomposition (`nyears_ad_carbon_only`,
`spinup_mortality_factor`) and cyclic ("typical year") forcing. Its role is
to spin up carbon/nitrogen pools to equilibrium before the coupled run,
which would be far too slow to do with ATS's subsurface solve in the loop.
Runs on the same mesh/domain decomposition as the ATS mesh, so its restart
state is directly usable by stage 2.

**Stage 2 -- ELM+ATS cyclic steady-state spinup**
The first fully coupled run: ELM+ATS with cyclic ("typical year") forcing
for ~10 years, to bring the *coupled* system (ELM carbon/water state +
ATS subsurface pressure) to a mutual steady state. Initial conditions come
from both prior stages -- ATS pressure restarts from stage 1a's
`checkpoint_final.h5`, ELM state restarts from stage 1b's `finidat`. Uses
the same ATS mesh/soil/region configuration as stage 3, packaged as
`coweeta_stage2.xml`.

**Stage 3 -- ELM+ATS transient run**
The final, fully coupled run, driven by real (non-cyclic) meteorology over
the actual simulation period. Initializes both ELM and ATS state from the
end of stage 2. Uses `coweeta_stage3.xml`, identical to stage 2's XML except
for which checkpoint it restarts ATS pressure from.

## Stage 3b (optional) -- ELM+ATS transient run, Satellite Phenology mode

Stage 3b is an independent, optional comparison run: fully coupled ELM+ATS,
driven by the same real transient AORC meteorology as stage 3, but with ELM
running in Satellite Phenology (SP) mode instead of prognostic CN --
LAI/SAI are prescribed from a MODIS-derived monthly climatology per PFT
(built in `coweeta_elm_ats.py`'s "Stage 3b" section: MODIS LAI + land cover
correlated against the same NLCD raster used for PFT assignment, reduced to
a repeating 12-month climatology per PFT) rather than predicted from carbon
allocation.

This sidesteps stages 1c and 2's CN spinup entirely -- stage 3b restarts ATS
pressure directly from **stage 1a**'s checkpoint (not stage 2's) and starts
ELM cold, with no `finidat`, since SP mode carries no carbon/nitrogen state
to initialize. **Stage 3b depends only on stage 1a**, not 1c/2/3, and is
useful as a faster, independent point of comparison against stage 3's
CN-mode result.

Built with compset `ICBELMBC` (selects SP mode intrinsically, the same
compset `examples/oakharbor_column` uses) instead of the campaign's default
CN compset. Not part of the default (no-argument) `build_example.sh` build --
must be requested explicitly, e.g. `./build_example.sh 1a 3b`.

## How to run the full example

### 1. Prerequisites

A modulefile (or equivalent) should set, once, before doing anything:

- `ELM_ATS_SRC_DIR` -- root of this repository
- `E3SM_WORK_DIR` -- parent directory where the campaign
  (`Coweeta_Campaign0/` by default) will be created
- `MACHINE_NAME`, `COMPILER_NAME` -- CIME machine/compiler names

`NTASKS` (the MPI rank count) is **not** set by the modulefile -- you set it
yourself for each build. It must be the same value used to partition the
mesh in `coweeta_elm_ats.py` (`m2.partition(int(os.environ['NTASKS']))`),
since ATS's mesh decomposition, and the checkpoint restart chain across
stages, are both fixed at that process count. `build_example.sh` checks this
for you (see below) and refuses to run on a mismatch.

### 2. Generate mesh, domain, surfdata, ATS XMLs, and ELM namelists

Set `NTASKS` in the environment, then run
`watershed_workflow/examples/Coweeta/coweeta_elm_ats.py` top to bottom (this
is the sole source for the Coweeta ELM-ATS workflow -- there is no paired
notebook). This writes, to that script's `elm_output_data/`:

- `coweeta_np<NTASKS>.exo`, `coweeta_np<NTASKS>.h5` -- the 3D mesh,
  partitioned for `NTASKS` MPI ranks (the filename is tagged with `NTASKS`
  so a mesh built for the wrong task count is obviously named wrong, not
  just silently mismatched)
- `coweeta_domain.nc`, `coweeta_surfdata.nc` -- ELM domain/surface data
- `coweeta_stage1a.xml` -- stage 1a's self-contained ATS input, with a
  `STEADYSTATE_PRECIP_MPS` placeholder `build_example.sh` fills in later
- `coweeta_stage2.xml`, `coweeta_stage3.xml`, `coweeta_stage3b.xml` -- the
  coupled ELM+ATS ATS inputs, identical except for which checkpoint each
  restarts from (stage 3b restarts from stage 1a, not stage 2)
- `coweeta_subsurface_properties.csv` -- soil properties lookup table
- `user_nl_elm_stage1c`, `user_nl_elm_stage2`, `user_nl_elm_stage3`,
  `user_nl_elm_stage3b` -- ELM's own input files for each ELM-running stage,
  written by `writeUserNlElmStage1c/2/3/3b()`. Just like the ATS XMLs, these
  are complete and ready to use as-is -- `build_example.sh` only copies each
  into its case directory, it does not generate or edit their content.
- `coweeta_stage3b_surfdata.nc` -- Satellite Phenology (SP) mode surfdata,
  with `MONTHLY_LAI`/etc. tables derived from MODIS, for stage 3b only

### 3. Generate meteorology

Run `watershed_workflow/examples/Coweeta/coweeta_aorc_elm.ipynb` top to
bottom. This downloads AORC and writes, to its own `elm_output_data/`:

- `atm_forcing/` -- transient (real calendar) cpl_bypass forcing, for stage 3
- `atm_forcing_spinup/` -- cyclic "typical year" cpl_bypass forcing, for
  stages 1b and 2
- `coweeta_mean_precip_rain_mps.txt` -- domain/time-mean precipitation rate,
  used by `build_example.sh` to fill in stage 1a's steady-state forcing

### 4. Build all four cases

No manual copy step needed -- `build_example.sh` and `stage_inputdata.sh`
read directly from `watershed_workflow/examples/Coweeta/elm_output_data/`,
the fixed output directory `coweeta_elm_ats.py` and
`coweeta_aorc_elm.ipynb` write to.

```bash
export NTASKS=4   # or whatever you used to partition the mesh in step 2
./build_example.sh
```

This stages a shared `inputdata/` directory once
(`${E3SM_WORK_DIR}/Coweeta_Campaign0/inputdata/`, via `stage_inputdata.sh`),
verifies `NTASKS` matches the mesh partition count baked into
`coweeta_np${NTASKS}.exo`, then creates and builds (but does not submit) the
four main campaign stages:

```
${E3SM_WORK_DIR}/Coweeta_Campaign0/
  inputdata/                    (shared: mesh, domain, surfdata, forcing,
                                  global ELM datasets)
  1a_ats_spinup/                (stage 1a: bare ATS run, no CIME case)
  1c_pft_columns/                (CIME case)
  2_cyclic_steadystate/         (CIME case)
  3_transient/                  (CIME case)
```

Stage 3b is not included in this default build -- it's an independent,
optional comparison run depending only on stage 1a. Build it explicitly
alongside stage 1a:

```bash
./build_example.sh 1a 3b
```

which adds a `3b_transient_sp/` (CIME case) sibling directory.

The whole `Coweeta_Campaign0/` directory is self-contained and can be
`rsync`ed onto HPC scratch space to run elsewhere -- it does not depend on
the (large, git-tracked) `inputdata/` mirror repo except at first build.

### 5. Run the four stages in order

Each stage's initial conditions depend on files the previous stage's run
produces, so run these one at a time, waiting for each to finish:

```bash
CAMPAIGN=${E3SM_WORK_DIR}/Coweeta_Campaign0

# Stage 1a: bare ATS run (not a CIME case)
cd ${CAMPAIGN}/1a_ats_spinup/run
mpiexec -n ${NTASKS} ats --xml_file=../coweeta_stage1a.xml

# Stage 1c: spatially-reduced per-PFT ELM carbon spinup
pushd ${CAMPAIGN}/1c_pft_columns
./case.submit
popd

# Stage 2: ELM+ATS cyclic steady-state (needs 1a and 1c complete)
pushd ${CAMPAIGN}/2_cyclic_steadystate
./case.submit
popd

# Stage 3: ELM+ATS transient (needs stage 2 complete)
pushd ${CAMPAIGN}/3_transient
./case.submit
popd
```

`build_example.sh`'s final summary output also prints these commands with
your actual paths filled in.

### 5b. Run stage 3b (optional, independent of 1c/2/3)

Only needs stage 1a complete -- can be run any time after step 5's stage 1a,
without waiting on 1c/2/3:

```bash
pushd ${CAMPAIGN}/3b_transient_sp
./case.submit
popd
```
