/* This program implements O(nlogn) quicksort using in-place partitioning.
 * This has been modified form the orginial quicksort to output number of operations per second  
 * Copyright 2016 Dinuni Fernando (dferna15@binghamton.edu)
 * Copyright 2009 Michael R. Hines (michael@hinespot.net)
 * Copyright 2009 Kartik Gopalan (kartik@cs.binghamton.edu)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
/*This is the modified quick sort which has same input - which is worstcase */
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/time.h>
#include <signal.h>
#include <sys/time.h>
#include <string.h>
#include <pthread.h>

#define UNIT int

pthread_mutex_t counter_lock;
int counter = 0;
unsigned long size;
unsigned long last = 0;

void *timer_handler(void *signum){
	while (1) {
		static int num_sec = 1;
		printf("\nSecond: %d | Number of Sorts: %d",num_sec++, counter);
		fflush(stdout);
		pthread_mutex_lock(&counter_lock);
		counter = 0;
		pthread_mutex_unlock(&counter_lock);
		sleep(1);
	}
}

/* In-place partition the array */
unsigned long partition(UNIT * e, unsigned long start, unsigned long stop) {
        UNIT temp;
        /* Pick a random pivot */
        unsigned long   r = random() % (stop - start + 1) + start,
                        x,
                        i = start - 1,
                        j;

        /* Put the pivot at the end */
        temp = e[stop];
        e[stop] = e[r];
        e[r] = temp;

        x = e[stop];

        /* partition the array */
        for(j = start; j < stop; j++)
                if(e[j] <= x) {
                        i++;
                        temp = e[i];
                        e[i] = e[j];
                        e[j] = temp;
                }

        /* Put the pivot in the middle of the two halves */
        temp = e[i + 1];
        e[i + 1] = e[stop];
        e[stop] = temp;

        /* Return the location of the pivot */
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

	if(argc < 2) {
		printf("usage: %s <memory size : B>\n", argv[0]);
		return 0;
	}

	size = atoi(argv[1]) / sizeof(UNIT);
	printf("Array Size: %lu\n", size);

	int j;

	pthread_mutex_init(&counter_lock, NULL);
	pthread_t tid;
	pthread_create(&tid, NULL, &timer_handler, NULL);

	while(1)
	{
		struct timeval one, two, diff;
		UNIT * array;

		srandom(102);

		if(!(array = (UNIT *) malloc(size * sizeof(UNIT)))) {
			perror("malloc");
			return 1;
		}

		gettimeofday(&one, NULL);
		for(j = 0; j < size; ++j){
			array[j] = size - j;                              
			last++;
		}
		gettimeofday(&two, NULL);

		timersub(&two, &one, &diff);
		
		if(diff.tv_sec)
			gettimeofday(&one, NULL);

		quicksort(array, 0, size - 1, 1);
		pthread_mutex_lock(&counter_lock);
		counter++;
		pthread_mutex_unlock(&counter_lock);
		gettimeofday(&two, NULL);
		timersub(&two, &one, &diff);

		free(array);
	}	

	return 0;
}