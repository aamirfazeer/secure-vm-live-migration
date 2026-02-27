
#include <stdio.h>
#include <unistd.h> 
int main() {
    while (1) {
        printf("MyNameIsAamir\n");
        fflush(stdout); // Ensure it prints immediately
        usleep(500000); // Print roughly every 0.5 seconds
                       // Adjust sleep time as needed for readability
    }
    return 0;
}
