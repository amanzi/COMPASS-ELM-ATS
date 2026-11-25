#!/usr/bin/env python3
"""plot_elm.py -- Plot ELM (carbon spinup / cyclic steady-state / ...)
forcing vs. ELM output for any case in the coweeta multi-stage campaign.

Reads every available monthly history file (*.elm.h0.YYYY-MM.nc) from a
case's run directory, plus the cyclic spinup forcing files it was driven
with, and produces a four-panel PNG:

  1. Forcing vs. ELM check (precipitation, twin axis: incident shortwave):
     forcing (hourly->daily mean, and monthly-integrated) vs. ELM's own RAIN
     diagnostic (monthly mean) on the left axis, and forcing vs. ELM's FSDS
     diagnostic on a twin right axis -- confirms ELM is actually receiving
     the forcing correctly.
  2. Water table position relative to the local land surface: `-ZWT` (ZWT is
     ELM's own depth-below-local-surface diagnostic, so this is 0 at the
     surface and negative with depth) over the full run, showing the median
     and 10th-90th percentile spread across all grid cells. Plotted relative
     to each cell's own surface rather than in absolute elevation, since
     Coweeta's ~850 m of topographic relief otherwise swamps the (order-
     meters) water table dynamics this panel is meant to show.
  3. Per-PFT leaf area index: per-cell TLAI apportioned to each present PFT
     by its `PCT_NAT_PFT` area fraction -- one line (median, with 10th-90th
     pct band across cells) per PFT actually present on the domain (inferred
     from the history file itself, not hardcoded).
  4. Subsurface/detrital carbon pools: TOTSOMC (soil organic matter),
     TOTLITC (litter), and CWDC (coarse woody debris) over the full run,
     each as a domain mean with a 10th-90th pct band across cells.

Usage:
    python3 plot_elm.py RUN_DIR [--forcing-dir DIR] [--out PNG]

RUN_DIR is a case's run directory, e.g. .../1c_pft_columns/run -- the same
directory the history files themselves live in. --forcing-dir defaults to
RUN_DIR/../../inputdata/atm_forcing_spinup (the campaign directory is
always two levels up from a case's run directory, per build_example.sh's
layout). --out is the output PNG path; if omitted, the plot is shown
interactively instead of saved.

Requires netCDF4, numpy, matplotlib (no watershed_workflow/conda env needed).
"""
import argparse
import glob
import os
import re
import warnings

import netCDF4
import numpy as np

DAYS_IN_MONTH = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

# Fixed categorical order for PFT lines -- colors are assigned by PFT index
# position (not cycled/reassigned as PFTs come and go), so a given PFT keeps
# the same color across figures.
PFT_COLORS = ['forestgreen', 'darkorange', 'steelblue', 'firebrick',
              'purple', 'goldenrod', 'teal', 'slategray']


def campaignDirFromRunDir(run_dir):
    """The campaign directory is always two levels up from a case's run
    directory (<campaign>/<case>/run), matching build_example.sh's layout --
    used to find the shared inputdata/atm_forcing_spinup/ alongside it."""
    return os.path.abspath(os.path.join(run_dir, '..', '..'))


def findHistoryMonths(case_run_dir):
    """Return sorted list of (year, month, filepath) for every monthly
    history file found, e.g. 1b_elm_carbon_spinup.elm.h0.0003-07.nc."""
    pattern = os.path.join(case_run_dir, '*.elm.h0.*-*.nc')
    months = []
    rx = re.compile(r'\.elm\.h0\.(\d{4})-(\d{2})\.nc$')
    for f in glob.glob(pattern):
        m = rx.search(f)
        if m:
            months.append((int(m.group(1)), int(m.group(2)), f))
    months.sort()
    return months


