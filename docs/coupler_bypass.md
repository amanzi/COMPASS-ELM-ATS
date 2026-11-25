# CPL_BYPASS Mode: User Options

`CPL_BYPASS` is a compile-time preprocessor flag that causes ELM to read all
meteorological forcing directly from NetCDF files rather than receiving it through
the MCT coupler. This document describes the namelist options available to users
when running in CPL_BYPASS mode.

All variables below go in `user_nl_elm` under the `elm_inparm` namelist group.

---

## Forcing Data Source (`metdata_type`, `metdata_bypass`)

`metdata_type` selects the format and provenance of the forcing files.
`metdata_bypass` gives the directory that contains them.

```fortran
metdata_type   = 'atssubdaily'
metdata_bypass = '/path/to/forcing/data'
```

### Supported `metdata_type` values

| Value | Dataset | Default year range |
|---|---|---|
| `'qian'` | Qian et al. (2006) | spinup 1948–1972, transient to 2004 |
| `'cruncep'` or `'cru'` | CRU-NCEP v5 | spinup 1901–1920, transient to 2016 |
| `'princeton'` | Princeton global forcing | spinup 1901–1920, transient to 2012 |
| `'gswp3'` | GSWP3 | spinup 1901–1920, transient to 2014 |
| `'era5'` | ERA5 reanalysis | spinup 1950–1970, transient to 2025 |
| `'cpl'` | CPL-format (synthetic, 14-variable) | 566–590 |
| `'atssubdaily'` | Subdaily AORC-format, for watershed runs | reads from file |
| `'site'` | Single-site hourly data | reads from file |

For most ELM-ATS watershed runs, `'atssubdaily'` is the appropriate choice.

### File organization

All dataset types except `'site'` use a zone-based file layout:

- `{metdata_bypass}/zone_mappings.txt` — maps each model grid cell to a forcing
  zone ID. Format: `longitude latitude zone_id grid_id`, one line per cell.
- `{metdata_bypass}/{DATASET}_{VARNAME}_z{ZZ}.nc` — one file per variable per
  zone. The zone suffix is formatted as the two-digit zone ID plus 100
  (e.g. zone 3 → `z103`).

For `'site'` mode, all variables are in a single file:
`{metdata_bypass}/all_hourly.nc`.

### Standard forcing variables

All types provide these seven variables:

| NetCDF name | Description | Units |
|---|---|---|
| `TBOT` | Near-surface air temperature | K |
| `PSRF` | Surface pressure | Pa |
| `QBOT` or `RH` | Specific or relative humidity | kg/kg or % |
| `FSDS` | Incident shortwave radiation | W m⁻² |
| `FLDS` | Incident longwave radiation | W m⁻² |
| `PRECTmms` | Precipitation | mm s⁻¹ |
| `WIND` | Wind speed | m s⁻¹ |

The `'cpl'` type additionally provides split radiation bands and separate rain/snow
fields (14 variables total).

NetCDF files may use CF-convention `scale_factor` and `add_offset` attributes;
the reader applies these automatically.

---

## Data Paging / Memory Usage (`metdata_read_buffer_ntimes`)

```fortran
metdata_read_buffer_ntimes = -1
```

This controls how many timesteps of forcing data are held in memory at once.

| Value | Behavior |
|---|---|
| `-1` (default) | Load the entire record into memory on the first timestep. No subsequent I/O. Use this for small domains or short records. |
| `N > 0` | Rolling buffer: load `N` timesteps at a time. When the run advances past the end of the buffer, the next chunk is read from disk. |

**Choosing a buffer size:** A practical value is the number of forcing timesteps
in one year (e.g. 365 for daily data, 8760 for hourly). Smaller values reduce
memory at the cost of more frequent I/O; larger values amortize I/O over longer
periods. The reload happens automatically and transparently — no user intervention
is needed when the buffer is exhausted.

---

## Spinup Cycling (`const_climate_hist`)

```fortran
const_climate_hist = .false.
```

This controls whether the forcing record is cycled repeatedly (for spinup) or
advanced in calendar time (for transient runs).

### Transient mode (`const_climate_hist = .false.`, default)

The run advances through calendar time. The simulation start date must fall
within the dataset's year range (`startyear_met` to `endyear_met_trans`), and
the run aborts if it attempts to advance past the end of the transient record.
Use this for production runs that need to track actual historical forcing.

### Spinup/cycling mode (`const_climate_hist = .true.`)

The forcing record is cycled indefinitely over the spinup sub-period
(`startyear_met` to `endyear_met_spinup`). The model calendar advances normally,
but the forcing time index wraps back to the beginning of the spinup window each
time it reaches the end. This allows arbitrarily long spinup runs driven by a
short (e.g. 5–10 year) forcing record.

Each dataset has built-in spinup and transient year ranges (see the table above).
These can be overridden with the `startyear_met`, `endyear_met_spinup`, and
`endyear_met_trans` namelist variables if the dataset covers a different period.

---

## Bias Correction (`metdata_biases`)

```fortran
metdata_biases = '/path/to/bias_corrections.txt'
```

Optional. If specified, the reader loads monthly mean corrections for temperature
and precipitation from this ASCII file and applies them as additive temperature
offsets and multiplicative precipitation adjustments. The file contains one record
per grid cell with 12 months of corrections. Leave unset (default: empty) to
apply no bias correction.

---

## Ancillary Forcing Files

```fortran
co2_file  = '/path/to/co2_annual.nc'
aero_file = '/path/to/aerosol_deposition.nc'
```

- `co2_file` — Annual CO2 concentrations, used when `co2_type = 'diagnostic'`.
- `aero_file` — Monthly aerosol deposition fields.

Both are required for fully realistic land-surface simulations. Standard files
for these are available in the E3SM inputdata repository.

---

## Climate Perturbation Experiments

```fortran
add_temperature         = 2.0        ! K warming
startdate_add_temperature = 20100101 ! YYYYMMDD

add_co2                 = 100.0      ! ppm above baseline
startdate_add_co2       = 20100101
```

Additive offsets applied to temperature and CO2 starting at the specified date.
Useful for sensitivity experiments without modifying the forcing files themselves.

---

## Time Interpolation Notes

The reader linearly interpolates all variables between the two bracketing forcing
timesteps, with two exceptions:

- **Precipitation** uses only the later timestep (no interpolation), to preserve
  accumulation consistency.
- **Shortwave radiation** is scaled by the instantaneous-to-mean solar zenith
  angle ratio rather than linearly interpolated, to reproduce the correct diurnal
  cycle even when forcing data is at daily or 3-hourly resolution.

---

## Key Source Files

| File | Role |
|---|---|
| `E3SM/components/elm/src/cpl/lnd_import_export.F90` | Forcing reader: initialization, buffering, interpolation |
| `E3SM/components/elm/src/main/atm2lndType.F90` | Data structures for buffered forcing fields |
| `E3SM/components/elm/src/main/elm_varctl.F90` | Namelist variable declarations and defaults |
| `E3SM/components/elm/src/main/controlMod.F90` | Namelist reading and MPI broadcast |
