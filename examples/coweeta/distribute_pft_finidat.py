#!/usr/bin/env python3
"""distribute_pft_finidat.py -- Build stage 2's ELM finidat by broadcasting
stage 1c's per-PFT restart onto the full Coweeta mesh.

Stage 1c (examples/coweeta/build_example.sh) runs a 200-year accelerated-
decomposition ELM carbon spinup on a tiny synthetic mesh: one flat column per
PFT type actually present in the Coweeta domain. The full Coweeta mesh
(~2701 cells) is too expensive to run that same spinup on directly. Since
every full-mesh cell is already 100% covered by exactly one PFT (ELM+ATS's
sub-grid convention here has no fractional PFT mixing), stage 2's initial
condition can instead be built by copying -- not interpolating -- each
full-mesh cell's state from whichever stage 1c column shares its PFT type.
This is a broadcast/lookup keyed on PFT type, not a geometric regrid: no
distance metric or interpolation weight is involved anywhere in this script.

The output file is built by expanding stage 1c's own restart file schema
(every variable's name/dtype/dimensions/attributes, copied as-is) to the full
mesh's dimension sizes, rather than starting from any other "native" restart
template -- no native full-mesh ELM restart file exists to use as one, and
building one would require running ELM on the full mesh once, which is
exactly the cost this script exists to avoid. Only the resizable subgrid
dimensions (gridcell, topounit, landunit, column, pft) change size; every
other dimension (levgrnd, levtot, month, ...) is copied through unchanged.

ELM always allocates all 17 natural-PFT slots per natural-vegetation column
(only one slot is active/nonzero-weight per column in this one-PFT-per-cell
setup), so the pft dimension is (number of columns) * 17, not a 1:1 map with
column -- pft-dimensioned variables are broadcast in 17-slot blocks per
column, not element-by-element.

Usage:
    python3 distribute_pft_finidat.py \\
        --stage1c-restart PATH --full-surfdata PATH --crosswalk PATH --output PATH

--stage1c-restart is stage 1c's actual restart NetCDF (e.g.
.../1c_pft_columns/run/1c_pft_columns.elm.r.0201-01-01-00000.nc), produced by
running that case's case.submit -- not a predicted filename, since this
script needs real per-column state to copy. --full-surfdata is the full
mesh's ELM surfdata file (coweeta_surfdata.nc), whose PCT_NAT_PFT array gives
each target cell's PFT type and whose LATIXY/LONGXY give each target cell's
coordinates. --crosswalk is the PFT-index-per-1c-column JSON written by
coweeta_elm_ats.ipynb (coweeta_1c_pft_crosswalk.json). --output is the
destination path for the new finidat file.

Requires netCDF4, numpy (no watershed_workflow/conda env needed).
"""
import argparse
import json

import netCDF4
import numpy as np

N_PFT_SLOTS = 17

# Variables regenerated as fresh positional/coordinate identity rather than
# copied verbatim from the matched source column -- copying 1c's own values
# for these would be wrong at the new mesh size (index variables only run
# 1..3 in the source; lon/lat are 1c's single shared synthetic centroid, not
# each target cell's real position).
INDEX_VAR_SUFFIXES = ('_gridcell_index', '_topounit_index', '_landunit_index',
                       '_column_index')
IXY_VAR_SUFFIXES = ('_ixy', )
JXY_VAR_SUFFIXES = ('_jxy', )
LON_VAR_SUFFIXES = ('_lon', )
LAT_VAR_SUFFIXES = ('_lat', )


def loadPftCrosswalk(path):
    """Load the 1c-column -> PFT-type crosswalk written by coweeta_elm_ats.ipynb.

    Parameters
    ----------
    path : str
        Path to coweeta_1c_pft_crosswalk.json.

    Returns
    -------
    list of int
        PFT type (0-16) of each 1c column, indexed 0-based (crosswalk_pft_indices[i]
        is the PFT type of 1c column i+1, 1-based, matching cols1d_gridcell_index).
    """
    with open(path) as f:
        crosswalk = json.load(f)
    return [int(p) for p in crosswalk['pft_indices']]


