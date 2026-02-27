# YCSB VM Migration Automation Suite
## /mnt/nfs/aamir/Scripts/Migration/Automations/YCSB/

---

## Directory Structure

```
YCSB/
├── common_scripts/             # Shared helper scripts (aamir's own copies)
│   ├── arg_parser.sh           # Generic CLI argument parser
│   ├── script_init.sh          # Creates log folder, records config
│   ├── terminate_qemu.sh       # Shuts down VMs + kills QEMU
│   ├── wait_util_vm_is_up.sh   # Polls until VM is pingable
│   ├── get_migration_details.sh# Polls migration-status.sh until "completed"
│   ├── get_system_usage.sh     # Streams CPU/mem usage from VM to log
│   ├── start_source_script.sh  # Starts source QEMU VM
│   ├── start_destination_script.sh  # Starts destination QEMU VM
│   └── trigger_migration.sh    # Sends migration command (plain/tls/ipsec/ssh)
│
├── ycsb.sh                     # Plain migration (no encryption)
├── ycsb_tls.sh                 # TLS-encrypted migration
├── ycsb_ipsec.sh               # IPsec migration (enables/disables strongSwan)
├── ycsb_ssh.sh                 # SSH tunnel migration
├── batchYCSB.sh                # Master batch runner
└── sample_ycsb_config.xml      # BenchBase YCSB config
```

---

## Quick Start

```bash
cd /mnt/nfs/aamir/Scripts/Migration/Automations/YCSB
chmod +x *.sh common_scripts/*.sh
```

### Run a single mode
```bash
./ycsb.sh         --type=precopy --ram_size=4096 --iterations=5
./ycsb_tls.sh     --type=precopy --ram_size=4096 --iterations=5
./ycsb_ipsec.sh   --type=precopy --ram_size=4096 --iterations=5
./ycsb_ssh.sh     --type=precopy --ram_size=4096 --iterations=5
```

### Run the full batch (all modes × all types × all sizes)
```bash
./batchYCSB.sh --rounds=10
```

### Run specific modes/types
```bash
./batchYCSB.sh --mode=ipsec --type=precopy --rounds=5
./batchYCSB.sh --mode=tls   --type=all     --rounds=3
./batchYCSB.sh --mode=all   --type=precopy --rounds=10 --optimization=/path/opt.sh
```

---

## Arguments

### Individual scripts (ycsb.sh, ycsb_tls.sh, ycsb_ipsec.sh, ycsb_ssh.sh)

| Flag | Default | Description |
|------|---------|-------------|
| `--vm_img` | `oltp` | VM image name |
| `--ram_size` | `1024` | RAM in MB |
| `--cores` | `1` | vCPU count |
| `--tap` | `tap0` | TAP network device |
| `--type` | `precopy` | `precopy`, `postcopy`, `hybrid`, or `all` |
| `--iterations` | `10` | Number of migration iterations |
| `--log` | timestamp | Log folder name |
| `--optimization` | _(none)_ | Path to optimization script |
| `--optimization_script_step` | _(none)_ | `source`, `destination`, or leave blank for both |

#### TLS only
| `--setup_certs` | `false` | Set `true` to auto-run cert setup |

#### IPsec only
| `--ipsec_manager` | `.../ipsec/ipsec_manager.sh` | Path to ipsec_manager.sh |

#### SSH only
| `--tunnel_port` | `4444` | Port for SSH tunnel |

### batchYCSB.sh

| Flag | Default | Description |
|------|---------|-------------|
| `--mode` | `all` | `plain`, `tls`, `ipsec`, `ssh`, or `all` |
| `--type` | `all` | `precopy`, `postcopy`, `hybrid`, or `all` |
| `--rounds` | `10` | Number of rounds (outer loop) |
| `--log` | timestamp | Shared log folder for entire batch |
| `--optimization` | _(none)_ | Optimization script (applied to all runs) |
| `--tunnel_port` | `4444` | SSH tunnel port (ssh mode only) |

---

## IPsec Notes

`ycsb_ipsec.sh` manages IPsec automatically per iteration:
1. **Disables** IPsec (clean state) before the run begins
2. **Enables** IPsec on **both** source and destination via `ipsec_manager.sh enable`
3. Verifies Security Associations are established
4. Runs the migration (IPsec is transparent — same trigger scripts as plain)
5. **Disables** IPsec on both machines after the run

---

## Log Structure

```
logs/<LOG_FOLDER>/
├── optimization.txt                      # Optimization script path (if used)
├── <type>_plain_<img>_<size>_<ts>_vm.txt        # Migration result
├── <type>_plain_<img>_<size>_<ts>_ycsb/         # YCSB output files
├── <type>_plain_<img>_<size>_<ts>_system_usage.log
├── <type>_tls_...
├── <type>_ipsec_...
└── <type>_ssh_...
```

---

## Infrastructure

| Role | IP |
|------|----|
| Source | 10.22.196.162 |
| Destination | 10.22.196.163 |
| Utility VM | 10.22.196.200 |
