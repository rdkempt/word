/* runstat: run a command, and print its wall time in ms, peak RSS in KB and exit
   status to stderr. bench.sh and scaling.sh use it because GNU time(1) isn't
   always installed. */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <sys/time.h>
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: runstat cmd [args...]\n"); return 2; }
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    pid_t pid = fork();
    if (pid == 0) { execvp(argv[1], argv + 1); _exit(127); }
    int status; struct rusage ru;
    wait4(pid, &status, 0, &ru);
    gettimeofday(&t1, NULL);
    double ms = (t1.tv_sec - t0.tv_sec) * 1000.0 + (t1.tv_usec - t0.tv_usec) / 1000.0;
    fprintf(stderr, "RUNSTAT %.3f %ld %d\n", ms, ru.ru_maxrss,
            WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status));
    return 0;
}