def findInLndIn(case_run_dir, namelist_var):
    """Read an absolute input-file path directly out of this case's own
    runtime namelist (run/lnd_in, written by CIME at case.build/submit
    time), e.g. namelist_var='paramfile' or 'fsurdat'. This is the
    authoritative source ELM itself reads the path from -- unlike guessing
    a relative location, it's correct regardless of whether the file lives
    under the campaign's local inputdata/ or a separate global inputdata
    mirror (as clm_params_*.nc does for this campaign)."""
    lnd_in = os.path.join(case_run_dir, 'lnd_in')
    if not os.path.isfile(lnd_in):
        return None
    rx = re.compile(rf"^\s*{re.escape(namelist_var)}\s*=\s*'([^']+)'")
    with open(lnd_in) as fh:
        for line in fh:
            m = rx.match(line)
            if m:
                path = m.group(1)
                return path if os.path.isfile(path) else None
    return None


def findInputFile(ds, case_run_dir, global_attr, namelist_var=None):
    """Locate an ELM input file this run used. Prefers the case's own
    runtime namelist (run/lnd_in), which has the authoritative absolute
    path; falls back to searching for the history file's global-attribute
    basename (e.g. 'PFT_physiological_constants_dataset', 'Surface_dataset')
    anywhere under the campaign tree, for cases without a readable lnd_in."""
    if namelist_var is not None:
        path = findInLndIn(case_run_dir, namelist_var)
        if path is not None:
            return path
    fname = getattr(ds, global_attr, None)
    if not fname:
        return None
    search_root = os.path.abspath(os.path.join(case_run_dir, '..', '..', '..'))
    for root, _dirs, files in os.walk(search_root):
        if fname in files:
            return os.path.join(root, fname)
    return None


def pftNamesPresent(ds, case_run_dir):
    """Names for the natpft axis, read from the run's own PFT physiological-
    constants file (`pftname` variable, the authoritative source ELM itself
    reads them from) when it can be located, falling back to a plain
    numeric label otherwise."""
    n_pft = ds.variables['PCT_NAT_PFT'].shape[1]
    names = [f'PFT {i}' for i in range(n_pft)]
    param_path = findInputFile(ds, case_run_dir, 'PFT_physiological_constants_dataset',
                                namelist_var='paramfile')
    if param_path is not None:
        pds = netCDF4.Dataset(param_path)
        pftname = netCDF4.chartostring(pds.variables['pftname'][:n_pft])
        pds.close()
        names = [str(n).strip() for n in pftname]
    return names


