"""Compare satellite-phenology forcing (MONTHLY_LAI/SAI/HEIGHT from the
surface dataset) against the corresponding ELM history output (TLAI/TSAI)
for the oakharbor_column example, to confirm SP-mode picked up the
prescribed monthly climatology correctly.
"""

import glob
import os

import matplotlib.pyplot as plt
import netCDF4 as nc
import numpy as np
import pandas as pd
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
BASE = os.path.join(E3SM_WORK_DIR, "oakharbor_column")
SURFDATA = os.path.join(
    os.environ.get(
        "ELM_ATS_SRC_DIR", os.path.join(SCRIPT_DIR, "..", "..")
    ),
    "inputdata", "lnd", "clm2", "surfdata_map", "surfdata_oakharbor_column.nc",
)
DOMINANT_PFT = 15  # c3_crop, 100% PCT_NAT_PFT in this single-column surface file

RUNS = {
    "ELM (no ATS)": dict(suffix="elm", color="tab:blue"),
    "ELM+ATS IC": dict(suffix="ic_only", color="tab:orange"),
    "ELM-ATS": dict(suffix="elm-ats", color="tab:green"),
}


def _fix_time(ds):
    if HAS_CFTIME and len(ds["time"]) > 0:
        if isinstance(ds["time"].values[0], cftime.datetime):
            ds["time"] = pd.to_datetime(
                [t.strftime("%Y-%m-%d %H:%M:%S") for t in ds["time"].values]
            )
    return ds


def load(suffix):
    pattern = f"{BASE}/{suffix}/run/*.elm.h0.*.nc"
    files = sorted(glob.glob(pattern))
    if not files:
        return None
    opened = [xr.open_dataset(f) for f in files]
    ds = xr.concat(opened, dim="time").sortby("time")
    return _fix_time(ds)


def monthly_forcing_series(varname, time_index):
    """Tile the surface file's 12-month climatology (for DOMINANT_PFT) across
    the calendar years spanned by time_index, so it can be overlaid on the
    multi-year history time series -- SP mode repeats the same climatology
    every year, there's no interannual variation in the forcing itself.
    """
    f = nc.Dataset(SURFDATA)
    monthly = f.variables[varname][:, DOMINANT_PFT, 0, 0]
    f.close()

    years = sorted(set(time_index.year))
    dates, vals = [], []
    for yr in years:
        for m in range(12):
            dates.append(pd.Timestamp(year=yr, month=m + 1, day=15))
            vals.append(monthly[m])
    return pd.Series(vals, index=pd.DatetimeIndex(dates))


def main():
    datasets = {label: load(cfg["suffix"]) for label, cfg in RUNS.items()}
    for label, ds in datasets.items():
        if ds is None:
            print(f"WARNING: no usable h0 output for {label}, skipping in plot")
    datasets = {label: ds for label, ds in datasets.items() if ds is not None}

    any_ds = next(iter(datasets.values()))
    time_index = pd.DatetimeIndex(any_ds["time"].values)

    panels = [
        ("TLAI", "MONTHLY_LAI", "Total LAI (m^2/m^2)"),
        ("TSAI", "MONTHLY_SAI", "Total SAI (m^2/m^2)"),
    ]

    fig, axes = plt.subplots(len(panels), 1, figsize=(9, 4 * len(panels)), sharex=True)

    for ax, (hist_var, forc_var, ylabel) in zip(axes, panels):
        forcing = monthly_forcing_series(forc_var, time_index)
        ax.plot(
            forcing.index, forcing.values,
            color="k", lw=1.5, ls="--", marker="o", ms=4,
            label=f"{forc_var} forcing (PFT {DOMINANT_PFT})",
        )
        for label, ds in datasets.items():
            cfg = RUNS[label]
            data = ds[hist_var].isel(lndgrid=0)
            ax.plot(ds["time"], data, color=cfg["color"], lw=1.2, label=f"{hist_var} ({label})")
        ax.set_ylabel(ylabel)
        ax.set_title(f"{hist_var} vs {forc_var}")
        ax.grid(alpha=0.3)
        ax.legend(frameon=False, fontsize=8)

    axes[-1].set_xlabel("Time")
    fig.suptitle("oakharbor_column: satellite-phenology forcing vs history output")
    fig.tight_layout()

    out_path = os.path.join(SCRIPT_DIR, "oakharbor_column_sp_veg.png")
    fig.savefig(out_path, dpi=150)
    plt.show()
    print(f"Saved {out_path}")


if __name__ == "__main__":
    main()
