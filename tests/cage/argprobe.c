/* A compiled stand-in for an agent executable: drops the leading --options a cage recipe passes, then runs
   /bin/sh with the rest (-c PROG, or a script), like the zero-token suite's PROBE script. */
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  int i = 1;
  while (i < argc && strncmp(argv[i], "--", 2) == 0) i++;
  argv[i - 1] = "/bin/sh";
  execv("/bin/sh", argv + i - 1);
  return 127;
}
