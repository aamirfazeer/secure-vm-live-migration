#!/bin/bash

# Array of "tuples": --flag:VAR_NAME:default_value
ARG_TUPLES=(
  "--vnc:VNC_NUM:1"
  "--vm:VM:oltp"
  "--size:SIZE:8096"
  "--cores:CORES:1"
  "--tap:TAP:tap0"
  "--type:TYPE:precopy"
  "--iterations:ITERATIONS:10"
  "--log:LOG_FOLDER:$(date "+%Y%m%d_%H%M%S")"
)

# ------------------------------- Do not change --------------------------------------
# Initialize variables with defaults
for tuple in "${ARG_TUPLES[@]}"; do
  IFS=":" read -r FLAG VAR DEFAULT <<< "$tuple"
  declare "$VAR=$DEFAULT"
done

# Parse arguments
for ARG in "$@"; do
  KEY="${ARG%%=*}"   # --flag
  VALUE="${ARG#*=}"  # value
  MATCHED=false

  for tuple in "${ARG_TUPLES[@]}"; do
    IFS=":" read -r FLAG VAR DEFAULT <<< "$tuple"
    if [[ "$KEY" == "$FLAG" ]]; then
      declare "$VAR=$VALUE"
      MATCHED=true
      break
    fi
  done

  if ! $MATCHED; then
    echo "Unknown argument: $ARG"
    exit 1
  fi
done

# ------------------------------------------------------------------------------------

# Updated IP addresses
SOURCE_SERVER="10.22.192.155"
DESTINATION_SERVER="10.22.192.158" 
VM_IP="10.22.196.195"

LOG_ID=""
POST_COPYABLE=""
MIGRATION=""
QUICKSORT_PID=""

# SSH credentials (you may need to update these)
SOURCE_PASS="primedirective"
DEST_PASS="primedirective"
VM_PASS="vmpassword"

terminate-qemu () {
    echo ">>> Terminating VMs and cleaning up..."
    
    # Stop quicksort benchmark in VM if running
    if [[ -n $QUICKSORT_PID ]]; then
        sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@$VM_IP \
            "kill -USR1 $QUICKSORT_PID 2>/dev/null || true"
        sleep 2
        sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@$VM_IP \
            "pkill -f quicksort 2>/dev/null || true"
    fi
    
    # Shutdown VM gracefully
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=60 root@$VM_IP \
        "poweroff" > /dev/null 2>&1
	sleep 5

    # Kill QEMU processes on destination
	DESTINATION_CHECK=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_SERVER "pgrep qemu")
	if [[ -n $DESTINATION_CHECK ]]; then
		sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_SERVER "pkill qemu"
	fi
	sleep 5
	
	# Kill QEMU processes on source
	sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_SERVER "pkill qemu"
}

get_migration_details() {
	MIGRATION=""
	sleep 90

	MAX_RETRIES=10
	RETRY=0
	while [[ $MIGRATION != *"completed"* && $RETRY -lt $MAX_RETRIES ]]; do
		sleep 10
		echo ">>> Checking for Migration Status (Attempt $((RETRY + 1))/$MAX_RETRIES)"
		
		MIGRATION=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_SERVER \
			"bash /mnt/nfs/aamir/Scripts/Migration/Status/migration-status.sh")
		
		((RETRY++))
	done

	if [[ $MIGRATION == *"completed"* ]]; then
		echo ">>> Migration completed successfully."

		# Signal the quicksort benchmark to stop and save results
		if [[ -n $QUICKSORT_PID ]]; then
		    echo ">>> Stopping quicksort benchmark and collecting results..."
		    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
		        "kill -USR1 $QUICKSORT_PID"
		    sleep 5
		fi

		# Get the Quicksort Results from VM
		echo ">>> Retrieving quicksort results..."
		sshpass -p "$VM_PASS" rsync \
		    -e "ssh -o StrictHostKeyChecking=no" \
		    -av --progress --no-o --no-g \
		    "root@$VM_IP:/home/results/${LOG_ID}_quicksort_results.txt" \
		    "logs/${LOG_FOLDER}/" 2>/dev/null || echo "Warning: Could not retrieve quicksort results"

		# Write the Migration Details
		echo "$MIGRATION" > "logs/${LOG_FOLDER}/${LOG_ID}_migration.txt"
		
		# Create a combined results file
		create_combined_results
	else
		echo "Migration did not complete after $MAX_RETRIES attempts."
		# Still try to get quicksort results
		if [[ -n $QUICKSORT_PID ]]; then
		    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
		        "kill -USR1 $QUICKSORT_PID"
		fi
	fi
}

create_combined_results() {
    local combined_file="logs/${LOG_FOLDER}/${LOG_ID}_combined_results.txt"
    echo ">>> Creating combined results file: $combined_file"
    
    {
        echo "=== VM Migration and Quicksort Benchmark Results ==="
        echo "Log ID: $LOG_ID"
        echo "Migration Type: $TYPE"
        echo "VM: $VM"
        echo "VM Size: ${SIZE}MB"
        echo "VM Cores: $CORES"
        echo "Timestamp: $(date)"
        echo ""
        echo "=== Migration Details ==="
        if [[ -f "logs/${LOG_FOLDER}/${LOG_ID}_migration.txt" ]]; then
            cat "logs/${LOG_FOLDER}/${LOG_ID}_migration.txt"
        else
            echo "Migration details not available"
        fi
        echo ""
        echo "=== Quicksort Benchmark Results ==="
        if [[ -f "logs/${LOG_FOLDER}/${LOG_ID}_quicksort_results.txt" ]]; then
            cat "logs/${LOG_FOLDER}/${LOG_ID}_quicksort_results.txt"
        else
            echo "Quicksort results not available"
        fi
    } > "$combined_file"
}

