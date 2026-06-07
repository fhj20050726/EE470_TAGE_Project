/*
#include <stdint.h>

volatile uint64_t sink = 0;

uint64_t branch_test(uint64_t n)
{
  uint64_t sum = 0;
  uint64_t hist = 0;

  for (uint64_t i = 0; i < n; i++) {

    if ((i & 1) == 0)
      sum += 3;
    else
      sum -= 1;

    if ((i & 7) != 0)
      sum += i;
    else
      sum -= i;

    hist = ((hist << 1) ^ i) & 31;

    if ((hist == 3) || (hist == 17))
      sum += 11;
    else
      sum -= 2;
  }

  return sum;
}

int main()
{
  sink = branch_test(50000);

  while (1) {
    asm volatile ("wfi");
  }

  return 0;
}
*/
/*
#include <stdint.h>

volatile uint64_t sink = 0;

void branch_kernel(void)
{
  uint64_t sum = 0;
  uint64_t lfsr = 0xACE1u;
  uint64_t hist = 0;

  for (uint64_t i = 0; i < 200000; i++) {

    // Generate pseudo-random history branch
    lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xD800000000000000ull);
    uint64_t b0 = lfsr & 1u;

    if (b0)
      sum += 3;
    else
      sum -= 1;

    hist = ((hist << 1) | b0) & 0xFFFFull;

    // Branch depends on older global history
    uint64_t b1 = (hist >> 11) & 1u;

    if (b1)
      sum += i;
    else
      sum -= i;

    // Another delayed-history branch
    uint64_t b2 = (hist >> 15) & 1u;

    if (b2)
      sum += 7;
    else
      sum -= 5;

    // Simple loop branch still exists naturally
  }

  sink = sum;

  while (1) {
    asm volatile ("nop");
  }
}

__attribute__((naked, section(".text.init")))
void _start(void)
{
  asm volatile (
    "li sp, 0x80010000\n"
    "j branch_kernel\n"
  );
}
*/
/*
#include <stdint.h>

volatile uint64_t sink = 0;

#define HIST_LEN 128

void branch_kernel(void)
{
  uint8_t hist[HIST_LEN];
  uint64_t sum = 0;

  for (int i = 0; i < HIST_LEN; i++)
    hist[i] = i & 1;

  for (uint64_t i = 0; i < 300000; i++) {

    // Outcome depends on OLD history entries
    uint8_t outcome =
      hist[(i - 17) & (HIST_LEN - 1)] ^
      hist[(i - 43) & (HIST_LEN - 1)] ^
      hist[(i - 71) & (HIST_LEN - 1)];

    if (outcome)
      sum += i;
    else
      sum -= i;

    hist[i & (HIST_LEN - 1)] = outcome;
  }

  sink = sum;

  while (1) {
    asm volatile ("nop");
  }
}

__attribute__((naked, section(".text.init")))
void _start(void)
{
  asm volatile (
    "li sp, 0x80010000\n"
    "j branch_kernel\n"
  );
}
*/


#include <stdint.h>

volatile uint64_t sink = 0;

#define ITERS 200000

#define DO_BRANCH(ID, A, B, C)                         \
  do {                                                  \
    uint64_t out = ((gh >> A) ^ (gh >> B) ^ (gh >> C)) & 1; \
    if (out)                                            \
      sum += (ID + i);                                  \
    else                                                \
      sum -= (ID + i);                                  \
    gh = ((gh << 1) | out) & 0xffffffffffffffffull;     \
  } while (0)

void branch_kernel(void)
{
  uint64_t sum = 0;
  uint64_t gh = 0x9e3779b97f4a7c15ull;

  for (uint64_t i = 0; i < ITERS; i++) {
    DO_BRANCH( 1,  5, 17, 41);
    DO_BRANCH( 2,  7, 23, 53);
    DO_BRANCH( 3, 11, 29, 47);
    DO_BRANCH( 4, 13, 31, 59);
    DO_BRANCH( 5,  3, 19, 61);
    DO_BRANCH( 6,  9, 27, 43);
    DO_BRANCH( 7, 15, 33, 55);
    DO_BRANCH( 8, 21, 37, 63);

    DO_BRANCH( 9,  6, 18, 42);
    DO_BRANCH(10,  8, 24, 54);
    DO_BRANCH(11, 12, 30, 48);
    DO_BRANCH(12, 14, 32, 60);
    DO_BRANCH(13,  4, 20, 62);
    DO_BRANCH(14, 10, 28, 44);
    DO_BRANCH(15, 16, 34, 56);
    DO_BRANCH(16, 22, 38, 58);
  }

  sink = sum;

  while (1) {
    asm volatile ("nop");
  }
}

__attribute__((naked, section(".text.init")))
void _start(void)
{
  asm volatile (
    "li sp, 0x80010000\n"
    "j branch_kernel\n"
  );
}
