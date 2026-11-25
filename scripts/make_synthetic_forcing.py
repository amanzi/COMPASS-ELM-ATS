"""
Generate idealized/synthetic ELM meteorological forcing in the
metdata_type='atssubdaily' cpl_bypass format.

This is the same format Coweeta's coweeta_aorc_elm.ipynb produces (see
watershed_workflow/examples/Coweeta/elm_output_data/atm_forcing_spinup/),
read by ELM's src/cpl/lnd_import_export.F90 when metsource==8: seven
files named ATS-subdaily_<VAR>_z<zone>.nc (VAR in TBOT, PSRF, QBOT,
FSDS, PRECTmms, WIND, FLDS), each with dims (n, DTIME), plus a
zone_mappings.txt with one row per gridcell.

Unlike metdata_type='gswp3' (which hard-codes startyear_met=1901 and a
20-year 1901-1920 spinup-cycling window with a required 365-day/year
DTIME cadence), atssubdaily reads start_year/end_year directly from the
NetCDF files (from ATS-subdaily_TBOT_z01.nc specifically), so a short,
few-day/few-week idealized forcing record works fine in transient
(non-cycling) mode -- no need to pad out to a full calendar year or hit
specific hard-coded year ranges.

The record count DOES still need to bracket the full run length,
though: the reader (read_met_buffer/the per-step tindex advance in
lnd_import_export.F90) always interpolates linearly between the two
DTIME records straddling the current model time, so covering a run of
length `days` requires a record at *both* t=0 and t=days -- i.e.
`days*24/timestep_hours + 1` records, not `days*24/timestep_hours`. One
record short and the last step(s) of the run have no valid right-hand
bracket, and the transient (non-cycling) path errors out with
"advanced past the end of the met forcing record" one step early.

Units required by the reader (ELM's forc_* fields, verified against
lnd_import_export.F90):
    TBOT      Kelvin
    PSRF      Pa
    QBOT      specific humidity, kg/kg
    FSDS      W/m^2, total incident shortwave
    PRECTmms  mm/s == kg/m^2/s, precipitation RATE (not accumulation)
    WIND      m/s, scalar wind speed
    FLDS      W/m^2, downwelling longwave (values <=50 or >=600 are
              treated as missing and recomputed from T/q internally,
              so avoid those bounds for real forcing)

DTIME is raw fractional days (not encoded datetimes), starting at 0,
at a regular interval (the reader infers timeres from DTIME[1]-DTIME[0]
and requires the ELM timestep to divide it evenly, e.g. 3-hourly with
a 1800s ELM step gives 6 substeps per forcing record).

Each met variable MUST be written as packed int16 with real
scale_factor/add_offset attributes, matching the reference cpl_bypass
files exactly. read_met_buffer() in lnd_import_export.F90 always reads
into an `integer*2` buffer via nf90_get_var regardless of the on-disk
dtype -- writing plain unpacked float64 causes netCDF to silently
truncate/clamp values on the implicit double->int16 conversion (e.g.
PSRF~98500 Pa is far outside int16 range and clamps to garbage), and
the Fortran caller does not check that read's error status. This is
what produces NaNs downstream (garbage surface pressure feeding
vapor-pressure calculations, etc).
"""

import argparse
import os
import numpy as np
import xarray as xr


MET_VARS = ["TBOT", "PSRF", "QBOT", "FSDS", "PRECTmms", "WIND", "FLDS"]


def _dtime(n_steps, timestep_hours):
    """Raw fractional-day DTIME array, starting at 0, at a fixed cadence."""
    return np.arange(n_steps, dtype=np.float64) * (timestep_hours / 24.0)


def makeConstantForcing(
    n_steps,
    timestep_hours,
    tbot_k=283.15,
    psrf_pa=98500.0,
    qbot_kgkg=0.006,
    fsds_wm2=0.0,
    prectmms=0.0,
    wind_ms=2.0,
    flds_wm2=300.0,
):
    """Build a dict of constant-in-time forcing arrays.

    No diurnal option is provided: a physically correct diurnal FSDS
    shape requires the site's lat/lon (via a solar zenith angle
    calculation, see ELM's szenith() in lnd_import_export.F90) to place
    sunrise/sunset and solar noon correctly in UTC -- getting this wrong
    silently produces a diurnal cycle that's out of phase with what
    ELM's own cosine-zenith-angle FSDS downscaling expects. For
    idealized runs (no diurnal cycle, by design) a flat FSDS avoids the
    issue entirely; for anything wanting a real diurnal cycle, use real
    forcing data (e.g. AORC) instead of approximating one here.

    Parameters
    ----------
    n_steps : int
        Number of forcing records to generate.
    timestep_hours : float
        Spacing between records, in hours (e.g. 3.0 for 3-hourly).

    Returns
    -------
    dict mapping MET_VARS name -> np.ndarray of shape (n_steps,)
    """
    return {
        "TBOT": np.full(n_steps, tbot_k, dtype=np.float64),
        "PSRF": np.full(n_steps, psrf_pa, dtype=np.float64),
        "QBOT": np.full(n_steps, qbot_kgkg, dtype=np.float64),
        "FSDS": np.full(n_steps, fsds_wm2, dtype=np.float64),
        "PRECTmms": np.full(n_steps, prectmms, dtype=np.float64),
        "WIND": np.full(n_steps, wind_ms, dtype=np.float64),
        "FLDS": np.full(n_steps, flds_wm2, dtype=np.float64),
    }


