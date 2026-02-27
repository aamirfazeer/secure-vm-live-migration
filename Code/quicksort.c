#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <errno.h>

volatile sig_atomic_t migration_flag = 0;
long long total_sorts = 0;
char results_dir[256] = "/home/results";
char log_id[256] = "";
FILE *performance_log = NULL;
struct timeval start_time;

void signal_handler(int sig) {
    migration_flag = 1;
    printf("Migration signal received! Stopping benchmark and saving results...\n");
    fflush(stdout);
}

void swap(int* a, int* b) {
    int temp = *a;
    *a = *b;
    *b = temp;
}

int partition(int arr[], int low, int high) {
    int pivot = arr[high];
    int i = (low - 1);
    
    for (int j = low; j <= high - 1; j++) {
        if (arr[j] < pivot) {
            i++;
            swap(&arr[i], &arr[j]);
        }
    }
    swap(&arr[i + 1], &arr[high]);
    return (i + 1);
}

void quicksort(int arr[], int low, int high) {
    if (low < high) {
        int pi = partition(arr, low, high);
        quicksort(arr, low, pi - 1);
        quicksort(arr, pi + 1, high);
    }
}

void generate_random_array(int arr[], int size) {
    for (int i = 0; i < size; i++) {
        arr[i] = rand() % 100000;
    }
}

double get_elapsed_time() {
    struct timeval current_time;
    gettimeofday(&current_time, NULL);
    return (current_time.tv_sec - start_time.tv_sec) + 
           (current_time.tv_usec - start_time.tv_usec) / 1000000.0;
}

void log_performance(double elapsed_time, long long sorts) {
    if (performance_log != NULL) {
        fprintf(performance_log, "Time: %.2f seconds, Total Sorts: %lld, Rate: %.2f sorts/sec\n", 
                elapsed_time, sorts, sorts / elapsed_time);
        fflush(performance_log);
    }
}

void write_final_results() {
    char filepath[1024];
    snprintf(filepath, sizeof(filepath), "%s/%s_quicksort_results.txt", results_dir, log_id);
    
    printf("Writing final results to: %s\n", filepath);
    fflush(stdout);
    
    FILE *file = fopen(filepath, "w");
    if (file != NULL) {
        double total_time = get_elapsed_time();
        fprintf(file, "=== Quicksort Benchmark Results ===\n");
        fprintf(file, "Log ID: %s\n", log_id);
        fprintf(file, "Total Quicksorts Completed: %lld\n", total_sorts);
        fprintf(file, "Total Runtime: %.2f seconds\n", total_time);
        if (total_time > 0) {
            fprintf(file, "Average Rate: %.2f sorts/second\n", total_sorts / total_time);
        } else {
            fprintf(file, "Average Rate: N/A (runtime too short)\n");
        }
        fprintf(file, "Benchmark Ended: Migration Detected\n");
        fprintf(file, "Timestamp: %ld\n", time(NULL));
        fprintf(file, "\n=== Performance Timeline ===\n");
        fclose(file);
        
        // Append performance log to results if it exists
        char perf_log_path[1024];
        snprintf(perf_log_path, sizeof(perf_log_path), "%s/%s_performance.log", results_dir, log_id);
        
        FILE *perf_file = fopen(perf_log_path, "r");
        if (perf_file != NULL) {
            file = fopen(filepath, "a");
            if (file != NULL) {
                char buffer[1024];
                while (fgets(buffer, sizeof(buffer), perf_file)) {
                    fputs(buffer, file);
                }
                fclose(file);
            }
            fclose(perf_file);
        }
        
        printf("Results successfully written to: %s\n", filepath);
        fflush(stdout);
    } else {
        printf("Error: Could not write results to file: %s (errno: %d - %s)\n", 
               filepath, errno, strerror(errno));
        fflush(stdout);
    }
}

int create_directory(const char* path) {
    struct stat st = {0};
    if (stat(path, &st) == -1) {
        if (mkdir(path, 0755) == -1) {
            printf("Error creating directory %s: %s\n", path, strerror(errno));
            return -1;
        }
    }
    return 0;
}

int main(int argc, char *argv[]) {
    // Parse command line arguments
    if (argc < 2) {
        printf("Usage: %s <log_id> [results_directory]\n", argv[0]);
        return 1;
    }
    
    strncpy(log_id, argv[1], sizeof(log_id) - 1);
    log_id[sizeof(log_id) - 1] = '\0';
    
    if (argc >= 3) {
        strncpy(results_dir, argv[2], sizeof(results_dir) - 1);
        results_dir[sizeof(results_dir) - 1] = '\0';
    }
    
    // Create results directory
    if (create_directory(results_dir) != 0) {
        printf("Failed to create results directory: %s\n", results_dir);
        return 1;
    }
    
    // Open performance log file
    char perf_log_path[1024];
    snprintf(perf_log_path, sizeof(perf_log_path), "%s/%s_performance.log", results_dir, log_id);
    performance_log = fopen(perf_log_path, "w");
    if (performance_log != NULL) {
        fprintf(performance_log, "=== Quicksort Performance Log ===\n");
        fprintf(performance_log, "Log ID: %s\n", log_id);
        fprintf(performance_log, "Start Time: %ld\n", time(NULL));
        fprintf(performance_log, "Performance Data:\n");
        fflush(performance_log);
    } else {
        printf("Warning: Could not create performance log file: %s\n", perf_log_path);
    }
    
    // Set up signal handler for migration detection
    signal(SIGUSR1, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    
    printf("Starting Quicksort Benchmark (Log ID: %s)\n", log_id);
    printf("Results will be saved to: %s\n", results_dir);
    printf("Process ID: %d\n", getpid());
    printf("Send SIGUSR1 signal to stop and save results\n");
    fflush(stdout);
    
    srand(time(NULL));
    gettimeofday(&start_time, NULL);
    
    const int ARRAY_SIZE = 10000;
    int *arr = malloc(ARRAY_SIZE * sizeof(int));
    
    if (arr == NULL) {
        printf("Memory allocation failed\n");
        return 1;
    }
    
    // Continuous quicksort operations until migration signal
    while (!migration_flag) {
        generate_random_array(arr, ARRAY_SIZE);
        quicksort(arr, 0, ARRAY_SIZE - 1);
        total_sorts++;
        
        // Log performance every 100 sorts for more frequent updates
        if (total_sorts % 100 == 0) {
            double elapsed = get_elapsed_time();
            printf("Completed %lld sorts (%.2f sorts/sec)\n", 
                   total_sorts, elapsed > 0 ? total_sorts / elapsed : 0.0);
            fflush(stdout);
            log_performance(elapsed, total_sorts);
        }
        
        // Small delay to prevent overwhelming the CPU
        usleep(1000); // 1ms delay
    }
    
    printf("Total sorts completed: %lld\n", total_sorts);
    printf("Final elapsed time: %.2f seconds\n", get_elapsed_time());
    fflush(stdout);
    
  if (performance_log != NULL) {
        // Add a final entry before closing
        fprintf(performance_log, "End of Log. Total Sorts: %lld\n", total_sorts);
        fclose(performance_log);
        performance_log = NULL; 
    }

        // Write final results
    write_final_results();

    free(arr);
    printf("Quicksort benchmark completed successfully.\n");
    fflush(stdout);
    return 0;
}