// Append 200-byte records to a fresh file with each sync policy; report per-append cost.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static double now_ms(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1e3 + t.tv_nsec / 1e6; }
static int cmp(const void *a, const void *b) { double x = *(double *)a, y = *(double *)b; return x < y ? -1 : x > y; }
int main(int argc, char **argv) {
    const char *names[] = {"write only", "F_BARRIERFSYNC", "F_FULLFSYNC"};
    int n = 400; char rec[200]; memset(rec, 'x', sizeof rec); rec[199] = '\n';
    for (int mode = 0; mode < 3; mode++) {
        char path[512]; snprintf(path, sizeof path, "%s/bench-%d.jsonl", argv[1], mode);
        unlink(path);
        int fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_APPEND, 0600);
        double *t = malloc(sizeof(double) * n);
        for (int i = 0; i < n; i++) {
            double s = now_ms();
            if (write(fd, rec, sizeof rec) != sizeof rec) { perror("write"); return 1; }
            if (mode == 1 && fcntl(fd, F_BARRIERFSYNC) != 0) { perror("barrier"); return 1; }
            if (mode == 2 && fcntl(fd, F_FULLFSYNC) != 0) { perror("full"); return 1; }
            t[i] = now_ms() - s;
        }
        close(fd); unlink(path);
        qsort(t, n, sizeof(double), cmp);
        printf("%-15s p50 %7.3f ms  p90 %7.3f ms  max %7.3f ms\n", names[mode], t[n / 2], t[n * 9 / 10], t[n - 1]);
        free(t);
    }
    return 0;
}