def loadTargetPftPerCell(surfdata_path):
    """Read each full-mesh cell's dominant PFT type from PCT_NAT_PFT.

    Parameters
    ----------
    surfdata_path : str
        Path to the full mesh's ELM surfdata file (coweeta_surfdata.nc).

    Returns
    -------
    np.ndarray of int, shape (ncells,)
        PFT type (0-16) of each target gridcell.

    Notes
    -----
    Asserts every gridcell has exactly one nonzero PCT_NAT_PFT entry (the
    ELM+ATS one-PFT-per-cell convention this whole broadcast approach
    depends on) -- fails loudly rather than silently picking an argmax over
    a fractional mix if that assumption is ever violated.
    """
    ds = netCDF4.Dataset(surfdata_path)
    ds.set_auto_mask(False)
    pct_nat_pft = ds.variables['PCT_NAT_PFT'][:]  # (natpft, gridcell)
    ds.close()

    nonzero_counts = (pct_nat_pft > 0).sum(axis=0)
    if not np.all(nonzero_counts == 1):
        n_bad = int(np.sum(nonzero_counts != 1))
        raise ValueError(
            f'{n_bad} of {pct_nat_pft.shape[1]} gridcells in {surfdata_path} do not '
            'have exactly one nonzero PCT_NAT_PFT entry -- this script assumes every '
            'target cell is 100% one PFT (no fractional PFT mixing).')
    return np.argmax(pct_nat_pft, axis=0).astype(int)


def buildColumnLookup(crosswalk_pft_indices, target_pft_per_cell):
    """Map each target cell to its matching stage 1c source column.

    Parameters
    ----------
    crosswalk_pft_indices : list of int
        PFT type of each 1c column, 0-based (see loadPftCrosswalk).
    target_pft_per_cell : np.ndarray of int, shape (ncells,)
        PFT type of each target gridcell (see loadTargetPftPerCell).

    Returns
    -------
    np.ndarray of int, shape (ncells,)
        0-based source-column index in the 1c restart file for each target cell.
    """
    pft_to_column = {pft: i for i, pft in enumerate(crosswalk_pft_indices)}
    missing = sorted(set(target_pft_per_cell.tolist()) - set(pft_to_column.keys()))
    if missing:
        raise ValueError(
            f'Target PFT type(s) {missing} have no matching stage 1c column in the '
            'crosswalk -- stage 1c must include one column for every PFT present in '
            'the full mesh.')
    return np.array([pft_to_column[p] for p in target_pft_per_cell], dtype=int)


def classifyVariables(src_ds):
    """Bucket every restart variable by which resizable subgrid dimension it uses.

    Parameters
    ----------
    src_ds : netCDF4.Dataset
        The open stage 1c restart file.

    Returns
    -------
    dict of str to list of str
        Variable names grouped into 'GRIDCELL', 'TOPOUNIT', 'LANDUNIT', 'COLUMN',
        'PFT', or 'OTHER' (scalars and anything with no resizable subgrid
        dimension, copied through unchanged).

    Notes
    -----
    A variable is classified by the first resizable dimension (gridcell,
    topounit, landunit, column, pft, checked in that priority order) that
    appears anywhere in its dimension tuple -- none of these dimensions
    co-occur on the same variable in an ELM restart file, so the order only
    matters for variables using none of them (OTHER).
    """
    resizable_priority = [('gridcell', 'GRIDCELL'), ('topounit', 'TOPOUNIT'),
                           ('landunit', 'LANDUNIT'), ('column', 'COLUMN'),
                           ('pft', 'PFT')]
    buckets = {name: [] for _, name in resizable_priority}
    buckets['OTHER'] = []

    for var_name, var in src_ds.variables.items():
        dims = var.dimensions
        bucket = 'OTHER'
        for dim_name, bucket_name in resizable_priority:
            if dim_name in dims:
                bucket = bucket_name
                break
        buckets[bucket].append(var_name)

    n_classified = sum(len(v) for v in buckets.values())
    if n_classified != len(src_ds.variables):
        raise AssertionError(
            f'classifyVariables bucketed {n_classified} variables but the source '
            f'file has {len(src_ds.variables)} -- every variable must land in '
            'exactly one bucket.')
    return buckets