def writeForcing(
    output_dir,
    forcing,
    lon,
    lat,
    timestep_hours,
    start_year,
    end_year=None,
    zone=1,
):
    """Write the seven ATS-subdaily_<VAR>_z<zone>.nc files plus zone_mappings.txt.

    Parameters
    ----------
    output_dir : str
        Directory to write into (created if missing). This is the path
        a case's user_nl_elm should set as `metdata_bypass`.
    forcing : dict or list of dict
        Either a single dict (MET_VARS name -> 1D np.ndarray, one
        gridcell) or a list of such dicts (one per gridcell, for a
        multi-column mesh) -- all must share the same length/timestep.
    lon, lat : float or array-like
        Longitude/latitude per gridcell (matched 1:1 with `forcing` if
        it's a list). Only used for zone_mappings.txt / nearest-neighbor
        gridcell matching -- does not need to be exact.
    timestep_hours : float
        Spacing between forcing records, in hours.
    start_year, end_year : int
        Written into each file's start_year/end_year scalars. Defaults
        end_year = start_year (a single-year record; DTIME still just
        counts up from 0, the year fields are metadata cpl_bypass uses
        for its startyear_met/endyear_met_spinup bookkeeping).
    zone : int
        Zone id, 1-99, becomes the z<NN> in filenames. Arbitrary as
        long as it's consistent between zone_mappings.txt and filenames.
    """
    if end_year is None:
        end_year = start_year

    if isinstance(forcing, dict):
        forcing = [forcing]
        lon = [lon]
        lat = [lat]
    lon = np.asarray(lon, dtype=np.float64)
    lat = np.asarray(lat, dtype=np.float64)
    ncells = len(forcing)
    assert len(lon) == ncells and len(lat) == ncells, (
        "lon/lat must match the number of gridcells in `forcing`"
    )

    n_steps = len(forcing[0]["TBOT"])
    for f in forcing:
        for v in MET_VARS:
            assert v in f, f"forcing dict missing required variable '{v}'"
            assert len(f[v]) == n_steps, "all gridcells must share the same length"

    os.makedirs(output_dir, exist_ok=True)

    dtime = _dtime(n_steps, timestep_hours)

    for v in MET_VARS:
        data = np.stack([f[v] for f in forcing], axis=0)  # (n, DTIME)
        # ELM's cpl_bypass reader (lnd_import_export.F90::read_met_buffer)
        # reads every met variable into an `integer*2` buffer via
        # nf90_get_var, unconditionally -- regardless of the on-disk
        # dtype. If the variable is stored as plain float64 (no
        # scale_factor/add_offset), netCDF silently does an implicit
        # double->int16 conversion: values within int16 range get
        # truncated to integers (e.g. TBOT=283.15 K becomes the raw
        # "unpacked" value 283, then used as-is since scale_factor
        # defaults to 1.0/add_offset to 0.0), and values outside int16
        # range (e.g. PSRF~98500 Pa, far above the int16 max of 32767)
        # fail the conversion and silently clamp to garbage -- and the
        # Fortran caller does not check that read's ierr. Garbage PSRF
        # feeding vapor-pressure/psychrometric calculations is what
        # produces the NaNs. So: pack every variable as int16 with real
        # scale_factor/add_offset, exactly like the reference cpl_bypass
        # files (e.g. Coweeta's ATS-subdaily_*.nc), instead of writing
        # unpacked float64.
        vmin = float(np.min(data))
        vmax = float(np.max(data))
        # Pack into the full symmetric range [-32767, 32767] (never
        # -32768), leaving -32768 unused so it can be declared as the
        # explicit _FillValue below. -32767 is NetCDF's *default* fill
        # value for NC_SHORT, and readers (plain nf90_get_var with
        # fill-checking enabled, or any Python/xarray post-processing of
        # these files) silently treat a raw value equal to it as
        # missing/masked -- even with no _FillValue attribute written.
        # A constant-in-time variable packed at the range midpoint used
        # to land exactly on -32767 and got masked out entirely, which
        # is why the fill value must be pinned to -32768 explicitly
        # instead of relying on -32767 never coming up by chance.
        if vmax > vmin:
            scale_factor = (vmax - vmin) / (2 * 32767.0)
        else:
            scale_factor = 1.0
        add_offset = (vmax + vmin) / 2.0  # packed 0 sits mid-range
        packed = np.round((data - add_offset) / scale_factor).astype(np.int16)
        ds = xr.Dataset(
            {
                "LONGXY": xr.DataArray(lon, dims=("n",)),
                "LATIXY": xr.DataArray(lat, dims=("n",)),
                v: xr.DataArray(
                    packed,
                    dims=("n", "DTIME"),
                    attrs={
                        "long_name": v,
                        "scale_factor": np.float64(scale_factor),
                        "add_offset": np.float64(add_offset),
                    },
                ),
                "start_year": xr.DataArray(np.int32(start_year)),
                "end_year": xr.DataArray(np.int32(end_year)),
            },
            coords={
                "DTIME": xr.DataArray(
                    dtime,
                    dims=("DTIME",),
                    attrs={
                        "units": f"days since {start_year}-01-01 00:00:00",
                        "long_name": "Day of Year",
                    },
                ),
            },
        )
        fname = f"ATS-subdaily_{v}_z{zone:02d}.nc"
        # Disable xarray's default _FillValue=NaN encoding on every
        # variable except the packed met variable itself: the reference
        # atssubdaily files (e.g. Coweeta's ATS-subdaily_*.nc) either
        # have no _FillValue or a real packed-integer sentinel, never a
        # literal NaN attribute -- leaving xarray's default in place on
        # LONGXY/LATIXY/etc risks the Fortran reader's fill-value
        # handling treating valid data as missing. The met variable
        # itself gets an explicit int16 _FillValue=-32768, unused by
        # the packing above, so real data is never mistaken for fill.
        encoding = {name: {"_FillValue": None} for name in ds.variables}
        encoding[v] = {"_FillValue": np.int16(-32768)}
        ds.to_netcdf(os.path.join(output_dir, fname), encoding=encoding)

    zone_mapping_path = os.path.join(output_dir, "zone_mappings.txt")
    with open(zone_mapping_path, "w") as f:
        for i in range(ncells):
            f.write(f"{lon[i]:12.5f} {lat[i]:12.5f} {zone:6d} {i+1:6d}\n")

    print(f"Wrote {len(MET_VARS)} forcing files + zone_mappings.txt to {output_dir}")
    print(f"  ncells={ncells}, n_steps={n_steps}, timestep={timestep_hours}h, "
          f"duration={n_steps * timestep_hours / 24.0:.2f} days")


