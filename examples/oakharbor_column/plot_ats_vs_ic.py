"""Compare ELM-ATS vs ELM+ATS IC water balance for oakharbor_column: ET
terms (QSOIL/QVEGE/QVEGT), integrated (cumulative) runoff, and total water
storage (TWS), from the monthly (h0) history files.
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
BASE = os.path.join(E3SM_WORK_DIR, "oakharbor_column")

RUNS = {
    "ELM-ATS": dict(suffix="elm-ats", color="tab:green"),
    "ELM+ATS IC": dict(suffix="ic_only", color="tab:orange"),
}

SECONDS_PER_DAY = 86400.0


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


def days_in_month(time_da):
    """Approximate days-per-record from consecutive time deltas (h0 is
    monthly-mean but not evenly spaced in days), needed to integrate a
    mm/s rate into mm of accumulated depth.
    """
    t = time_da.values
    deltas = np.diff(t).astype("timedelta64[s]").astype(float) / SECONDS_PER_DAY
    # First record: assume same spacing as the second (no left-neighbor).
    deltas = np.concatenate([[deltas[0]], deltas])
    return deltas


def cumulative_mm(rate_mm_s, time_da):
    """Integrate a mm/s rate over time into cumulative mm."""
    dt_days = days_in_month(time_da)
    dt_s = dt_days * SECONDS_PER_DAY
    return np.cumsum(rate_mm_s.values * dt_s)


def main():
    datasets = {label: load(cfg["suffix"]) for label, cfg in RUNS.items()}
    for label, ds in datasets.items():
        if ds is None:
            print(f"WARNING: no usable h0 output for {label}, skipping in plot")
    datasets = {label: ds for label, ds in datasets.items() if ds is not None}

    fig, axes = plt.subplots(4, 1, figsize=(9, 14), sharex=True)
    ax_et, ax_runoff_rate, ax_runoff_cum, ax_tws = axes

    et_vars = [("QSOIL", "-"), ("QVEGE", "--"), ("QVEGT", ":")]
    for label, ds in datasets.items():
        cfg = RUNS[label]
        for var, ls in et_vars:
            data = ds[var].isel(lndgrid=0) * SECONDS_PER_DAY
            ax_et.plot(ds["time"], data, color=cfg["color"], ls=ls, lw=1.3,
                       label=f"{var} ({label})")
    ax_et.set_ylabel("Flux (mm/day)")
    ax_et.set_title("ET terms: QSOIL (soil evap, solid), QVEGE (canopy evap, dash), QVEGT (transpiration, dot)")
    ax_et.legend(frameon=False, fontsize=7, ncol=2)
    ax_et.grid(alpha=0.3)

    for label, ds in datasets.items():
        cfg = RUNS[label]
        data = ds["QRUNOFF"].isel(lndgrid=0) * SECONDS_PER_DAY
        ax_runoff_rate.plot(ds["time"], data, color=cfg["color"], lw=1.3, label=label)
    ax_runoff_rate.set_ylabel("QRUNOFF (mm/day)")
    ax_runoff_rate.set_title("Total runoff rate")
    ax_runoff_rate.legend(frameon=False)
    ax_runoff_rate.grid(alpha=0.3)

    for label, ds in datasets.items():
        cfg = RUNS[label]
        cum = cumulative_mm(ds["QRUNOFF"].isel(lndgrid=0), ds["time"])
        ax_runoff_cum.plot(ds["time"], cum, color=cfg["color"], lw=1.5, label=label)
    ax_runoff_cum.set_ylabel("Cumulative QRUNOFF (mm)")
    ax_runoff_cum.set_title("Integrated (cumulative) runoff")
    ax_runoff_cum.legend(frameon=False)
    ax_runoff_cum.grid(alpha=0.3)

    for label, ds in datasets.items():
        cfg = RUNS[label]
        data = ds["TWS"].isel(lndgrid=0)
        ax_tws.plot(ds["time"], data, color=cfg["color"], lw=1.5, label=label)
    ax_tws.set_ylabel("TWS (mm)")
    ax_tws.set_xlabel("Time")
    ax_tws.set_title("Total water storage")
    ax_tws.legend(frameon=False)
    ax_tws.grid(alpha=0.3)

    fig.suptitle("oakharbor_column: ELM-ATS vs ELM+ATS IC water balance")
    fig.tight_layout()

    out_path = os.path.join(SCRIPT_DIR, "oakharbor_column_ats_vs_ic.png")
    fig.savefig(out_path, dpi=150)
    plt.show()
    print(f"Saved {out_path}")


if __name__ == "__main__":
    main()
