"""Compare raw forcing-file met data against what ELM reports in its
history stream, for the idealized_evaporation example. Diagnostic for
tracking down where a diurnal cycle enters despite flat input forcing.
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
INPUTDATA_DIR = os.environ.get(
    "DIN_LOC_ROOT", os.path.join(SCRIPT_DIR, "..", "..", "inputdata")
)
BASE = os.path.join(E3SM_WORK_DIR, "idealized_evaporation")
FORCING_DIR = os.path.join(
    INPUTDATA_DIR, "atm", "datm7", "atm_forcing.idealized_evaporation"
)

RUNS = {
    "ELM-ATS": dict(suffix="elm-ats", color="tab:green"),
    "ELM+ATS IC": dict(suffix="ic_only", color="tab:orange"),
}

# forcing-file variable name -> (hist-file variable name, unit conversion)
MET_VARS = {
    "TBOT": ("TBOT", 1.0),
    "FSDS": ("FSDS", 1.0),
    "FLDS": ("FLDS", 1.0),
    "PSRF": ("PBOT", 1.0),
    "QBOT": (None, 1.0),
    "WIND": (None, 1.0),
    "PRECTmms": ("RAIN", 1.0),
}


def _fix_time(ds):
    if HAS_CFTIME and len(ds["time"]) > 0:
        if isinstance(ds["time"].values[0], cftime.datetime):
            import pandas as pd

            ds["time"] = pd.to_datetime(
                [t.strftime("%Y-%m-%d %H:%M:%S") for t in ds["time"].values]
            )
    return ds


def load_hist(suffix):
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


def load_forcing(var):
    path = os.path.join(FORCING_DIR, f"ATS-subdaily_{var}_z01.nc")
    ds = xr.open_dataset(path)
    return ds["DTIME"].values, ds[var].isel(n=0).values


def main():
    hist = {label: load_hist(cfg["suffix"]) for label, cfg in RUNS.items()}
    for label, ds in list(hist.items()):
        if ds is None:
            print(f"WARNING: no usable output for {label}, skipping in plot")
            del hist[label]

    forcing_vars = [v for v in MET_VARS if v != "PRECTmms" or True]
    n = len(forcing_vars)
    fig, axes = plt.subplots(n, 1, figsize=(9, 2.5 * n), sharex=True)

    for ax, fvar in zip(axes, forcing_vars):
        t_f, v_f = load_forcing(fvar)
        ax.plot(t_f, v_f, color="black", lw=2.5, ls="--", label="forcing file", alpha=0.6)

        hvar, scale = MET_VARS[fvar]
        if hvar is not None:
            for label, ds in hist.items():
                if hvar not in ds:
                    continue
                cfg = RUNS[label]
                y = ds[hvar].isel(lndgrid=0).values * scale
                ax.plot(ds["time"], y, color=cfg["color"], lw=1.2, label=f"hist: {label}")

        ax.set_ylabel(fvar)
        ax.legend(frameon=False, fontsize=8)
        ax.grid(alpha=0.3)

    axes[-1].set_xlabel("Time")
    fig.suptitle("idealized_evaporation: forcing file vs ELM history met data")
    fig.tight_layout()

    out_path = os.path.join(SCRIPT_DIR, "idealized_evaporation_met_data.png")
    fig.savefig(out_path, dpi=150)
    print(f"Saved {out_path}")


if __name__ == "__main__":
    main()
