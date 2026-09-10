/* Test-only driver for the unmodified MIT-licensed upstream fzy scorer. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "match.h"

int main(void) {
  char line[8192];
  while (fgets(line, sizeof(line), stdin)) {
    char *separator = strchr(line, '\t');
    if (!separator) return 2;
    *separator++ = '\0';
    separator[strcspn(separator, "\r\n")] = '\0';
    if (!has_match(line, separator)) {
      puts("-inf");
      continue;
    }
    size_t positions[MATCH_MAX_LEN] = {0};
    score_t score = match_positions(line, separator, positions);
    printf("%.17g", score);
    if (strlen(line) && strlen(line) <= strlen(separator) && strlen(separator) <= MATCH_MAX_LEN) {
      for (size_t index = 0; index < strlen(line); ++index) printf(" %zu", positions[index]);
    }
    putchar('\n');
  }
  return ferror(stdin) ? 1 : 0;
}
