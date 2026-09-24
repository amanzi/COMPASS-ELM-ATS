# Assumptions

This repo is a meta-repo which stores submodules to all the software
stacks needed to run coupled ELM+ATS simulations.  It is important for
users to understand the assumptions that go into ELM+ATS.


## ELM assumptions

* Only natural / vegetated land surface types are allowed
* One land type per grid cell, one topo unit per land type, one water column per topo unit -- the heirarchy is collapsed through water columns.
* Currently one PFT with area fraction 1, all others 0 per water column.  This could eventually be relaxed.

## ATS assumptions

* Meshes are extruded with a uniform number of grid cells.
* Meshes are pre-partitioned and written with 'one block' option of Watershed Workflow.

## Shared assumptions

* ELM's surfdata and domain files are organized in the same ordering
  as ATS's columns.  This is satisfied if the above ATS assumptions
  are met (using WW with pre-partitioning and 'one block').
* ATS's mesh is the same vertical structure as ELM's mesh -- zi, dz, nlevgrnd

# Who owns what -- design

## ELM owns:

* meteorologic data
* all vegetation and land surface properties
* currently (may change) porosity, sand/silt/clay

## ATS owns:

* domain decomposition and mesh
* permeability and WRMs


# Building prototype ELM-ATS:

[![Build Docker Image](https://github.com/amanzi/COMPASS-ELM-ATS/actions/workflows/docker-ci.yml/badge.svg)](https://github.com/amanzi/COMPASS-ELM-ATS/actions/workflows/docker-ci.yml)

ELM-ATS should build from the head of ATS master branch, and against
the E3SM commit in the linked submodule. Two options to test/build the stack -- with docker and locally.  Both need to clone the repository:

## Repo and branch selection

1) Clone this repo. `git clone https://github.com/amanzi/COMPASS-ELM-ATS`
2) While submodules are included for E3SM, Amanzi, ATS, and ELM input datafiles, for now it is safer to use the tip of the corresponding development branch.

```
cd COMPASS-ELM-ATS
export ELM_ATS_SRC_DIR=`pwd`

# E3SM
git submodule update --init --recursive E3SM
cd E3SM
git checkout elm-ats-dev
git pull
cd ..

# Amanzi & ATS
git submodule update --init --recursive amanzi
cd amanzi
git checkout elm_ats
git pull
cd src/physics/ats
git checkout elm_ats
git pull
cd ../../../..
```

3) Set up the work and cases directories and unpack the input data.

```
git submodule update --init --recursive work/inputdata
cd work/inputdata
git checkout compass-glm
git pull
. ./unpack.sh
cd ../../
```

OR, if you know what you're doing or you are on an established HPC
machien, replace `work/inputdata` with a link to an existing, unpacked
ELM inputdata repo.


## Docker
~~The image created by CI works now! So: `docker run -it metsi/compass-elm-ats:latest` and then can follow the general workflow in the ci.yml file to setup and build the case.~~ 

Steps if using docker but not the CI image (e.g., Apple Silicon).  By default this uses the CI-built ATS, so if you change ATS, either push it to e.g. the elm_ats branch and rebuild there, or rebuild ATS in the container from your local source with `REBUILD_ATS=true` (see below).

1) Build the docker container:
```
docker build --pull --progress=plain --no-cache -f Docker/Dockerfile-ATS-ELM -t metsi/ats:elm_api .
```

### Rebuilding ATS from local source

By default both `Docker/Dockerfile-ATS-ELM` and `Docker/Dockerfile-run` use the
ATS already compiled into the base image. To instead compile ATS from whatever
is currently checked out in `amanzi/` and `amanzi/src/physics/ats/` -- including
uncommitted changes -- pass `REBUILD_ATS=true`:

```
# via the deploy script
REBUILD_ATS=true ./Docker/deploy-ats-elm-docker.sh

# or directly
docker build --build-arg REBUILD_ATS=true -f Docker/Dockerfile-ATS-ELM -t metsi/ats:elm_api .

# or for the self-contained run image
REBUILD_ATS=true ./examples/run_all_cases.sh
```

The rebuild reuses the base image's prebuilt TPLs, so only Amanzi/ATS is
recompiled (~10 min). Tune parallelism with `ATS_BUILD_PARALLEL` (default 4) and
the build type with `ATS_BUILD_TYPE` (`opt`, `debug`, `relwithdebinfo`).

The resulting image records provenance in its labels:
```
docker inspect metsi/ats:elm_api --format '{{json .Config.Labels}}'
```
Because `amanzi/.git` is kept out of the build context, `ats --version` reports a
static version rather than the commit hash; use the labels above instead.

2) Then, from the top level repo directory: 
```
docker run -it --user=amanzi_user -e E3SM_WORK_DIR=/home/amanzi_user/compass/work -e ELM_ATS_SRC_DIR=/home/amanzi_user/compass -e MACHINE_NAME=docker-ats -e COMPILER_NAME=gnu -v $(pwd):/home/amanzi_user/compass metsi/ats:elm_api 
```

### Common issues:

- NC_FillValue errors in build log - `$ELM_ATS_SRC_DIR` is pointing to out-of-date E3SM version.
- "No machine docker-ats found" - is `$HOME` set to `/home/amanzi_user`?


## Local Builds
To build locally on a Mac or Linux machine, follow the following steps.

### Precursors

