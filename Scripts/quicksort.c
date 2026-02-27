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
#undef DEBUG

int counter = 0; //global counter to counter number of operations
pthread_mutex_t counter_lock;

//hardik start
void *timer_handler(void *signum){
    while (1) {
        static int num_sec = 1;
        struct timeval tv;
        struct tm* ptm;
        char time_string[40];
        long milliseconds;

        // Get the current time
        gettimeofday(&tv, NULL);
        // Format the date and time, down to a single second
        ptm = localtime(&tv.tv_sec);
        strftime(time_string, sizeof(time_string), "%Y-%m-%d %H:%M:%S", ptm);
        // Compute milliseconds from microseconds
        milliseconds = tv.tv_usec / 1000;

        printf("\nSecond: %d number of sorts: %d, Current Time: %s.%03ld", num_sec++, counter, time_string, milliseconds);
        fflush(stdout);
        pthread_mutex_lock(&counter_lock);
        counter = 0;
        pthread_mutex_unlock(&counter_lock);
        sleep(1);
    }
}
//hardik end

#define UNIT int
unsigned long last = 0;
float percent = 0.0, curr;
unsigned long size;
int tofile = 0;
//int counter = 0; //global counter to counter number of operations

void reset() {
	percent = 0.0;
	last = 0;
}

void increase(int level) {
	int change = 0;

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
		//increase(level);
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
		//hardcoded no.pages to create
		struct timeval one, two, diff;
		unsigned long pages = 1, j, offset = 0;
		UNIT * v;

		size = 2048 / sizeof(UNIT);

		if(argc > 2) {
			offset = atol(argv[1]);
			tofile = 1;
		}

		srandom(102);
#ifdef DEBUG
		printf("Filling data array: ");
		fflush(stdout);
#endif
		if(!(v = (UNIT *) malloc(size * sizeof(UNIT)))) {
			perror("malloc");
			return 1;
		}
#ifdef DEBUG
		printf(" %d units, %lu pages, %lu MB\n",
				size, pages , size * sizeof(UNIT) / 1024 / 1024);
#endif
		reset();
		int itr;
		gettimeofday(&one, NULL);
		for (itr = 0; itr < 1; itr++) {
			for(j = 0; j < size; ++j){
				v[j] = size -j;                              
				// v[j] = random();
				//increase(0);
				if (itr == 0) {
					last++;
				}
			}
#ifdef DEBUG
			printf("itr %d completed-------\n",itr);
#endif		
		}
		gettimeofday(&two, NULL);

		timersub(&two, &one, &diff);
		if(diff.tv_sec)
#ifdef DEBUG
			printf("\rTime = %d secs %d usecs, bw: %d                                   \n",
					diff.tv_sec, diff.tv_usec,
					(size * sizeof(UNIT) - offset) / 1024 / 1024 * 8 / diff.tv_sec);
		fflush(stdout);
		printf("Sorting progress......\n");
#endif
		gettimeofday(&one, NULL);
		for (itr = 0; itr < 1; itr++) {
			reset();
			quicksort(v, 0, size - 1, 1);
#ifdef DEBUG
			printf("itr %d completed\n", itr);
#endif

			pthread_mutex_lock(&counter_lock);
			counter++;
			pthread_mutex_unlock(&counter_lock);
			gettimeofday(&two, NULL);
			timersub(&two, &one, &diff);

#ifdef DEBUG
			printf("\rcounter %d Final Time = %d secs %d usecs                                                   \n",
					counter,diff.tv_sec, diff.tv_usec);
#endif
		}
	}	

	return 0;
}




