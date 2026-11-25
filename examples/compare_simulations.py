"""Compare ELM, ELM+ATS IC, and ELM-ATS simulation outputs.

Works with any COMPASS-ELM-ATS test case. Automatically discovers
available variables from the loaded datasets.
"""

import argparse
import glob
import os
import re
import sys

import matplotlib.pyplot as plt
import numpy as np
import xarray as xr

cftime = None  # placeholder to satisfy static analysis
try:
    import cftime

    HAS_CFTIME = True
except ImportError:
    HAS_CFTIME = False

# Dimensions to skip when listing plottable variables
SKIP_VARS = {"time", "mcdate", "mcsec", "mdcur", "mscur", "nstep",
             "time_bounds", "date_written", "time_written",
             "lon", "lat", "area", "landfrac", "landmask", "pftmask",
             "levgrnd", "levsoi", "levdcmp", "levlak", "levurb",
             "cols1d_lon", "cols1d_lat", "cols1d_ixy", "cols1d_jxy",
             "cols1d_gridcell_index", "cols1d_wtgcell", "cols1d_active",
             "cols1d_itype_col", "cols1d_itype_lunit",
             "pfts1d_lon", "pfts1d_lat", "pfts1d_ixy", "pfts1d_jxy",
             "pfts1d_gridcell_index", "pfts1d_wtgcell", "pfts1d_active",
             "pfts1d_itype_veg", "pfts1d_itype_lunit",
             "land1d_lon", "land1d_lat", "land1d_ixy", "land1d_jxy",
             "land1d_gridcell_index", "land1d_wtgcell", "land1d_active",
             "land1d_ityplunit"}

SIM_SUFFIXES = {
    "ELM": "elm",
    "ELM+ATS IC": "ic_only",
    "ELM-ATS": "elm-ats",
}

SIM_COLORS = {
    "ELM": "C0",
    "ELM+ATS IC": "C1",
    "ELM-ATS": "C2",
}

DEPTH_DIMS = ("levgrnd", "levsoi", "levdcmp")

# Depth threshold (m) for the shallow contour plots
SHALLOW_DEPTH_M = 4.0

