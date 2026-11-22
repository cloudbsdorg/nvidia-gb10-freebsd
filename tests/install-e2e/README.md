# Stock-install test (`make test-install`)

The standard install test for any repository that follows the project Makefile contract: on a
fresh, stock FreeBSD machine from the FreeBSD project, as a normal user, from a fresh clone,
`make preflight`, `make install-prereqs`, `make install`, the checks, `make configure` and
`make deinstall` must all pass with nothing done by hand. Any manual step fails it. The
results are JSON and JSONL.

The harness is two scripts with no knowledge of the repository they test:

- `guest.sh` runs inside the fresh machine, as the normal user the test runs as;
- `run.sh` runs on the test host: it gets the machine, runs `guest.sh` in it, and brings the
  results back.

Another repository calls them from a checkout of this directory (or a copy of the two scripts
and `schema/stock-install-*.schema.json`).

## run.sh

```sh
sh tests/install-e2e/run.sh --repo-url URL [--ref REF] [--os OS] [--arch ARCH] \
    [--backend vmm|ssh] [--ssh USER@HOST] [--ssh-key FILE] \
    [--installed-manifest PATH] [--expected-manifest REL] [--load MODULE] \
    [--make-arg VAR=VALUE]... [--results DIR] [--dry-run]
```

| Argument | Meaning | Default |
|---|---|---|
| `--repo-url` | what the guest clones. For a test this is the read-only mirror the test host serves on the VM network; a real user clones from GitHub | required |
| `--ref` | the commit, branch or tag to test; only `[0-9A-Za-z._/-]` | checkout HEAD through `make test-install`; the default branch when `run.sh` is called directly |
| `--os` | `16.0-CURRENT` (the latest official snapshot, checked live), `15.1-RELEASE`, ... | `16.0-CURRENT` |
| `--arch` | `aarch64` or `amd64` | `aarch64` |
| `--backend` | `vmm`: a new VM from the FreeBSD project's BASIC-CLOUDINIT image through cloudbsd-vmm, deleted afterwards. `ssh`: a fresh stock machine you made, reached as `USER@HOST` | `vmm` |
| `--ssh-key` | the private key for reaching the guest (a path; the key itself is never printed or put on a command line) | ssh's own |
| `--installed-manifest` | the manifest `make install` writes (`path mode owner:group sha256`, `path link -> target`, `path dir`; `@prefix PREFIX` is metadata, not a path) | none |
| `--expected-manifest` | the manifest the repository commits (`path mode owner:group`, `path link target`; `#` comments), relative to the checkout | none |
| `--load` | a kernel module to `kldload` after install and unload after (the VM only); it must load or be refused cleanly, with no panic | none |
| `--make-arg` | added to every make command line in the guest, for example `ACCEPT_NVIDIA_LICENSE=1` when the person running the test accepts that licence (a repository never gets a licence accepted any other way) | none |
| `--results` | where the run goes | `tests/install-e2e/results/<os>-<arch>-<UTC time>` |

The `vmm` backend reaches cloudbsd-vmm with a command of the test host's own, so nothing
about a fleet is in a repository: `E2E_VMM_CALL` is a program that reads one `fleet.call`
JSON request on stdin and prints the answer, and `E2E_VMM_WORKER_AARCH64` and
`E2E_VMM_WORKER_AMD64` name the worker for each guest arch. Unset, the run is blocked (exit 3).
The guest clones from `--repo-url`: for a test, a read-only mirror the test host serves on
the VM network (no keys and no GitHub access in the VM).

Exit status: `0` every step passed, `1` a step failed, `2` usage, `3` blocked (no machine: no
image, no vmm worker for the arch, or the guest could not be reached; the summary says why).

## guest.sh

```sh
sh guest.sh --repo-url URL [--ref REF] --results DIR [--installed-manifest PATH] \
    [--expected-manifest REL] [--load MODULE | --no-load] [--watch DIR]... \
    [--make-arg VAR=VALUE]...
```

Steps, in order: `env`, `clone`, `preflight-before` (the JSON contract must print),
`install-prereqs` (`YES=1` and the `--make-arg` settings; a repository that needs a licence
accepted stops here unless the caller passed its setting, for example
`--make-arg ACCEPT_NVIDIA_LICENSE=1`), `preflight-after` (must exit 0; the `device` field is recorded), `install`
(`YES=1`), `manifest-on-disk`, `manifest-expected`, `kldxref` (every dependency of an
installed module is provided by a module in `/boot/kernel`, `/boot/modules` or the kernel
itself), `load` (the modules the load added are unloaded again, newest first), `rcd-devd`, `man` (`mandoc -T lint` and `man -w` for every installed page),
`configure` (when the repository has it), `deinstall`, `nothing-left` (the system after
deinstall equals the system before install: path, type, size, mode and link target under
`/boot/modules`, `/usr/local`, `/var/db` and every `--watch` directory, and the content of
`/boot/loader.conf`, `/etc/rc.conf` and every module in `/boot/modules`).

Exit status: `0` pass, `1` fail, `2` usage (or run as root).

## Output

- `RESULTS/run.jsonl`: one object per step, host steps first (`host:image`, ...), then the
  guest's, schema `schema/stock-install-step-1.schema.json`:
  `{"schema":"stock-install-step/1","index":0,"step":"clone","pass":true,"rc":0,"seconds":3,"detail":"...","log":"logs/clone.log"}`
- `RESULTS/summary.json`: schema `schema/stock-install-summary-1.schema.json`, with `pass`,
  `os`, `arch`, `backend`, and `blocked` (why there was no machine).
- `RESULTS/results/`: the guest's `steps.jsonl`, `summary.json`, the preflight JSON before and
  after, the installed manifest, the before and after snapshots, and one log per step.

## In this repository

`make test-install ACCEPT_NVIDIA_LICENSE=1` runs `run.sh` with this repository's manifest
(`/var/db/nvidia-gb10-freebsd/installed.manifest`), `expected.manifest`, `--load nvidia-drm`
and, because you gave it, `--make-arg ACCEPT_NVIDIA_LICENSE=1`; without a licence setting
the guest stops at the licence, as any install would. The default `--ref` is the checkout's
`git rev-parse HEAD`; the mirror must carry that commit. Set `E2E_REF=` to override it.
`E2E_REPO_URL=`, `E2E_OS=`, `E2E_ARCH=`, `E2E_BACKEND=` and `E2E_SSH=` choose the rest.
`tests/install_e2e_test.sh` tests the harness itself on a fixture repository, without a VM.