def broadcastColumnDimVar(src_var, column_lookup):
    """Gather a column-dimensioned variable's rows per target cell's source column.

    Parameters
    ----------
    src_var : netCDF4.Variable
        Source variable whose first dimension is 'column' (any trailing
        dimensions, e.g. levgrnd, are carried through unchanged).
    column_lookup : np.ndarray of int, shape (ncells,)
        0-based source-column index for each target cell.

    Returns
    -------
    np.ndarray
        Values gathered for each target cell, shape (ncells, ...).
    """
    return src_var[:][column_lookup, ...]


def broadcastPftDimVar(src_var, column_lookup, n_pft_slots=N_PFT_SLOTS):
    """Gather a pft-dimensioned variable's 17-slot blocks per target cell.

    Parameters
    ----------
    src_var : netCDF4.Variable
        Source variable whose first dimension is 'pft' (any trailing
        dimensions carried through unchanged).
    column_lookup : np.ndarray of int, shape (ncells,)
        0-based source-column index for each target cell.
    n_pft_slots : int, optional
        Natural-PFT slots allocated per column. Default is 17.

    Returns
    -------
    np.ndarray
        Values gathered for each target cell's 17-slot block, shape
        (ncells * n_pft_slots, ...).

    Notes
    -----
    Each target cell's entire 17-slot block (including inactive/zero-weight
    slots) is copied verbatim from its matched source column's block --
    since both source and target always lay out the same 17 PFT types in the
    same slot order, this preserves which slot is active without any
    separate remapping.
    """
    pft_gather = (np.repeat(column_lookup, n_pft_slots) * n_pft_slots
                  + np.tile(np.arange(n_pft_slots), len(column_lookup)))
    return src_var[:][pft_gather, ...]


def rewriteIdentityIndexVars(out_ds, ncells, target_lon, target_lat):
    """Overwrite positional/coordinate variables that the generic broadcast corrupts.

    Parameters
    ----------
    out_ds : netCDF4.Dataset
        The output file, open for writing, after the generic per-bucket
        broadcast has already populated every variable.
    ncells : int
        Number of target gridcells (== topounit == landunit == column count,
        in this natural-vegetation-only domain).
    target_lon : np.ndarray of float, shape (ncells,)
        Each target cell's real longitude.
    target_lat : np.ndarray of float, shape (ncells,)
        Each target cell's real latitude.

    Notes
    -----
    Everything not covered here (all prognostic/physical state -- carbon,
    nitrogen, phosphorus, water, energy, weights, active flags) was already
    copied verbatim by the generic broadcast and is left untouched. Only
    identity/coordinate bookkeeping is regenerated:

    - ``*_gridcell_index``, ``*_topounit_index``, ``*_landunit_index``,
      ``*_column_index``: fresh sequential 1-based indices matching the new
      grid's own topology (source values only run 1..3).
    - ``*_ixy``/``*_jxy``: the ELM_USRDAT 1D-unstructured convention
      (``ixy = 1..ncells``, ``jxy = 1``), confirmed against stage 1c's own
      restart file before writing.
    - ``*_lon``/``*_lat``: each target cell's real coordinates, not stage
      1c's single shared synthetic centroid.
    """
    for var_name in out_ds.variables:
        var = out_ds.variables[var_name]
        dims = var.dimensions
        if not dims:
            continue
        dim0 = dims[0]
        if dim0 not in ('gridcell', 'topounit', 'landunit', 'column', 'pft'):
            continue
        n_slots = N_PFT_SLOTS if dim0 == 'pft' else 1
        n_units = ncells if dim0 != 'pft' else ncells
        n_entries = n_units * n_slots

        if var_name.endswith(INDEX_VAR_SUFFIXES):
            if dim0 == 'pft':
                # pft-dimensioned index vars point at the *column* they
                # belong to -- one repeated value per 17-slot block.
                var[:] = np.repeat(np.arange(1, ncells + 1), N_PFT_SLOTS)
            else:
                var[:] = np.arange(1, n_entries + 1)
        elif var_name.endswith(IXY_VAR_SUFFIXES):
            base = np.arange(1, ncells + 1)
            var[:] = np.repeat(base, n_slots) if dim0 == 'pft' else base
        elif var_name.endswith(JXY_VAR_SUFFIXES):
            var[:] = np.ones(n_entries, dtype=var.dtype)
        elif var_name.endswith(LON_VAR_SUFFIXES):
            var[:] = np.repeat(target_lon, n_slots) if dim0 == 'pft' else target_lon
        elif var_name.endswith(LAT_VAR_SUFFIXES):
            var[:] = np.repeat(target_lat, n_slots) if dim0 == 'pft' else target_lat