def loadOneMonth(f, case_run_dir, pft_names):
    """Read one monthly history file into a record dict. May raise -- the
    caller is responsible for treating a failure as 'skip this month', since
    a file can be transiently unreadable while still being written by an
    in-progress run (truncated/incomplete on disk), not just genuinely bad.
    Returns (record, pft_names)."""
    ds = netCDF4.Dataset(f)
    try:
        rain_mm_day = float(np.nanmean(ds.variables['RAIN'][:])) * 86400.0
        fsds = float(np.nanmean(ds.variables['FSDS'][:]))
        tlai_cell = np.array(ds.variables['TLAI'][0, :])  # (lndgrid,)
        tlai = float(np.nanmean(tlai_cell))
        # PCT_NAT_PFT: (time, natpft, lndgrid), percent (0-100) of natural-
        # vegetation-landunit area in each PFT. Per-cell TLAI apportioned by
        # this fraction gives each present PFT's contribution to LAI on each
        # cell; where only one PFT occupies a cell (the usual ELM+ATS
        # single-column setup) this fraction is exactly 1, so the
        # apportioned value is exact, not approximate. Keeping the
        # apportionment per-cell (rather than on the domain-mean TLAI) lets
        # us take percentiles of per-PFT LAI across cells below.
        pct_pft_cell = np.array(ds.variables['PCT_NAT_PFT'][0, :, :]) / 100.0  # (natpft, lndgrid)
        pft_lai_cell = tlai_cell[np.newaxis, :] * pct_pft_cell  # (natpft, lndgrid)
        pct_pft = np.nanmean(pct_pft_cell, axis=1)
        # Percentiles must be taken only over cells where this PFT is
        # actually present -- cells lacking a PFT contribute a structural 0
        # to pft_lai_cell (from pct_pft_cell==0), not a sampled LAI value,
        # so including them would pull the median/percentiles toward zero
        # rather than describing the LAI distribution on cells that carry
        # the PFT.
        pft_lai_masked = np.where(pct_pft_cell > 0, pft_lai_cell, np.nan)
        with warnings.catch_warnings():
            warnings.filterwarnings('ignore', message='All-NaN slice encountered')
            pft_lai_p10 = np.nanpercentile(pft_lai_masked, 10, axis=1)
            pft_lai_p50 = np.nanpercentile(pft_lai_masked, 50, axis=1)
            pft_lai_p90 = np.nanpercentile(pft_lai_masked, 90, axis=1)
        # PFTs absent everywhere this month yield all-NaN rows above (which
        # is correct -- nothing to summarize); replace with 0 for plotting.
        pft_lai_p10 = np.nan_to_num(pft_lai_p10)
        pft_lai_p50 = np.nan_to_num(pft_lai_p50)
        pft_lai_p90 = np.nan_to_num(pft_lai_p90)
        if pft_names is None:
            pft_names = pftNamesPresent(ds, case_run_dir)
        totsomc_cell = np.array(ds.variables['TOTSOMC'][0, :])
        totlitc_cell = np.array(ds.variables['TOTLITC'][0, :])
        cwdc_cell = np.array(ds.variables['CWDC'][0, :])
        totsomc = float(np.nanmean(totsomc_cell))
        totlitc = float(np.nanmean(totlitc_cell))
        cwdc = float(np.nanmean(cwdc_cell))
        totsomc_p10, totsomc_p90 = np.nanpercentile(totsomc_cell, [10, 90])
        totlitc_p10, totlitc_p90 = np.nanpercentile(totlitc_cell, [10, 90])
        cwdc_p10, cwdc_p90 = np.nanpercentile(cwdc_cell, [10, 90])
        zwt_cell = np.array(ds.variables['ZWT'][0, :])  # (lndgrid,), depth below local surface
        wt_rel_cell = -zwt_cell  # relative to surface at 0, positive up
        zwt = float(np.nanmean(zwt_cell))
        wt_rel_p10, wt_rel_p50, wt_rel_p90 = np.nanpercentile(wt_rel_cell, [10, 50, 90])

        record = {
            'elm_rain_mm_day': rain_mm_day,
            'elm_fsds': fsds,
            'elm_tlai': tlai,
            'pct_pft': pct_pft,
            'pft_lai_p10': pft_lai_p10,
            'pft_lai_p50': pft_lai_p50,
            'pft_lai_p90': pft_lai_p90,
            'totsomc': totsomc,
            'totlitc': totlitc,
            'cwdc': cwdc,
            'totsomc_p10': float(totsomc_p10),
            'totsomc_p90': float(totsomc_p90),
            'totlitc_p10': float(totlitc_p10),
            'totlitc_p90': float(totlitc_p90),
            'cwdc_p10': float(cwdc_p10),
            'cwdc_p90': float(cwdc_p90),
            'zwt': zwt,
            'wt_rel_p10': float(wt_rel_p10),
            'wt_rel_p50': float(wt_rel_p50),
            'wt_rel_p90': float(wt_rel_p90),
        }
        return record, pft_names
    finally:
        ds.close()


def loadElmMonthly(months, case_run_dir):
    """Read every month's history file, skipping (with a warning) any that
    can't be read or whose per-PFT array shape doesn't match the rest.

    Both failure modes are expected when plotting a campaign stage while its
    run is still in progress: the newest history file(s) can be mid-write
    (truncated/incomplete on disk, raising on read), and a stage whose PFT-
    column layout changes across the run (or a differently-configured re-run
    left older, incompatible files alongside newer ones) can produce a
    natpft dimension that differs month to month. Either way, one bad month
    shouldn't take down the whole plot -- skip it and keep going.

    Note: this does NOT try to detect/drop a stale tail of leftover files
    from a superseded run sharing the same directory (e.g. after a restart
    from an earlier point) -- file mtimes turned out to be an unreliable
    signal for that (a normal completed run can have irregular batch-write
    timing that looks just like a restart gap), and there's no dependable
    structural signal (no duplicate month indices) to fall back on. If a
    stage directory has stale files from a prior run mixed in with a fresh
    one, clean them up manually before plotting.
    """
    records = []
    pft_names = None
    n_pft_expected = None
    skipped = []
    for year, month, f in months:
        try:
            record, pft_names = loadOneMonth(f, case_run_dir, pft_names)
        except Exception as e:
            skipped.append((year, month, f, str(e)))
            continue
        n_pft = len(record['pct_pft'])
        if n_pft_expected is None:
            n_pft_expected = n_pft
        elif n_pft != n_pft_expected:
            skipped.append((year, month, f,
                             f'natpft dimension changed ({n_pft} vs expected {n_pft_expected})'))
            continue
        record['year'] = year
        record['month'] = month
        records.append(record)

    if skipped:
        print(f'WARNING: skipped {len(skipped)} month(s) that could not be read '
              '(likely an in-progress run still writing history files):')
        for year, month, f, reason in skipped:
            print(f'  {year:04d}-{month:02d} ({os.path.basename(f)}): {reason}')

    return records, pft_names