VARIABLE_GROUPS = {
    "hydrology": {
        "DWB", "H2OSFC", "H2OSNO", "H2OSNO_TOP", "INT_SNOW",
        "FSAT", "FINUNDATED", "FINUNDATED_LAG",
        "BSW",
        # Add any additional water‑related variables that appear in future cases.
    },
    "soil": {
        "ZSOI", "DZSOI",
    },
    "biogeochemistry": {
        "CPOOL", "CWDC", "CWDN", "CWDP",
        "CWDC_HR", "CWDC_LOSS", "CWDC_TO_LITR2C", "CWDC_TO_LITR3C",
        "CWDN_TO_LITR2N", "CWDN_TO_LITR3N",
        "CWDP_TO_LITR2P", "CWDP_TO_LITR3P",
        "DEADCROOTC", "DEADCROOTN", "DEADCROOTP",
        "DEADSTEMC", "DEADSTEMN", "DEADSTEMP",
        "DENIT", "NIT", "F_DENIT", "F_DENIT_vr",
        "F_N2O_DENIT", "F_N2O_NIT",
        "BIOCHEM_PMIN", "BIOCHEM_PMIN_TO_PLANT",
        "F_PMIN", "F_PMIN_vr", "F_NMIN", "F_NMIN_vr",
        "CH4PROD", "FCH4", "FCH4TOCO2", "FCH4_DFSAT",
        "CH4_SURF_AERE_SAT", "CH4_SURF_AERE_UNSAT",
        "CH4_SURF_DIFF_SAT", "CH4_SURF_DIFF_UNSAT",
        "CH4_SURF_EBUL_SAT", "CH4_SURF_EBUL_UNSAT",
        "CONC_CH4_SAT", "CONC_CH4_UNSAT",
        "CONC_O2_SAT", "CONC_O2_UNSAT",
        "F_CO2_SOIL", "F_CO2_SOIL_vr",
        "F_IRR", "F_IRR_R", "F_IRR_U",
    },
    "vegetation": {
        "GPP", "AGNPP", "AGWDNPP", "ELAI", "ELAI_MAX",
        "FROOTC", "FROOTC_ALLOC", "FROOTC_LOSS",
        "FROOTN", "FROOTP",
        "FPI", "FPI_P", "FPI_vr", "FPI_P_vr",
        "FPG", "FPG_P",
        "FAREA_BURNED", "FIRE", "FIRE_R", "FIRE_U",
        "FIRA", "FIRA_R", "FIRA_U",
        "LAI", "LAI_MAX", "LAI_MIN",
    },
    "energy": {
        "EFLX_DYNBAL", "EFLX_LH_TOT", "EFLX_LH_TOT_R", "EFLX_LH_TOT_U",
        "EFLX_GRND_LAKE",
        "FCEV", "FGEV", "FSA", "FSA_R", "FSA_U",
        "FSDS", "FSDSND", "FSDSNDLN", "FSDSNI",
        "FSDSVD", "FSDSVDLN", "FSDSVI", "FSDSVILN",
        "FSAT", "FGR", "FGR_R", "FGR_U",
        "HR", "HR_vr", "ER", "ER_vr",
        "FSNO", "FSNO_EFF",
        "FIRR", "FIRR_R", "FIRR_U",
    },
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _fix_time(ds):
    """Convert cftime datetimes to standard datetimes for matplotlib."""
    if HAS_CFTIME and len(ds["time"]) > 0 and cftime is not None:
        # Check if the first time value is a cftime datetime instance
        if isinstance(ds["time"].values[0], getattr(cftime, "datetime", type(None))):
            import pandas as pd

            ds["time"] = pd.to_datetime(
                [t.strftime("%Y-%m-%d %H:%M:%S") for t in ds["time"].values]
            )
    return ds


def _discover_variables(datasets):
    """Return sorted list of plottable variables found across all datasets."""
    all_vars = set()
    for ds in datasets.values():
        for var in ds.data_vars:
            if var in SKIP_VARS:
                continue
            if "time" not in ds[var].dims:
                continue
            all_vars.add(var)
    return sorted(all_vars)


def _get_depth_dim(da):
    """Return the name of the first depth dimension found in da, or None."""
    return next((d for d in DEPTH_DIMS if d in da.dims), None)


def _normalize_depth_array(da, depth_dim):
    """Return a 2-D numpy array shaped (n_time, n_depth).

    Any extra non-time/non-depth dimensions are averaged out.
    """
    extra = [d for d in da.dims if d not in ("time", depth_dim)]
    if extra:
        da = da.mean(dim=extra)
    return da.transpose("time", depth_dim).values


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare ELM, ELM+ATS IC, and ELM-ATS simulations."
    )
    parser.add_argument(
        "--base-dir",
        required=True,
        help="Path to E3SM_WORK_DIR (contains the <case-name>/ campaign subdirectory).",
    )
    parser.add_argument(
        "--case-name",
        required=True,
        help="Case name as it appears in output paths (e.g. oakharbor_column, "
        "oakharbor_transect.np1).",
    )
    parser.add_argument(
        "--hist-file",
        default="h0",
        choices=["h0", "h1"],
        help="History file stream to load (default: h0).",
    )
    parser.add_argument(
        "--output-dir",
        default="./figures",
        help="Directory for saved figures (default: ./figures).",
    )
    parser.add_argument(
        "--variables",
        nargs="+",
        default=None,
        help="Specific variables to plot (default: auto-discover from data).",
    )
    parser.add_argument(
        "--groups",
        nargs="+",
        default=None,
        help="Pre-defined groups of variables to plot (e.g. hydrology soil).",
    )
    parser.add_argument(
        "--list-groups",
        action="store_true",
        help="Print the available variable groups and exit.",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Data loading
# ---------------------------------------------------------------------------

def load_simulations(base_dir, case_name, hist_file):
    """Load output datasets for all three simulations.

    Returns a dict mapping simulation label to xarray.Dataset.
    xarray decodes times using cftime for non-standard calendars (e.g. no_leap);
    _fix_time converts these to pandas datetimes for matplotlib compatibility.
    """
    datasets = {}
    for label, suffix in SIM_SUFFIXES.items():
        pattern = os.path.join(
            base_dir,
            case_name,
            suffix,
            "run",
            f"{case_name}.{suffix}.elm.{hist_file}.*.nc",
        )
        print(f"Loading {label}: {pattern}")
        files = sorted(glob.glob(pattern))
        if not files:
            print(f"  No files found for {label}, skipping.")
            continue
        ds = xr.concat(
            [xr.open_dataset(f) for f in files],
            dim="time",
        )
        datasets[label] = _fix_time(ds)
    return datasets


def _get_long_name(var, ds):
    """Return the variable's long_name attribute if present, otherwise the variable name.

    Parameters
    ----------
    var: str
        Variable name.
    ds: xarray.Dataset
        Dataset containing the variable.
    """
    attrs = ds[var].attrs
    return attrs.get("long_name", var)

def plot_timeseries(datasets, variables, output_dir, hist_file):
    """Time series for surface (non-depth) variables, all simulations on one axes."""
    for var in variables:
        available = {k: ds for k, ds in datasets.items() if var in ds}
        if not available:
            print(f"  Skipping {var}: not found in any dataset.")
            continue

        sample_ds = next(iter(available.values()))
        long_name = _get_long_name(var, sample_ds)
        dims = sample_ds[var].dims
        has_depth = any(d in dims for d in ("levgrnd", "levsoi", "levdcmp"))

        if has_depth:
            # 2‑D contour: time vs depth, one subplot per simulation (stacked vertically)
            depth_dim = next(d for d in ("levgrnd", "levsoi", "levdcmp") if d in dims)
            depth_vals = sample_ds[depth_dim].values
            # Gather data from all simulations to compute a common colour scale
            all_data = []
            for ds in available.values():
                d = ds[var].values
                d = np.squeeze(d)
                if d.ndim == 2:
                    if d.shape[0] == len(depth_vals) and d.shape[1] == len(ds["time"]):
                        d = d.T
                elif d.ndim > 2:
                    d = d.mean(axis=tuple(range(2, d.ndim)))
                    if d.shape[0] == len(depth_vals) and d.shape[1] == len(ds["time"]):
                        d = d.T
                # Align shapes (trim if needed)
                t_vals = ds["time"].values
                if d.shape != (len(depth_vals), len(t_vals)):
                    if d.shape == (len(t_vals), len(depth_vals)):
                        d = d.T
                    else:
                        min_len = min(d.shape[-1], len(t_vals))
                        min_dep = min(d.shape[0], len(depth_vals))
                        d = d[:min_dep, :min_len]
                        t_vals = t_vals[:min_len]
                        depth_vals = depth_vals[:min_dep]
                all_data.append(d)
            # Compute global min/max ignoring NaNs
            global_min = np.nanmin([np.nanmin(d) for d in all_data])
            global_max = np.nanmax([np.nanmax(d) for d in all_data])
            # Create subplots
            fig, axes = plt.subplots(
                len(available), 1, figsize=(10, 3 * len(available)), sharex=True, sharey=True
            )
            # Adjust layout to make room for the shared colourbar
            fig.subplots_adjust(right=0.85)
            if len(available) == 1:
                axes = [axes]
            # Ensure deterministic order of simulations
            sim_items = list(available.items())
            cf = None  # will hold the last contour for colorbar
            for ax, (label, ds) in zip(axes, sim_items):
                data = ds[var].values
                data = np.squeeze(data)
                if data.ndim == 2:
                    if data.shape[0] == len(depth_vals) and data.shape[1] == len(ds["time"]):
                        data = data.T
                elif data.ndim > 2:
                    data = data.mean(axis=tuple(range(2, data.ndim)))
                    if data.shape[0] == len(depth_vals) and data.shape[1] == len(ds["time"]):
                        data = data.T
                time_vals = ds["time"].values
                if data.shape != (len(depth_vals), len(time_vals)):
                    if data.shape == (len(time_vals), len(depth_vals)):
                        data = data.T
                    else:
                        min_len = min(data.shape[-1], len(time_vals))
                        min_dep = min(data.shape[0], len(depth_vals))
                        data = data[:min_dep, :min_len]
                        time_vals = time_vals[:min_len]
                        depth_vals = depth_vals[:min_dep]
                # Use common colour limits
                cf = ax.contourf(time_vals, depth_vals, data, cmap="viridis", vmin=global_min, vmax=global_max)
                ax.set_ylabel("Depth (m)")
                ax.set_title(label)
                ax.invert_yaxis()
            # Add a single shared colourbar for the whole figure if contour data exists
            if cf is not None:
                cbar = fig.colorbar(cf, ax=axes, orientation="vertical", label=f"{var} ({long_name})", fraction=0.046, pad=0.04)
            axes[-1].set_xlabel("Time")
            fig.suptitle(f"{var} ({long_name}) — Time‑Depth Contour", fontsize=14)
        else:
            fig, ax = plt.subplots(figsize=(10, 4))
            for label, ds in available.items():
                data = ds[var].squeeze()
                ax.plot(ds["time"], data, label=label, color=SIM_COLORS[label])
            ax.set_ylabel(f"{var} ({long_name})")
            ax.set_xlabel("Time")
            ax.set_title(f"{long_name} — Time Series")
            ax.legend(loc='upper left', bbox_to_anchor=(1, 1))
            ax.grid(True, alpha=0.3)

        plt.tight_layout(rect=(0,0,0.85,1))
        fig.savefig(os.path.join(output_dir, f"timeseries_{var}_{hist_file}.png"), dpi=150, bbox_inches='tight')
        plt.close(fig)
        print(f"  Saved timeseries_{var}_{hist_file}.png")


def _format_time(t):
    """Return a short string representation of a time coordinate element.

    Handles NumPy ``datetime64`` objects, pandas ``Timestamp``/``datetime``
    objects, and plain numeric values (e.g., days since a reference).
    """
    # First, handle pandas Timestamp or Python datetime objects that have ``strftime``
    if hasattr(t, "strftime"):
        try:
            return t.strftime("%Y-%m-%d")
        except Exception:
            pass
    # NumPy datetime64 (or generic NumPy scalar that can be cast)
    if isinstance(t, np.generic):
        # Convert NumPy scalar (including datetime64) to string safely
        try:
            return str(t)
        except Exception:
            pass
    # Fallback: handle pure numeric values (e.g., days since reference) or generic fallback
    if isinstance(t, (int, float, np.number)):
        return str(t)
    try:
        return np.datetime_as_string(np.array(t, dtype="datetime64[ns]"), unit="D")
    except Exception:
        return str(t)

def plot_profiles(datasets, variables, output_dir, hist_file):
    """Plot vertical profiles for soil variables at selected time steps."""
    # Identify variables that have a depth dimension across any dataset
    depth_vars = []
    for v in variables:
        for ds in datasets.values():
            if v in ds and any(d in ds[v].dims for d in ("levgrnd", "levsoi", "levdcmp")):
                depth_vars.append(v)
                break
    if not depth_vars:
        return
    for var in depth_vars:
        available = {k: ds for k, ds in datasets.items() if var in ds}
        if not available:
            continue

        sample_ds = next(iter(available.values()))
        depth_dim = _get_depth_dim(sample_ds[var])
        if depth_dim is None:
            continue

        depth_vals = sample_ds[depth_dim].values
        n = len(depth_vals)
        indices = sorted({0, n // 4, n // 2, 3 * n // 4, n - 1})

        fig, axes = plt.subplots(len(indices), 1, figsize=(10, 3 * len(indices)), sharex=True)
        if len(indices) == 1:
            axes = [axes]

        # Determine the display name for the variable once, before plotting axes
        long_name = _get_long_name(var, sample_ds)
        for ax, ti in zip(axes, snap_indices):
            # Use robust formatting for the time label
            t_val = _format_time(sample_ds["time"].values[ti])
            for label, ds in available.items():
                depths = ds[depth_dim].values
                values = ds[var].isel(time=ti).squeeze().values
                ax.plot(values, depths, label=label, color=SIM_COLORS[label])
            ax.set_title(f"t = {t_val}")
            ax.set_xlabel(f"{var} ({long_name})")
            ax.invert_yaxis()
            ax.legend(fontsize="small")
            ax.grid(True, alpha=0.3)

        axes[0].set_ylabel("Depth (m)")
        long_name = _get_long_name(var, sample_ds)
        fig.suptitle(f"{var} ({long_name}) — Vertical Profiles", fontsize=14)
        plt.tight_layout(rect=(0,0,0.85,1))
        fig.savefig(os.path.join(output_dir, f"profile_{var}_{hist_file}.png"), dpi=150, bbox_inches='tight')
        plt.close(fig)
        print(f"  Saved depth_lines_{var}_{hist_file}.png")


def plot_depth_contour(datasets, variables, output_dir, hist_file, max_depth=None):
    """(b/c) Depth variables: time–depth contour, one subplot per simulation.

    A single shared colorbar is applied across all simulation subplots.
    If max_depth is given, only levels with depth <= max_depth are shown.
    """
    fname_suffix = f"_top{int(max_depth)}m" if max_depth is not None else ""

    for var in variables:
        available = {k: ds for k, ds in datasets.items() if var in ds}
        if not available:
            continue

        sample_ds = next(iter(available.values()))
        depth_dim = _get_depth_dim(sample_ds[var])
        if depth_dim is None:
            continue

        depth_vals = sample_ds[depth_dim].values
        if max_depth is not None:
            depth_mask = depth_vals <= max_depth
        else:
            depth_mask = np.ones(len(depth_vals), dtype=bool)
        plot_depths = depth_vals[depth_mask]

        # Build (time, depth) arrays and compute shared colour limits
        arrays = {
            label: _normalize_depth_array(ds[var], depth_dim)[:, depth_mask]
            for label, ds in available.items()
        }
        vmin = np.nanmin([np.nanmin(a) for a in arrays.values()])
        vmax = np.nanmax([np.nanmax(a) for a in arrays.values()])

        fig, axes = plt.subplots(
            1, len(available), figsize=(6 * len(available), 5), sharey=True
        )
        if len(available) == 1:
            axes = [axes]

        cf = None
        for ax, (label, ds) in zip(axes, available.items()):
            cf = ax.contourf(
                ds["time"].values,
                plot_depths,
                arrays[label].T,  # (depth, time)
                cmap="viridis",
                vmin=vmin,
                vmax=vmax,
            )
            ax.set_title(label)
            ax.set_xlabel("Time")
            ax.invert_yaxis()
        axes[0].set_ylabel("Depth (m)")
        fig.colorbar(cf, ax=list(axes), orientation="vertical", label=var)
        title = f"{var} — Time–Depth Contour"
        if max_depth is not None:
            title += f" (top {max_depth} m)"
        fig.suptitle(title, fontsize=14)
        plt.tight_layout()
        fname = f"contour_{var}{fname_suffix}_{hist_file}.png"
        fig.savefig(os.path.join(output_dir, fname), dpi=150)
        plt.close(fig)
        print(f"  Saved {fname}")


def plot_differences(datasets, variables, output_dir, hist_file):
    """Time series of differences relative to ELM-only for each variable."""
    if "ELM" not in datasets:
        print("  ELM baseline not available; skipping difference plots.")
        return

    ref = datasets["ELM"]
    diff_labels = {
        "ELM-ATS minus ELM": "ELM-ATS",
        "ELM+ATS IC minus ELM": "ELM+ATS IC",
    }
    diff_colors = {
        "ELM-ATS minus ELM": "C2",
        "ELM+ATS IC minus ELM": "C1",
    }

    for var in variables:
        if var not in ref:
            continue

        depth_dim = _get_depth_dim(ref[var])
        fig, ax = plt.subplots(figsize=(10, 4))

        if depth_dim is not None:
            for diff_label, sim_label in diff_labels.items():
                if sim_label not in datasets or var not in datasets[sim_label]:
                    continue
                sim_ds = datasets[sim_label]
                common_times = np.intersect1d(ref["time"].values, sim_ds["time"].values)
                if common_times.size == 0:
                    print(f"  Skipping {var} diff for {sim_label}: no overlapping times.")
                    continue
                diff = (
                    sim_ds[var].sel(time=common_times).mean(dim=depth_dim)
                    - ref[var].sel(time=common_times).mean(dim=depth_dim)
                ).squeeze()
                ax.plot(common_times, diff, label=diff_label, color=diff_colors[diff_label])
            ax.set_ylabel(f"Delta {var} (depth-averaged)")
            ax.legend(loc='upper left', bbox_to_anchor=(1, 1))
        else:
            for diff_label, sim_label in diff_labels.items():
                if sim_label not in datasets or var not in datasets[sim_label]:
                    continue
                sim_ds = datasets[sim_label]
                common_times = np.intersect1d(ref["time"].values, sim_ds["time"].values)
                if common_times.size == 0:
                    print(f"  Skipping {var} diff for {sim_label}: no overlapping times.")
                    continue
                diff = (
                    sim_ds[var].sel(time=common_times) - ref[var].sel(time=common_times)
                ).squeeze()
                ax.plot(common_times, diff, label=diff_label, color=diff_colors[diff_label])
            ax.set_ylabel(f"Delta {var}")

        ax.axhline(0, color="k", linewidth=0.5)
        ax.set_xlabel("Time")
        ax.set_title(f"{var} — Differences from ELM")
        ax.legend(loc='upper left', bbox_to_anchor=(1, 1))
        ax.grid(True, alpha=0.3)
        plt.tight_layout(rect=(0,0,0.85,1))
        fig.savefig(os.path.join(output_dir, f"diff_{var}_{hist_file}.png"), dpi=150, bbox_inches='tight')
        plt.close(fig)
        print(f"  Saved diff_{var}_{hist_file}.png")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()
    os.makedirs(args.output_dir, exist_ok=True)

    if args.list_groups:
        print("Available variable groups:")
        for g, vars_ in VARIABLE_GROUPS.items():
            print(f"  {g}: {', '.join(sorted(vars_))}")
        sys.exit(0)

    print("Loading simulations...")
    datasets = load_simulations(args.base_dir, args.case_name, args.hist_file)

    # Expand hydrology group to capture Q*, RAIN, SNOW, and other water variables
    all_ds_vars = set()
    for ds in datasets.values():
        all_ds_vars.update(ds.data_vars)
    hydro_patterns = [
        r"^Q", r"RAIN", r"SNOW", r"H2OS?FC", r"H2OSNO", r"WATSAT", r"SUCSAT",
        r"BSW", r"HKSAT", r"FINUNDATED", r"INT_SNOW", r"FSAT", r"ZWT",
        r"RETRANSP", r"RETRANSN", r"OVER", r"IRR", r"DRIP", r"DWB",
        r"ALT", r"ALTMAX", r"SOILLIQ", r"SOILICE",
    ]
    # Variables to explicitly exclude from hydrology group even if they match patterns.
    exclude_vars = {
        "ALT", "ALTMAX", "ALTMAX_LASTYEAR", "RAIN", "SNOW", "WATSAT", "HKSAT", "SUCSAT",
        "water_scaler",
        "QBOT", "QFLOOD", "QFLOOD_.*", "QFLX_ICE_DYNBAL", "QFLX_LIQ_DYNBAL",
        "QIRRIG", "QIRRIG_.*", "RETRANSN", "RETRANSP",
    }
    for v in all_vars:
        if any(re.search(p, v, re.I) for p in hydro_patterns):
            # Skip excluded variables (exact match or pattern match)
            if v in exclude_vars:
                continue
            # Additional pattern-based exclusions (wildcards handled via regex)
            if any(re.match(pat, v) for pat in [r'QFLOOD.*', r'QFLX_ICE_DYNBAL', r'QFLX_LIQ_DYNBAL', r'QIRRIG.*']):
                continue
            VARIABLE_GROUPS.setdefault('hydrology', set()).add(v)

    if not datasets:
        print("No simulation data found. Nothing to plot.")
        return

    # Determine variables to plot
    requested = set()
    if args.variables:
        requested.update(args.variables)
    if args.groups:
        unknown = [g for g in args.groups if g not in VARIABLE_GROUPS]
        if unknown:
            sys.exit(f"Error: unknown group(s): {', '.join(unknown)}")
        for g in args.groups:
            requested.update(VARIABLE_GROUPS[g])

    if not requested:
        available_vars = _discover_variables(datasets)
    else:
        available_vars = sorted(v for v in requested if any(v in ds for ds in datasets.values()))
        missing = requested - set(available_vars)
        if missing:
            print(f"Warning: variables not found in any file: {', '.join(sorted(missing))}")

    print(f"Variables to plot: {available_vars}")

    print("\nGenerating time series plots...")
    plot_timeseries(datasets, available_vars, args.output_dir, args.hist_file)

    print("\nGenerating depth line plots (a)...")
    plot_depth_lines(datasets, available_vars, args.output_dir, args.hist_file)

    print("\nGenerating depth contour plots (b) — full column...")
    plot_depth_contour(datasets, available_vars, args.output_dir, args.hist_file)

    print(f"\nGenerating depth contour plots (c) — top {SHALLOW_DEPTH_M} m...")
    plot_depth_contour(
        datasets, available_vars, args.output_dir, args.hist_file, max_depth=SHALLOW_DEPTH_M
    )

    print("\nGenerating difference plots...")
    plot_differences(datasets, available_vars, args.output_dir, args.hist_file)

    print(f"\nDone. Figures saved to {args.output_dir}/")


if __name__ == "__main__":
    main()
