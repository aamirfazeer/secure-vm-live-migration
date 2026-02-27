# MRMPPLM SCRIPTS

## General Scripts
    
- `createVM.sh <name_of_vm_image>` :  Execute this script to Create a VM Image 
- `startSource.sh <name_of_vm_image> <name_of_tap_device>` :  Execute this script to Start the VM in the Source Host
- `startDestination.sh <name_of_vm_image> <name_of_tap_device>` :  Execute this script to Prepare the Destination Host to recieve the VM
- `tap.sh <mode> <name_of_tap_device>` :  Execute this script to Create `mode = c` or Remove `mode = r` a tap device.

## Images Scripts

- `dcp.sh <source_image> <name_for_copy/copies> <destination_folder> <number_of_copies>` :  Execute this script to copy VM image/s (Single or Multiple)
- `drm.sh <name_for_copy/copies> <number_of_copies>` :  Execute this script to remove VM image/s

## Migration Scripts

### Automations

***Idle***
- `ildeExperiment.sh <number_of_cores> <number_of_iterations>` :  Execute this script to migrate idle vm for each every migration method for given number of iterations

***Sysbench***
- `sysbenchExperiment.sh <number_of_cores> <number_of_iterations>` :  Execute this script to migrate cpu-intensive vm for each every migration method for given number of iterations

***Workingset***
- `workingsetExperiment.sh <number_of_cores> <number_of_iterations>` :  Execute this script to migrate memory-intensive vm for each every migration method for given number of iterations

### Triggers

***Pre-Copy***
- `precopy-vm-migrate.sh` :  Execute this script to start _Pre-copy Migration_

***Post-Copy***
- `postcopy-vm-migrate.sh` :  Execute this script to start _Post-copy Migration_

***Hybrid***
- `hybrid-precopy.sh` :  Execute this script to start _Pre-copy Rounds_
- `hybrid-postcopy.sh` :  Execute this script to start _Post-copy Rounds_

### Status

- `migration-status.sh` :  Execute this script in **Source** to get migration status

### Destination

- `postcopy-dst-ram.sh` :  Execute this script in **Destination** if the migration is **Post-Copy** or **Hybrid**