def main():
    parser = argparse.ArgumentParser(
        description="Generate idealized/synthetic ELM meteorological forcing "
        "(metdata_type='atssubdaily' format)."
    )
    parser.add_argument("OUTPUT_DIR", help="Directory to write forcing files into")
    parser.add_argument("--lon", type=float, default=283.0, help="Longitude (deg E)")
    parser.add_argument("--lat", type=float, default=42.0, help="Latitude (deg N)")
    parser.add_argument("--days", type=float, default=30.0, help="Forcing record length, days")
    parser.add_argument("--timestep-hours", type=float, default=3.0, help="Forcing cadence, hours")
    parser.add_argument("--start-year", type=int, default=2000)
    parser.add_argument("--tbot-k", type=float, default=283.15, help="Air temp, K")
    parser.add_argument("--psrf-pa", type=float, default=98500.0, help="Surface pressure, Pa")
    parser.add_argument("--qbot-kgkg", type=float, default=0.006, help="Specific humidity, kg/kg")
    parser.add_argument("--fsds-wm2", type=float, default=0.0, help="Shortwave (flat, no diurnal cycle), W/m^2")
    parser.add_argument("--prectmms", type=float, default=0.0, help="Precip rate, mm/s")
    parser.add_argument("--wind-ms", type=float, default=2.0, help="Wind speed, m/s")
    parser.add_argument("--flds-wm2", type=float, default=300.0, help="Downwelling longwave, W/m^2")
    parser.add_argument("--zone", type=int, default=1, help="Zone id (1-99)")
    args = parser.parse_args()

    # +1: the reader interpolates between a bracketing pair of records, so
    # covering a run of length `days` requires a record at both t=0 and
    # t=days -- i.e. n_steps+1 records, not n_steps (see module docstring).
    n_steps = int(round(args.days * 24.0 / args.timestep_hours)) + 1
    forcing = makeConstantForcing(
        n_steps,
        args.timestep_hours,
        tbot_k=args.tbot_k,
        psrf_pa=args.psrf_pa,
        qbot_kgkg=args.qbot_kgkg,
        fsds_wm2=args.fsds_wm2,
        prectmms=args.prectmms,
        wind_ms=args.wind_ms,
        flds_wm2=args.flds_wm2,
    )
    writeForcing(
        args.OUTPUT_DIR,
        forcing,
        args.lon,
        args.lat,
        args.timestep_hours,
        args.start_year,
        zone=args.zone,
    )


if __name__ == "__main__":
    main()