def buildOutputFile(src_path, out_path, ncells, column_lookup, target_lon, target_lat):
    """Write the full-mesh finidat file by broadcasting stage 1c's restart.

    Parameters
    ----------
    src_path : str
        Path to stage 1c's actual restart NetCDF file.
    out_path : str
        Destination path for the new finidat file.
    ncells : int
        Number of target gridcells.
    column_lookup : np.ndarray of int, shape (ncells,)
        0-based source-column index for each target cell.
    target_lon : np.ndarray of float, shape (ncells,)
        Each target cell's real longitude.
    target_lat : np.ndarray of float, shape (ncells,)
        Each target cell's real latitude.
    """
    src_ds = netCDF4.Dataset(src_path)
    src_ds.set_auto_mask(False)

    out_ds = netCDF4.Dataset(out_path, 'w', format=src_ds.file_format)

    for attr_name in src_ds.ncattrs():
        out_ds.setncattr(attr_name, src_ds.getncattr(attr_name))
    out_ds.setncattr('case_id', 'coweeta_stage2_finidat_from_1c_pft_broadcast')

    resizable_dims = {
        'gridcell': ncells,
        'topounit': ncells,
        'landunit': ncells,
        'column': ncells,
        'pft': ncells * N_PFT_SLOTS,
    }
    for dim_name, dim in src_ds.dimensions.items():
        size = resizable_dims.get(dim_name, len(dim) if not dim.isunlimited() else None)
        out_ds.createDimension(dim_name, size)

    buckets = classifyVariables(src_ds)
    bucket_of = {v: b for b, vs in buckets.items() for v in vs}

    for var_name, src_var in src_ds.variables.items():
        fill_value = getattr(src_var, '_FillValue', None)
        out_var = out_ds.createVariable(var_name, src_var.dtype, src_var.dimensions,
                                         fill_value=fill_value)
        for attr_name in src_var.ncattrs():
            if attr_name == '_FillValue':
                continue
            out_var.setncattr(attr_name, src_var.getncattr(attr_name))

        bucket = bucket_of[var_name]
        if bucket == 'OTHER':
            out_var[:] = src_var[:]
        elif bucket == 'PFT':
            out_var[:] = broadcastPftDimVar(src_var, column_lookup)
        else:
            # GRIDCELL, TOPOUNIT, LANDUNIT, and COLUMN all use the same
            # first-axis gather -- this domain has no sub-gridcell landunit
            # splitting, so gridcell == topounit == landunit == column 1:1.
            out_var[:] = broadcastColumnDimVar(src_var, column_lookup)

    rewriteIdentityIndexVars(out_ds, ncells, target_lon, target_lat)

    src_ds.close()
    out_ds.close()


