.section .text.init
.global _start
.extern main

_start:
  li sp, 0x80010000
  jal ra, main

hang:
  j hang