def loadForcingDaily(forcing_dir):
    """Domain-mean hourly forcing (from the cyclic typical-year files),
    binned to daily means. Returns (precip_mm_day, fsds_w_m2, monthly_totals_mm)."""
    prect_path = os.path.join(forcing_dir, 'ATS-subdaily_PRECTmms_z01.nc')
    fsds_path = os.path.join(forcing_dir, 'ATS-subdaily_FSDS_z01.nc')

    ds_prect = netCDF4.Dataset(prect_path)
    prect = ds_prect.variables['PRECTmms'][:]  # (n, DTIME), mm/s
    prect_mean = np.nanmean(prect, axis=0)
    ds_prect.close()

    ds_fsds = netCDF4.Dataset(fsds_path)
    fsds = ds_fsds.variables['FSDS'][:]
    fsds_mean = np.nanmean(fsds, axis=0)
    ds_fsds.close()

    n_hours = len(prect_mean)
    n_days = n_hours // 24
    precip_daily = prect_mean[:n_days * 24].reshape(n_days, 24).mean(axis=1) * 86400.0
    fsds_daily = fsds_mean[:n_days * 24].reshape(n_days, 24).mean(axis=1)

    hour_starts = np.cumsum([0] + [d * 24 for d in DAYS_IN_MONTH[:-1]])
    monthly_totals = []
    for i, d in enumerate(DAYS_IN_MONTH):
        start = hour_starts[i]
        end = start + d * 24
        monthly_totals.append(float(np.sum(prect_mean[start:end]) * 3600.0))

    return precip_daily, fsds_daily, monthly_totals


