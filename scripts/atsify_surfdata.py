"""
ATS-ify an ELM surface data file, and optionally its paired domain file.

Enforces the constraints required for ELM-ATS single-PFT, pure natural
vegetation runs:
  - PCT_NATVEG = 100, all other landunit fractions = 0
  - PCT_NAT_PFT: dominant PFT (by total area) set to 100, rest 0
  - URBAN_REGION_ID = 0

Optionally also flattens MONTHLY_LAI to a constant value for the selected
PFT (--constant-lai), for satellite-phenology (SP) runs that want a
time-invariant LAI rather than the file's default seasonal cycle.

Optionally also fixes the domain file's grid cell area (--domain +
--area-km2): ELM's EM_ATS_CheckMesh (ExternalModelATS.F90) requires the
domain file's grid cell area to match the ATS mesh's cell area to within
1%, and endruns otherwise ("ATS column areas do not match ELM grid cell
areas"). This matters whenever a case borrows an ATS mesh built for a
different domain (e.g. idealized_sand_column reuses oakharbor_column's
mesh with its own sand_column domain/surfdata) -- the borrowed domain
file's area was never set to match. If --area-km2 is not given, the
domain file (if any) is left untouched.
"""

import xarray as xr
import numpy as np
import argparse
import sys


def find_dominant_pft(ds):
    pft = ds["PCT_NAT_PFT"].values
    # sum over all non-PFT dimensions
    totals = pft.sum(axis=tuple(range(1, pft.ndim)))
    return int(np.argmax(totals))


def atself_surfdata(ds, pft_index=None):
    ds = ds.copy()

    if pft_index is None:
        pft_index = find_dominant_pft(ds)
        print(f"Dominant PFT index: {pft_index}")

    # force pure natural vegetation landunit
    for var in ["PCT_LAKE", "PCT_CROP", "PCT_GLACIER", "PCT_WETLAND"]:
        if var in ds:
            ds[var] = xr.zeros_like(ds[var])

    ds["PCT_NATVEG"] = xr.full_like(ds["PCT_NATVEG"], 100.0)

    # zero all urban fractions across numurbl dimension
    if "PCT_URBAN" in ds:
        ds["PCT_URBAN"] = xr.zeros_like(ds["PCT_URBAN"])
    if "URBAN_REGION_ID" in ds:
        ds["URBAN_REGION_ID"] = xr.zeros_like(ds["URBAN_REGION_ID"])

    # set single dominant PFT
    pft = xr.zeros_like(ds["PCT_NAT_PFT"])
    # select the pft_index slice regardless of dimension layout
    pft_dim = ds["PCT_NAT_PFT"].dims[0]  # natpft is always the first dim
    pft[{pft_dim: pft_index}] = 100.0
    ds["PCT_NAT_PFT"] = pft

    return ds, pft_index


def set_constant_lai(ds, pft_index, lai_value):
    """Overwrite MONTHLY_LAI for one PFT so all 12 months are the same value.

    SatellitePhenologyMod.F90 (ELM's SP/satellite-phenology mode) reads
    MONTHLY_LAI straight from fsurdat and time-interpolates between the two
    bracketing months every timestep; there's no separate "constant LAI"
    namelist knob, so making all 12 months identical is the only way to get
    a time-invariant LAI without switching to LAI streams.
    """
    ds = ds.copy()
    lai_dim = ds["MONTHLY_LAI"].dims[1]  # (time, lsmpft, lsmlat, lsmlon)
    lai = ds["MONTHLY_LAI"]
    lai[{lai_dim: pft_index}] = lai_value
    ds["MONTHLY_LAI"] = lai
    return ds


