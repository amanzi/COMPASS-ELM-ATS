"""Plot ground evaporation rate (QSOIL) and water table depth (ZWT) vs time
for the idealized_evaporation example, comparing ELM-ATS and ELM+ATS IC runs.
"""

import glob
import os

import matplotlib.pyplot as plt
import numpy as np
import xarray as xr

try:
    import cftime

    HAS_CFTIME = True
except ImportError:
    HAS_CFTIME = False

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
E3SM_WORK_DIR = os.environ.get(
    "E3SM_WORK_DIR", os.path.join(SCRIPT_DIR, "..", "..", "work")
)
BASE = os.path.join(E3SM_WORK_DIR, "idealized_evaporation")

RUNS = {
    "ELM-ATS": dict(suffix="elm-ats", color="tab:green"),
    "ELM+ATS IC": dict(suffix="ic_only", color="tab:orange"),
}


def _fix_time(ds):
    if HAS_CFTIME and len(ds["time"]) > 0:
        if isinstance(ds["time"].values[0], cftime.datetime):
            import pandas as pd

            ds["time"] = pd.to_datetime(
                [t.strftime("%Y-%m-%d %H:%M:%S") for t in ds["time"].values]
            )
    return ds


def load(suffix):
    pattern = f"{BASE}/{suffix}/run/*.elm.h1.*.nc"
    files = sorted(glob.glob(pattern))
    non_empty = []
    for f in files:
        probe = xr.open_dataset(f, decode_times=False)
        if probe.sizes.get("time", 0) > 0:
            non_empty.append(f)
        probe.close()
    if not non_empty:
        return None
    opened = [xr.open_dataset(f) for f in non_empty]
    ds = xr.concat(opened, dim="time")
    return _fix_time(ds)


def _layer_thickness(levgrnd):
    """Derive ELM soil layer thicknesses (m) from layer-center depths.

    ELM's h1 stream reports levgrnd (node depths) but not the layer
    thicknesses (dz) directly, so reconstruct interface depths as the
    midpoints between consecutive nodes (standard ELM/CLM convention),
    with the top interface at 0 and the bottom extrapolated symmetrically.
    """
    z = np.asarray(levgrnd)
    n = len(z)
    zi = np.zeros(n + 1)
    zi[1:n] = 0.5 * (z[:-1] + z[1:])
    zi[n] = z[-1] + 0.5 * (z[-1] - z[-2])
    return np.diff(zi)


def total_subsurface_water(ds):
    """Total subsurface water content (mm) integrated over the soil column."""
    dz = _layer_thickness(ds["levgrnd"].values)
    dz_da = xr.DataArray(dz, dims="levgrnd")
    h2osoi = ds["H2OSOI"].isel(lndgrid=0)
    return (h2osoi * dz_da).sum(dim="levgrnd") * 1000.0


def main():
    datasets = {label: load(cfg["suffix"]) for label, cfg in RUNS.items()}
    for label, ds in datasets.items():
        if ds is None:
            print(f"WARNING: no usable output for {label}, skipping in plot")
    datasets = {label: ds for label, ds in datasets.items() if ds is not None}

    fig, (ax_evap, ax_zwt, ax_tws) = plt.subplots(3, 1, figsize=(9, 10), sharex=True)

    for label, ds in datasets.items():
        cfg = RUNS[label]
        evap = ds["QSOIL"].isel(lndgrid=0) * 86400.0
        ax_evap.plot(ds["time"], evap, color=cfg["color"], lw=1.5, label=label)

    ax_evap.set_ylabel("QSOIL (mm/day)")
    ax_evap.set_title("Evaporation rate (ground evaporation)")
    ax_evap.legend(frameon=False)
    ax_evap.grid(alpha=0.3)

    for label, ds in datasets.items():
        cfg = RUNS[label]
        zwt = ds["ZWT"].isel(lndgrid=0)
        ax_zwt.plot(ds["time"], zwt, color=cfg["color"], lw=1.5, label=label)

    ax_zwt.invert_yaxis()
    ax_zwt.set_ylabel("ZWT (m below surface)")
    ax_zwt.set_title("Water table depth")
    ax_zwt.legend(frameon=False)
    ax_zwt.grid(alpha=0.3)

    for label, ds in datasets.items():
        cfg = RUNS[label]
        tws = total_subsurface_water(ds)
        ax_tws.plot(ds["time"], tws, color=cfg["color"], lw=1.5, label=label)

    ax_tws.set_ylabel("Total subsurface water (mm)")
    ax_tws.set_xlabel("Time")
    ax_tws.set_title("Total subsurface water content")
    ax_tws.legend(frameon=False)
    ax_tws.grid(alpha=0.3)

    fig.suptitle("idealized_evaporation: ELM-ATS vs ELM+ATS IC")
    fig.tight_layout()

    out_path = os.path.join(SCRIPT_DIR, "idealized_evaporation_evap_zwt.png")
    fig.savefig(out_path, dpi=150)
    plt.show()
    print(f"Saved {out_path}")


if __name__ == "__main__":
    main()
