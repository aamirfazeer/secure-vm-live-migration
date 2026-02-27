#!/bin/bash
# Script to compile and setup quicksort on the VM

VM_IP="10.22.196.250"
VM_PASS="vmpassword"

echo ">>> Compiling quicksort on VM..."

# Create the quicksort.c file on the VM and compile it
sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no root@$VM_IP << 'EOF'
# Create the quicksort source code
cat > /tmp/quicksort.c << 'EOC'
/* This program implements O(nlogn) quicksort using in-place partitioning.
 * This has been modified form the orginial quicksort to output number of operations per second  
 */
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/time.h>
#include <signal.h>
#include <sys/time.h>
#include <string.h>
#include <pthread.h>

int counter = 0;
pthread_mutex_t counter_lock;

void *timer_handler(void *signum){
    while (1) {
        static int num_sec = 1;
        printf("\nSecond: %d number of sorts: %d",num_sec++, counter);
        fflush(stdout);
        pthread_mutex_lock(&counter_lock);
        counter = 0;
        pthread_mutex_unlock(&counter_lock);
        sleep(1);
    }
}

#define UNIT int
unsigned long last = 0;
float percent = 0.0, curr;
unsigned long size;
int tofile = 0;

void reset() {
    percent = 0.0;
    last = 0;
}

void increase(int level) {
    curr = (double) last / (double) size * 100;
    if(curr - percent >= .25) {
        percent = curr;
        if(tofile)
            printf("\n%.2f%% pages: %ld", percent, last * sizeof(UNIT) / 4096);
        else
            printf("\r%.2f%% pages: %ld", percent, last * sizeof(UNIT) / 4096);
        if(level) printf(", Recursion level: %d", level);
        fflush(stdout);
    }
}

unsigned long partition(UNIT * e, unsigned long start, unsigned long stop) {
    UNIT temp;
    unsigned long   r = random() % (stop - start + 1) + start,
            x,
            i = start - 1,
            j;

    temp = e[stop];
    e[stop] = e[r];
    e[r] = temp;

    x = e[stop];

    for(j = start; j < stop; j++)
        if(e[j] <= x) {
            i++;
            temp = e[i];
            e[i] = e[j];
            e[j] = temp;
        }

    temp = e[i + 1];
    e[i + 1] = e[stop];
    e[stop] = temp;

    return i + 1;
}

void quicksort(UNIT * e, unsigned long start, unsigned long stop, int level) {
    unsigned long pivot;

    if(start >= stop) {
        last = start;
        return;
    }

    pivot = partition(e, start, stop);

    if(pivot)
        quicksort(e, start, pivot - 1, level + 1);
    quicksort(e, pivot + 1, stop, level + 1);
}

int main(int argc, char ** argv){
    
    pthread_mutex_init(&counter_lock, NULL);
    pthread_t tid;
    pthread_create(&tid, NULL, &timer_handler, NULL);

    while(1)
    {
        struct timeval one, two, diff;
        unsigned long pages = 1, j, offset = 0;
        UNIT * v;

        size = 2048 / sizeof(UNIT);

        if(argc > 2) {
            offset = atol(argv[1]);
            tofile = 1;
        }

        srandom(102);

        if(!(v = (UNIT *) malloc(size * sizeof(UNIT)))) {
            perror("malloc");
            return 1;
        }

        reset();
        int itr;
        gettimeofday(&one, NULL);
        for (itr = 0; itr < 1; itr++) {
            for(j = 0; j < size; ++j){
                v[j] = size -j;
                if (itr == 0) {
                    last++;
                }
            }
        }
        gettimeofday(&two, NULL);

        timersub(&two, &one, &diff);

        gettimeofday(&one, NULL);
        for (itr = 0; itr < 1; itr++) {
            reset();
            quicksort(v, 0, size - 1, 1);

            pthread_mutex_lock(&counter_lock);
            counter++;
            pthread_mutex_unlock(&counter_lock);
            
            // REMOVED: Individual timing output that was cluttering the logs
            // This was the line causing the unwanted output:
            // printf("\rcounter %d Final Time = %ld secs %ld usecs\n", ...);
        }
        free(v);
    }    

    return 0;
}
EOC

# Make sure we're in the right directory
mkdir -p /home/vmuser/Desktop
cd /home/vmuser/Desktop

# Remove old binary if exists
rm -f quicksort

# Compile the quicksort program
gcc -o quicksort /tmp/quicksort.c -lpthread -lm

if [ $? -eq 0 ]; then
    echo ">>> Compilation successful!"
    # Simple test without verbose output
    timeout 3 ./quicksort >/dev/null 2>&1 && echo ">>> Binary works correctly" || echo ">>> Binary test failed"
else
    echo ">>> Compilation failed!"
    exit 1
fi

EOF

echo ">>> Setup complete!"