def _verifyOutputFile(src_path, out_path, ncells, target_pft_per_cell):
    """Run structural/physical sanity checks on the freshly written output file."""
    src_ds = netCDF4.Dataset(src_path)
    src_ds.set_auto_mask(False)
    out_ds = netCDF4.Dataset(out_path)
    out_ds.set_auto_mask(False)

    resizable_dims = {'gridcell', 'topounit', 'landunit', 'column'}
    for dim_name in ('gridcell', 'topounit', 'landunit', 'column'):
        if len(out_ds.dimensions[dim_name]) != ncells:
            raise AssertionError(
                f'Output dimension {dim_name!r} has size '
                f'{len(out_ds.dimensions[dim_name])}, expected {ncells}.')
    if len(out_ds.dimensions['pft']) != ncells * N_PFT_SLOTS:
        raise AssertionError(
            f'Output dimension "pft" has size {len(out_ds.dimensions["pft"])}, '
            f'expected {ncells * N_PFT_SLOTS}.')
    for dim_name, dim in src_ds.dimensions.items():
        if dim_name in resizable_dims or dim_name == 'pft':
            continue
        if len(out_ds.dimensions[dim_name]) != len(dim):
            raise AssertionError(
                f'Output dimension {dim_name!r} has size '
                f'{len(out_ds.dimensions[dim_name])}, expected {len(dim)} '
                '(unchanged from the stage 1c source).')

    if set(out_ds.variables.keys()) != set(src_ds.variables.keys()):
        missing = set(src_ds.variables) - set(out_ds.variables)
        extra = set(out_ds.variables) - set(src_ds.variables)
        raise AssertionError(
            f'Output variable set differs from source. Missing: {missing}. '
            f'Extra: {extra}.')

    pfts1d_wtxy = out_ds.variables['pfts1d_wtxy'][:]
    pfts1d_active = out_ds.variables['pfts1d_active'][:]
    pfts1d_itypveg = out_ds.variables['pfts1d_itypveg'][:]
    for cell in range(ncells):
        block = slice(cell * N_PFT_SLOTS, (cell + 1) * N_PFT_SLOTS)
        weights = pfts1d_wtxy[block]
        if not np.isclose(weights.sum(), 1.0):
            raise AssertionError(
                f'Target cell {cell}: pfts1d_wtxy block sums to {weights.sum()}, '
                'expected 1.0.')
        active_slots = np.where(pfts1d_active[block] == 1)[0]
        if len(active_slots) != 1:
            raise AssertionError(
                f'Target cell {cell}: expected exactly one active PFT slot, '
                f'found {len(active_slots)}.')
        active_pft = pfts1d_itypveg[block][active_slots[0]]
        if active_pft != target_pft_per_cell[cell]:
            raise AssertionError(
                f'Target cell {cell}: active PFT slot has type {active_pft}, '
                f'expected {target_pft_per_cell[cell]} (from full-mesh surfdata).')

    cols1d_wtxy = out_ds.variables['cols1d_wtxy'][:]
    cols1d_active = out_ds.variables['cols1d_active'][:]
    if not np.allclose(cols1d_wtxy, 1.0):
        raise AssertionError('Not every output column has cols1d_wtxy == 1.0.')
    if not np.all(cols1d_active == 1):
        raise AssertionError('Not every output column has cols1d_active == 1.')

    for var_name in ('totcolc', 'sminn_vr', 'T_SOISNO'):
        var = out_ds.variables[var_name]
        fill_value = getattr(var, '_FillValue', None)
        if fill_value is None:
            continue
        values = var[:]
        if np.any(values == fill_value):
            raise AssertionError(
                f'Output variable {var_name!r} contains _FillValue entries -- '
                'broadcast likely left some target cells unpopulated.')

    src_ds.close()
    out_ds.close()

    # Round-trip: reopen fresh to confirm the file was closed/flushed cleanly.
    netCDF4.Dataset(out_path).close()


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--stage1c-restart', required=True,
                    help="stage 1c's actual restart NetCDF file")
    p.add_argument('--full-surfdata', required=True,
                    help='full mesh ELM surfdata file (coweeta_surfdata.nc)')
    p.add_argument('--crosswalk', required=True,
                    help='coweeta_1c_pft_crosswalk.json')
    p.add_argument('--output', required=True,
                    help='destination path for the new finidat file')
    args = p.parse_args()

    crosswalk_pft_indices = loadPftCrosswalk(args.crosswalk)
    target_pft_per_cell = loadTargetPftPerCell(args.full_surfdata)
    ncells = len(target_pft_per_cell)
    column_lookup = buildColumnLookup(crosswalk_pft_indices, target_pft_per_cell)

    surfdata_ds = netCDF4.Dataset(args.full_surfdata)
    surfdata_ds.set_auto_mask(False)
    target_lon = surfdata_ds.variables['LONGXY'][:].reshape(-1)
    target_lat = surfdata_ds.variables['LATIXY'][:].reshape(-1)
    surfdata_ds.close()

    buildOutputFile(args.stage1c_restart, args.output, ncells, column_lookup,
                     target_lon, target_lat)
    _verifyOutputFile(args.stage1c_restart, args.output, ncells, target_pft_per_cell)

    print(f'Wrote {args.output}: {ncells} gridcells, broadcast from '
          f'{len(crosswalk_pft_indices)} stage 1c PFT columns.')


if __name__ == '__main__':
    main()
