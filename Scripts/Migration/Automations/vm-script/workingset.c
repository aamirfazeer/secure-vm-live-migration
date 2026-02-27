/*
 *This program implements a benchmark that dirty #pages to vary writable working set.
 *  Copyright 2016 Dinuni Fernando (dferna15@binghamton.edu)
 *  Copyright 2016 Hardik Bagdi (hbagdi1@binghamton.edu)
 *
 *
 */

#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>

int main(int argc, char ** argv){
	
	if(argv[1] == NULL){
		printf("\nGive size in MBs (<= than your RAM size)\n");
		return 1;	
	}
	int total_mb = atoi(argv[1]);

	// size of a page is supposed as 4kb constant		
	//calculate total pages
	unsigned long total_pages   = total_mb*256;
	
	// quantum: size to be skipped in terms of int*
	int quantum = 	4*1024 / sizeof(int);

	//allocate memory 
	int * array;
	if(!(array = malloc(total_pages*4*1024))) {
	        perror("malloc");
	 return 1;
	}
	
	//random number which will be written to mem
	//random pointer is random pointer inside of a page. so we dirty any random 4 bytes inside a page	
	int rand_no;
	int rand_pointer;

	//current page being dirtied inside the array	
	int page_no = 0;
  
	while(1)
	{
		page_no = 0;
		
		while(page_no < total_pages)
		{
			rand_no = rand() % 10000;
			rand_pointer = rand() % 1024;
			 array[page_no*quantum + rand_pointer] = rand_no;
			 array[page_no*quantum + rand() %1024] = rand_no;
			 array[page_no*quantum + rand() %1024] = rand_no;
			 array[page_no*quantum + rand() %1024] = rand_no;	
			page_no++;
		}	

	}	
	
	free(array);
	return 0;
}