def makePlot(records, pft_names, precip_daily, fsds_daily, forcing_monthly_totals,
             out_path, title=''):
    n_days = len(precip_daily)
    month_start = np.cumsum([0] + DAYS_IN_MONTH[:-1])
    month_mid = month_start + np.array(DAYS_IN_MONTH) / 2.0
    forcing_monthly_rate = [t / d for t, d in zip(forcing_monthly_totals, DAYS_IN_MONTH)]

    n_years = max(1, (len(records) + 11) // 12)
    precip_daily_ny = np.concatenate([precip_daily] * n_years)
    fsds_daily_ny = np.concatenate([fsds_daily] * n_years)
    days_ny = np.arange(len(precip_daily_ny))

    # Day-of-run is the shared x-axis unit for all four panels (not month
    # index), so zooming on one links the rest via sharex. Each record
    # (one per month) is placed at its month's midpoint day, continuing
    # past one cyclic year for multi-year runs.
    month_mid_ny = np.concatenate([month_mid + y * n_days for y in range(n_years)])
    forcing_rate_ny = forcing_monthly_rate * n_years
    n_records = len(records)
    x_month = month_mid_ny[:n_records]
    forcing_rate_ny = forcing_rate_ny[:n_records]

    elm_rain = [r['elm_rain_mm_day'] for r in records]
    elm_fsds = [r['elm_fsds'] for r in records]
    month_labels = [f"Y{r['year']}-{r['month']:02d}" for r in records]
    step = max(1, len(x_month) // 36)

    fig, axes = plt.subplots(4, 1, figsize=(13, 13), sharex=True)

    # --- Panel 1: forcing vs. ELM check (precip left axis, shortwave twin) ---
    ax_precip = axes[0]
    ax_fsds = ax_precip.twinx()

    ax_precip.plot(days_ny, precip_daily_ny, '-', color='steelblue', alpha=0.35, lw=0.8,
                   label='Precip forcing (hourly->daily mean)')
    ax_precip.plot(x_month, elm_rain, 'o-', color='navy', ms=4, lw=1.0,
                   label='ELM RAIN (monthly mean)')
    ax_precip.plot(x_month, forcing_rate_ny, '--', color='steelblue', lw=1.5,
                   label='Precip forcing (monthly-integrated)')
    ax_precip.set_ylabel('Precip [mm/day]', color='navy')
    ax_precip.tick_params(axis='y', labelcolor='navy')

    ax_fsds.plot(days_ny, fsds_daily_ny, color='moccasin', lw=1,
                 label='Shortwave forcing (hourly->daily mean)')
    ax_fsds.plot(x_month, elm_fsds, 'o-', color='darkorange', ms=4, lw=1.0,
                 label='ELM FSDS (monthly mean)')
    ax_fsds.set_ylabel('Incident shortwave [W/m^2]', color='darkorange')
    ax_fsds.tick_params(axis='y', labelcolor='darkorange')

    for y in range(1, n_years):
        ax_precip.axvline(y * n_days, color='gray', ls=':', lw=0.8)
    ax_precip.set_title(f'{title} -- forcing vs. ELM output')
    lines1, labels1 = ax_precip.get_legend_handles_labels()
    lines2, labels2 = ax_fsds.get_legend_handles_labels()
    ax_precip.legend(lines1 + lines2, labels1 + labels2, loc='upper right',
                      fontsize=7, framealpha=0.9)
    ax_precip.grid(alpha=0.3)

    # --- Panel 2: water table position, relative to the local land surface ---
    wt_rel_p10 = [r['wt_rel_p10'] for r in records]
    wt_rel_p50 = [r['wt_rel_p50'] for r in records]
    wt_rel_p90 = [r['wt_rel_p90'] for r in records]
    axes[1].axhline(0.0, color='black', lw=1.5, label='Ground surface')
    axes[1].fill_between(x_month, wt_rel_p10, wt_rel_p90, color='blue', alpha=0.2,
                          label='Water table (10th-90th pct across cells)')
    axes[1].plot(x_month, wt_rel_p50, '-', color='blue', lw=1.5, label='Water table (median)')
    axes[1].set_ylabel('Depth relative to surface [m]')
    axes[1].set_title('Water table position (relative to local land surface)')
    axes[1].legend(loc='best', fontsize=8)
    axes[1].grid(alpha=0.3)

    # --- Panel 3: per-PFT LAI ---
    n_pft = len(pft_names)
    pct_pft = np.array([r['pct_pft'] for r in records])  # (n_records, n_pft)
    pft_lai_p10 = np.array([r['pft_lai_p10'] for r in records])  # (n_records, n_pft)
    pft_lai_p50 = np.array([r['pft_lai_p50'] for r in records])
    pft_lai_p90 = np.array([r['pft_lai_p90'] for r in records])
    present = np.where(np.any(pct_pft > 0, axis=0))[0]
    for k, p in enumerate(present):
        color = PFT_COLORS[k % len(PFT_COLORS)]
        axes[2].fill_between(x_month, pft_lai_p10[:, p], pft_lai_p90[:, p],
                              color=color, alpha=0.2)
        axes[2].plot(x_month, pft_lai_p50[:, p], '-', lw=1.2, color=color, label=pft_names[p])
    axes[2].set_ylabel('LAI [m^2/m^2]')
    axes[2].set_title('Per-PFT leaf area index (median, 10th-90th pct across cells)')
    axes[2].legend(loc='best', fontsize=8)
    axes[2].grid(alpha=0.3)

    # --- Panel 4: subsurface carbon pools ---
    totsomc = [r['totsomc'] for r in records]
    totlitc = [r['totlitc'] for r in records]
    cwdc = [r['cwdc'] for r in records]
    totsomc_p10 = [r['totsomc_p10'] for r in records]
    totsomc_p90 = [r['totsomc_p90'] for r in records]
    totlitc_p10 = [r['totlitc_p10'] for r in records]
    totlitc_p90 = [r['totlitc_p90'] for r in records]
    cwdc_p10 = [r['cwdc_p10'] for r in records]
    cwdc_p90 = [r['cwdc_p90'] for r in records]
    axes[3].fill_between(x_month, totsomc_p10, totsomc_p90, color='saddlebrown', alpha=0.2)
    axes[3].plot(x_month, totsomc, '-', color='saddlebrown', lw=1.5, label='Soil organic matter C (TOTSOMC)')
    axes[3].fill_between(x_month, totlitc_p10, totlitc_p90, color='olive', alpha=0.2)
    axes[3].plot(x_month, totlitc, '-', color='olive', lw=1.5, label='Litter C (TOTLITC)')
    axes[3].fill_between(x_month, cwdc_p10, cwdc_p90, color='sienna', alpha=0.2)
    axes[3].plot(x_month, cwdc, '-', color='sienna', lw=1.5, label='Coarse woody debris C (CWDC)')
    axes[3].set_ylabel('Carbon [gC/m^2]')
    axes[3].set_xlabel('Day (run so far)')
    axes[3].set_title('Subsurface/detrital carbon pools (median, 10th-90th pct across cells)')
    axes[3].set_xticks(x_month[::step])
    axes[3].set_xticklabels([month_labels[i] for i in range(0, len(month_labels), step)],
                             rotation=45, ha='right')
    axes[3].legend(loc='best', fontsize=8)
    axes[3].grid(alpha=0.3)

    for ax in axes[:3]:
        ax.tick_params(labelbottom=False)

    plt.tight_layout()
    if out_path:
        plt.savefig(out_path, dpi=130)
    else:
        plt.show()


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('run_dir', help='case run directory to plot, e.g. .../1c_pft_columns/run')
    p.add_argument('--forcing-dir', default=None,
                    help='cyclic-forcing directory (default: inferred as '
                         '<run_dir>/../../inputdata/atm_forcing_spinup)')
    p.add_argument('--out', default=None,
                    help='output PNG path; if omitted, the plot is shown interactively instead of saved')
    args = p.parse_args()

    # Backend must be chosen before pyplot is imported: 'Agg' (headless) when
    # saving to a file, the default GUI backend when showing interactively.
    if args.out:
        import matplotlib
        matplotlib.use('Agg')
    global plt
    import matplotlib.pyplot as plt

    case_run = args.run_dir
    if not os.path.isdir(case_run):
        p.error(f"'{case_run}' is not a directory")

    forcing_dir = args.forcing_dir
    if forcing_dir is None:
        forcing_dir = os.path.join(campaignDirFromRunDir(case_run), 'inputdata', 'atm_forcing_spinup')

    case_label = os.path.basename(os.path.dirname(os.path.normpath(case_run))) or 'case'

    months = findHistoryMonths(case_run)
    if not months:
        raise SystemExit(f'No monthly history files (*.elm.h0.*.nc) found in {case_run}')

    records, pft_names = loadElmMonthly(months, case_run)
    if not records:
        raise SystemExit(f'No monthly history files in {case_run} could be read '
                          '(all were skipped -- see warnings above)')
    precip_daily, fsds_daily, forcing_monthly_totals = loadForcingDaily(forcing_dir)

    y0, m0 = records[0]['year'], records[0]['month']
    y1, m1 = records[-1]['year'], records[-1]['month']
    title = f'Coweeta {case_label}, Y{y0}-{m0:02d} through Y{y1}-{m1:02d}'

    makePlot(records, pft_names, precip_daily, fsds_daily, forcing_monthly_totals,
             args.out, title)
    if args.out:
        print(f'{len(records)} months plotted ({y0}-{m0:02d} .. {y1}-{m1:02d}) -> {args.out}')
    else:
        print(f'{len(records)} months plotted ({y0}-{m0:02d} .. {y1}-{m1:02d})')


if __name__ == '__main__':
    main()
