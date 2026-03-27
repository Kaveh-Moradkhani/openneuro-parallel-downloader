# OpenNeuro Parallel Downloader

A simple Bash script that downloads datasets from [OpenNeuro](https://openneuro.org) using DataLad — fast, in parallel, and with real file content (no symlinks).

Built for researchers who need MRI data ready to process with tools like FreeSurfer or FastSurfer.

---

## What it does

1. Clones the dataset repository from GitHub (structure only, no data yet)
2. Finds all files matching your requested modality (e.g. T1w)
3. Downloads the actual file content
4. Unlocks files so downstream tools can read them
5. Verifies every file is real data, not a symlink
6. Logs everything — one file per dataset, plus a summary

---

## Requirements

- [DataLad](https://www.datalad.org/) — `pip install datalad`
- [git-annex](https://git-annex.branchable.com/) — required by DataLad
- [GNU Parallel](https://www.gnu.org/software/parallel/) — `conda install -c conda-forge parallel`

To check everything is installed:
```bash
datalad --version
git annex version
parallel --version
```

---

## Usage

```bash
chmod +x download_openneuro.sh
```

**Download T1w images from a list of datasets:**
```bash
./download_openneuro.sh \
  --dest /data/openneuro \
  --datasets ds000115,ds000144,ds002862
```

**Download everything (all files) from a dataset list file:**
```bash
./download_openneuro.sh \
  --dest /data/openneuro \
  --datasets-file my_datasets.txt \
  --all
```

**Download T2w images with custom parallelism:**
```bash
./download_openneuro.sh \
  --dest /data/openneuro \
  --datasets ds000115,ds000144 \
  --modality T2w \
  --jobs 4 \
  --conn 4
```

---

## All options

| Option | Description | Default |
|---|---|---|
| `--dest` | Where to save the data | required |
| `--datasets` | Comma-separated dataset IDs | required* |
| `--datasets-file` | Text file with one dataset ID per line | required* |
| `--modality` | Which files to download: T1w, T2w, bold, dwi | T1w |
| `--all` | Download the entire dataset, not just one modality | off |
| `--jobs` | How many datasets to download at the same time | 15 |
| `--conn` | Connections per dataset | 8 |
| `--help` | Show usage | — |

*One of `--datasets` or `--datasets-file` is required.

---

## Dataset list file format

Just one dataset ID per line:

```
ds000115
ds000144
ds002862
ds003499
```

---

## Output structure

```
/data/openneuro/
├── ds000115/
│   └── sub-01/anat/sub-01_T1w.nii.gz   ← real file, not a symlink
├── ds000144/
│   └── ...
└── logs/
    ├── ds000115.log    ← full log per dataset
    ├── success.txt     ← list of successful datasets
    └── failed.txt      ← list of failed datasets
```

---

## Monitor progress

While the script is running, open a second terminal:

```bash
# See which datasets finished
watch -n 3 'cat /data/openneuro/logs/success.txt'

# Follow a specific dataset log
tail -f /data/openneuro/logs/ds000115.log
```

---

## Resume after interruption

Just run the same command again. Datasets that are already cloned will be skipped and only the missing files will be downloaded.

---

## Notes

- GPU does not help with downloading. Speed is limited by network bandwidth.
- On a fast network (e.g. Compute Canada / Narval), you can push close to full bandwidth by keeping `--jobs` and `--conn` high.
- If you are on a SLURM cluster, consider using a job array instead — one job per dataset — for even better performance.

---

## License

MIT