def atsify_domain_area(ds, area_km2):
    """Overwrite a domain file's grid cell area from a km^2 value.

    ELM's domain 'area' variable is in radians^2 (area of grid cell on the
    unit sphere); EM_ATS_CheckMesh (ExternalModelATS.F90) compares the ATS
    mesh's cell area (converted m^2 -> km^2) against this radians^2 field
    (implicitly converted to km^2 via Earth's mean radius) to a tight 1e-6
    relative tolerance. _R_ELM_KM matches watershed_workflow.io.elm.writeDomain's
    own constant, so 'area' here is computed the same way ELM's own domain
    files are actually generated (area_km2 -> area_sr), not derived by
    inverting an already-rounded radians^2 value -- that round-trip is lossy
    enough (~1e-4 relative) to itself fail the 1e-6 tolerance.

    Also sets 'area_km2' (a plain km^2 field ELM's domain files carry
    alongside 'area'), matching writeDomain's convention.
    """
    _R_ELM_KM = 6371.22
    area_rad2 = area_km2 / _R_ELM_KM**2
    ds = ds.copy()
    ds["area"] = xr.full_like(ds["area"], area_rad2)
    if "area_km2" in ds:
        ds["area_km2"] = xr.full_like(ds["area_km2"], area_km2)
    else:
        ds["area_km2"] = xr.full_like(ds["area"], area_km2)
        ds["area_km2"].attrs = {
            "long_name": "area of grid cell in kilometers squared",
            "units": "km^2",
        }
    return ds


def main():
    parser = argparse.ArgumentParser(
        description="ATS-ify an ELM surface data file, and optionally its paired domain file."
    )
    parser.add_argument("INPUT", help="Input ELM surface NetCDF file")
    parser.add_argument("OUTPUT", help="Output ATS-ified NetCDF file")
    parser.add_argument(
        "--pft",
        type=int,
        default=None,
        metavar="INDEX",
        help="PFT index to use (default: dominant by total area)",
    )
    parser.add_argument(
        "--constant-lai",
        type=float,
        default=None,
        metavar="LAI",
        help="If given, overwrite MONTHLY_LAI for the selected PFT so all "
        "12 months equal this value (for SP/satellite-phenology runs that "
        "want a time-invariant LAI). If omitted, MONTHLY_LAI is left "
        "untouched.",
    )
    parser.add_argument(
        "--domain",
        metavar="FILE",
        help="Input ELM domain NetCDF file to also fix up (optional)",
    )
    parser.add_argument(
        "--domain-output",
        metavar="FILE",
        help="Output path for the fixed-up domain file (required if --domain is given)",
    )
    parser.add_argument(
        "--area-km2",
        type=float,
        default=None,
        metavar="AREA",
        help="If given (with --domain), overwrite the domain file's grid cell "
        "area to this value (km^2) -- e.g. the ATS mesh's actual cell area, "
        "when reusing a mesh built for a different domain. If omitted, the "
        "domain file's area is left untouched.",
    )
    args = parser.parse_args()

    if args.domain and not args.domain_output:
        print("--domain-output is required when --domain is given", file=sys.stderr)
        sys.exit(1)

    print(f"Reading: {args.INPUT}")
    try:
        ds = xr.load_dataset(args.INPUT)
    except FileNotFoundError:
        print(f"File not found: {args.INPUT}", file=sys.stderr)
        sys.exit(1)
    except OSError as e:
        print(f"Error opening file: {e}", file=sys.stderr)
        sys.exit(1)

    ds_out, pft_index = atself_surfdata(ds, pft_index=args.pft)

    if args.constant_lai is not None:
        ds_out = set_constant_lai(ds_out, pft_index, args.constant_lai)
        print(f"  Set MONTHLY_LAI[*, {pft_index}] = {args.constant_lai} (all 12 months)")

    print(f"Writing: {args.OUTPUT}  (PFT index {pft_index})")
    ds_out.to_netcdf(args.OUTPUT)
    print("Done.")

    if args.domain:
        print(f"Reading domain: {args.domain}")
        try:
            dom = xr.load_dataset(args.domain)
        except FileNotFoundError:
            print(f"File not found: {args.domain}", file=sys.stderr)
            sys.exit(1)
        except OSError as e:
            print(f"Error opening file: {e}", file=sys.stderr)
            sys.exit(1)

        if args.area_km2 is not None:
            dom = atsify_domain_area(dom, args.area_km2)
            print(f"  Set domain area = {args.area_km2} km^2")
        else:
            print("  --area-km2 not given; domain area left unchanged")

        print(f"Writing domain: {args.domain_output}")
        dom.to_netcdf(args.domain_output)
        print("Done.")


if __name__ == "__main__":
    main()