if [ "$TYPE" = "precopy" ]; then
	POST_COPYABLE="false"
else
	POST_COPYABLE="true"
fi

# ---------------- Making Destination Ready  -------------------
start_destination() {
	echo ">>> Starting destination VM on $DESTINATION_SERVER"
	sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_SERVER \
	    "bash /mnt/nfs/ayash/Scripts/Migration/Automations/vm-start/startDestination.sh $VM tap0 $SIZE $CORES $POST_COPYABLE" &
	sleep 10
	DESTINATION_ID=$(sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_SERVER "pgrep qemu")

	if [[ -n $DESTINATION_ID ]]; then
		echo ">>> Destination VM Up & Running (PID: $DESTINATION_ID)"
	else
		echo ">>> Destination VM Not Started"
		exit 255       
	fi
}

# Starting the VM in Source Machine
start_source() {
	echo ">>> Starting source VM on $SOURCE_SERVER"
	sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_SERVER \
	    "bash /mnt/nfs/aamir/Scripts/General/startSource.sh --vm=$VM --size=$SIZE" &
	sleep 10
	SOURCE_ID=$(sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_SERVER "pgrep qemu")

	if [[ -n $SOURCE_ID ]]; then
		echo ">>> Source VM Up & Running (PID: $SOURCE_ID)"
	else
		echo ">>> Source VM Not Started"
		sshpass -p "$DEST_PASS" ssh -o StrictHostKeyChecking=no root@$DESTINATION_SERVER "pkill qemu"
		exit 255
	fi
}

# Setup quicksort benchmark in VM
setup_quicksort() {
    echo ">>> Setting up quicksort benchmark in VM"
    
    # Create results directory in VM
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
        "mkdir -p /home/results"
    
    # Copy quicksort binary to VM (assuming it's compiled and available)
    echo ">>> Copying quicksort binary to VM"
    sshpass -p "$VM_PASS" scp -o StrictHostKeyChecking=no \
        quicksort root@$VM_IP:/home/quicksort 2>/dev/null || {
        echo "Warning: Could not copy quicksort binary. Make sure it's compiled and available."
    }
    
    # Make it executable
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
        "chmod +x /home/quicksort"
}

# ----------------- Starting the Quicksort Workload -------------------
start_workload() {
	echo ">>> Starting Quicksort Benchmark in VM"
	sleep 10

	sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP \
	    "/home/quicksort $LOG_ID /home/results > /dev/null 2>&1 &"
	
	sleep 5

	QUICKSORT_PID=$(sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP "pgrep -f quicksort")

	if [[ -n $QUICKSORT_PID ]]; then
		printf ">>> Started Quicksort Benchmark in VM, Process ID: %s\n" $QUICKSORT_PID
	else
		echo ">>> Quicksort Benchmark Not Started"
		terminate-qemu
		exit 255
	fi
}

TRIGGERS=/mnt/nfs/aamir/Scripts/Migration/Triggers

trigger_migration() {
	echo ">>> Triggering Migration (Type: $TYPE)"

	if [ "$TYPE" = "precopy" ]; then
		sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_SERVER \
		    "bash $TRIGGERS/Pre-Copy/precopy-vm-migrate1.sh"
	elif [ "$TYPE" = "postcopy" ]; then
		sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_SERVER \
		    "bash $TRIGGERS/Post-Copy/postcopy-vm-migrate.sh"
	elif [ "$TYPE" = "hybrid" ]; then
		sshpass -p "$SOURCE_PASS" ssh -o StrictHostKeyChecking=no root@$SOURCE_SERVER \
		    "bash $TRIGGERS/Hybrid/hybrid-vm-migrate.sh"
	fi
}

# -------------------------------- Main Execution -----------------------------
# Create the logging folder if it doesn't exist
mkdir -p "logs/${LOG_FOLDER}"
echo ">>> Creating logs/${LOG_FOLDER} folder"

# Compile quicksort program
echo ">>> Compiling quicksort benchmark..."
gcc -o quicksort quicksort.c -O2 || {
    echo "Error: Could not compile quicksort.c"
    exit 1
}

terminate-qemu

for (( i=1; i<=$ITERATIONS; i++ )); do
	echo ">>> Starting Migration Iteration $i of $ITERATIONS"

	timestamp=$(date "+%Y%m%d_%H%M%S")
	LOG_ID="${TYPE}_${VM}_${SIZE}_${timestamp}_iter${i}"
	
	echo ">>> Log ID for this iteration: $LOG_ID"

	start_source
	start_destination
	setup_quicksort
	start_workload
	
	# Wait a bit for quicksort to start properly
	sleep 15
	
	trigger_migration
	get_migration_details
	terminate-qemu
	
	echo ">>> Iteration $i completed. Waiting before next iteration..."
	sleep 10
done

echo ">>> All iterations completed. Results saved in logs/${LOG_FOLDER}/"
