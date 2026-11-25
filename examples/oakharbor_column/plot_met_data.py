"""Plot GSWP3 meteorological forcing (as seen by ELM) vs time for the
oakharbor_column example, from the monthly (h0) history files.
"""

import glob
import os

import matplotlib.pyplot as plt
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

RUNS = {
    "ELM (no ATS)": dict(suffix="elm", color="tab:blue"),
    "ELM+ATS IC": dict(suffix="ic_only", color="tab:orange"),
    "ELM-ATS": dict(suffix="elm-ats", color="tab:green"),
}

MET_VARS = [
    ("TBOT", "Air temperature (K)"),
    ("RAIN", "Rainfall (mm/s)"),
    ("SNOW", "Snowfall (mm/s)"),
    ("FSDS", "Incident shortwave (W/m^2)"),
    ("FLDS", "Incident longwave (W/m^2)"),
    ("WIND", "Wind speed (m/s)"),
    ("PBOT", "Surface pressure (Pa)"),
    ("QBOT", "Specific humidity (kg/kg)"),
]


def _fix_time(ds):
    if HAS_CFTIME and len(ds["time"]) > 0:
        if isinstance(ds["time"].values[0], cftime.datetime):
            import pandas as pd

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


def main():
    datasets = {label: load(cfg["suffix"]) for label, cfg in RUNS.items()}
    for label, ds in datasets.items():
        if ds is None:
            print(f"WARNING: no usable h0 output for {label}, skipping in plot")
    datasets = {label: ds for label, ds in datasets.items() if ds is not None}

    fig, axes = plt.subplots(len(MET_VARS), 1, figsize=(9, 2 * len(MET_VARS)), sharex=True)

    for ax, (var, ylabel) in zip(axes, MET_VARS):
        for label, ds in datasets.items():
            cfg = RUNS[label]
            data = ds[var].isel(lndgrid=0)
            ax.plot(ds["time"], data, color=cfg["color"], lw=1.2, label=label)
        ax.set_ylabel(ylabel)
        ax.set_title(var)
        ax.grid(alpha=0.3)

    axes[0].legend(frameon=False)
    axes[-1].set_xlabel("Time")

    fig.suptitle("oakharbor_column: GSWP3 meteorological forcing (monthly means)")
    fig.tight_layout()

    out_path = os.path.join(SCRIPT_DIR, "oakharbor_column_met_data.png")
    fig.savefig(out_path, dpi=150)
    plt.show()
    print(f"Saved {out_path}")


if __name__ == "__main__":
    main()