0) Set environmental variables for using ELM+ATS.
   - `ELM_ATS_SRC_DIR` = path to where you will clone this repository
   - Set standard ATS environmental variables:
      - `export AMANZI_SRC_DIR=${ELM_ATS_SRC_DIR}/amanzi`
      - `export ATS_SRC_DIR=${ELM_ATS_SRC_DIR}/amanzi/src/physics/ats`
      - Set `AMANZI_TPLS_DIR` and `AMANZI_TPLS_BUILD_DIR` as for standard Amanzi-ATS TPL installations.
      - Set `AMANZI_DIR` and `AMANZI_BUILD_DIR` as for standard Amanzi-ATS installations.
   - Set standard E3SM environmental variables:
      - `export E3SM_SRC_DIR=${ELM_ATS_SRC_DIR}/E3SM`
      - `MACHINE_NAME` and `COMPILER_NAME` -- set your machine and compiler (likely gnu) names -- see later steps for how this is used
      - Set an `E3SM_WORK_DIR` where you will place cases/builds/runs.

1) make sure you have dependencies (or their homebrew equivalents):
   - Perl LibXML: `sudo apt-get install libxml-libxml-perl`
   - MPI: `sudo apt-get install openmpi-dev`
   - blas/lapack-dev `sudo apt-get install libblas-dev liblapack-dev`
   - libcurl-dev: `sudo apt-get install libcurl4-gnutls-dev`
   
2) `git clone --recurse-submodules git@github.com:amanzi/COMPASS-ELM-ATS ${ELM_ATS_SRC_DIR}`
3) `git clone -b compass-glm git@github.com:rfiorella/pt-e3sm-inputdata ${E3SM_WORK_DIR}/inputdata`  Unpack the inputdata files: `cd ${E3SM_WORK_DIR}/inputdata; . unpack.sh`
4) Build Amanzi TPLs as normal (using bootstrap).
5) Build ATS using `--enable-elm_ats_api` in bootstrap.
6) FIX amanzi/amanzi#886 --- but until then, hack `$AMANZI_DIR/lib/AmanziImportedTargets.cmake` to protect the netcdf section with: `IF (NOT TARGET netcdf) ... ENDIF`
7) (optional) If building on a machine not supported by E3SM, you'll need to update cmake files for E3SM. Examples are provided in cime_files in this repo for how these were configured for the docker machine. Typically they get placed in ~/.cime or /.cime if they are not part of the E3SM repo (in the container, they are in both locations).
  - `mkdir ~/.cime`
  - `cp ${ELM_ATS_SRC_DIR}/cime_files/config_machines.xml ~/.cime`
  - `cp ${ELM_ATS_SRC_DIR}/cime_files/gnu_docker-ats.cmake ~/.cime/${COMPILER_NAME}_${MACHINE_NAME}.cmake`
  - edit `~/.cime/config_machines.xml`, adding an entry for `$MACHINE_NAME` based on one of the existing machines.
 

### Create and build the new case.

Follow the examples:

1) `cd ${ELM_ATS_SRC_DIR}/examples/EXAMPLE_NAME`
2) Run the enclosed script `./build_example.sh` which creates the new case and calls case.setup and case.build.  Pass the USE_ATS flag to get the variation you want:
  - `USE_ATS=FALSE ./build_example.sh` Runs native ELM
  - `USE_ATS=IC_ONLY ./build_example.sh` Runs native ELM but with ATS's iniitial condition for easier comparison
  - `USE_ATS=TRUE ./build_example.sh` Runs ELM + ATS
3) Follow the on-screen instructions to run the case: `cd ${CASE_DIR} && ./case.submit`

# Directory Structure and Input File Workflow

This repo uses multiple directories to track input files for a given `CASE_NAME`. This is convoluted and probably needs to be rethought and streamlined at some point.

1. `./watershed_workflow/examples/CASE_NAME` may include scripts for Watershed Workflow used to generate input files. This is the workflow tool that sets up runs — most "real" runs will use this tool.

2. Once the input data is created, it is typically moved into an `./examples/CASE_NAME` directory. This directory stages the input for E3SM and includes a `build_example.sh` script that runs E3SM/CIME's `create_newcase` and related scripts. Run-specific Watershed Workflow output from step 1 is copied into this directory (ATS xml files, ATS exo files, `user_nl` files — all non-data files).

3. `./inputdata` is E3SM's repo for storing input files. Once met data, surfdata, and domain files are created in step 1, they are moved to subdirectories here.

4. Once `create_newcase` is run (in the `build_example.sh` script), a `CASE_DIR` — typically something like `${CASE_ROOT}/CASE_NAME.npX` — is created. This is E3SM's staging directory for repeated runs. All files from step 2 are copied here and sometimes modified (e.g. via `sed`) to inject mesh names etc. **This is the authoritative location for ATS input XML files used in a run.**

5. `create_newcase` also creates a run directory where the actual runs execute. Few or no input files live there (perhaps namelist files); it is primarily for run output.

**Note:** A file `work/CASE_NAME.ats/run/CASE_NAME.xml` may exist but is **not** used — the XML in the `CASE_DIR` (step 4) is what ATS reads. Do not edit the run-directory copy.

# Examples

This documents and describes the sequence of examples developed in this repo.

## Column Examples

1) `oakharbor_column` The default Oak Harbor column -- 1 column only.  (runs, untested)
2) `oakharbor_bare_column` Same as 0, but with bare ground PFT, not a plant-based PFT.  (runs, untested)
3) `idealized_sand_column` Same as 0, but with pure sand? (different WRM?)  (runs on non-ATS, untested)

## Transect Examples

1) `oakharbor_transect_flat` A 5-column transect where the columns all have the same lat-long (same forcing data) and slope is 0, creating effectively 5 independent columns with no lateral flow.  (runs, untested.)
2) `oakharbor_transect` Same as above, but with a slope so that lateral flow is generated.  (Starts to run -- needs debugging.)
3) `tempest_transect` A ~100 column transect set to the Tempest transect from COMPASS FME. (WIP)

## 3D Examples

1) `coweeta`  A first watershed run, for comparison to ATS native.  Set up via Watershed Workflow.  (WIP)
